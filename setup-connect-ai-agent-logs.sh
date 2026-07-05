#!/usr/bin/env bash
#
# setup-connect-ai-agent-logs.sh
#
# 用法:
#   ./setup-connect-ai-agent-logs.sh <amazon-connect-instance-arn>
#
# 示例:
#   ./setup-connect-ai-agent-logs.sh \
#     arn:aws:connect:us-west-2:991727053196:instance/abcd1234-5678-90ab-cdef-1234567890ab
#
# 功能:
#   只需提供 Amazon Connect 实例 ARN，脚本会自动完成 Connect AI Agent
#   的 CloudWatch Logs 日志投递配置:
#     1. 解析实例 ARN，得到 region / account-id / instance-id
#     2. 通过 Connect 集成关联找到底层的 Q in Connect (Wisdom) assistant ARN
#     3. 创建/复用投递源 (PutDeliverySource, logType=EVENT_LOGS)
#     4. 创建目标日志组
#     5. 创建/更新投递目标 (PutDeliveryDestination, 输出 json 到 CloudWatch Logs)
#     6. 创建投递关系 (CreateDelivery)，将源与目标关联
#
# 依赖: aws cli v2 （已配置好凭证），无需 jq。
#
set -euo pipefail

# ----------------------------------------------------------------------------
# 0. 参数与环境检查
# ----------------------------------------------------------------------------
INSTANCE_ARN="${1:-}"

# 未通过参数提供 ARN 时，提示用户手动输入 Amazon Connect 客户实例 ARN
if [[ -z "${INSTANCE_ARN}" ]]; then
  echo "请输入 Amazon Connect 客户实例 ARN" >&2
  echo "（示例: arn:aws:connect:us-west-2:111122223333:instance/<instance-id>）:" >&2
  read -r INSTANCE_ARN
fi

# 去除可能存在的首尾空白字符
INSTANCE_ARN="$(echo "${INSTANCE_ARN}" | tr -d '[:space:]')"

if [[ -z "${INSTANCE_ARN}" ]]; then
  echo "错误: 未提供 Amazon Connect 客户实例 ARN。" >&2
  echo "用法: $0 <amazon-connect-instance-arn>" >&2
  exit 1
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "错误: 未找到 aws CLI，请先安装并配置凭证。" >&2
  exit 1
fi

# 校验 ARN 形态: arn:aws:connect:<region>:<account>:instance/<instance-id>
if [[ ! "${INSTANCE_ARN}" =~ ^arn:aws:connect:[a-z0-9-]+:[0-9]+:instance/[0-9a-fA-F-]+$ ]]; then
  echo "错误: 这不是合法的 Connect 实例 ARN:" >&2
  echo "  ${INSTANCE_ARN}" >&2
  echo "期望形如: arn:aws:connect:us-west-2:111122223333:instance/<instance-id>" >&2
  exit 1
fi

# ----------------------------------------------------------------------------
# 1. 解析实例 ARN
# ----------------------------------------------------------------------------
REGION="$(echo "${INSTANCE_ARN}" | cut -d: -f4)"
ACCOUNT_ID="$(echo "${INSTANCE_ARN}" | cut -d: -f5)"
INSTANCE_ID="$(echo "${INSTANCE_ARN}" | cut -d/ -f2)"

echo "==> 解析实例 ARN"
echo "    Region      : ${REGION}"
echo "    Account ID  : ${ACCOUNT_ID}"
echo "    Instance ID : ${INSTANCE_ID}"

# 命名约定（与文档一致）
SOURCE_NAME="connect-ai-agent-delivery-source"
DEST_NAME="connect-ai-agent-delivery-destination"
LOG_GROUP="/aws/connect/ai-agent-logs"

# ----------------------------------------------------------------------------
# 2. 通过集成关联找到 Wisdom assistant ARN
# ----------------------------------------------------------------------------
echo "==> 查询该实例关联的 Q in Connect (Wisdom) assistant ..."
ASSISTANT_ARN="$(aws connect list-integration-associations \
  --instance-id "${INSTANCE_ID}" \
  --integration-type WISDOM_ASSISTANT \
  --region "${REGION}" \
  --query 'IntegrationAssociationSummaryList[0].IntegrationArn' \
  --output text 2>/dev/null || true)"

if [[ -z "${ASSISTANT_ARN}" || "${ASSISTANT_ARN}" == "None" ]]; then
  echo "错误: 在该 Connect 实例上未找到 WISDOM_ASSISTANT 集成关联。" >&2
  echo "      请先在 Connect 控制台为该实例启用 AI agent / Q in Connect。" >&2
  exit 1
fi

echo "    Assistant ARN: ${ASSISTANT_ARN}"

# ----------------------------------------------------------------------------
# 3. 创建/复用投递源 (PutDeliverySource)
# ----------------------------------------------------------------------------
echo "==> 检查是否已存在指向该 assistant 的投递源 ..."
EXISTING_SOURCE="$(aws logs describe-delivery-sources \
  --region "${REGION}" \
  --query "deliverySources[?contains(resourceArns, '${ASSISTANT_ARN}')].name | [0]" \
  --output text 2>/dev/null || true)"

if [[ -n "${EXISTING_SOURCE}" && "${EXISTING_SOURCE}" != "None" ]]; then
  SOURCE_NAME="${EXISTING_SOURCE}"
  echo "    已存在投递源，直接复用: ${SOURCE_NAME}"
else
  echo "    未找到，创建投递源: ${SOURCE_NAME}"
  aws logs put-delivery-source \
    --name "${SOURCE_NAME}" \
    --log-type "EVENT_LOGS" \
    --resource-arn "${ASSISTANT_ARN}" \
    --region "${REGION}" >/dev/null
  echo "    投递源已创建。"
fi

# ----------------------------------------------------------------------------
# 4. 创建目标日志组（已存在则忽略）
# ----------------------------------------------------------------------------
echo "==> 确保日志组存在: ${LOG_GROUP}"
if aws logs create-log-group \
     --log-group-name "${LOG_GROUP}" \
     --region "${REGION}" 2>/dev/null; then
  echo "    日志组已创建。"
else
  echo "    日志组已存在，跳过创建。"
fi

# ----------------------------------------------------------------------------
# 5. 创建/更新投递目标 (PutDeliveryDestination)
# ----------------------------------------------------------------------------
DEST_RESOURCE_ARN="arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:${LOG_GROUP}:*"

echo "==> 创建/更新投递目标: ${DEST_NAME}"
DEST_ARN="$(aws logs put-delivery-destination \
  --name "${DEST_NAME}" \
  --output-format "json" \
  --delivery-destination-configuration "{\"destinationResourceArn\": \"${DEST_RESOURCE_ARN}\"}" \
  --region "${REGION}" \
  --query 'deliveryDestination.arn' \
  --output text)"

echo "    投递目标 ARN: ${DEST_ARN}"

# ----------------------------------------------------------------------------
# 6. 创建投递关系 (CreateDelivery)，已存在则跳过
# ----------------------------------------------------------------------------
echo "==> 检查投递关系是否已存在 ..."
EXISTING_DELIVERY="$(aws logs describe-deliveries \
  --region "${REGION}" \
  --query "deliveries[?deliverySourceName=='${SOURCE_NAME}' && deliveryDestinationArn=='${DEST_ARN}'].id | [0]" \
  --output text 2>/dev/null || true)"

if [[ -n "${EXISTING_DELIVERY}" && "${EXISTING_DELIVERY}" != "None" ]]; then
  echo "    投递关系已存在 (id=${EXISTING_DELIVERY})，跳过创建。"
else
  echo "    创建投递关系 ..."
  DELIVERY_ID="$(aws logs create-delivery \
    --delivery-source-name "${SOURCE_NAME}" \
    --delivery-destination-arn "${DEST_ARN}" \
    --region "${REGION}" \
    --query 'delivery.id' \
    --output text)"
  echo "    投递关系已创建 (id=${DELIVERY_ID})。"
fi

# ----------------------------------------------------------------------------
# 7. 完成提示
# ----------------------------------------------------------------------------
echo ""
echo "==================================================================="
echo "配置完成！"
echo "  投递源     : ${SOURCE_NAME}"
echo "  投递目标   : ${DEST_NAME}"
echo "  日志组     : ${LOG_GROUP} (region: ${REGION})"
echo ""
echo "产生真实会话事件后，可这样查看日志:"
echo "  aws logs tail \"${LOG_GROUP}\" --region ${REGION} --follow"
echo "==================================================================="
