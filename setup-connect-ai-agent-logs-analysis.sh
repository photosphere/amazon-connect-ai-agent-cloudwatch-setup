#!/usr/bin/env bash
#
# setup-connect-ai-agent-logs-analysis.sh
#
# 用途:
#   从配置文件 config.env 指定的两个 CloudWatch 日志组 ARN 拉取日志:
#     1) Amazon Connect AI Agent 日志
#     2) Bedrock AgentCore Gateway 应用日志
#   解析并按 Contact ID 关联成可视化时间线，生成静态 HTML 页面，并本地预览，
#   便于按某次通话/聊天快速排查会话编排、LLM 调用、(网关)工具调用、转人工与错误。
#
# 用法:
#   ./setup-connect-ai-agent-logs-analysis.sh [--log-file <file>] [--config <file>] \
#       [--hours <n>] [--out-dir <dir>] [--no-serve] [--port <n>]
#
# 参数:
#   --log-file <f>   直接加载本地 Connect AI Agent 日志文件(可含相对目录)，跳过下载；
#                    留空则从 config.env 读取 ARN 下载。不带该参数时会交互式询问。
#   --gateway-file <f> 本地 Bedrock AgentCore Gateway 日志文件(可选，仅本地模式生效)，
#                    与 --log-file 搭配可做跨源关联；不提供则只展示 Connect 一路。
#   --config <file>  配置文件路径，默认 ./config.env
#   --hours <n>      拉取最近 n 小时日志，默认 24
#   --out-dir <dir>  站点构建输出目录，默认 ./dist
#   --no-serve       只构建，不启动本地预览
#   --port <n>       本地预览端口，默认 8080
#   -h, --help       显示帮助
#
# 两种数据来源(二选一):
#   A) 提供 --log-file(或交互式输入)  -> 直接加载并解析该本地日志文件, 不下载。
#      可再用 --gateway-file 传入 Gateway 本地日志做跨源关联。
#      支持 load-cloudwatch-logs.sh 生成的 events.log / events.json。
#   B) 留空                            -> 从 config.env 读取以下两个变量并下载:
#        CONNECT_AI_AGENT_LOG_ARN            Connect AI Agent 日志组 ARN
#        BEDROCK_AGENTCORE_GATEWAY_LOG_ARN   AgentCore Gateway 日志组 ARN
#
# 依赖: python3；方式 B(下载)还需 aws cli v2(已配置凭证)。
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
WEB_DIR="${LIB_DIR}/web"
PARSER="${LIB_DIR}/parse-connect-ai-logs.py"

# ---------------------------------------------------------------------------
# 默认值
# ---------------------------------------------------------------------------
CONFIG_FILE="${SCRIPT_DIR}/config.env"
LOG_FILE=""
GATEWAY_FILE=""
HOURS="24"
OUT_DIR="${SCRIPT_DIR}/dist"
SERVE="true"
PORT="8080"

usage() { sed -n '2,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# ---------------------------------------------------------------------------
# 解析参数
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --log-file)    LOG_FILE="$2"; shift 2;;
    --gateway-file) GATEWAY_FILE="$2"; shift 2;;
    --config)   CONFIG_FILE="$2"; shift 2;;
    --hours)    HOURS="$2"; shift 2;;
    --out-dir)  OUT_DIR="$2"; shift 2;;
    --no-serve) SERVE="false"; shift;;
    --port)     PORT="$2"; shift 2;;
    -h|--help)  usage; exit 0;;
    *) echo "未知参数: $1" >&2; usage; exit 1;;
  esac
done

# ---------------------------------------------------------------------------
# 依赖检查(aws CLI 仅在需要下载时才检查)
# ---------------------------------------------------------------------------
if ! command -v python3 >/dev/null 2>&1; then
  echo "错误: 未找到 python3。" >&2; exit 1
fi
if [[ ! -f "${PARSER}" ]]; then
  echo "错误: 找不到解析脚本 ${PARSER}" >&2; exit 1
fi

# ---------------------------------------------------------------------------
# 选择数据来源: 本地日志文件 或 从 config.env 下载
#   未通过 --log-file 指定时，交互式询问(直接回车表示走下载)。
# ---------------------------------------------------------------------------
if [[ -z "${LOG_FILE}" ]]; then
  echo "请输入本地 Connect AI Agent 日志文件路径(可含相对目录)。"
  echo "  例如: cloudwatch-logs-20260707-021617/events.log"
  echo "  直接回车 = 不用本地文件，改为从 config.env 读取 ARN 下载。"
  printf "Connect 日志文件: "
  read -r LOG_FILE
  # 若交互式给了 Connect 本地文件，再可选地询问 Gateway 本地文件
  if [[ -n "${LOG_FILE}" && -z "${GATEWAY_FILE}" ]]; then
    echo "请输入本地 Bedrock AgentCore Gateway 日志文件路径(可选，直接回车跳过)。"
    printf "Gateway 日志文件: "
    read -r GATEWAY_FILE
  fi
fi

# ---------------------------------------------------------------------------
# 1. 准备站点构建目录(两种来源都需要)
# ---------------------------------------------------------------------------
echo "==> 准备站点构建目录: ${OUT_DIR}"
mkdir -p "${OUT_DIR}"
cp "${WEB_DIR}/index.html" "${OUT_DIR}/"
cp "${WEB_DIR}/app.js" "${OUT_DIR}/"
cp "${WEB_DIR}/i18n.js" "${OUT_DIR}/"
cp "${WEB_DIR}/site-config.js" "${OUT_DIR}/"
# 可选的 Amazon Connect 补充数据; 不存在则生成空桩, 避免页面 404
if [[ -f "${WEB_DIR}/connect-enrich.js" ]]; then
  cp "${WEB_DIR}/connect-enrich.js" "${OUT_DIR}/"
elif [[ ! -f "${OUT_DIR}/connect-enrich.js" ]]; then
  echo "window.__CONNECT_CONTACT_ENRICH__ = {};" > "${OUT_DIR}/connect-enrich.js"
fi

if [[ -n "${LOG_FILE}" ]]; then
  # =========================================================================
  # 来源 A: 直接加载本地日志文件(不下载、不读取 config.env)
  # =========================================================================
  # 解析路径: 依次尝试 原样(相对当前目录) / 相对脚本目录
  if [[ -f "${LOG_FILE}" ]]; then
    RESOLVED_LOG="${LOG_FILE}"
  elif [[ -f "${SCRIPT_DIR}/${LOG_FILE}" ]]; then
    RESOLVED_LOG="${SCRIPT_DIR}/${LOG_FILE}"
  else
    echo "错误: 找不到日志文件 ${LOG_FILE}" >&2
    echo "      支持相对当前目录或相对脚本目录的路径。" >&2
    exit 1
  fi

  echo "==> 使用本地 Connect 日志文件: ${RESOLVED_LOG}"

  # 可选: 解析 Gateway 本地日志文件(同样支持相对当前目录/相对脚本目录)
  PARSER_ARGS=(--connect "${RESOLVED_LOG}")
  if [[ -n "${GATEWAY_FILE}" ]]; then
    if [[ -f "${GATEWAY_FILE}" ]]; then
      RESOLVED_GW="${GATEWAY_FILE}"
    elif [[ -f "${SCRIPT_DIR}/${GATEWAY_FILE}" ]]; then
      RESOLVED_GW="${SCRIPT_DIR}/${GATEWAY_FILE}"
    else
      echo "错误: 找不到 Gateway 日志文件 ${GATEWAY_FILE}" >&2
      echo "      支持相对当前目录或相对脚本目录的路径。" >&2
      exit 1
    fi
    echo "==> 使用本地 Gateway 日志文件: ${RESOLVED_GW}"
    PARSER_ARGS+=(--gateway "${RESOLVED_GW}")
  fi

  echo "==> 解析日志 -> data.js"
  python3 "${PARSER}" \
    "${PARSER_ARGS[@]}" \
    --out "${OUT_DIR}/data.js"

  echo "==> 站点已构建到: ${OUT_DIR}"

  # 统计解析出的事件数，为 0 时给出提示
  DATA_COUNT="$(python3 -c "import json,sys,re; t=open(sys.argv[1],encoding='utf-8').read(); m=re.search(r'=\s*(\[.*\]);\s*$', t, re.S); print(len(json.loads(m.group(1))) if m else 0)" "${OUT_DIR}/data.js" 2>/dev/null || echo 0)"
  if [[ "${DATA_COUNT}" == "0" ]]; then
    echo ""
    echo "⚠️  提示: 从 ${RESOLVED_LOG} 未解析出任何事件，页面会是空的。"
    echo "    请确认该文件是 load-cloudwatch-logs.sh 生成的 events.log / events.json，"
    echo "    或 filter-log-events 的 JSON / 控制台导出的 CSV。"
    echo ""
  fi

else
  # =========================================================================
  # 来源 B: 从 config.env 读取 ARN 并下载
  # =========================================================================
  if ! command -v aws >/dev/null 2>&1; then
    echo "错误: 未找到 aws CLI，下载模式需要 aws CLI(已配置凭证)。" >&2
    echo "      若只想加载本地文件，请用 --log-file 指定或按提示输入路径。" >&2
    exit 1
  fi

  # ------ 读取配置文件 ------
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "错误: 找不到配置文件 ${CONFIG_FILE}" >&2
    echo "      请参考 config.env 提供 CONNECT_AI_AGENT_LOG_ARN 与 BEDROCK_AGENTCORE_GATEWAY_LOG_ARN。" >&2
    exit 1
  fi
  echo "==> 读取配置: ${CONFIG_FILE}"
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"

  CONNECT_ARN="${CONNECT_AI_AGENT_LOG_ARN:-}"
  GATEWAY_ARN="${BEDROCK_AGENTCORE_GATEWAY_LOG_ARN:-}"

  if [[ -z "${CONNECT_ARN}" ]]; then
    echo "错误: 配置文件缺少 CONNECT_AI_AGENT_LOG_ARN。" >&2; exit 1
  fi
  if [[ -z "${GATEWAY_ARN}" ]]; then
    echo "错误: 配置文件缺少 BEDROCK_AGENTCORE_GATEWAY_LOG_ARN。" >&2; exit 1
  fi

  # ------ 从日志组 ARN 解析 region 与日志组名 ------
  #   ARN 形如 arn:aws:logs:<region>:<account>:log-group:<name>[:*]
  arn_region()    { echo "$1" | cut -d: -f4; }
  arn_log_group() {
    local rest="${1#*:log-group:}"
    rest="${rest%:\*}"
    echo "${rest}"
  }

  CONNECT_REGION="$(arn_region "${CONNECT_ARN}")"
  CONNECT_LG="$(arn_log_group "${CONNECT_ARN}")"
  GATEWAY_REGION="$(arn_region "${GATEWAY_ARN}")"
  GATEWAY_LG="$(arn_log_group "${GATEWAY_ARN}")"

  echo "    Connect : region=${CONNECT_REGION} log-group=${CONNECT_LG}"
  echo "    Gateway : region=${GATEWAY_REGION} log-group=${GATEWAY_LG}"

  # 计算起始时间(毫秒)
  if date -u -d "@0" >/dev/null 2>&1; then
    START_MS="$(( ( $(date -u +%s) - HOURS * 3600 ) * 1000 ))"
  else
    START_MS="$(python3 -c "import time,sys; print(int((time.time()-int(sys.argv[1])*3600)*1000))" "${HOURS}")"
  fi

  # ------ 从 CloudWatch 拉取两路日志(自动翻页) ------
  fetch_log_group() {
    # $1=region $2=log-group $3=输出json路径
    python3 - "$1" "$2" "${START_MS}" "$3" <<'PYEOF'
import json, subprocess, sys
region, log_group, start_ms, out = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
events, next_token = [], None
while True:
    cmd = ["aws", "logs", "filter-log-events",
           "--region", region, "--log-group-name", log_group,
           "--start-time", start_ms, "--output", "json"]
    if next_token:
        cmd += ["--next-token", next_token]
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, check=True)
    except subprocess.CalledProcessError as e:
        sys.stderr.write((e.stderr or "filter-log-events 调用失败\n"))
        sys.exit(1)
    data = json.loads(res.stdout or "{}")
    for ev in data.get("events", []):
        events.append({"timestamp": ev.get("timestamp"), "message": ev.get("message")})
    next_token = data.get("nextToken")
    if not next_token:
        break
with open(out, "w", encoding="utf-8") as f:
    json.dump({"events": events}, f, ensure_ascii=False)
sys.stderr.write("  拉取 %d 条 (%s)\n" % (len(events), log_group))
PYEOF
  }

  CONNECT_JSON="${OUT_DIR}/_connect.json"
  GATEWAY_JSON="${OUT_DIR}/_gateway.json"

  echo "==> 拉取 Connect AI Agent 日志(最近 ${HOURS} 小时) ..."
  fetch_log_group "${CONNECT_REGION}" "${CONNECT_LG}" "${CONNECT_JSON}"

  echo "==> 拉取 AgentCore Gateway 日志(最近 ${HOURS} 小时) ..."
  fetch_log_group "${GATEWAY_REGION}" "${GATEWAY_LG}" "${GATEWAY_JSON}"

  # ------ 解析 + 关联 -> data.js ------
  echo "==> 解析并关联两路日志 -> data.js"
  python3 "${PARSER}" \
    --connect "${CONNECT_JSON}" \
    --gateway "${GATEWAY_JSON}" \
    --out "${OUT_DIR}/data.js"

  # 统计两路事件数(从临时 JSON 里数)，都为 0 时给出明确提示
  CONNECT_COUNT="$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1])).get('events',[])))" "${CONNECT_JSON}" 2>/dev/null || echo 0)"
  GATEWAY_COUNT="$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1])).get('events',[])))" "${GATEWAY_JSON}" 2>/dev/null || echo 0)"

  rm -f "${CONNECT_JSON}" "${GATEWAY_JSON}"

  echo "==> 站点已构建到: ${OUT_DIR}"

  if [[ "${CONNECT_COUNT}" == "0" && "${GATEWAY_COUNT}" == "0" ]]; then
    echo ""
    echo "⚠️  提示: 最近 ${HOURS} 小时两个日志组都没有日志，页面会是空的。"
    echo "    可能原因与排查:"
    echo "      1) 该时间范围内没有真实会话 → 加大时间范围, 例如 --hours 168"
    echo "      2) 日志组名/区域与实际不符 → 核对 ${CONFIG_FILE} 里的两个 ARN"
    echo "      3) 当前 AWS 身份无该日志组的 logs:FilterLogEvents 权限 → 检查凭证/权限"
    echo "    手动验证示例:"
    echo "      aws logs tail \"${CONNECT_LG}\" --region ${CONNECT_REGION} --since ${HOURS}h"
    echo ""
  fi
fi

# ---------------------------------------------------------------------------
# 5. 本地预览
# ---------------------------------------------------------------------------
if [[ "${SERVE}" == "true" ]]; then
  # 端口被占用时自动向后探测一个空闲端口，避免直接崩溃
  port_in_use() {
    if command -v lsof >/dev/null 2>&1; then
      lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
    else
      python3 -c "import socket,sys; s=socket.socket(); r=s.connect_ex(('127.0.0.1',int(sys.argv[1]))); s.close(); sys.exit(0 if r==0 else 1)" "$1"
    fi
  }

  TRY_PORT="${PORT}"
  ATTEMPTS=0
  while port_in_use "${TRY_PORT}" && [[ ${ATTEMPTS} -lt 20 ]]; do
    echo "    端口 ${TRY_PORT} 已被占用，尝试 $((TRY_PORT + 1)) ..."
    TRY_PORT=$((TRY_PORT + 1))
    ATTEMPTS=$((ATTEMPTS + 1))
  done

  if port_in_use "${TRY_PORT}"; then
    echo "错误: 未能在 ${PORT}~${TRY_PORT} 找到空闲端口。" >&2
    echo "      请用 --port 指定其它端口，或释放被占用的端口。" >&2
    exit 1
  fi

  echo ""
  echo "==> 启动本地预览服务器: http://localhost:${TRY_PORT}"
  echo "    (通过 lib/serve.py 提供静态站点 + /api 接口: 按需翻译、DescribeContact 实时查询)"
  echo "    按 Ctrl+C 退出。"
  SERVE_PY="${LIB_DIR}/serve.py"
  if [[ -f "${SERVE_PY}" ]]; then
    # serve.py 会在缺少 aws CLI / 凭证时自动降级(隐藏对应功能)，可安全启动
    exec python3 "${SERVE_PY}" --dir "${OUT_DIR}" --port "${TRY_PORT}"
  else
    # 兜底: 纯静态预览(无 /api 接口，翻译与 DescribeContact 实时查询不可用)
    cd "${OUT_DIR}"
    exec python3 -m http.server "${TRY_PORT}"
  fi
else
  echo ""
  echo "==================================================================="
  echo "构建完成！本地预览方式(推荐, 含 /api 接口: 翻译 + DescribeContact 实时查询):"
  echo "  python3 \"${LIB_DIR}/serve.py\" --dir \"${OUT_DIR}\" --port ${PORT}"
  echo "或纯静态预览(无 /api 接口):"
  echo "  cd \"${OUT_DIR}\" && python3 -m http.server ${PORT}"
  echo "  然后浏览器访问 http://localhost:${PORT}"
  echo "==================================================================="
fi
