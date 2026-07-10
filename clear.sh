#!/usr/bin/env bash
#
# clear.sh — 按资源清单删除一套由
#   setup-connect-ai-agent-logs-analysis-in-cloudfront.sh
# 创建/管理的 AWS 资源。
#
# 用法:
#   ./clear.sh <manifest-file> [--yes] [--profile <p>] [--keep-buckets]
#
# 参数:
#   <manifest-file>  setup 脚本生成的资源清单(aws-resources-<suffix>.manifest)
#   --yes | -y       跳过交互确认(危险: 直接删除)
#   --profile <p>    使用指定 AWS CLI profile
#   --keep-buckets   保留 S3 桶(只删其它资源;想留存日志时用)
#   -h, --help       显示帮助
#
# 说明:
#   - 删除不可逆。默认先打印将删除的资源并要求输入 yes 确认。
#   - 按依赖顺序删除: CloudFront 分配(先禁用并等待 Deployed) -> OAC -> Lambda ->
#     S3 桶(清空后删除) -> Cognito 身份池 -> Cognito 用户池 -> IAM 角色。
#   - 幂等: 资源不存在会跳过、不中断;个别删除失败仅告警并继续。
#
# 依赖: aws cli v2、python3。
#
# 注意: 有意不使用 `set -e`/`set -u`——删除是尽力而为(best-effort)，
#       单个资源失败或清单中某项为空都不应中断整体清理。
set -o pipefail

usage() {
  sed -n '2,23p' "${BASH_SOURCE[0]}" | sed 's/^#\{1,\} \{0,1\}//; s/^#$//'
}

# ---------------------------------------------------------------------------
# 解析参数
# ---------------------------------------------------------------------------
MANIFEST=""
ASSUME_YES="false"
PROFILE=""
KEEP_BUCKETS="false"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)       ASSUME_YES="true"; shift;;
    --profile)      PROFILE="$2"; shift 2;;
    --keep-buckets) KEEP_BUCKETS="true"; shift;;
    -h|--help)      usage; exit 0;;
    -*)             echo "未知参数: $1" >&2; usage; exit 1;;
    *)
      if [[ -z "${MANIFEST}" ]]; then MANIFEST="$1"; else
        echo "多余参数: $1" >&2; exit 1
      fi
      shift;;
  esac
done

[[ -n "${MANIFEST}" ]] || { echo "错误: 需指定清单文件。用法: ./clear.sh <manifest-file> [--yes]" >&2; exit 1; }
[[ -f "${MANIFEST}" ]] || { echo "错误: 清单文件不存在: ${MANIFEST}" >&2; exit 1; }
command -v aws >/dev/null 2>&1 || { echo "错误: 未找到 aws CLI(需 v2 且已配置凭证)。" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "错误: 未找到 python3。" >&2; exit 1; }

# aws CLI 包装(带上可选 profile)
awscli() {
  if [[ -n "${PROFILE}" ]]; then aws --profile "${PROFILE}" "$@"; else aws "$@"; fi
}

# ---------------------------------------------------------------------------
# 解析清单 -> 分类数组
# ---------------------------------------------------------------------------
REGION=""
ACCOUNT=""
CF_DISTRIBUTIONS=(); CF_OACS=(); LAMBDAS=(); S3_BUCKETS=()
IDENTITY_POOLS=(); USER_POOLS=(); IAM_ROLES=()

while IFS='|' read -r rtype rval; do
  # 跳过空行与注释
  [[ -z "${rtype}" ]] && continue
  case "${rtype}" in \#*) continue;; esac
  # 清理可能的回车与首尾空白
  rval="$(printf '%s' "${rval}" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  case "${rtype}" in
    REGION)                REGION="${rval}";;
    ACCOUNT)               ACCOUNT="${rval}";;
    CF_DISTRIBUTION)       [[ -n "${rval}" && "${rval}" != "None" ]] && CF_DISTRIBUTIONS+=("${rval}");;
    CF_OAC)                [[ -n "${rval}" && "${rval}" != "None" ]] && CF_OACS+=("${rval}");;
    LAMBDA)                [[ -n "${rval}" ]] && LAMBDAS+=("${rval}");;
    S3_BUCKET)             [[ -n "${rval}" ]] && S3_BUCKETS+=("${rval}");;
    COGNITO_IDENTITY_POOL) [[ -n "${rval}" && "${rval}" != "None" ]] && IDENTITY_POOLS+=("${rval}");;
    COGNITO_USER_POOL)     [[ -n "${rval}" && "${rval}" != "None" ]] && USER_POOLS+=("${rval}");;
    IAM_ROLE)              [[ -n "${rval}" ]] && IAM_ROLES+=("${rval}");;
    *)                     echo "  (忽略未知条目: ${rtype}|${rval})";;
  esac
done < "${MANIFEST}"

# 区域参数(IAM/CloudFront 为全局服务，不需要 region;其余带上)
REGION_ARG=()
[[ -n "${REGION}" ]] && REGION_ARG=(--region "${REGION}")

# ---------------------------------------------------------------------------
# 删除函数(全部幂等: 资源不存在则跳过)
# ---------------------------------------------------------------------------
delete_distribution() {
  local id="$1"
  if ! awscli cloudfront get-distribution --id "${id}" >/dev/null 2>&1; then
    echo "  分配不存在，跳过: ${id}"; return 0
  fi
  local tmp etag enabled
  tmp="$(mktemp)"
  etag="$(awscli cloudfront get-distribution-config --id "${id}" --query 'ETag' --output text 2>/dev/null)"
  awscli cloudfront get-distribution-config --id "${id}" --query 'DistributionConfig' --output json > "${tmp}" 2>/dev/null
  enabled="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("Enabled"))' "${tmp}" 2>/dev/null)"
  if [[ "${enabled}" == "True" ]]; then
    echo "  禁用分配 ${id} ..."
    python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["Enabled"]=False; json.dump(d, open(p,"w"))' "${tmp}"
    awscli cloudfront update-distribution --id "${id}" \
      --distribution-config "file://${tmp}" --if-match "${etag}" >/dev/null 2>&1 \
      || echo "  ⚠️ 禁用分配失败(可能已在禁用中): ${id}"
  fi
  echo "  等待分配 ${id} 变为 Deployed(可能数分钟)…"
  awscli cloudfront wait distribution-deployed --id "${id}" 2>/dev/null || true
  etag="$(awscli cloudfront get-distribution-config --id "${id}" --query 'ETag' --output text 2>/dev/null)"
  if awscli cloudfront delete-distribution --id "${id}" --if-match "${etag}" 2>/dev/null; then
    echo "  已删除 CloudFront 分配: ${id}"
  else
    echo "  ⚠️ 删除分配失败(可能仍在部署中，可稍后重跑 clear.sh): ${id}"
  fi
  rm -f "${tmp}"
}

delete_oac() {
  local id="$1" etag n
  # 分配删除后 OAC 可能短暂仍被标记占用，重试几次
  for n in 1 2 3 4 5; do
    etag="$(awscli cloudfront get-origin-access-control --id "${id}" --query 'ETag' --output text 2>/dev/null)"
    if [[ -z "${etag}" || "${etag}" == "None" ]]; then
      echo "  OAC 不存在，跳过: ${id}"; return 0
    fi
    if awscli cloudfront delete-origin-access-control --id "${id}" --if-match "${etag}" 2>/dev/null; then
      echo "  已删除 OAC: ${id}"; return 0
    fi
    echo "  OAC 仍被占用，等待后重试 (${n}/5) ..."
    sleep 10
  done
  echo "  ⚠️ 删除 OAC 失败(请确认对应分配已删除后重跑): ${id}"
}

delete_lambda() {
  local name="$1"
  if awscli lambda delete-function --function-name "${name}" "${REGION_ARG[@]}" 2>/dev/null; then
    echo "  已删除 Lambda: ${name}"
  else
    echo "  Lambda 不存在或已删除，跳过: ${name}"
  fi
}

delete_bucket() {
  local b="$1"
  if ! awscli s3api head-bucket --bucket "${b}" "${REGION_ARG[@]}" >/dev/null 2>&1; then
    echo "  S3 桶不存在，跳过: ${b}"; return 0
  fi
  echo "  清空并删除 S3 桶: ${b} ..."
  if awscli s3 rb "s3://${b}" --force "${REGION_ARG[@]}" >/dev/null 2>&1; then
    echo "  已删除 S3 桶: ${b}"
  else
    echo "  ⚠️ 删除 S3 桶失败(可能有对象版本残留或权限不足): ${b}"
  fi
}

delete_identity_pool() {
  local id="$1"
  if awscli cognito-identity delete-identity-pool --identity-pool-id "${id}" "${REGION_ARG[@]}" 2>/dev/null; then
    echo "  已删除 Cognito 身份池: ${id}"
  else
    echo "  身份池不存在或已删除，跳过: ${id}"
  fi
}

delete_user_pool() {
  local id="$1" dom
  # 若曾创建自定义域需先删域(本部署未创建;稳妥起见探测)
  dom="$(awscli cognito-idp describe-user-pool --user-pool-id "${id}" "${REGION_ARG[@]}" \
        --query 'UserPool.Domain' --output text 2>/dev/null)"
  if [[ -n "${dom}" && "${dom}" != "None" ]]; then
    awscli cognito-idp delete-user-pool-domain --user-pool-id "${id}" --domain "${dom}" \
      "${REGION_ARG[@]}" >/dev/null 2>&1 || true
  fi
  if awscli cognito-idp delete-user-pool --user-pool-id "${id}" "${REGION_ARG[@]}" 2>/dev/null; then
    echo "  已删除 Cognito 用户池: ${id}"
  else
    echo "  用户池不存在或已删除，跳过: ${id}"
  fi
}

delete_role() {
  local r="$1" pols att p a
  if ! awscli iam get-role --role-name "${r}" >/dev/null 2>&1; then
    echo "  IAM 角色不存在，跳过: ${r}"; return 0
  fi
  # 先删内联策略
  pols="$(awscli iam list-role-policies --role-name "${r}" --query 'PolicyNames[]' --output text 2>/dev/null)"
  for p in ${pols}; do
    [[ -z "${p}" || "${p}" == "None" ]] && continue
    awscli iam delete-role-policy --role-name "${r}" --policy-name "${p}" >/dev/null 2>&1 || true
  done
  # 再分离托管策略(本部署未附加;稳妥起见)
  att="$(awscli iam list-attached-role-policies --role-name "${r}" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null)"
  for a in ${att}; do
    [[ -z "${a}" || "${a}" == "None" ]] && continue
    awscli iam detach-role-policy --role-name "${r}" --policy-arn "${a}" >/dev/null 2>&1 || true
  done
  if awscli iam delete-role --role-name "${r}" 2>/dev/null; then
    echo "  已删除 IAM 角色: ${r}"
  else
    echo "  ⚠️ 删除 IAM 角色失败: ${r}"
  fi
}

print_items() {
  local label="$1"; shift
  [[ $# -eq 0 ]] && return 0
  local it
  for it in "$@"; do echo "   [${label}] ${it}"; done
}

# ---------------------------------------------------------------------------
# 打印计划 + 确认
# ---------------------------------------------------------------------------
echo "==================================================================="
echo " 将根据清单删除以下 AWS 资源"
echo "   区域(region) : ${REGION:-未指定}"
echo "   账号(account): ${ACCOUNT:-未知}"
echo "   清单文件     : ${MANIFEST}"
echo "-------------------------------------------------------------------"
print_items "CloudFront 分配" "${CF_DISTRIBUTIONS[@]}"
print_items "CloudFront OAC"  "${CF_OACS[@]}"
print_items "Lambda"          "${LAMBDAS[@]}"
if [[ "${KEEP_BUCKETS}" == "true" ]]; then
  echo "   [S3 桶] (已用 --keep-buckets 保留，不删除)"
else
  print_items "S3 桶"         "${S3_BUCKETS[@]}"
fi
print_items "Cognito 身份池"  "${IDENTITY_POOLS[@]}"
print_items "Cognito 用户池"  "${USER_POOLS[@]}"
print_items "IAM 角色"        "${IAM_ROLES[@]}"
echo "==================================================================="

if [[ "${ASSUME_YES}" != "true" ]]; then
  echo ""
  echo "⚠️  以上资源将被永久删除，且不可恢复。"
  printf "确认删除? 请输入 yes 继续: "
  read -r ans
  [[ "${ans}" == "yes" ]] || { echo "已取消，未删除任何资源。"; exit 0; }
fi

# ---------------------------------------------------------------------------
# 按依赖顺序删除
# ---------------------------------------------------------------------------
echo "==> 删除 CloudFront 分配 ..."
for id in "${CF_DISTRIBUTIONS[@]}"; do delete_distribution "${id}"; done
echo "==> 删除 CloudFront OAC ..."
for id in "${CF_OACS[@]}"; do delete_oac "${id}"; done
echo "==> 删除 Lambda ..."
for n in "${LAMBDAS[@]}"; do delete_lambda "${n}"; done
if [[ "${KEEP_BUCKETS}" != "true" ]]; then
  echo "==> 删除 S3 桶 ..."
  for b in "${S3_BUCKETS[@]}"; do delete_bucket "${b}"; done
else
  echo "==> 跳过 S3 桶(--keep-buckets)"
fi
echo "==> 删除 Cognito 身份池 ..."
for id in "${IDENTITY_POOLS[@]}"; do delete_identity_pool "${id}"; done
echo "==> 删除 Cognito 用户池 ..."
for id in "${USER_POOLS[@]}"; do delete_user_pool "${id}"; done
echo "==> 删除 IAM 角色 ..."
for r in "${IAM_ROLES[@]}"; do delete_role "${r}"; done

echo "==================================================================="
echo " 清理完成。"
echo " 清单文件未删除，如已确认全部清理，可自行移除: ${MANIFEST}"
echo "==================================================================="
