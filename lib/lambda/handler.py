#!/usr/bin/env python3
"""
handler.py — S3 事件触发的 Lambda: 在云端完成日志解析与拆分(替代本地 split-contacts.py)

触发方式:
  日志桶 ai-agent-logs<suffix> 配置了 S3 事件通知: 当 "trigger/" 前缀下出现 .json
  触发对象(由部署脚本在原始数据上传完成后写入)时，调用本函数。

处理逻辑(全部在云端，本地不落任何文件):
  1) 读取触发对象(JSON)，得到原始数据的键: connect(必选) / gateway(可选) 及 prefix;
  2) 从桶里流式读取 raw/connect.ndjson、raw/gateway.ndjson(每行一个 {timestamp,message});
  3) 复用 connect_parser(即 parse-connect-ai-logs.py)的 sanitize/关联逻辑，按 Contact ID
     分组，为每个 Contact 生成 <contactId>.log(已存在则跳过，幂等)并写回 logs/ 前缀;
  4) 生成 index.json 清单写回桶根(供 Web 应用加载)。

依赖: Lambda 运行时自带 boto3;connect_parser.py 随部署包一起打包。
"""
import datetime
import json
import re
import urllib.parse

import boto3
import connect_parser as cp

s3 = boto3.client("s3")

UNATTACHED_GATEWAY = "unattached-gateway-logs"


def _read_ndjson(bucket, key, source):
    """流式读取 S3 上的 NDJSON(每行一个事件)，归一化为 rows。"""
    rows = []
    resp = s3.get_object(Bucket=bucket, Key=key)
    for raw in resp["Body"].iter_lines():
        if not raw:
            continue
        try:
            e = json.loads(raw.decode("utf-8", "ignore"))
        except (ValueError, TypeError):
            continue
        ts, msg = e.get("timestamp"), e.get("message")
        if ts is None or msg is None:
            continue
        rows.append({"timestamp": int(ts),
                     "message": cp.sanitize_message(msg),
                     "source": source})
    return rows


def _safe_name(contact_id):
    name = re.sub(r"[^A-Za-z0-9._-]+", "_", str(contact_id)).strip("._")
    return name or "unknown"


def _resolve_contact_id(row):
    cid = row.get("contactId") or ""
    if cid:
        return cid
    if row.get("source") == "gateway":
        return UNATTACHED_GATEWAY
    _, sid = cp._extract_connect_ids(row.get("message", ""))
    return sid or "unknown"


def _object_exists(bucket, key):
    try:
        s3.head_object(Bucket=bucket, Key=key)
        return True
    except Exception:  # noqa: BLE001  (404/403 均视为不存在/需要重写)
        return False


def _process(bucket, connect_key, gateway_key, prefix):
    connect_rows = _read_ndjson(bucket, connect_key, "connect")
    gateway_rows = _read_ndjson(bucket, gateway_key, "gateway") if gateway_key else []

    cp.correlate(connect_rows, gateway_rows)

    all_rows = connect_rows + gateway_rows
    all_rows.sort(key=lambda r: r["timestamp"])

    groups = {}
    for r in all_rows:
        groups.setdefault(_resolve_contact_id(r), []).append(r)

    used_names = {}
    contacts_index = []
    uploaded = skipped = 0

    for cid in sorted(groups.keys()):
        rows = groups[cid]
        base = _safe_name(cid)
        name = base
        n = 1
        while name in used_names:
            n += 1
            name = "%s-%d" % (base, n)
        used_names[name] = cid

        rel_path = "logs/%s.log" % name
        key = prefix + rel_path

        min_ts = min(r["timestamp"] for r in rows)
        max_ts = max(r["timestamp"] for r in rows)
        source_counts = {}
        for r in rows:
            src = r.get("source", "connect")
            source_counts[src] = source_counts.get(src, 0) + 1

        # 已存在则跳过(幂等)
        if _object_exists(bucket, key):
            skipped += 1
        else:
            lines = []
            for r in rows:
                lines.append(json.dumps({
                    "timestamp": r["timestamp"],
                    "message": r["message"],
                    "source": r.get("source", "connect"),
                    "contactId": cid,
                }, ensure_ascii=False))
            body = ("\n".join(lines) + "\n").encode("utf-8")
            s3.put_object(Bucket=bucket, Key=key, Body=body,
                          ContentType="text/plain; charset=utf-8")
            uploaded += 1

        contacts_index.append({
            "contactId": cid, "file": rel_path, "count": len(rows),
            "minTs": min_ts, "maxTs": max_ts, "sourceCounts": source_counts,
        })

    index = {
        "generatedAt": datetime.datetime.now(datetime.timezone.utc)
        .isoformat().replace("+00:00", "Z"),
        "contactCount": len(contacts_index),
        "eventCount": len(all_rows),
        "contacts": contacts_index,
    }
    s3.put_object(Bucket=bucket, Key=prefix + "index.json",
                  Body=json.dumps(index, ensure_ascii=False).encode("utf-8"),
                  ContentType="application/json")

    print("processed: contacts=%d uploaded=%d skipped=%d events=%d"
          % (len(contacts_index), uploaded, skipped, len(all_rows)))
    return index


def handler(event, context):
    for rec in event.get("Records", []):
        bucket = rec["s3"]["bucket"]["name"]
        key = urllib.parse.unquote_plus(rec["s3"]["object"]["key"])
        trig = json.loads(s3.get_object(Bucket=bucket, Key=key)["Body"].read())
        _process(bucket, trig["connect"], trig.get("gateway"), trig.get("prefix", ""))
    return {"ok": True}
