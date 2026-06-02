# Amazon Connect AI Agent CloudWatch 日志自动配置

本仓库提供一个脚本，**只需传入 Amazon Connect 实例 ARN**，即可自动为该实例下的 Connect AI Agent（底层为 Amazon Q in Connect / Wisdom assistant）配置 CloudWatch Logs 日志投递。

| 文件 | 说明 |
|------|------|
| [`setup-connect-ai-agent-logs.sh`](./setup-connect-ai-agent-logs.sh) | 一键配置脚本，幂等可重复执行 |

> 配置原理参考官方文档：[Monitor Connect AI agents by using CloudWatch Logs](https://docs.aws.amazon.com/connect/latest/adminguide/monitor-ai-agents.html)

---

## 前置条件

1. **AWS CLI v2** 已安装，并配置了具备目标账号/区域权限的凭证。
2. 执行身份具备以下权限：
   - Connect：`connect:ListIntegrationAssociations`
   - CloudWatch Logs：`logs:DescribeDeliverySources`、`logs:PutDeliverySource`、`logs:CreateLogGroup`、`logs:PutDeliveryDestination`、`logs:DescribeDeliveries`、`logs:CreateDelivery`
   - 供应日志投递：`wisdom:AllowVendedLogDeliveryForResource`
3. 目标 Connect 实例**已启用 AI agent / Q in Connect**（即存在 `WISDOM_ASSISTANT` 集成关联），否则脚本会在第 2 步报错退出。

---

## 用法

```bash
# 赋予执行权限（首次）
chmod +x setup-connect-ai-agent-logs.sh

# 执行：唯一参数是 Connect 实例 ARN
./setup-connect-ai-agent-logs.sh <amazon-connect-instance-arn>
```

示例：

```bash
./setup-connect-ai-agent-logs.sh \
  arn:aws:connect:us-west-2:991727053196:instance/abcd1234-5678-90ab-cdef-1234567890ab
```

脚本**无需手动指定 region**——region、account-id、instance-id 都从实例 ARN 中解析得到。

### 命名约定

脚本使用以下固定名称：

| 资源 | 名称 |
|------|------|
| 投递源 Delivery Source | `connect-ai-agent-delivery-source` |
| 投递目标 Delivery Destination | `connect-ai-agent-delivery-destination` |
| 日志组 Log Group | `/aws/connect/ai-agent-logs` |

> 如果脚本检测到该 assistant 已存在投递源，会自动复用其原有名称，而非强制使用上表中的名字。

---

## 执行逻辑

脚本按以下顺序执行，每一步都做了**幂等处理**（已存在则复用/跳过），因此可以安全地重复运行。

```
输入: Connect 实例 ARN
  │
  ├─ ① 校验并解析 ARN  →  region / account-id / instance-id
  │
  ├─ ② 查询 WISDOM_ASSISTANT 集成关联  →  得到 assistant ARN
  │      (connect list-integration-associations)
  │
  ├─ ③ 投递源 Delivery Source
  │      已存在指向该 assistant 的源? → 复用
  │      否则创建 (logs put-delivery-source, logType=EVENT_LOGS)
  │
  ├─ ④ 日志组 Log Group  (/aws/connect/ai-agent-logs)
  │      创建; 已存在则跳过 (logs create-log-group)
  │
  ├─ ⑤ 投递目标 Delivery Destination
  │      创建/更新, 输出 json 到 CloudWatch Logs
  │      (logs put-delivery-destination)
  │
  └─ ⑥ 投递关系 Delivery
         已存在(同源+同目标)? → 跳过
         否则创建 (logs create-delivery)
  │
  ▼
完成: 打印资源汇总与查看日志的命令
```

### 各步骤详解

1. **解析与校验实例 ARN**
   用正则校验 ARN 形态 `arn:aws:connect:<region>:<account>:instance/<id>`，并用 `cut` 拆出 region、account-id、instance-id，作为后续所有命令的输入。

2. **定位 Wisdom assistant ARN**
   官方配置实际需要的是 `arn:aws:wisdom:...:assistant/...`，而用户只提供了实例 ARN。脚本通过 Connect 的集成关联接口把二者打通，取第一条 `WISDOM_ASSISTANT` 关联的 `IntegrationArn`。若查不到则说明实例未启用 AI agent，直接报错退出。

3. **创建/复用投递源**
   先查询是否已有指向该 assistant 的投递源（控制台启用功能时常会自动创建）。有则复用其名称，无则以 `EVENT_LOGS` 类型新建。

4. **确保日志组存在**
   投递目标指向 CloudWatch Logs 时，目标日志组必须先存在。`create-log-group` 若返回"已存在"错误则视为正常并跳过。

5. **创建/更新投递目标**
   指定 `outputFormat=json`，`destinationResourceArn` 指向日志组（ARN 结尾带 `:*`）。返回的投递目标 ARN 供下一步使用。

6. **创建投递关系**
   将"投递源"与"投递目标"关联，正式开始投递。先检查是否已存在相同源+目标的投递关系，避免重复创建。

---

## 涉及的 API 用途说明

### Amazon Connect

| API / CLI | 用途 |
|-----------|------|
| `connect list-integration-associations` | 列出 Connect 实例的集成关联。脚本用 `--integration-type WISDOM_ASSISTANT` 过滤，拿到底层 Q in Connect (Wisdom) assistant 的 ARN |

### CloudWatch Logs（供应日志投递三件套 + 日志组）

CloudWatch 的"供应日志（vended logs）"由三个对象串联组成：**投递源**指明"监控谁"，**投递目标**指明"存到哪"，**投递关系**把两者连起来开始投递。

| API / CLI | 用途 |
|-----------|------|
| `logs describe-delivery-sources` | 查询现有投递源，判断目标 assistant 是否已有投递源以便复用 |
| `logs put-delivery-source` | 创建投递源，指向 assistant 资源，`logType=EVENT_LOGS`（Connect AI agent 当前支持的日志类型）|
| `logs create-log-group` | 创建用于存储日志的 CloudWatch 日志组 `/aws/connect/ai-agent-logs` |
| `logs put-delivery-destination` | 创建/更新投递目标，指定存储位置（CloudWatch Logs）与输出格式（`json`）|
| `logs describe-deliveries` | 查询现有投递关系，避免重复创建 |
| `logs create-delivery` | 创建投递关系，把投递源与投递目标关联，正式开始投递 |

> `outputFormat` 还支持 `plain`、`w3c`、`raw`、`parquet`；投递目标除 CloudWatch Logs 外也可改为 Amazon S3 或 Amazon Data Firehose（需调整 `destinationResourceArn` 及相应资源权限）。

---

## 验证与查看日志

脚本执行成功后，会打印资源汇总和查看命令。产生真实会话事件后，可这样实时查看：

```bash
aws logs tail "/aws/connect/ai-agent-logs" --region <your-region> --follow
```

也可在 CloudWatch Logs Insights 中按会话过滤：

```
filter session_id   = "<SessionId>"
filter session_name = "<SessionName>"
```

> 短时间内看不到日志属正常现象——只有在有真实通话/聊天/任务/邮件会话事件时才会投递。

---

## 常见问题

- **报错"未找到 WISDOM_ASSISTANT 集成关联"**
  说明该 Connect 实例尚未启用 AI agent / Q in Connect，请先在 Connect 控制台启用。也可手动运行 `aws connect list-integration-associations --instance-id <id> --region <region>` 确认实际的 `IntegrationType` 取值。

- **`ServiceQuotaExceededException`**
  CloudWatch Logs 投递相关 API 存在配额限制，参见 [CloudWatch Logs endpoints and quotas](https://docs.aws.amazon.com/general/latest/gr/cwl_region.html)。

- **重复执行会不会建出重复资源？**
  不会。投递源、日志组、投递关系均做了存在性检查，幂等执行。

- **能否投递到 S3 / Firehose？**
  可以。修改脚本第 5 步的 `destinationResourceArn` 为对应的 S3 桶或 Firehose 流 ARN，并配置相应的资源策略。
