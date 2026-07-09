#!/usr/bin/env python3
"""
split-contacts.py

从 CloudWatch 拉取两路日志(Connect AI Agent + 可选 Bedrock AgentCore Gateway)，
按 Contact ID 拆分，为每个 Contact 生成以 Contact ID 命名的 .log 文件并上传到 S3，
同时生成 index.json 清单，供部署在 CloudFront 上的 Web 应用加载。

复用 parse-connect-ai-logs.py 的关联(correlate)与 ID 解析逻辑，保证拆分口径与
本地可视化版本完全一致。

为避免大日志(如 >100MB)撑爆本地磁盘，做了以下处理:
  1) 拉取阶段边翻页边把"原始日志"以 NDJSON 流式上传到 S3(raw/ 前缀)长期保存，
     不在本地磁盘落大文件;
  2) 解析/上传阶段在控制台实时显示进度;
  3) 每解析完一个 Contact 就把它的 .log 立即上传到 S3，再处理下一个;
     上传成功后删除该临时文件，本地磁盘占用始终很小;
  4) 上传前先检查该 Contact 的 .log 是否已存在于桶中，已存在则跳过(幂等)。

数据来源(二选一):
  A) CloudWatch:  --connect-log-group + --connect-region [ + --gateway-log-group/-region ]
                  拉取时把原始 NDJSON 归档到 s3://<bucket>/<prefix><raw-prefix>{connect,gateway}.ndjson
  B) 本地文件:    --connect FILE [ --gateway FILE ]   (主要用于本地测试)

输出:
  --out-dir DIR   小体积临时目录(仅暂存单个 .log 与 index.json)
  --bucket NAME   目标 S3 桶(如 ai-agent-logs<suffix>)
  --prefix P      S3 键前缀(默认空)
  --raw-prefix P  原始日志归档前缀(默认 raw/)
  --region R      S3 区域
  --profile P     AWS CLI profile

每个 .log 文件为 NDJSON(每行一个 JSON 对象):
  {"timestamp": <epoch_ms>, "message": "<原始消息>", "source": "connect"|"gateway",
   "contactId": "<Contact ID>"}
"""
import argparse
import datetime
import importlib.util
import json
import os
import re
import subprocess
import sys

# ---------------------------------------------------------------------------
# 动态加载同目录下的 parse-connect-ai-logs.py(文件名含连字符，不能直接 import)
# ---------------------------------------------------------------------------
_HERE = os.path.dirname(os.path.abspath(__file__))
_PARSER_PATH = os.path.join(_HERE, "parse-connect-ai-logs.py")
_spec = importlib.util.spec_from_file_location("connect_parser", _PARSER_PATH)
_parser = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_parser)


UNATTACHED_GATEWAY = "unattached-gateway-logs"


def _human_size(n):
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return "%.1f%s" % (n, unit)
        n /= 1024.0


def _progress(prefix, done, total, suffix=""):
    """在同一行刷新进度条(输出到 stderr)。"""
    pct = int(done * 100 / total) if total else 100
    bar_len = 24
    filled = int(bar_len * pct / 100)
    bar = "█" * filled + "░" * (bar_len - filled)
    sys.stderr.write("\r  %s [%s] %3d%% %s" % (prefix, bar, pct, suffix))
    sys.stderr.flush()


def _aws_base(profile):
    cmd = ["aws"]
    if profile:
        cmd += ["--profile", profile]
    return cmd


# ---------------------------------------------------------------------------
# A) 从 CloudWatch 拉取，并把原始 NDJSON 流式归档到 S3(不落本地大文件)
# ---------------------------------------------------------------------------
def fetch_source(region, log_group, start_ms, source, label,
                 bucket, raw_key, s3_region, profile):
    """翻页拉取日志组全部事件:
       - 边拉边把原始 NDJSON 写入 `aws s3 cp - s3://bucket/raw_key` 的 stdin(流式归档);
       - 同时把归一化后的行累积在内存里，供后续关联/拆分使用。
    返回内存中的 rows 列表。
    """
    archive = None
    if bucket:
        acmd = _aws_base(profile) + [
            "s3", "cp", "-", "s3://%s/%s" % (bucket, raw_key),
            "--content-type", "text/plain; charset=utf-8", "--only-show-errors",
        ]
        if s3_region:
            acmd += ["--region", s3_region]
        archive = subprocess.Popen(
            acmd, stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            text=True, encoding="utf-8",
        )

    rows = []
    next_token = None
    count = 0
    try:
        while True:
            cmd = _aws_base(profile) + [
                "logs", "filter-log-events", "--region", region,
                "--log-group-name", log_group, "--output", "json",
            ]
            if start_ms:
                cmd += ["--start-time", str(start_ms)]
            if next_token:
                cmd += ["--next-token", next_token]
            res = subprocess.run(cmd, capture_output=True, text=True)
            if res.returncode != 0:
                raise RuntimeError((res.stderr or "filter-log-events 调用失败").strip())
            data = json.loads(res.stdout or "{}")
            for ev in data.get("events", []):
                ts, msg = ev.get("timestamp"), ev.get("message")
                if ts is None or msg is None:
                    continue
                if archive:
                    archive.stdin.write(
                        json.dumps({"timestamp": ts, "message": msg}, ensure_ascii=False))
                    archive.stdin.write("\n")
                rows.append({
                    "timestamp": int(ts),
                    "message": _parser.sanitize_message(msg),
                    "source": source,
                })
                count += 1
            sys.stderr.write("\r  拉取 %s… 已获取 %d 条" % (label, count))
            sys.stderr.flush()
            next_token = data.get("nextToken")
            if not next_token:
                break
    finally:
        if archive:
            try:
                archive.stdin.close()
            except (BrokenPipeError, ValueError):
                pass
            rc = archive.wait()
            if rc != 0:
                raise RuntimeError(
                    "归档原始日志到 s3://%s/%s 失败(退出码 %d)" % (bucket, raw_key, rc))

    if bucket:
        sys.stderr.write(
            "\r  拉取 %s 完成: %d 条; 原始数据已归档到 s3://%s/%s\n"
            % (label, count, bucket, raw_key))
    else:
        sys.stderr.write("\r  拉取 %s 完成: %d 条\n" % (label, count))
    return rows


# ---------------------------------------------------------------------------
# B) 本地文件读取(测试用)
# ---------------------------------------------------------------------------
def load_ndjson(path, source, label):
    """流式读取 NDJSON(每行一个事件)，按字节百分比实时显示解析进度。"""
    total = os.path.getsize(path)
    rows, read, last_pct = [], 0, -1
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            read += len(line.encode("utf-8", "ignore"))
            s = line.strip()
            if s:
                try:
                    e = json.loads(s)
                    ts, msg = e.get("timestamp"), e.get("message")
                    if ts is not None and msg is not None:
                        rows.append({"timestamp": int(ts),
                                     "message": _parser.sanitize_message(msg),
                                     "source": source})
                except (ValueError, TypeError):
                    pass
            pct = int(read * 100 / total) if total else 100
            if pct != last_pct:
                last_pct = pct
                _progress("解析 %s" % label, read, total,
                          "%s / %s · %d 条" % (_human_size(read), _human_size(total), len(rows)))
    _progress("解析 %s" % label, total, total, "%s · %d 条" % (_human_size(total), len(rows)))
    sys.stderr.write("\n")
    return rows


def load_input(path, source, label):
    if path.endswith(".ndjson"):
        return load_ndjson(path, source, label)
    sys.stderr.write("  解析 %s: %s (%s)\n"
                     % (label, os.path.basename(path), _human_size(os.path.getsize(path))))
    return _parser.load_any(path, source)


def _safe_name(contact_id):
    """把 Contact ID 转成安全的文件名(仅保留字母数字与 . _ -)。"""
    name = re.sub(r"[^A-Za-z0-9._-]+", "_", str(contact_id)).strip("._")
    return name or "unknown"


def _resolve_contact_id(row):
    """给一行日志确定归属的 Contact ID。"""
    cid = row.get("contactId") or ""
    if cid:
        return cid
    if row.get("source") == "gateway":
        return UNATTACHED_GATEWAY
    _, sid = _parser._extract_connect_ids(row.get("message", ""))
    return sid or "unknown"


def _object_exists(key, bucket, region, profile):
    """检查 S3 上是否已存在该对象(head-object 返回码 0 表示存在)。"""
    cmd = _aws_base(profile) + ["s3api", "head-object", "--bucket", bucket, "--key", key]
    if region:
        cmd += ["--region", region]
    return subprocess.run(cmd, capture_output=True, text=True).returncode == 0


def _upload(local_path, key, bucket, region, profile):
    """用 aws CLI 把单个文件上传到 S3;失败则抛出异常。"""
    ctype = "application/json" if key.endswith(".json") else "text/plain; charset=utf-8"
    cmd = _aws_base(profile) + [
        "s3", "cp", local_path, "s3://%s/%s" % (bucket, key),
        "--content-type", ctype, "--only-show-errors",
    ]
    if region:
        cmd += ["--region", region]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        raise RuntimeError("上传 %s 失败: %s" % (key, (res.stderr or "").strip()))


def main():
    ap = argparse.ArgumentParser(
        description="拉取并按 Contact ID 拆分 Connect AI Agent + Gateway 日志")
    # 数据来源 A: CloudWatch
    ap.add_argument("--connect-log-group", help="Connect 日志组名")
    ap.add_argument("--connect-region", default="", help="Connect 日志组区域")
    ap.add_argument("--gateway-log-group", help="Gateway 日志组名(可选)")
    ap.add_argument("--gateway-region", default="", help="Gateway 日志组区域")
    ap.add_argument("--start-ms", default="", help="起始时间(epoch 毫秒);空=全部历史")
    # 数据来源 B: 本地文件(测试)
    ap.add_argument("--connect", help="本地 Connect 日志文件")
    ap.add_argument("--gateway", help="本地 Gateway 日志文件(可选)")
    # 输出与上传
    ap.add_argument("--out-dir", required=True, help="临时目录(暂存单个 .log 与 index.json)")
    ap.add_argument("--bucket", help="目标 S3 桶;提供后逐个 Contact 上传")
    ap.add_argument("--prefix", default="", help="S3 键前缀(默认空)")
    ap.add_argument("--raw-prefix", default="raw/", help="原始日志归档前缀(默认 raw/)")
    ap.add_argument("--region", default="", help="S3 区域")
    ap.add_argument("--profile", default="", help="AWS CLI profile")
    args = ap.parse_args()

    prefix = args.prefix or ""
    raw_prefix = args.raw_prefix or ""

    # --- 获取两路日志 ---
    sys.stderr.write("==> 拉取日志并归档原始数据到 S3 ...\n")
    if args.connect_log_group:
        connect_rows = fetch_source(
            args.connect_region, args.connect_log_group, args.start_ms,
            "connect", "Connect", args.bucket, prefix + raw_prefix + "connect.ndjson",
            args.region, args.profile)
    elif args.connect:
        connect_rows = load_input(args.connect, "connect", "Connect")
    else:
        ap.error("需要 --connect-log-group 或 --connect")

    if args.gateway_log_group:
        gateway_rows = fetch_source(
            args.gateway_region, args.gateway_log_group, args.start_ms,
            "gateway", "Gateway", args.bucket, prefix + raw_prefix + "gateway.ndjson",
            args.region, args.profile)
    elif args.gateway:
        gateway_rows = load_input(args.gateway, "gateway", "Gateway")
    else:
        gateway_rows = []

    # --- 关联 ---
    sys.stderr.write("==> 按 Contact ID 关联两路日志 ...\n")
    _parser.correlate(connect_rows, gateway_rows)

    all_rows = connect_rows + gateway_rows
    all_rows.sort(key=lambda r: r["timestamp"])

    # --- 分组 ---
    groups = {}
    for r in all_rows:
        groups.setdefault(_resolve_contact_id(r), []).append(r)

    logs_dir = os.path.join(args.out_dir, "logs")
    os.makedirs(logs_dir, exist_ok=True)

    total_contacts = len(groups)
    if args.bucket:
        sys.stderr.write("==> 逐个 Contact 生成 .log 并上传到 s3://%s/%s (共 %d 个) ...\n"
                         % (args.bucket, prefix, total_contacts))
    else:
        sys.stderr.write("==> 逐个 Contact 生成 .log (共 %d 个) ...\n" % total_contacts)

    used_names = {}
    contacts_index = []
    done = uploaded = skipped = 0

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
        out_path = os.path.join(logs_dir, "%s.log" % name)
        key = prefix + rel_path

        min_ts = min(r["timestamp"] for r in rows)
        max_ts = max(r["timestamp"] for r in rows)
        source_counts = {}
        for r in rows:
            src = r.get("source", "connect")
            source_counts[src] = source_counts.get(src, 0) + 1

        # 已存在则跳过(幂等)，也不必写本地文件
        if args.bucket and _object_exists(key, args.bucket, args.region, args.profile):
            skipped += 1
            status = "已存在,跳过"
        else:
            with open(out_path, "w", encoding="utf-8") as f:
                for r in rows:
                    f.write(json.dumps({
                        "timestamp": r["timestamp"],
                        "message": r["message"],
                        "source": r.get("source", "connect"),
                        "contactId": cid,
                    }, ensure_ascii=False))
                    f.write("\n")
            if args.bucket:
                _upload(out_path, key, args.bucket, args.region, args.profile)
                uploaded += 1
                status = "已上传"
                # 上传成功后删除本地临时文件，保持磁盘占用极小
                try:
                    os.remove(out_path)
                except OSError:
                    pass
            else:
                status = "已写入"

        contacts_index.append({
            "contactId": cid, "file": rel_path, "count": len(rows),
            "minTs": min_ts, "maxTs": max_ts, "sourceCounts": source_counts,
        })

        done += 1
        _progress("上传" if args.bucket else "写入", done, total_contacts,
                  "%d/%d · %s (%d 条) [%s]" % (done, total_contacts, cid[:40], len(rows), status))

    sys.stderr.write("\n")
    if args.bucket:
        sys.stderr.write("==> Contact 上传统计: 新上传 %d 个, 已存在跳过 %d 个\n"
                         % (uploaded, skipped))

    # index.json: 写本地一份(用于读取数量)，若配置了桶再上传
    index = {
        "generatedAt": datetime.datetime.now(datetime.timezone.utc)
        .isoformat().replace("+00:00", "Z"),
        "contactCount": len(contacts_index),
        "eventCount": len(all_rows),
        "contacts": contacts_index,
    }
    index_path = os.path.join(args.out_dir, "index.json")
    with open(index_path, "w", encoding="utf-8") as f:
        json.dump(index, f, ensure_ascii=False)
    if args.bucket:
        _upload(index_path, prefix + "index.json", args.bucket, args.region, args.profile)
        sys.stderr.write("==> 已上传 index.json\n")

    n_gw_linked = sum(1 for g in gateway_rows if g.get("contactId"))
    sys.stderr.write(
        "==> 完成: %d 个 Contact(connect=%d 条, gateway=%d 条, gateway 已关联 %d 条)\n"
        % (len(contacts_index), len(connect_rows), len(gateway_rows), n_gw_linked))


if __name__ == "__main__":
    main()
