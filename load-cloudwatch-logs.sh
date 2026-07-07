#!/usr/bin/env bash
#
# load-cloudwatch-logs.sh
#
# 用途:
#   交互式地从用户提供的一个 CloudWatch 日志组 ARN 下载全部日志事件，
#   自动翻页拉取所有日志流的日志，并打包成一个 zip 文件，方便离线归档与分享。
#
# 用法:
#   ./load-cloudwatch-logs.sh [--arn <log-group-arn>] [--hours <n>] \
#       [--out-dir <dir>] [--zip <file>]
#
# 参数:
#   --arn <arn>      CloudWatch 日志组 ARN。不提供时脚本会交互式提示输入。
#   --hours <n>      只拉取最近 n 小时日志；不提供或为 0 时拉取全部历史日志。
#   --out-dir <dir>  日志文件输出目录，默认脚本所在目录
#   --zip <file>     打包生成的 zip 文件路径，默认 ./cloudwatch-logs-<时间戳>.zip
#   -h, --help       显示帮助
#
# 依赖: aws cli v2(已配置凭证)、python3、zip。
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# 默认值
# ---------------------------------------------------------------------------
LOG_ARN=""
HOURS="0"
OUT_DIR="${SCRIPT_DIR}"
ZIP_FILE=""

usage() { sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# ---------------------------------------------------------------------------
# 解析参数
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arn)     LOG_ARN="$2"; shift 2;;
    --hours)   HOURS="$2"; shift 2;;
    --out-dir) OUT_DIR="$2"; shift 2;;
    --zip)     ZIP_FILE="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "未知参数: $1" >&2; usage; exit 1;;
  esac
done

# ---------------------------------------------------------------------------
# 依赖检查
# ---------------------------------------------------------------------------
if ! command -v python3 >/dev/null 2>&1; then
  echo "错误: 未找到 python3。" >&2; exit 1
fi
if ! command -v aws >/dev/null 2>&1; then
  echo "错误: 未找到 aws CLI，请先安装并配置凭证。" >&2; exit 1
fi
if ! command -v zip >/dev/null 2>&1; then
  echo "错误: 未找到 zip 命令，请先安装。" >&2; exit 1
fi

# ---------------------------------------------------------------------------
# 1. 获取日志组 ARN(参数优先，否则交互式提示)
# ---------------------------------------------------------------------------
if [[ -z "${LOG_ARN}" ]]; then
  echo "请输入 CloudWatch 日志组 ARN"
  echo "  (形如 arn:aws:logs:<region>:<account>:log-group:<name>[:*])"
  printf "ARN: "
  read -r LOG_ARN
fi

if [[ -z "${LOG_ARN}" ]]; then
  echo "错误: 未提供日志组 ARN。" >&2; exit 1
fi

# ---------------------------------------------------------------------------
# 工具函数: 从日志组 ARN 解析 region 与日志组名
#   ARN 形如 arn:aws:logs:<region>:<account>:log-group:<name>[:*]
# ---------------------------------------------------------------------------
arn_region()    { echo "$1" | cut -d: -f4; }
arn_log_group() {
  # 去掉前缀到 "log-group:" 之后的部分，并去掉结尾可能的 ":*"
  local rest="${1#*:log-group:}"
  rest="${rest%:\*}"
  echo "${rest}"
}

REGION="$(arn_region "${LOG_ARN}")"
LOG_GROUP="$(arn_log_group "${LOG_ARN}")"

if [[ -z "${REGION}" || -z "${LOG_GROUP}" || "${LOG_GROUP}" == "${LOG_ARN}" ]]; then
  echo "错误: 无法从 ARN 解析 region 与日志组名，请检查格式。" >&2
  echo "      期望形如: arn:aws:logs:<region>:<account>:log-group:<name>[:*]" >&2
  exit 1
fi

echo "==> 日志组: region=${REGION} log-group=${LOG_GROUP}"

# 计算起始时间(毫秒)。HOURS 为 0 时表示拉取全部历史(START_MS=0)
if [[ "${HOURS}" == "0" ]]; then
  START_MS="0"
  echo "    时间范围: 全部历史日志"
elif date -u -d "@0" >/dev/null 2>&1; then
  START_MS="$(( ( $(date -u +%s) - HOURS * 3600 ) * 1000 ))"
  echo "    时间范围: 最近 ${HOURS} 小时"
else
  START_MS="$(python3 -c "import time,sys; print(int((time.time()-int(sys.argv[1])*3600)*1000))" "${HOURS}")"
  echo "    时间范围: 最近 ${HOURS} 小时"
fi

# ---------------------------------------------------------------------------
# 2. 输出文件路径(默认直接放在脚本所在目录)
# ---------------------------------------------------------------------------
mkdir -p "${OUT_DIR}"

RAW_JSON="${OUT_DIR}/events.json"
TEXT_LOG="${OUT_DIR}/events.log"

# ---------------------------------------------------------------------------
# 3. 从 CloudWatch 拉取全部日志(自动翻页)
# ---------------------------------------------------------------------------
python3 - "${REGION}" "${LOG_GROUP}" "${START_MS}" "${RAW_JSON}" "${TEXT_LOG}" <<'PYEOF'
import json, subprocess, sys, datetime
region, log_group, start_ms, out_json, out_txt = sys.argv[1:6]
is_tty = sys.stderr.isatty()


def run_page(next_token):
    """调用一次 filter-log-events，返回 (events, nextToken)。"""
    cmd = ["aws", "logs", "filter-log-events",
           "--region", region, "--log-group-name", log_group,
           "--start-time", start_ms, "--output", "json"]
    if next_token:
        cmd += ["--next-token", next_token]
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, check=True)
    except subprocess.CalledProcessError as e:
        if is_tty:
            sys.stderr.write("\n")
        sys.stderr.write((e.stderr or "filter-log-events 调用失败\n"))
        sys.exit(1)
    data = json.loads(res.stdout or "{}")
    return data.get("events", []), data.get("nextToken")


def show(msg, newline=False):
    if is_tty and not newline:
        sys.stderr.write("\r\033[K" + msg)
    else:
        sys.stderr.write(msg + "\n")
    sys.stderr.flush()


# ---------------------------------------------------------------------------
# 阶段一: 预统计——先翻页数一遍，算出总页数与总事件数
# ---------------------------------------------------------------------------
sys.stderr.write("==> 统计日志总量(预扫描) ...\n")
total_pages, total_events, token = 0, 0, None
while True:
    evs, token = run_page(token)
    total_pages += 1
    total_events += len(evs)
    show("  扫描中: 已统计 %d 页, %d 条事件 ..." % (total_pages, total_events))
    if not token:
        break
show("  共需拉取 %d 条事件, 分 %d 页。" % (total_events, total_pages), newline=True)

# ---------------------------------------------------------------------------
# 阶段二: 实际拉取——带实时进度
# ---------------------------------------------------------------------------
sys.stderr.write("==> 拉取日志中(自动翻页) ...\n")
events, page, token = [], 0, None
while True:
    evs, token = run_page(token)
    for ev in evs:
        events.append({
            "timestamp": ev.get("timestamp"),
            "logStreamName": ev.get("logStreamName"),
            "message": ev.get("message"),
        })
    page += 1
    pct = (len(events) * 100 // total_events) if total_events else 100
    show("  进度: %d/%d 页, %d/%d 条 (%d%%) ..." % (page, total_pages, len(events), total_events, pct))
    if not token:
        break
show("  拉取完成, 共 %d 条日志事件。" % len(events), newline=True)

# 完整 JSON(便于程序化处理)
with open(out_json, "w", encoding="utf-8") as f:
    json.dump({"logGroup": log_group, "region": region, "events": events},
              f, ensure_ascii=False, indent=2)


# 可读文本(按时间排序，每行一条)
def fmt(ts):
    if ts is None:
        return "-"
    dt = datetime.datetime.fromtimestamp(ts / 1000.0, datetime.timezone.utc)
    return dt.strftime("%Y-%m-%d %H:%M:%S.%f")[:-3] + "Z"


with open(out_txt, "w", encoding="utf-8") as f:
    for ev in sorted(events, key=lambda e: e.get("timestamp") or 0):
        f.write("%s\t%s\t%s\n" % (fmt(ev.get("timestamp")),
                                  ev.get("logStreamName") or "-",
                                  (ev.get("message") or "").rstrip("\n")))
PYEOF

# 统计事件数
EVENT_COUNT="$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1])).get('events',[])))" "${RAW_JSON}" 2>/dev/null || echo 0)"

if [[ "${EVENT_COUNT}" == "0" ]]; then
  echo ""
  echo "⚠️  提示: 未拉取到任何日志事件，zip 内容会是空的。"
  echo "    可能原因与排查:"
  echo "      1) 该时间范围内没有日志 → 使用更大范围, 例如 --hours 720，或不带 --hours 拉取全部"
  echo "      2) 日志组名/区域与实际不符 → 核对提供的 ARN"
  echo "      3) 当前 AWS 身份无该日志组的 logs:FilterLogEvents 权限 → 检查凭证/权限"
  echo ""
fi

# ---------------------------------------------------------------------------
# 4. 打包成 zip
# ---------------------------------------------------------------------------
if [[ -z "${ZIP_FILE}" ]]; then
  TS="$(date -u +%Y%m%d-%H%M%S)"
  ZIP_FILE="${SCRIPT_DIR}/cloudwatch-logs-${TS}.zip"
fi

echo "==> 打包日志到 zip: ${ZIP_FILE}"
# 只打包本次生成的两个日志文件，避免把目录里其它文件一起打包进去
( cd "${OUT_DIR}" && zip -q "${ZIP_FILE}" "$(basename "${RAW_JSON}")" "$(basename "${TEXT_LOG}")" )

echo ""
echo "==================================================================="
echo "完成！"
echo "  事件数量 : ${EVENT_COUNT}"
echo "  日志文件 : ${RAW_JSON}"
echo "             ${TEXT_LOG}"
echo "  Zip 文件 : ${ZIP_FILE}"
echo "==================================================================="
