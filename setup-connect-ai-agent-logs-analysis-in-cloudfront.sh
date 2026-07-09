#!/usr/bin/env bash
#
# setup-connect-ai-agent-logs-analysis-in-cloudfront.sh
#
# 用途:
#   参考 setup-connect-ai-agent-logs-analysis.sh，但不再本地预览，而是把
#   日志排查 Web 应用部署到 Amazon CloudFront，并用 Amazon Cognito 做登录鉴权。
#
#   流程概览:
#     1) 拉取 CONNECT_AI_AGENT_LOG_ARN (必选) 与 BEDROCK_AGENTCORE_GATEWAY_LOG_ARN
#        (可选) 两个日志组的全部日志;
#     2) 按 Contact ID 拆分，为每个 contact 生成 "<contactId>.log" 文件，
#        连同 index.json 清单上传到 S3 存储桶 "ai-agent-logs<suffix>"(不存在则自动创建);
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
#       [--out-dir <dir>] [--keep] [-h|--help]
#
# 参数(未提供的必选项会交互式询问):
#   --connect-arn <arn>  Connect AI Agent 日志组 ARN            [必选]
#   --gateway-arn <arn>  Bedrock AgentCore Gateway 日志组 ARN    [可选]
#   --email <addr>       登录用户邮箱(接收一次性密码)             [必选]
#   --suffix <s>         桶名后缀; 日志桶为 ai-agent-logs<suffix> [必选]
#   --region <r>         部署区域; 默认取自 connect-arn
#   --hours <n>          仅拉取最近 n 小时; 0 或不填=全部历史     [默认 0]
#   --profile <p>        AWS CLI profile
#   --out-dir <dir>      本地构建目录; 默认 ./dist-cloudfront
#   --keep               保留本地构建目录(默认结束后保留)
#   -h, --help           显示帮助
#
# 依赖: aws cli v2(已配置凭证)、python3。
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
WEB_DIR="${LIB_DIR}/web"
WEB_CF_DIR="${LIB_DIR}/web-cloudfront"
SPLITTER="${LIB_DIR}/split-contacts.py"

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
OUT_DIR="${SCRIPT_DIR}/dist-cloudfront"
KEEP="true"

# CloudFront 托管缓存策略 CachingOptimized 的固定 ID
CF_CACHE_POLICY_ID="658327ea-f89d-4fab-a63d-7e88639e58f6"
# 浏览器版 AWS SDK v2
AWS_SDK_URL="https://sdk.amazonaws.com/js/aws-sdk-2.1691.0.min.js"

usage() { sed -n '2,39p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

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
[[ -f "${SPLITTER}" ]] || { echo "错误: 找不到拆分脚本 ${SPLITTER}" >&2; exit 1; }
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
echo "   登录邮箱          : ${EMAIL}"
echo "   拉取范围          : $([[ "${HOURS}" == "0" ]] && echo '全部历史' || echo "最近 ${HOURS} 小时")"
echo "==================================================================="

WORK="${OUT_DIR}"
LOGS_BUILD="${WORK}/logs-build"
SITE_BUILD="${WORK}/site"
mkdir -p "${LOGS_BUILD}" "${SITE_BUILD}"

# ---------------------------------------------------------------------------
# 1. 从 CloudWatch 拉取日志(自动翻页)
# ---------------------------------------------------------------------------
# 计算起始时间(毫秒)；HOURS=0 表示全部历史(不设 start-time)
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

fetch_log_group() {
  # $1=region $2=log-group $3=输出NDJSON路径 $4=start_ms(可空)
  # 边翻页边写 NDJSON(每行一个事件)，并在控制台实时显示已拉取条数。
  python3 - "$1" "$2" "$3" "$4" "${PROFILE}" <<'PYEOF'
import json, subprocess, sys
region, log_group, out, start_ms = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
profile = sys.argv[5] if len(sys.argv) > 5 else ""
next_token, count = None, 0
with open(out, "w", encoding="utf-8") as f:
    while True:
        cmd = ["aws"]
        if profile:
            cmd += ["--profile", profile]
        cmd += ["logs", "filter-log-events", "--region", region,
                "--log-group-name", log_group, "--output", "json"]
        if start_ms:
            cmd += ["--start-time", start_ms]
        if next_token:
            cmd += ["--next-token", next_token]
        try:
            res = subprocess.run(cmd, capture_output=True, text=True, check=True)
        except subprocess.CalledProcessError as e:
            sys.stderr.write((e.stderr or "filter-log-events 调用失败\n"))
            sys.exit(1)
        data = json.loads(res.stdout or "{}")
        for ev in data.get("events", []):
            ts, msg = ev.get("timestamp"), ev.get("message")
            if ts is None or msg is None:
                continue
            f.write(json.dumps({"timestamp": ts, "message": msg}, ensure_ascii=False))
            f.write("\n")
            count += 1
        sys.stderr.write("\r  拉取中… 已获取 %d 条" % count)
        sys.stderr.flush()
        next_token = data.get("nextToken")
        if not next_token:
            break
sys.stderr.write("\r  拉取完成: %d 条 (%s)\n" % (count, log_group))
PYEOF
}

CONNECT_NDJSON="${WORK}/_connect.ndjson"
echo "==> 拉取 Connect AI Agent 日志 ..."
fetch_log_group "${CONNECT_REGION}" "${CONNECT_LG}" "${CONNECT_NDJSON}" "${START_MS}"

SPLIT_ARGS=(--connect "${CONNECT_NDJSON}" --out-dir "${LOGS_BUILD}")
GATEWAY_NDJSON=""
if [[ -n "${GATEWAY_ARN}" ]]; then
  GATEWAY_NDJSON="${WORK}/_gateway.ndjson"
  echo "==> 拉取 Bedrock AgentCore Gateway 日志 ..."
  fetch_log_group "${GATEWAY_REGION}" "${GATEWAY_LG}" "${GATEWAY_NDJSON}" "${START_MS}"
  SPLIT_ARGS+=(--gateway "${GATEWAY_NDJSON}")
fi

# ---------------------------------------------------------------------------
# 2. 确保日志存储桶存在并配置 CORS(需在拆分之前，因为拆分会逐个 Contact 上传)
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
# 3. 按 Contact ID 拆分: 每解析完一个 Contact 立即上传其 .log，再处理下一个
#     - 对 >100MB 的大日志会显示解析/上传进度
#     - 上传前检查该 Contact 的 .log 是否已存在于桶中，已存在则跳过(幂等)
# ---------------------------------------------------------------------------
SPLIT_ARGS+=(--bucket "${LOGS_BUCKET}" --region "${REGION}" --prefix "")
if [[ -n "${PROFILE}" ]]; then
  SPLIT_ARGS+=(--profile "${PROFILE}")
fi
echo "==> 按 Contact ID 解析并逐个上传到 s3://${LOGS_BUCKET}/ ..."
python3 "${SPLITTER}" "${SPLIT_ARGS[@]}"
rm -f "${CONNECT_NDJSON}" "${GATEWAY_NDJSON}"

CONTACT_COUNT="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('contactCount',0))" "${LOGS_BUILD}/index.json" 2>/dev/null || echo 0)"
if [[ "${CONTACT_COUNT}" == "0" ]]; then
  echo ""
  echo "⚠️  提示: 未从日志中解析出任何 Contact，站点会是空的。"
  echo "    可加大时间范围(去掉 --hours 或加大值)，或核对日志组 ARN/权限。"
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
# 5. 构建 Web 站点(登录门禁版)并上传到 Web 桶
# ---------------------------------------------------------------------------
echo "==> 构建站点到: ${SITE_BUILD}"
# 复用现有前端逻辑
cp "${WEB_DIR}/app.js"        "${SITE_BUILD}/"
cp "${WEB_DIR}/i18n.js"       "${SITE_BUILD}/"
cp "${WEB_DIR}/site-config.js" "${SITE_BUILD}/"
cp "${WEB_CF_DIR}/auth.js"    "${SITE_BUILD}/"

# 生成运行时配置 aws-config.js
cat > "${SITE_BUILD}/aws-config.js" <<JSON
/* 由 setup-connect-ai-agent-logs-analysis-in-cloudfront.sh 自动生成，请勿手工编辑 */
window.__AWS_CONFIG__ = {
  region: "${REGION}",
  userPoolId: "${USER_POOL_ID}",
  clientId: "${CLIENT_ID}",
  identityPoolId: "${IDENTITY_POOL_ID}",
  logsBucket: "${LOGS_BUCKET}",
  logsPrefix: ""
};
JSON

# 由 lib/web/index.html 生成登录门禁版 index.html:
#   - 去掉静态的 data.js(数据改为登录后从 S3 加载)
#   - 用 SDK + aws-config.js + auth.js 取代静态 app.js(app.js 由 auth.js 动态加载)
AWS_SDK_URL="${AWS_SDK_URL}" python3 - "${WEB_DIR}/index.html" "${SITE_BUILD}/index.html" <<'PYEOF'
import os, re, sys
src, dst = sys.argv[1], sys.argv[2]
sdk = os.environ["AWS_SDK_URL"]
html = open(src, encoding="utf-8").read()

# 移除静态 data.js
html = re.sub(r'[ \t]*<script src="\./data\.js"></script>\s*\n', "", html)

# 用鉴权脚本链替换静态 app.js
replacement = (
    '<script src="%s"></script>\n'
    '<script src="./aws-config.js"></script>\n'
    '<script src="./auth.js"></script>\n'
) % sdk
html, n = re.subn(r'[ \t]*<script src="\./app\.js"></script>\s*\n', replacement, html)
if n == 0:
    sys.stderr.write("警告: 未在 index.html 找到 app.js 脚本标签，请检查模板。\n")

open(dst, "w", encoding="utf-8").write(html)
PYEOF

# Web 桶
if bucket_exists "${WEB_BUCKET}"; then
  echo "==> Web 桶已存在，复用: ${WEB_BUCKET}"
else
  create_bucket "${WEB_BUCKET}"
fi

echo "==> 上传站点到 s3://${WEB_BUCKET}/ ..."
awscli s3 sync "${SITE_BUILD}/" "s3://${WEB_BUCKET}/" --delete >/dev/null

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
# 7. 汇总
# ---------------------------------------------------------------------------
echo ""
echo "==================================================================="
echo " 部署完成 🎉"
echo "-------------------------------------------------------------------"
echo " 访问地址(CloudFront):  https://${DIST_DOMAIN}"
echo " 登录邮箱:              ${EMAIL}"
echo "   · 首次登录: 使用邮件里收到的一次性密码，登录后按提示设置新密码。"
echo "   · 忘记密码: 登录页点击「忘记密码」，向该邮箱发送新的验证码后重置。"
echo ""
echo " 资源清单:"
echo "   CloudFront 访问地址: https://${DIST_DOMAIN}"
echo "   CloudFront 分配 ID:  ${DIST_ID}"
echo "   日志存储桶:          s3://${LOGS_BUCKET}  (${CONTACT_COUNT} 个 Contact)"
echo "   Web 存储桶:          s3://${WEB_BUCKET}"
echo "   Cognito 用户池:      ${USER_POOL_ID}"
echo "   Cognito 应用客户端:  ${CLIENT_ID}"
echo "   Cognito 身份池:      ${IDENTITY_POOL_ID}"
echo "   鉴权角色:            ${AUTH_ROLE_ARN}"
echo "-------------------------------------------------------------------"
echo " 注意: CloudFront 分配首次部署通常需数分钟才能全球生效。"
echo "       若更新了日志，重跑本脚本会重新拆分上传并使 CloudFront 缓存失效。"
echo "==================================================================="

if [[ "${KEEP}" != "true" ]]; then
  rm -rf "${WORK}"
else
  echo " 本地构建目录已保留: ${WORK}"
fi
