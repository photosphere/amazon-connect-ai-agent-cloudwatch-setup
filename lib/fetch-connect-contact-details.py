#!/usr/bin/env python3
"""
fetch-connect-contact-details.py

调用 Amazon Connect API，为每个 Contact 拉取"无法从 CloudWatch AI Agent 日志里
得到"的补充字段，生成 connect-enrich.js 供前端消费:

  window.__CONNECT_CONTACT_ENRICH__ = {
    "<contactId>": {
      "summary":          "客户与机器人对话的智能摘要",  # 需求五
      "disconnectReason": "CUSTOMER_DISCONNECT",          # 需求八(挂断方)
      "surveyResult":     "5",                            # 需求十三(CSAT)
      "did":              "+1xxxxxxxxxx",                 # 接电话的 DID
      "aiAgentCalls":     3                               # 需求十四(可选)
    },
    ...
  }

数据来源(均通过 aws CLI, 需已配置凭证且有相应权限):
  - aws connect describe-contact        -> DisconnectReason / SystemEndpoint(DID) / Attributes / 录音在 S3 的位置
  - aws connect get-contact-attributes  -> 联系人属性(CSAT / BU / 摘要等自定义键)
  - aws s3 (list-objects-v2 / cp)       -> 读取与录音同桶的分析结果 JSON, 取生成式
                                            "自动交互摘要"(ContactSummary.AutomatedInteractionSummary)
    需要额外的 S3 权限: s3:ListBucket / s3:GetObject(录音/分析结果所在桶)

CSAT(满意度评分)取自联系人属性里的某个自定义键, 键名不写死, 由配置决定:
  优先级: --csat-attr 参数 > 环境变量 CSAT_ATTRIBUTE_KEY > config.env 里的 CSAT_ATTRIBUTE_KEY
          > 默认值 "botevaluation"

Contact ID 来源(二选一):
  --data-js FILE      从前端 data.js 里解析出所有 contactId(session_name)
  --contact-ids A,B   直接给定逗号分隔的 contactId 列表

用法:
  python3 fetch-connect-contact-details.py \
      --instance-id <connect-instance-id> --region us-east-1 \
      --data-js dist/data.js --out dist/connect-enrich.js

说明:
  - 摘要(通话/自动交互智能摘要)不在 describe-contact 返回体里, 而在与录音同桶的分析结果
    JSON(路径把 .../CallRecordings/<sub>/<date>/ 映射为 Analysis/Voice(或 Chat)/<sub>/<date>/,
    文件名形如 <contactId>_analysis_*.json)的
    ConversationCharacteristics.ContactSummary.AutomatedInteractionSummary.Content 里。
    脚本优先从该分析结果 JSON 取摘要, 取不到再回退 describe-contact 返回体字段及联系人
    属性里的 contactSummary / summary 自定义键。都取不到则留空, 前端显示 N/A。
  - 任何单个 Contact 拉取失败都不会中断整体, 仅记录并跳过该字段。
"""
import argparse
import json
import os
import re
import subprocess
import sys

# CSAT 联系人属性键名的默认值(可被配置覆盖, 见 resolve_csat_key)
DEFAULT_CSAT_ATTRIBUTE_KEY = "botevaluation"


def read_config_value(path, key):
    """从简单的 KEY="value" 形式的 env 配置文件里读取某个键;取不到返回 None。"""
    if not path or not os.path.isfile(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                if k.strip() != key:
                    continue
                v = v.strip().strip('"').strip("'")
                return v or None
    except OSError:
        return None
    return None


def resolve_csat_key(cli_value, config_path):
    """按优先级解析 CSAT 属性键名: CLI > 环境变量 > 配置文件 > 默认值。"""
    return (
        (cli_value or "").strip()
        or (os.environ.get("CSAT_ATTRIBUTE_KEY") or "").strip()
        or (read_config_value(config_path, "CSAT_ATTRIBUTE_KEY") or "").strip()
        or DEFAULT_CSAT_ATTRIBUTE_KEY
    )


def aws_cli(service, subcommand, args, region):
    """执行 aws <service> <subcommand> ... --output json 并返回解析后的 JSON;失败返回 None。"""
    cmd = ["aws", service, subcommand, "--region", region, "--output", "json"] + args
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, check=True)
    except FileNotFoundError:
        sys.stderr.write("错误: 未找到 aws CLI。\n")
        sys.exit(2)
    except subprocess.CalledProcessError as e:
        sys.stderr.write("  [%s %s] 调用失败: %s\n"
                         % (service, subcommand, (e.stderr or "").strip()[:300]))
        return None
    try:
        return json.loads(res.stdout or "{}")
    except ValueError:
        return None


def aws_connect(subcommand, args, region):
    """执行 aws connect <subcommand> ... 并返回解析后的 JSON;失败返回 None。"""
    return aws_cli("connect", subcommand, args, region)


def s3_get_text(bucket, key, region):
    """把 s3://bucket/key 的内容读为文本;失败返回 None。"""
    cmd = ["aws", "s3", "cp", "s3://%s/%s" % (bucket, key), "-", "--region", region]
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, check=True)
    except FileNotFoundError:
        sys.stderr.write("错误: 未找到 aws CLI。\n")
        sys.exit(2)
    except subprocess.CalledProcessError as e:
        sys.stderr.write("  [s3 cp %s] 调用失败: %s\n" % (key, (e.stderr or "").strip()[:300]))
        return None
    return res.stdout


def extract_contact_ids_from_data_js(path):
    """从 data.js 里解析出去重后的 contactId(优先 contactId 字段, 回退 session_name)。"""
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    m = re.search(r"=\s*(\[.*\])\s*;\s*$", text, re.S)
    if not m:
        return []
    try:
        rows = json.loads(m.group(1))
    except ValueError:
        return []
    ids = []
    seen = set()
    for r in rows:
        cid = r.get("contactId") or ""
        if not cid:
            msg = r.get("message") or ""
            mm = re.search(r'"session_name"\s*:\s*"([^"]+)"', msg)
            if mm:
                cid = mm.group(1)
        if cid and cid not in seen:
            seen.add(cid)
            ids.append(cid)
    return ids


def analysis_key_prefix(contact):
    """由 describe-contact 的 Recordings 位置推断分析结果 JSON 在 S3 的 (bucket, keyPrefix)。

    describe-contact 不直接返回摘要, 但会返回录音/记录在 S3 的位置, 例如:
        <bucket>/connect/<alias>/CallRecordings/ivr/2026/07/17/<cid>_<ts>_UTC.wav
    生成式"自动交互摘要"分析结果与录音同桶, 路径把
        .../CallRecordings/<sub>/<date>/   映射为   Analysis/Voice/<sub>/<date>/
    (聊天则为 ChatTranscripts/ -> Analysis/Chat/), 文件名形如
        <contactId>_analysis_<timestamp>.json
    返回 (bucket, prefix) 或 (None, None)。
    """
    recs = contact.get("Recordings") or []
    channel = (contact.get("Channel") or "VOICE").upper()
    analysis_root = "Analysis/Chat" if channel == "CHAT" else "Analysis/Voice"

    def rel_dir(loc, marker):
        # loc: <bucket>/.../<marker><sub>/<date>/<file>; 返回 (bucket, "<sub>/<date>")
        bucket, _, rest = loc.partition("/")
        if marker not in rest:
            return None, None
        sub = rest.split(marker, 1)[1]      # ivr/2026/07/17/<file>.wav
        if "/" not in sub:
            return None, None
        return bucket, sub.rsplit("/", 1)[0]  # ivr/2026/07/17

    # 优先用音频/文字记录(排除 AUTOMATED_INTERACTION_LOG 等辅助流)推断目录
    candidates = []
    for r in recs:
        if isinstance(r, dict) and r.get("StorageType") == "S3" and r.get("Location"):
            mst = r.get("MediaStreamType") or ""
            score = 0 if mst in ("AUDIO", "CHAT", "") else 1  # 辅助流排后面
            candidates.append((score, r["Location"]))
    candidates.sort(key=lambda x: x[0])

    for marker in ("CallRecordings/", "ChatTranscripts/"):
        for _, loc in candidates:
            bucket, subdir = rel_dir(loc, marker)
            if bucket and subdir:
                cid = contact.get("Id") or ""
                return bucket, "%s/%s/%s_analysis_" % (analysis_root, subdir, cid)
    return None, None


def fetch_analysis_summary(contact, region):
    """从 S3 分析结果 JSON 里取生成式"自动交互摘要"(AutomatedInteractionSummary)。取不到返回 ""。"""
    bucket, prefix = analysis_key_prefix(contact)
    if not bucket or not prefix:
        return ""
    lo = aws_cli("s3api", "list-objects-v2",
                 ["--bucket", bucket, "--prefix", prefix], region)
    keys = [c.get("Key") for c in (lo or {}).get("Contents", []) if c.get("Key")]
    if not keys:
        return ""
    # 文件名带时间戳, 可排序; 取最新的一个
    body = s3_get_text(bucket, sorted(keys)[-1], region)
    if not body:
        return ""
    try:
        data = json.loads(body)
    except ValueError:
        return ""
    cc = data.get("ConversationCharacteristics") or {}
    cs = cc.get("ContactSummary") or {}
    ais = cs.get("AutomatedInteractionSummary") or {}
    content = ais.get("Content")
    return content.strip() if isinstance(content, str) and content.strip() else ""


def pick_summary(contact, attrs):
    """尽力从 describe-contact 返回体或联系人属性里取一段"客户/机器人对话摘要"。"""
    # 1) describe-contact 可能返回的摘要字段(不同版本命名不一, 逐个尝试)
    for key in ("Summary", "ContactSummary", "GeneratedSummary"):
        v = contact.get(key)
        if isinstance(v, dict):
            v = v.get("Content") or v.get("Text") or v.get("Summary")
        if isinstance(v, str) and v.strip():
            return v.strip()
    # 2) 联系人属性里的自定义摘要键
    for key in ("contactSummary", "summary", "conversationSummary", "aiAgentSummary"):
        v = attrs.get(key)
        if isinstance(v, str) and v.strip():
            return v.strip()
    return ""


def pick_did(contact):
    """取接电话的 DID: 优先 SystemEndpoint.Address, 回退 Tags['aws:connect:systemEndpoint']。"""
    ep = contact.get("SystemEndpoint") or {}
    if isinstance(ep, dict) and ep.get("Address"):
        return ep["Address"]
    tags = contact.get("Tags") or {}
    if isinstance(tags, dict) and tags.get("aws:connect:systemEndpoint"):
        return tags["aws:connect:systemEndpoint"]
    return ""


def fetch_one(instance_id, region, contact_id, csat_key):
    """拉取单个 contact 的补充字段, 返回 dict(可能部分为空)。

    csat_key: CSAT 满意度评分对应的联系人属性键名(来自配置, 不写死)。
    """
    out = {}
    dc = aws_connect("describe-contact",
                     ["--instance-id", instance_id, "--contact-id", contact_id],
                     region)
    contact = (dc or {}).get("Contact", {}) if dc else {}

    ga = aws_connect("get-contact-attributes",
                     ["--instance-id", instance_id, "--initial-contact-id", contact_id],
                     region)
    # 合并两处联系人属性: describe-contact 返回体里的 Attributes 作为兜底,
    # get-contact-attributes 的结果优先(键相同时覆盖)。
    dc_attrs = contact.get("Attributes", {})
    if not isinstance(dc_attrs, dict):
        dc_attrs = {}
    ga_attrs = (ga or {}).get("Attributes", {}) if ga else {}
    if not isinstance(ga_attrs, dict):
        ga_attrs = {}
    attrs = dict(dc_attrs)
    attrs.update(ga_attrs)

    disconnect = contact.get("DisconnectReason") or attrs.get("disconnectReason") or ""
    # 摘要优先取 S3 分析结果里的生成式"自动交互摘要", 取不到再回退到属性/返回体字段
    summary = fetch_analysis_summary(contact, region) or pick_summary(contact, attrs)
    did = pick_did(contact) or attrs.get("did", "")
    # CSAT: 用配置的键名取值; 未取到时保持回退 csat 键以兼容旧数据。
    survey = attrs.get(csat_key, attrs.get("csat", ""))
    ai_calls = attrs.get("aiAgentCalls", "")

    # 缓存完整 DescribeContact 结果, 供前端「Contact 详情」tab 离线/静态展示
    if contact:
        out["describeContact"] = {"Contact": contact}
    if disconnect:
        out["disconnectReason"] = disconnect
    if summary:
        out["summary"] = summary
    if did:
        out["did"] = did
    if survey not in ("", None):
        out["surveyResult"] = survey
    if ai_calls not in ("", None):
        try:
            out["aiAgentCalls"] = int(ai_calls)
        except (ValueError, TypeError):
            pass
    return out


def main():
    ap = argparse.ArgumentParser(
        description="调用 Amazon Connect API 生成前端补充数据 connect-enrich.js")
    ap.add_argument("--instance-id", required=True, help="Amazon Connect 实例 ID")
    ap.add_argument("--region", required=True, help="Amazon Connect 实例所在 region")
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--data-js", help="前端 data.js 路径(从中解析 contactId)")
    src.add_argument("--contact-ids", help="逗号分隔的 contactId 列表")
    ap.add_argument("--out", required=True, help="输出的 connect-enrich.js 路径")
    ap.add_argument("--config", default=os.path.join(os.getcwd(), "config.env"),
                    help="配置文件路径, 用于读取 CSAT_ATTRIBUTE_KEY 等(默认 ./config.env)")
    ap.add_argument("--csat-attr", default="",
                    help="CSAT 满意度评分对应的联系人属性键名; "
                         "留空则回退环境变量/配置文件, 最终默认 " + DEFAULT_CSAT_ATTRIBUTE_KEY)
    args = ap.parse_args()

    csat_key = resolve_csat_key(args.csat_attr, args.config)

    if args.contact_ids:
        contact_ids = [c.strip() for c in args.contact_ids.split(",") if c.strip()]
    else:
        contact_ids = extract_contact_ids_from_data_js(args.data_js)

    if not contact_ids:
        sys.stderr.write("未发现任何 contactId, 生成空的 connect-enrich.js。\n")

    enrich = {}
    ok = 0
    for cid in contact_ids:
        # contactId 形如 UUID; 过滤掉前端兜底分组名(含中文/括号)
        if not re.match(r"^[A-Za-z0-9._-]+$", cid):
            continue
        info = fetch_one(args.instance_id, args.region, cid, csat_key)
        if info:
            enrich[cid] = info
            ok += 1

    with open(args.out, "w", encoding="utf-8") as f:
        f.write("// 由 fetch-connect-contact-details.py 自动生成，请勿手工编辑\n")
        f.write("window.__CONNECT_CONTACT_ENRICH__ = ")
        f.write(json.dumps(enrich, ensure_ascii=False))
        f.write(";\n")

    sys.stderr.write("已写入 %s: 共 %d 个 Contact, 成功补充 %d 个。(CSAT 键名=%s)\n"
                     % (args.out, len(contact_ids), ok, csat_key))


if __name__ == "__main__":
    main()
