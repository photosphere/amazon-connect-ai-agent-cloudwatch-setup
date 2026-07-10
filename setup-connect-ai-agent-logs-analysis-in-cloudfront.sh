#!/usr/bin/env bash
#
# setup-connect-ai-agent-logs-analysis-in-cloudfront.sh
#
# 用途:
#   参考 setup-connect-ai-agent-logs-analysis.sh，但不再本地预览，而是把
#   日志排查 Web 应用部署到 Amazon CloudFront，并用 Amazon Cognito 做登录鉴权。
#
#   流程概览(全程不在本地处理任何日志文件):
#     1) 创建日志桶 "ai-agent-logs<suffix>"(不存在则自动创建)，并为其配置 S3 事件通知,
#        关联一个 Lambda 函数负责在云端解析原始日志;
#     2) 把 CONNECT_AI_AGENT_LOG_ARN (必选) 与 BEDROCK_AGENTCORE_GATEWAY_LOG_ARN (可选)
#        的全部日志以 NDJSON 流式"直传"到日志桶的 raw/ 前缀(原始数据长期保存),
#        随后写入触发对象; S3 事件触发 Lambda 按 Contact ID 拆分, 生成
#        "<contactId>.log" 与 index.json 写回同一个桶;
#     3) 把 Web 应用发布到独立的 S3 桶并经 CloudFront(OAC) 对外提供;
#        登录成功的用户经 Cognito Identity Pool 换取临时凭证，直接从
#        "ai-agent-logs<suffix>" 桶加载全部日志渲染页面;
#     4) 用用户提供的邮箱创建 Cognito 用户，Cognito 会把一次性密码发到该邮箱;
#        首次用一次性密码登录后强制重置密码;登录页提供"忘记密码"，
#        点击后向该邮箱发送新的一次性验证码用于重置。
#
# 用法:
#   ./setup-connect-ai-agent-logs-analysis-in-cloudfront.sh \
#       [--connect-arn <arn>] [--gateway-arn <arn>] [--email <addr>] \
#       [--suffix <s>] [--region <r>] [--hours <n>] [--profile <p>] \
#       [--out-dir <dir>] [--keep] [--lambda-memory <MB>] [-h|--help]
#
# 参数(未提供的必选项会交互式询问):
#   --connect-arn <arn>  Connect AI Agent 日志组 ARN            [必选]
#   --gateway-arn <arn>  Bedrock AgentCore Gateway 日志组 ARN    [可选]
#   --email <addr>       登录用户邮箱(接收一次性密码)             [必选]
#   --suffix <s>         桶名后缀; 日志桶为 ai-agent-logs<suffix> [必选]
#   --region <r>         部署区域; 默认取自 connect-arn
#   --hours <n>          仅拉取最近 n 小时; 0 或不填=全部历史     [默认 0]
#   --profile <p>        AWS CLI profile
#   --out-dir <dir>      放临时部署产物的目录; 默认系统临时目录(/tmp)
#   --keep               保留临时产物目录(默认结束后自动清理)
#   --lambda-memory <MB> 解析 Lambda 内存; 默认 3008; 日志量大时调大(如 8192/10240)
#   -h, --help           显示帮助
#
# 依赖: aws cli v2(已配置凭证)、python3。
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
WEB_DIR="${LIB_DIR}/web"
WEB_CF_DIR="${LIB_DIR}/web-cloudfront"
FETCHER="${LIB_DIR}/fetch-to-s3.py"
LAMBDA_HANDLER="${LIB_DIR}/lambda/handler.py"
PARSER_MODULE="${LIB_DIR}/parse-connect-ai-logs.py"

# ---------------------------------------------------------------------------
# 默认值
# ---------------------------------------------------------------------------
CONNECT_ARN=""
GATEWAY_ARN=""
EMAIL=""
SUFFIX=""
REGION=""
HOURS="0"
PROFILE=""
OUT_DIR=""
KEEP="false"
# 解析用 Lambda 的内存(MB)。内存同时决定分配到的 CPU，越大解析越快、越不易 OOM;
# 日志量很大(如 >100MB)时可调大，例如 --lambda-memory 6144 / 8192 / 10240。
LAMBDA_MEMORY="3008"

# CloudFront 托管缓存策略 CachingOptimized 的固定 ID
CF_CACHE_POLICY_ID="658327ea-f89d-4fab-a63d-7e88639e58f6"
# 浏览器版 AWS SDK v2
AWS_SDK_URL="https://sdk.amazonaws.com/js/aws-sdk-2.1691.0.min.js"

usage() { sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# ---------------------------------------------------------------------------
# 解析参数
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --connect-arn) CONNECT_ARN="$2"; shift 2;;
    --gateway-arn) GATEWAY_ARN="$2"; shift 2;;
    --email)       EMAIL="$2"; shift 2;;
    --suffix)      SUFFIX="$2"; shift 2;;
    --region)      REGION="$2"; shift 2;;
    --hours)       HOURS="$2"; shift 2;;
    --profile)     PROFILE="$2"; shift 2;;
    --out-dir)     OUT_DIR="$2"; shift 2;;
    --keep)        KEEP="true"; shift;;
    --lambda-memory) LAMBDA_MEMORY="$2"; shift 2;;
    -h|--help)     usage; exit 0;;
    *) echo "未知参数: $1" >&2; usage; exit 1;;
  esac
done

# aws CLI 包装(带上可选 profile)
awscli() {
  if [[ -n "${PROFILE}" ]]; then
    aws --profile "${PROFILE}" "$@"
  else
    aws "$@"
  fi
}

# ---------------------------------------------------------------------------
# 依赖检查
# ---------------------------------------------------------------------------
command -v aws >/dev/null 2>&1 || { echo "错误: 未找到 aws CLI(需 v2 且已配置凭证)。" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "错误: 未找到 python3。" >&2; exit 1; }
[[ -f "${FETCHER}" ]] || { echo "错误: 找不到拉取脚本 ${FETCHER}" >&2; exit 1; }
[[ -f "${LAMBDA_HANDLER}" ]] || { echo "错误: 找不到 Lambda 代码 ${LAMBDA_HANDLER}" >&2; exit 1; }
[[ -f "${PARSER_MODULE}" ]] || { echo "错误: 找不到解析模块 ${PARSER_MODULE}" >&2; exit 1; }
[[ -f "${WEB_CF_DIR}/auth.js" ]] || { echo "错误: 找不到 ${WEB_CF_DIR}/auth.js" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 交互式补全必选参数
# ---------------------------------------------------------------------------
if [[ -z "${CONNECT_ARN}" ]]; then
  echo "请输入 Connect AI Agent 日志组 ARN(必选):"
  echo "  例如: arn:aws:logs:us-west-2:111122223333:log-group:/aws/connect/ai-agent-logs:*"
  printf "CONNECT_AI_AGENT_LOG_ARN: "
  read -r CONNECT_ARN
fi
CONNECT_ARN="$(echo "${CONNECT_ARN}" | tr -d '[:space:]')"
[[ -n "${CONNECT_ARN}" ]] || { echo "错误: 必须提供 CONNECT_AI_AGENT_LOG_ARN。" >&2; exit 1; }

if [[ -z "${GATEWAY_ARN}" ]]; then
  echo "请输入 Bedrock AgentCore Gateway 日志组 ARN(可选，直接回车跳过):"
  printf "BEDROCK_AGENTCORE_GATEWAY_LOG_ARN: "
  read -r GATEWAY_ARN
fi
GATEWAY_ARN="$(echo "${GATEWAY_ARN}" | tr -d '[:space:]')"

if [[ -z "${EMAIL}" ]]; then
  echo "请输入登录用户邮箱(将接收一次性密码，必选):"
  printf "EMAIL: "
  read -r EMAIL
fi
EMAIL="$(echo "${EMAIL}" | tr -d '[:space:]')"
[[ "${EMAIL}" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] \
  || { echo "错误: 邮箱格式不正确: ${EMAIL}" >&2; exit 1; }

if [[ -z "${SUFFIX}" ]]; then
  echo "请输入存储桶名后缀(日志桶将命名为 ai-agent-logs<suffix>，必选):"
  echo "  只能包含小写字母、数字和连字符(-)。例如: -demo 或 20260709"
  printf "SUFFIX: "
  read -r SUFFIX
fi
SUFFIX="$(echo "${SUFFIX}" | tr -d '[:space:]' | tr 'A-Z' 'a-z')"

# ---------------------------------------------------------------------------
# 从 ARN 解析 region / account / 日志组名
# ---------------------------------------------------------------------------
arn_region()    { echo "$1" | cut -d: -f4; }
arn_account()   { echo "$1" | cut -d: -f5; }
arn_log_group() { local rest="${1#*:log-group:}"; rest="${rest%:\*}"; echo "${rest}"; }

CONNECT_REGION="$(arn_region "${CONNECT_ARN}")"
ACCOUNT_ID="$(arn_account "${CONNECT_ARN}")"
CONNECT_LG="$(arn_log_group "${CONNECT_ARN}")"
[[ -n "${REGION}" ]] || REGION="${CONNECT_REGION}"

if [[ -z "${REGION}" || -z "${ACCOUNT_ID}" || -z "${CONNECT_LG}" ]]; then
  echo "错误: 无法从 CONNECT_AI_AGENT_LOG_ARN 解析出 region/account/日志组名。" >&2
  echo "      期望形如 arn:aws:logs:<region>:<account>:log-group:<name>[:*]" >&2
  exit 1
fi

GATEWAY_REGION=""; GATEWAY_LG=""
if [[ -n "${GATEWAY_ARN}" ]]; then
  GATEWAY_REGION="$(arn_region "${GATEWAY_ARN}")"
  GATEWAY_LG="$(arn_log_group "${GATEWAY_ARN}")"
fi

# ---------------------------------------------------------------------------
# 资源命名
# ---------------------------------------------------------------------------
LOGS_BUCKET="ai-agent-logs${SUFFIX}"
WEB_BUCKET="ai-agent-logs${SUFFIX}-web"
USER_POOL_NAME="connect-ai-agent-logs${SUFFIX}"
IDENTITY_POOL_NAME="connect_ai_agent_logs${SUFFIX//-/_}"
AUTH_ROLE_NAME="connect-ai-logs${SUFFIX}-auth-role"
LAMBDA_NAME="connect-ai-logs${SUFFIX}-splitter"
LAMBDA_ROLE_NAME="connect-ai-logs${SUFFIX}-lambda-role"

# 校验桶名(S3 命名规则: 3-63 位小写字母/数字/连字符，首尾为字母数字)
validate_bucket() {
  local b="$1"
  if [[ ! "${b}" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]]; then
    echo "错误: 生成的桶名不合法: ${b}" >&2
    echo "      请调整 --suffix(只用小写字母、数字、连字符)。" >&2
    exit 1
  fi
}
validate_bucket "${LOGS_BUCKET}"
validate_bucket "${WEB_BUCKET}"

echo "==================================================================="
echo " 部署配置"
echo "   区域(region)      : ${REGION}"
echo "   账号(account)     : ${ACCOUNT_ID}"
echo "   Connect 日志组    : ${CONNECT_LG}"
if [[ -n "${GATEWAY_ARN}" ]]; then
echo "   Gateway 日志组    : ${GATEWAY_LG} (${GATEWAY_REGION})"
else
echo "   Gateway 日志组    : (未提供)"
fi
echo "   日志存储桶        : ${LOGS_BUCKET}"
echo "   Web 存储桶        : ${WEB_BUCKET}"
echo "   解析 Lambda 内存  : ${LAMBDA_MEMORY} MB"
echo "   登录邮箱          : ${EMAIL}"
echo "   拉取范围          : $([[ "${HOURS}" == "0" ]] && echo '全部历史' || echo "最近 ${HOURS} 小时")"
echo "==================================================================="

# 临时产物目录: 只存放很小的部署制品(IAM/桶策略等 JSON 与 Lambda 部署包)。
# 默认放到系统临时目录(/tmp)，避免受限的 $HOME 磁盘配额(如 CloudShell)被占满。
# 原始日志与拆分结果全部在云端处理，本地不落任何日志文件。
if [[ -z "${OUT_DIR}" ]]; then
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/connect-ai-cf.XXXXXX")"
else
  WORK="${OUT_DIR}"
  mkdir -p "${WORK}"
fi
cleanup() { [[ "${KEEP}" == "true" ]] || rm -rf "${WORK}" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. 计算起始时间与通用辅助函数
# ---------------------------------------------------------------------------
# HOURS=0 表示全部历史(不设 start-time)
START_MS=""
if [[ "${HOURS}" != "0" ]]; then
  if date -u -d "@0" >/dev/null 2>&1; then
    START_MS="$(( ( $(date -u +%s) - HOURS * 3600 ) * 1000 ))"
  else
    START_MS="$(python3 -c "import time,sys; print(int((time.time()-int(sys.argv[1])*3600)*1000))" "${HOURS}")"
  fi
fi

# S3 桶辅助函数(供日志桶与 Web 桶复用)
bucket_exists() { awscli s3api head-bucket --bucket "$1" >/dev/null 2>&1; }

create_bucket() {
  local b="$1"
  echo "==> 创建 S3 桶: ${b}"
  if [[ "${REGION}" == "us-east-1" ]]; then
    awscli s3api create-bucket --bucket "${b}" --region "${REGION}" >/dev/null
  else
    awscli s3api create-bucket --bucket "${b}" --region "${REGION}" \
      --create-bucket-configuration LocationConstraint="${REGION}" >/dev/null
  fi
  # 关闭公共访问(日志与站点都不公开，站点经 CloudFront/OAC，日志经 Cognito 凭证)
  awscli s3api put-public-access-block --bucket "${b}" \
    --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true >/dev/null
}

# ---------------------------------------------------------------------------
# 2. 确保日志存储桶存在并配置 CORS
#     (需在拉取/拆分之前：原始日志会流式归档到该桶，拆分也会逐个 Contact 上传)
# ---------------------------------------------------------------------------
if bucket_exists "${LOGS_BUCKET}"; then
  echo "==> 日志桶已存在，复用: ${LOGS_BUCKET}"
else
  create_bucket "${LOGS_BUCKET}"
fi

# 允许浏览器(经 Cognito 临时凭证的 S3 SDK 请求)跨域读取日志
CORS_JSON="${WORK}/_cors.json"
cat > "${CORS_JSON}" <<'JSON'
{
  "CORSRules": [
    {
      "AllowedOrigins": ["*"],
      "AllowedMethods": ["GET", "HEAD"],
      "AllowedHeaders": ["*"],
      "ExposeHeaders": ["ETag"],
      "MaxAgeSeconds": 3000
    }
  ]
}
JSON
echo "==> 配置日志桶 CORS ..."
awscli s3api put-bucket-cors --bucket "${LOGS_BUCKET}" --cors-configuration "file://${CORS_JSON}" >/dev/null

# ---------------------------------------------------------------------------
# 2b. 解析用 Lambda: 执行角色 + 部署包 + 函数 + S3 触发权限 + 桶事件通知
#     由 "trigger/*.json" 的 S3 事件触发，在云端读取 raw/ 原始日志并按 Contact 拆分。
# ---------------------------------------------------------------------------
# Lambda 执行角色信任策略
LAMBDA_TRUST_JSON="${WORK}/_lambda_trust.json"
cat > "${LAMBDA_TRUST_JSON}" <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Principal": { "Service": "lambda.amazonaws.com" },
      "Action": "sts:AssumeRole" }
  ]
}
JSON

# Lambda 权限: 读写日志桶 + 写自身日志
LAMBDA_POLICY_JSON="${WORK}/_lambda_policy.json"
cat > "${LAMBDA_POLICY_JSON}" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"],
      "Resource": ["arn:aws:s3:::${LOGS_BUCKET}", "arn:aws:s3:::${LOGS_BUCKET}/*"]
    },
    {
      "Effect": "Allow",
      "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
      "Resource": "arn:aws:logs:*:*:*"
    }
  ]
}
JSON

if awscli iam get-role --role-name "${LAMBDA_ROLE_NAME}" >/dev/null 2>&1; then
  echo "==> 复用 Lambda 执行角色: ${LAMBDA_ROLE_NAME}"
  awscli iam update-assume-role-policy --role-name "${LAMBDA_ROLE_NAME}" \
    --policy-document "file://${LAMBDA_TRUST_JSON}" >/dev/null
  LAMBDA_ROLE_ARN="$(awscli iam get-role --role-name "${LAMBDA_ROLE_NAME}" \
    --query 'Role.Arn' --output text)"
else
  echo "==> 创建 Lambda 执行角色: ${LAMBDA_ROLE_NAME}"
  LAMBDA_ROLE_ARN="$(awscli iam create-role --role-name "${LAMBDA_ROLE_NAME}" \
    --assume-role-policy-document "file://${LAMBDA_TRUST_JSON}" \
    --query 'Role.Arn' --output text)"
fi
awscli iam put-role-policy --role-name "${LAMBDA_ROLE_NAME}" \
  --policy-name "logs-bucket-rw" \
  --policy-document "file://${LAMBDA_POLICY_JSON}" >/dev/null

# 打包 Lambda 部署包(handler.py + connect_parser.py)
LAMBDA_ZIP="${WORK}/lambda.zip"
python3 - "${LAMBDA_ZIP}" "${LAMBDA_HANDLER}" "${PARSER_MODULE}" <<'PYEOF'
import sys, zipfile
zp, handler, parser = sys.argv[1], sys.argv[2], sys.argv[3]
with zipfile.ZipFile(zp, "w", zipfile.ZIP_DEFLATED) as z:
    z.write(handler, "handler.py")
    z.write(parser, "connect_parser.py")
PYEOF

# IAM 角色最终一致性
sleep 8

if awscli lambda get-function --function-name "${LAMBDA_NAME}" --region "${REGION}" >/dev/null 2>&1; then
  echo "==> 更新 Lambda: ${LAMBDA_NAME}"
  awscli lambda update-function-code --function-name "${LAMBDA_NAME}" --region "${REGION}" \
    --zip-file "fileb://${LAMBDA_ZIP}" >/dev/null
  awscli lambda wait function-updated --function-name "${LAMBDA_NAME}" --region "${REGION}" 2>/dev/null || sleep 5
  awscli lambda update-function-configuration --function-name "${LAMBDA_NAME}" --region "${REGION}" \
    --runtime python3.12 --role "${LAMBDA_ROLE_ARN}" --handler handler.handler \
    --timeout 900 --memory-size "${LAMBDA_MEMORY}" >/dev/null
  awscli lambda wait function-updated --function-name "${LAMBDA_NAME}" --region "${REGION}" 2>/dev/null || sleep 5
else
  echo "==> 创建 Lambda: ${LAMBDA_NAME}"
  n=0
  until awscli lambda create-function --function-name "${LAMBDA_NAME}" --region "${REGION}" \
      --runtime python3.12 --role "${LAMBDA_ROLE_ARN}" --handler handler.handler \
      --timeout 900 --memory-size "${LAMBDA_MEMORY}" --zip-file "fileb://${LAMBDA_ZIP}" >/dev/null 2>&1; do
    n=$((n + 1))
    if [[ ${n} -ge 6 ]]; then
      echo "错误: 创建 Lambda 失败(执行角色可能尚未生效)。请稍后重跑本脚本。" >&2
      exit 1
    fi
    echo "    等待执行角色生效，重试 (${n}/6) ..."
    sleep 5
  done
fi
LAMBDA_ARN="$(awscli lambda get-function --function-name "${LAMBDA_NAME}" --region "${REGION}" \
  --query 'Configuration.FunctionArn' --output text)"

# S3 触发是"异步调用": 失败(如 OOM/超时)默认会自动重试 2 次，每次都从头重跑
# 整份解析(大日志下每次可能长达 15 分钟)，纯属浪费。这里把最大重试次数设为 0:
# 失败就快速失败，由 index.json 的 error 字段(可捕获异常)或函数日志(OOM/超时)体现。
awscli lambda put-function-event-invoke-config --function-name "${LAMBDA_NAME}" \
  --region "${REGION}" --maximum-retry-attempts 0 >/dev/null 2>&1 || true

# 允许该日志桶调用此 Lambda(幂等: 先删同名声明)
awscli lambda remove-permission --function-name "${LAMBDA_NAME}" --region "${REGION}" \
  --statement-id s3invoke >/dev/null 2>&1 || true
awscli lambda add-permission --function-name "${LAMBDA_NAME}" --region "${REGION}" \
  --statement-id s3invoke --action "lambda:InvokeFunction" \
  --principal s3.amazonaws.com \
  --source-arn "arn:aws:s3:::${LOGS_BUCKET}" \
  --source-account "${ACCOUNT_ID}" >/dev/null

# 配置桶事件通知: trigger/ 前缀且 .json 后缀 -> 触发 Lambda
NOTIF_JSON="${WORK}/_notif.json"
cat > "${NOTIF_JSON}" <<JSON
{
  "LambdaFunctionConfigurations": [
    {
      "Id": "process-raw-logs",
      "LambdaFunctionArn": "${LAMBDA_ARN}",
      "Events": ["s3:ObjectCreated:*"],
      "Filter": {
        "Key": {
          "FilterRules": [
            { "Name": "prefix", "Value": "trigger/" },
            { "Name": "suffix", "Value": ".json" }
          ]
        }
      }
    }
  ]
}
JSON
echo "==> 配置日志桶事件通知 -> Lambda"
awscli s3api put-bucket-notification-configuration --bucket "${LOGS_BUCKET}" \
  --notification-configuration "file://${NOTIF_JSON}" >/dev/null

# ---------------------------------------------------------------------------
# 3. 拉取原始日志"直传"S3(本地不落文件) -> 写触发对象 -> Lambda 在云端拆分
# ---------------------------------------------------------------------------
build_fetch_args() {
  # $1=region $2=log-group $3=key $4=label
  FETCH_ARGS=(--region "$1" --log-group "$2" --bucket "${LOGS_BUCKET}"
              --key "$3" --s3-region "${REGION}" --label "$4")
  [[ -n "${START_MS}" ]] && FETCH_ARGS+=(--start-ms "${START_MS}")
  [[ -n "${PROFILE}" ]] && FETCH_ARGS+=(--profile "${PROFILE}")
  # 必须显式 return 0:
  # 否则当 START_MS 与 PROFILE 均为空时，函数最后一条 `[[ ... ]] && ...`
  # 因条件为假而返回 1，在 `set -e` 下会让整个脚本在"拉取日志"这一步
  # 静默退出(既不报错也不继续)。
  return 0
}

echo "==> 拉取 Connect AI Agent 日志并直传 s3://${LOGS_BUCKET}/raw/connect.ndjson ..."
build_fetch_args "${CONNECT_REGION}" "${CONNECT_LG}" "raw/connect.ndjson" "Connect"
python3 "${FETCHER}" "${FETCH_ARGS[@]}" >/dev/null

GATEWAY_TRIG=""
if [[ -n "${GATEWAY_ARN}" ]]; then
  echo "==> 拉取 Gateway 日志并直传 s3://${LOGS_BUCKET}/raw/gateway.ndjson ..."
  build_fetch_args "${GATEWAY_REGION}" "${GATEWAY_LG}" "raw/gateway.ndjson" "Gateway"
  python3 "${FETCHER}" "${FETCH_ARGS[@]}" >/dev/null
  GATEWAY_TRIG=',"gateway":"raw/gateway.ndjson"'
fi

# 删除旧 index.json，便于随后轮询判断本次 Lambda 是否已生成
awscli s3 rm "s3://${LOGS_BUCKET}/index.json" >/dev/null 2>&1 || true

# 写触发对象(原始数据已就位) -> 触发 Lambda
TRIGGER_JSON="${WORK}/_trigger.json"
printf '{"connect":"raw/connect.ndjson"%s,"prefix":""}\n' "${GATEWAY_TRIG}" > "${TRIGGER_JSON}"
echo "==> 写入触发对象，S3 事件将触发 Lambda 在云端解析 ..."
awscli s3 cp "${TRIGGER_JSON}" "s3://${LOGS_BUCKET}/trigger/process.json" \
  --content-type application/json >/dev/null

# 轮询等待 Lambda 生成 index.json(最长约 16 分钟，覆盖 Lambda 15 分钟上限)
echo "==> 等待 Lambda 解析并生成 index.json(最长约 16 分钟)..."
CONTACT_COUNT="?"
PARSE_ERROR=""
for _ in $(seq 1 200); do
  if awscli s3api head-object --bucket "${LOGS_BUCKET}" --key index.json >/dev/null 2>&1; then
    IDX_JSON="$(awscli s3 cp "s3://${LOGS_BUCKET}/index.json" - 2>/dev/null || echo '')"
    CONTACT_COUNT="$(printf '%s' "${IDX_JSON}" \
      | python3 -c 'import sys,json; print(json.load(sys.stdin).get("contactCount","?"))' 2>/dev/null || echo '?')"
    PARSE_ERROR="$(printf '%s' "${IDX_JSON}" \
      | python3 -c 'import sys,json; print(json.load(sys.stdin).get("error",""))' 2>/dev/null || echo '')"
    break
  fi
  sleep 5
done

if [[ -n "${PARSE_ERROR}" ]]; then
  echo ""
  echo "⚠️  Lambda 解析报错: ${PARSE_ERROR}"
  echo "    站点将没有数据。请查看函数日志排查:"
  echo "    aws logs tail /aws/lambda/${LAMBDA_NAME} --region ${REGION} --follow"
  echo ""
elif [[ "${CONTACT_COUNT}" == "?" ]]; then
  echo "    Lambda 仍在后台处理(或耗时较长)。index.json 生成后站点即可加载数据。"
  echo "    若长时间不出现，多半是日志量过大导致内存不足(OOM)或超过 15 分钟超时被中止，可:"
  echo "      · 用更大的内存重跑:  --lambda-memory 8192  (或 10240)"
  echo "      · 或缩小拉取范围:    --hours <n>"
  echo "    查看函数日志: aws logs tail /aws/lambda/${LAMBDA_NAME} --region ${REGION} --follow"
elif [[ "${CONTACT_COUNT}" == "0" ]]; then
  echo ""
  echo "⚠️  提示: 未从日志中解析出任何 Contact，站点会是空的。"
  echo "    可加大时间范围(--hours 更大或不加)，或核对日志组 ARN/权限。"
  echo ""
fi

# ---------------------------------------------------------------------------
# 4. Amazon Cognito: 用户池 + 应用客户端 + 身份池 + 鉴权角色
# ---------------------------------------------------------------------------
# 复用已存在的同名资源(幂等)，否则创建。

# 4.1 用户池
find_user_pool() {
  awscli cognito-idp list-user-pools --max-results 60 \
    --region "${REGION}" \
    --query "UserPools[?Name=='${USER_POOL_NAME}'].Id | [0]" --output text 2>/dev/null
}
USER_POOL_ID="$(find_user_pool || true)"
if [[ -z "${USER_POOL_ID}" || "${USER_POOL_ID}" == "None" ]]; then
  echo "==> 创建 Cognito 用户池: ${USER_POOL_NAME}"
  USER_POOL_ID="$(awscli cognito-idp create-user-pool \
    --pool-name "${USER_POOL_NAME}" \
    --region "${REGION}" \
    --username-attributes email \
    --auto-verified-attributes email \
    --admin-create-user-config 'AllowAdminCreateUserOnly=true' \
    --policies 'PasswordPolicy={MinimumLength=8,RequireUppercase=true,RequireLowercase=true,RequireNumbers=true,RequireSymbols=false}' \
    --query 'UserPool.Id' --output text)"
else
  echo "==> 复用已存在的用户池: ${USER_POOL_ID}"
fi

# 4.2 应用客户端(公共客户端，无 secret，启用 USER_PASSWORD_AUTH)
CLIENT_ID="$(awscli cognito-idp list-user-pool-clients \
  --user-pool-id "${USER_POOL_ID}" --region "${REGION}" --max-results 60 \
  --query "UserPoolClients[?ClientName=='${USER_POOL_NAME}-web'].ClientId | [0]" \
  --output text 2>/dev/null || true)"
if [[ -z "${CLIENT_ID}" || "${CLIENT_ID}" == "None" ]]; then
  echo "==> 创建用户池应用客户端"
  CLIENT_ID="$(awscli cognito-idp create-user-pool-client \
    --user-pool-id "${USER_POOL_ID}" --region "${REGION}" \
    --client-name "${USER_POOL_NAME}-web" \
    --no-generate-secret \
    --explicit-auth-flows ALLOW_USER_PASSWORD_AUTH ALLOW_REFRESH_TOKEN_AUTH \
    --query 'UserPoolClient.ClientId' --output text)"
else
  echo "==> 复用已存在的应用客户端: ${CLIENT_ID}"
fi

# 4.3 身份池
PROVIDER_NAME="cognito-idp.${REGION}.amazonaws.com/${USER_POOL_ID}"
IDENTITY_POOL_ID="$(awscli cognito-identity list-identity-pools --max-results 60 \
  --region "${REGION}" \
  --query "IdentityPools[?IdentityPoolName=='${IDENTITY_POOL_NAME}'].IdentityPoolId | [0]" \
  --output text 2>/dev/null || true)"
if [[ -z "${IDENTITY_POOL_ID}" || "${IDENTITY_POOL_ID}" == "None" ]]; then
  echo "==> 创建 Cognito 身份池: ${IDENTITY_POOL_NAME}"
  IDENTITY_POOL_ID="$(awscli cognito-identity create-identity-pool \
    --region "${REGION}" \
    --identity-pool-name "${IDENTITY_POOL_NAME}" \
    --no-allow-unauthenticated-identities \
    --cognito-identity-providers "ProviderName=${PROVIDER_NAME},ClientId=${CLIENT_ID},ServerSideTokenCheck=false" \
    --query 'IdentityPoolId' --output text)"
else
  echo "==> 复用已存在的身份池: ${IDENTITY_POOL_ID}"
  # 确保 provider 与本次的用户池/客户端一致
  awscli cognito-identity update-identity-pool \
    --region "${REGION}" \
    --identity-pool-id "${IDENTITY_POOL_ID}" \
    --identity-pool-name "${IDENTITY_POOL_NAME}" \
    --no-allow-unauthenticated-identities \
    --cognito-identity-providers "ProviderName=${PROVIDER_NAME},ClientId=${CLIENT_ID},ServerSideTokenCheck=false" >/dev/null
fi

# 4.4 鉴权角色(供登录用户读取日志桶)
TRUST_JSON="${WORK}/_trust.json"
cat > "${TRUST_JSON}" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Federated": "cognito-identity.amazonaws.com" },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": { "cognito-identity.amazonaws.com:aud": "${IDENTITY_POOL_ID}" },
        "ForAnyValue:StringLike": { "cognito-identity.amazonaws.com:amr": "authenticated" }
      }
    }
  ]
}
JSON

S3_POLICY_JSON="${WORK}/_s3policy.json"
cat > "${S3_POLICY_JSON}" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject"],
      "Resource": "arn:aws:s3:::${LOGS_BUCKET}/*"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": "arn:aws:s3:::${LOGS_BUCKET}"
    }
  ]
}
JSON

if awscli iam get-role --role-name "${AUTH_ROLE_NAME}" >/dev/null 2>&1; then
  echo "==> 复用鉴权角色: ${AUTH_ROLE_NAME}"
  awscli iam update-assume-role-policy --role-name "${AUTH_ROLE_NAME}" \
    --policy-document "file://${TRUST_JSON}" >/dev/null
  AUTH_ROLE_ARN="$(awscli iam get-role --role-name "${AUTH_ROLE_NAME}" \
    --query 'Role.Arn' --output text)"
else
  echo "==> 创建鉴权角色: ${AUTH_ROLE_NAME}"
  AUTH_ROLE_ARN="$(awscli iam create-role --role-name "${AUTH_ROLE_NAME}" \
    --assume-role-policy-document "file://${TRUST_JSON}" \
    --query 'Role.Arn' --output text)"
fi
awscli iam put-role-policy --role-name "${AUTH_ROLE_NAME}" \
  --policy-name "read-logs-bucket" \
  --policy-document "file://${S3_POLICY_JSON}" >/dev/null

# 等待角色可被身份池引用(IAM 最终一致性)
sleep 8
echo "==> 关联身份池与鉴权角色"
awscli cognito-identity set-identity-pool-roles \
  --region "${REGION}" \
  --identity-pool-id "${IDENTITY_POOL_ID}" \
  --roles "authenticated=${AUTH_ROLE_ARN}" >/dev/null

# 4.5 创建登录用户(Cognito 会把一次性密码发送到邮箱)
if awscli cognito-idp admin-get-user --user-pool-id "${USER_POOL_ID}" \
     --username "${EMAIL}" --region "${REGION}" >/dev/null 2>&1; then
  echo "==> 用户已存在，跳过创建: ${EMAIL}"
  echo "    如需重新发送一次性密码，可在登录页点击「忘记密码」，或删除该用户后重跑。"
else
  echo "==> 创建登录用户并发送一次性密码到: ${EMAIL}"
  awscli cognito-idp admin-create-user \
    --user-pool-id "${USER_POOL_ID}" --region "${REGION}" \
    --username "${EMAIL}" \
    --user-attributes Name=email,Value="${EMAIL}" Name=email_verified,Value=true \
    --desired-delivery-mediums EMAIL >/dev/null
fi

# ---------------------------------------------------------------------------
# 5. 发布 Web 站点(登录门禁版) -> Web 桶(全部直传，不落本地文件)
# ---------------------------------------------------------------------------
if bucket_exists "${WEB_BUCKET}"; then
  echo "==> Web 桶已存在，复用: ${WEB_BUCKET}"
else
  create_bucket "${WEB_BUCKET}"
fi

echo "==> 发布站点到 s3://${WEB_BUCKET}/ ..."
JS_CT="application/javascript; charset=utf-8"
# 复用现有前端逻辑，直接从仓库拷贝到 S3
awscli s3 cp "${WEB_DIR}/app.js"         "s3://${WEB_BUCKET}/app.js"         --content-type "${JS_CT}" >/dev/null
awscli s3 cp "${WEB_DIR}/i18n.js"        "s3://${WEB_BUCKET}/i18n.js"        --content-type "${JS_CT}" >/dev/null
awscli s3 cp "${WEB_DIR}/site-config.js" "s3://${WEB_BUCKET}/site-config.js" --content-type "${JS_CT}" >/dev/null
awscli s3 cp "${WEB_CF_DIR}/auth.js"     "s3://${WEB_BUCKET}/auth.js"        --content-type "${JS_CT}" >/dev/null

# 生成运行时配置 aws-config.js(从内存直传，不落本地文件)
awscli s3 cp - "s3://${WEB_BUCKET}/aws-config.js" --content-type "${JS_CT}" >/dev/null <<JSCFG
/* 由 setup-connect-ai-agent-logs-analysis-in-cloudfront.sh 自动生成，请勿手工编辑 */
window.__AWS_CONFIG__ = {
  region: "${REGION}",
  userPoolId: "${USER_POOL_ID}",
  clientId: "${CLIENT_ID}",
  identityPoolId: "${IDENTITY_POOL_ID}",
  logsBucket: "${LOGS_BUCKET}",
  logsPrefix: ""
};
JSCFG

# 由 lib/web/index.html 生成登录门禁版 index.html 并直传:
#   - 去掉静态 data.js(数据改为登录后从 S3 加载)
#   - 用 SDK + aws-config.js + auth.js 取代静态 app.js(app.js 由 auth.js 动态加载)
AWS_SDK_URL="${AWS_SDK_URL}" python3 - "${WEB_DIR}/index.html" <<'PYEOF' \
  | awscli s3 cp - "s3://${WEB_BUCKET}/index.html" --content-type "text/html; charset=utf-8" >/dev/null
import os, re, sys
sdk = os.environ["AWS_SDK_URL"]
html = open(sys.argv[1], encoding="utf-8").read()
html = re.sub(r'[ \t]*<script src="\./data\.js"></script>\s*\n', "", html)
replacement = (
    '<script src="%s"></script>\n'
    '<script src="./aws-config.js"></script>\n'
    '<script src="./auth.js"></script>\n'
) % sdk
html, n = re.subn(r'[ \t]*<script src="\./app\.js"></script>\s*\n', replacement, html)
if n == 0:
    sys.stderr.write("警告: 未在 index.html 找到 app.js 脚本标签，请检查模板。\n")
sys.stdout.write(html)
PYEOF

# ---------------------------------------------------------------------------
# 6. CloudFront: 源访问控制(OAC) + 分配 + 回源桶策略
# ---------------------------------------------------------------------------
# 6.1 OAC(按名称复用)
OAC_NAME="connect-ai-logs${SUFFIX}-oac"
OAC_ID="$(awscli cloudfront list-origin-access-controls \
  --query "OriginAccessControlList.Items[?Name=='${OAC_NAME}'].Id | [0]" \
  --output text 2>/dev/null || true)"
if [[ -z "${OAC_ID}" || "${OAC_ID}" == "None" ]]; then
  echo "==> 创建 CloudFront OAC: ${OAC_NAME}"
  OAC_CFG="${WORK}/_oac.json"
  cat > "${OAC_CFG}" <<JSON
{
  "Name": "${OAC_NAME}",
  "Description": "OAC for ${WEB_BUCKET}",
  "SigningProtocol": "sigv4",
  "SigningBehavior": "always",
  "OriginAccessControlOriginType": "s3"
}
JSON
  OAC_ID="$(awscli cloudfront create-origin-access-control \
    --origin-access-control-config "file://${OAC_CFG}" \
    --query 'OriginAccessControl.Id' --output text)"
else
  echo "==> 复用已存在的 OAC: ${OAC_ID}"
fi

# 6.2 分配(按 Comment 复用；不存在则创建)
DIST_COMMENT="connect-ai-agent-logs${SUFFIX}"
WEB_ORIGIN_DOMAIN="${WEB_BUCKET}.s3.${REGION}.amazonaws.com"
DIST_ID="$(awscli cloudfront list-distributions \
  --query "DistributionList.Items[?Comment=='${DIST_COMMENT}'].Id | [0]" \
  --output text 2>/dev/null || true)"

if [[ -z "${DIST_ID}" || "${DIST_ID}" == "None" ]]; then
  echo "==> 创建 CloudFront 分配 ..."
  DIST_CFG="${WORK}/_dist.json"
  cat > "${DIST_CFG}" <<JSON
{
  "CallerReference": "${DIST_COMMENT}-$(date +%s)",
  "Comment": "${DIST_COMMENT}",
  "Enabled": true,
  "DefaultRootObject": "index.html",
  "Origins": {
    "Quantity": 1,
    "Items": [
      {
        "Id": "s3-web",
        "DomainName": "${WEB_ORIGIN_DOMAIN}",
        "OriginAccessControlId": "${OAC_ID}",
        "S3OriginConfig": { "OriginAccessIdentity": "" }
      }
    ]
  },
  "DefaultCacheBehavior": {
    "TargetOriginId": "s3-web",
    "ViewerProtocolPolicy": "redirect-to-https",
    "CachePolicyId": "${CF_CACHE_POLICY_ID}",
    "Compress": true,
    "AllowedMethods": {
      "Quantity": 2,
      "Items": ["GET", "HEAD"],
      "CachedMethods": { "Quantity": 2, "Items": ["GET", "HEAD"] }
    }
  },
  "CustomErrorResponses": {
    "Quantity": 2,
    "Items": [
      { "ErrorCode": 403, "ResponseCode": "200", "ResponsePagePath": "/index.html", "ErrorCachingMinTTL": 10 },
      { "ErrorCode": 404, "ResponseCode": "200", "ResponsePagePath": "/index.html", "ErrorCachingMinTTL": 10 }
    ]
  }
}
JSON
  DIST_ID="$(awscli cloudfront create-distribution \
    --distribution-config "file://${DIST_CFG}" \
    --query 'Distribution.Id' --output text)"
else
  echo "==> 复用已存在的分配: ${DIST_ID}"
fi

DIST_DOMAIN="$(awscli cloudfront get-distribution --id "${DIST_ID}" \
  --query 'Distribution.DomainName' --output text)"
DIST_ARN="arn:aws:cloudfront::${ACCOUNT_ID}:distribution/${DIST_ID}"

# 6.3 Web 桶策略: 仅允许该 CloudFront 分配经 OAC 读取
WEB_POLICY_JSON="${WORK}/_webpolicy.json"
cat > "${WEB_POLICY_JSON}" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowCloudFrontOAC",
      "Effect": "Allow",
      "Principal": { "Service": "cloudfront.amazonaws.com" },
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::${WEB_BUCKET}/*",
      "Condition": { "StringEquals": { "AWS:SourceArn": "${DIST_ARN}" } }
    }
  ]
}
JSON
echo "==> 配置 Web 桶策略(仅允许 CloudFront OAC 访问)"
awscli s3api put-bucket-policy --bucket "${WEB_BUCKET}" \
  --policy "file://${WEB_POLICY_JSON}" >/dev/null

# 若为已存在分配，发起一次失效以刷新站点资源
awscli cloudfront create-invalidation --distribution-id "${DIST_ID}" \
  --paths "/*" >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 6.4 等待 CloudFront 部署完成(状态 InProgress -> Deployed)
# ---------------------------------------------------------------------------
echo "==> 等待 CloudFront 分配部署完成(通常 3~10 分钟)…"
CF_STATUS="Unknown"
WAITED=0
MAX_WAIT=1200   # 最长等待 20 分钟
while [[ ${WAITED} -lt ${MAX_WAIT} ]]; do
  CF_STATUS="$(awscli cloudfront get-distribution --id "${DIST_ID}" \
    --query 'Distribution.Status' --output text 2>/dev/null || echo 'Unknown')"
  if [[ "${CF_STATUS}" == "Deployed" ]]; then
    printf "\r    CloudFront 状态: Deployed ✅ (耗时 %ds)                    \n" "${WAITED}"
    break
  fi
  printf "\r    CloudFront 状态: %s … 已等待 %ds" "${CF_STATUS}" "${WAITED}"
  sleep 15
  WAITED=$((WAITED + 15))
done
if [[ "${CF_STATUS}" != "Deployed" ]]; then
  printf "\n    CloudFront 仍在后台部署(状态: %s)。可稍后用以下命令查看:\n" "${CF_STATUS}"
  echo "      aws cloudfront get-distribution --id ${DIST_ID} --query 'Distribution.Status' --output text"
fi

# ---------------------------------------------------------------------------
# 6.5 写资源清单文件(供 clear.sh 按清单删除本次部署创建/管理的全部资源)
# ---------------------------------------------------------------------------
# 每行格式: 类型|标识符;以 # 开头为注释。clear.sh 会按依赖顺序删除。
# 文件名带 suffix + 时间戳(UTC，精确到秒): 每次运行都生成一个新清单、不覆盖历史，
# 同一天多次运行也不会冲突。删除时用 clear.sh 指定具体某个清单文件即可。
MANIFEST_TS="$(date -u +%Y%m%dT%H%M%SZ)"
MANIFEST_FILE="${SCRIPT_DIR}/aws-resources-${SUFFIX}-${MANIFEST_TS}.manifest"
{
  echo "# Amazon Connect AI Agent 日志分析 — AWS 资源清单"
  echo "# 生成时间(UTC): $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# suffix       : ${SUFFIX}"
  echo "# 删除全部资源 : ./clear.sh \"${MANIFEST_FILE}\""
  echo "# 每行: 类型|标识符"
  echo "REGION|${REGION}"
  echo "ACCOUNT|${ACCOUNT_ID}"
  echo "CF_DISTRIBUTION|${DIST_ID}"
  echo "CF_OAC|${OAC_ID}"
  echo "LAMBDA|${LAMBDA_NAME}"
  echo "S3_BUCKET|${WEB_BUCKET}"
  echo "S3_BUCKET|${LOGS_BUCKET}"
  echo "COGNITO_IDENTITY_POOL|${IDENTITY_POOL_ID}"
  echo "COGNITO_USER_POOL|${USER_POOL_ID}"
  echo "IAM_ROLE|${LAMBDA_ROLE_NAME}"
  echo "IAM_ROLE|${AUTH_ROLE_NAME}"
} > "${MANIFEST_FILE}"
echo "==> 已写入资源清单: ${MANIFEST_FILE}"

# ---------------------------------------------------------------------------
# 7. 汇总
# ---------------------------------------------------------------------------
echo ""
echo "==================================================================="
echo " 部署完成 🎉"
echo "-------------------------------------------------------------------"
echo " 访问地址(CloudFront):  https://${DIST_DOMAIN}"
echo " CloudFront 部署状态:   $([[ "${CF_STATUS}" == "Deployed" ]] && echo '已完成 (Deployed)' || echo "${CF_STATUS}(后台继续部署中)")"
echo " 登录邮箱:              ${EMAIL}"
echo "   · 首次登录: 使用邮件里收到的一次性密码，登录后按提示设置新密码。"
echo "   · 忘记密码: 登录页点击「忘记密码」，向该邮箱发送新的验证码后重置。"
echo ""
echo " 资源清单:"
echo "   CloudFront 访问地址: https://${DIST_DOMAIN}"
echo "   CloudFront 分配 ID:  ${DIST_ID}"
echo "   CloudFront 部署状态: ${CF_STATUS}"
echo "   日志存储桶:          s3://${LOGS_BUCKET}  ($([[ "${CONTACT_COUNT}" == "?" ]] && echo 'Lambda 处理中' || echo "${CONTACT_COUNT} 个 Contact"))"
echo "   原始数据(归档):      s3://${LOGS_BUCKET}/raw/"
echo "   解析 Lambda:         ${LAMBDA_NAME}"
echo "   Web 存储桶:          s3://${WEB_BUCKET}"
echo "   Cognito 用户池:      ${USER_POOL_ID}"
echo "   Cognito 应用客户端:  ${CLIENT_ID}"
echo "   Cognito 身份池:      ${IDENTITY_POOL_ID}"
echo "   鉴权角色:            ${AUTH_ROLE_ARN}"
echo "   资源清单文件:        ${MANIFEST_FILE}"
echo "-------------------------------------------------------------------"
if [[ "${CF_STATUS}" == "Deployed" ]]; then
  echo " 提示: CloudFront 已部署完成，可直接访问上面的地址。"
else
  echo " 提示: CloudFront 仍在后台部署，状态变为 Deployed 后即可访问。"
fi
echo "       原始日志与拆分均在云端完成(S3 事件触发 Lambda)，本地不处理任何日志文件。"
echo "       删除本次部署的全部资源: ./clear.sh \"${MANIFEST_FILE}\""
echo "       重跑本脚本会重新拉取归档并触发 Lambda(已存在的 Contact 日志会跳过)。"
echo "==================================================================="

if [[ "${KEEP}" == "true" ]]; then
  echo " 临时产物目录已保留: ${WORK}"
fi

# 显式以 0 退出:
# 避免最后一条命令(如上面的条件判断为假时)让脚本以非零码结束，
# 从而使调用方误以为部署失败(实际已成功完成)。
exit 0
