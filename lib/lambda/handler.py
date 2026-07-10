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
     分组，为每个 Contact 按"内容哈希"幂等地写 <contactId>.log 到 logs/ 前缀:
     内容未变则跳过、内容变化(或首次)则重写;
  4) 生成 index.json 清单写回桶根(供 Web 应用加载)，随后清理 logs/ 下不再被
     本次 index.json 引用的孤儿 .log 文件。

大日志量加固:
  - 每个 Contact 的 S3 head/put 通过线程池并发执行(默认 16 并发)，把原来
    "上千 Contact 串行几千次 S3 调用" 的耗时从数分钟降到数十秒级;
  - 逐个 Contact 构建并写出日志体、随即释放，峰值内存只受"最大单个 Contact +
    并发数"限制，避免一次性把所有输出体都堆在内存;
  - 幂等按"内容哈希"判定(而非仅按文件是否存在): 相同 suffix 换不同 --hours 重跑时，
    没变的 Contact 跳过、内容变化的 Contact 刷新、窗口缩小后多出的孤儿日志清理，
    保证 logs/ 与 index.json 始终一致;
  - 顶层 try/except: 解析失败时把错误写进 index.json(error 字段)，让部署脚本与
    前端能明确看到"解析失败"而不是无限等待一个永不出现的 index.json。
    注意: 内存溢出(OOM)或 15 分钟超时会直接杀死运行时，无法自报错误;这类情况
    应通过提高 Lambda 内存(见部署脚本 --lambda-memory)与缩小拉取时间范围来规避。

依赖: Lambda 运行时自带 boto3;connect_parser.py 随部署包一起打包。
"""
import concurrent.futures
import datetime
import hashlib
import json
import os
import re
import traceback
import urllib.parse

import boto3
from botocore.config import Config

import connect_parser as cp

UNATTACHED_GATEWAY = "unattached-gateway-logs"

# 并发写 S3 的线程数(可用环境变量覆盖)。连接池要略大于并发数，避免排队。
UPLOAD_WORKERS = max(1, int(os.environ.get("UPLOAD_WORKERS", "16")))
s3 = boto3.client("s3", config=Config(
    max_pool_connections=UPLOAD_WORKERS + 4,
    retries={"max_attempts": 5, "mode": "adaptive"},
))


def _read_ndjson(bucket, key, source):
    """流式读取 S3 上的 NDJSON(每行一个事件)，归一化为 rows。

    用 iter_lines() 从 S3 流式读取(不整文件落地)，逐行解析后追加。分组/关联/
    排序需要全量数据，因此这一份行数据会驻留内存(内存随日志量线性增长)。
    """
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


CONTENT_HASH_META = "contenthash"


def _object_meta_hash(bucket, key):
    """返回对象元数据里记录的内容哈希;对象不存在或无该元数据则返回 None。"""
    try:
        resp = s3.head_object(Bucket=bucket, Key=key)
    except Exception:  # noqa: BLE001  (404/403 均视为不存在)
        return None
    return (resp.get("Metadata") or {}).get(CONTENT_HASH_META)


def _write_contact(bucket, prefix, name, cid, rows):
    """处理单个 Contact: 计算摘要 + 按内容哈希幂等写出 <name>.log。

    返回 (index_entry, status)，status ∈ {"created","updated","skipped"}。

    幂等策略(按内容比对，而非仅按文件是否存在):
      - 为保证同一份事件集合在不同运行下生成完全相同的字节，先把该 Contact 的
        行按 (timestamp, source, message) 规范化排序，再逐行序列化成 body;
      - 计算 body 的 sha256，与对象元数据里记录的哈希比对:
          * 相等         -> 内容未变，跳过(不重写);
          * 不等 / 缺失  -> 内容变化(或首次/旧版本无哈希)，重写并写入新哈希。
      这样既保留幂等(没变的不重写)，又能在"窗口扩大 / 两次运行间该 Contact 又
      新增了日志"等场景下正确刷新其日志文件。

    该函数被线程池并发调用;只读取入参、只操作自身这一个对象，并发安全。
    """
    rel_path = "logs/%s.log" % name
    key = prefix + rel_path

    # 规范化排序: 让相同事件集合产出稳定字节，避免因抓取顺序不同而误判为"已变化"
    rows = sorted(rows, key=lambda r: (r["timestamp"], r.get("source", "connect"),
                                       r["message"]))

    min_ts = rows[0]["timestamp"]
    max_ts = rows[-1]["timestamp"]
    source_counts = {}
    lines = []
    for r in rows:
        src = r.get("source", "connect")
        source_counts[src] = source_counts.get(src, 0) + 1
        lines.append(json.dumps({
            "timestamp": r["timestamp"],
            "message": r["message"],
            "source": src,
            "contactId": cid,
        }, ensure_ascii=False))
    body = ("\n".join(lines) + "\n").encode("utf-8")
    del lines
    new_hash = hashlib.sha256(body).hexdigest()

    existing_hash = _object_meta_hash(bucket, key)
    if existing_hash == new_hash:
        status = "skipped"
    else:
        s3.put_object(Bucket=bucket, Key=key, Body=body,
                      ContentType="text/plain; charset=utf-8",
                      Metadata={CONTENT_HASH_META: new_hash})
        status = "updated" if existing_hash is not None else "created"

    entry = {
        "contactId": cid, "file": rel_path, "count": len(rows),
        "minTs": min_ts, "maxTs": max_ts, "sourceCounts": source_counts,
    }
    return entry, status


def _delete_orphan_logs(bucket, prefix, referenced_keys):
    """删除 logs/ 下不再被本次 index.json 引用的 <contactId>.log(孤儿文件)。

    仅限 prefix+"logs/" 前缀且以 .log 结尾的对象，不会触碰 raw/、trigger/、index.json。
    """
    logs_prefix = prefix + "logs/"
    to_delete = []
    token = None
    while True:
        kw = {"Bucket": bucket, "Prefix": logs_prefix}
        if token:
            kw["ContinuationToken"] = token
        resp = s3.list_objects_v2(**kw)
        for obj in resp.get("Contents", []):
            k = obj["Key"]
            if k.endswith(".log") and k not in referenced_keys:
                to_delete.append({"Key": k})
        if resp.get("IsTruncated"):
            token = resp.get("NextContinuationToken")
        else:
            break

    deleted = 0
    for i in range(0, len(to_delete), 1000):
        batch = to_delete[i:i + 1000]
        s3.delete_objects(Bucket=bucket, Delete={"Objects": batch, "Quiet": True})
        deleted += len(batch)
    return deleted


def _process(bucket, connect_key, gateway_key, prefix):
    connect_rows = _read_ndjson(bucket, connect_key, "connect")
    gateway_rows = _read_ndjson(bucket, gateway_key, "gateway") if gateway_key else []

    cp.correlate(connect_rows, gateway_rows)

    # 合并到一份并全局按时间排序;就地 extend + 释放 gateway_rows，避免额外整份拷贝。
    connect_rows.extend(gateway_rows)
    gateway_rows = None
    all_rows = connect_rows
    connect_rows = None
    all_rows.sort(key=lambda r: r["timestamp"])
    event_count = len(all_rows)

    # 按 Contact 分组(groups 复用同一批 dict 引用，不产生额外拷贝)
    groups = {}
    for r in all_rows:
        groups.setdefault(_resolve_contact_id(r), []).append(r)
    all_rows = None

    # 先串行计算每个 Contact 的唯一文件名(避免并发下命名竞争)，再并发写 S3
    used_names = {}
    tasks = []  # [(name, cid, rows)]
    for cid in sorted(groups.keys()):
        rows = groups[cid]
        base = _safe_name(cid)
        name = base
        n = 1
        while name in used_names:
            n += 1
            name = "%s-%d" % (base, n)
        used_names[name] = cid
        tasks.append((name, cid, rows))

    contacts_index = []
    created = updated = skipped = 0
    workers = min(UPLOAD_WORKERS, len(tasks)) or 1
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        futs = [pool.submit(_write_contact, bucket, prefix, name, cid, rows)
                for (name, cid, rows) in tasks]
        for fut in concurrent.futures.as_completed(futs):
            entry, status = fut.result()
            contacts_index.append(entry)
            if status == "created":
                created += 1
            elif status == "updated":
                updated += 1
            else:
                skipped += 1

    # 并发完成的顺序不确定，按 contactId 排序让 index 输出稳定
    contacts_index.sort(key=lambda e: e["contactId"])

    index = {
        "generatedAt": datetime.datetime.now(datetime.timezone.utc)
        .isoformat().replace("+00:00", "Z"),
        "contactCount": len(contacts_index),
        "eventCount": event_count,
        "contacts": contacts_index,
    }
    # 先写新的 index.json(它只引用本次确实存在的文件)，再清理孤儿:
    # 保证任何时刻 index.json 引用的文件都存在，不会指向已被删掉的对象。
    s3.put_object(Bucket=bucket, Key=prefix + "index.json",
                  Body=json.dumps(index, ensure_ascii=False).encode("utf-8"),
                  ContentType="application/json")

    referenced = {prefix + e["file"] for e in contacts_index}
    orphans = _delete_orphan_logs(bucket, prefix, referenced)

    print("processed: contacts=%d created=%d updated=%d skipped=%d "
          "orphans_deleted=%d events=%d workers=%d"
          % (len(contacts_index), created, updated, skipped,
             orphans, event_count, workers))
    return index


def _write_error_index(bucket, prefix, err):
    """把解析错误写进 index.json(error 字段)，让部署脚本/前端能明确感知失败。

    仅对"被捕获的异常"有效;OOM 或超时会直接杀死运行时，无法写出错误标记。
    """
    try:
        s3.put_object(
            Bucket=bucket, Key=prefix + "index.json",
            Body=json.dumps({
                "generatedAt": datetime.datetime.now(datetime.timezone.utc)
                .isoformat().replace("+00:00", "Z"),
                "error": str(err),
                "contactCount": 0,
                "eventCount": 0,
                "contacts": [],
            }, ensure_ascii=False).encode("utf-8"),
            ContentType="application/json")
    except Exception:  # noqa: BLE001  写错误标记本身失败就只能靠函数日志了
        pass


def handler(event, context):
    for rec in event.get("Records", []):
        bucket = rec["s3"]["bucket"]["name"]
        key = urllib.parse.unquote_plus(rec["s3"]["object"]["key"])
        trig = json.loads(s3.get_object(Bucket=bucket, Key=key)["Body"].read())
        prefix = trig.get("prefix", "")
        try:
            _process(bucket, trig["connect"], trig.get("gateway"), prefix)
        except Exception as err:  # noqa: BLE001
            traceback.print_exc()
            _write_error_index(bucket, prefix, err)
            raise
    return {"ok": True}
