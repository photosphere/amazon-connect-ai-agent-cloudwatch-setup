#!/usr/bin/env python3
"""
split-contacts.py

把两路 CloudWatch 日志(Connect AI Agent + 可选的 Bedrock AgentCore Gateway)
按 Contact ID 拆分，为每一个 Contact 生成一个以 Contact ID 命名的 .log 文件，
并生成 index.json 清单，供部署在 CloudFront 上的 Web 应用从 S3 加载。

复用 parse-connect-ai-logs.py 的关联(correlate)与 ID 解析逻辑，保证拆分口径与
本地可视化版本完全一致。

针对大日志(如 >100MB)做了两点优化:
  1) 读取/解析阶段在控制台按字节百分比实时显示进度;
  2) 每解析完一个 Contact 就把它的 .log 立即上传到 S3(--bucket)，再处理下一个，
     而不是全部解析完再统一上传;
  3) 上传前先检查该 Contact 的 .log 是否已存在于桶中，已存在则跳过上传(幂等)。

输入:
  --connect FILE   Connect AI Agent 日志(NDJSON 每行一个事件，或 filter-log-events
                   JSON / events.log / CSV; 后几种由 parse 模块的 load_any 读取)  [必选]
  --gateway FILE   Bedrock AgentCore Gateway 日志(同上)                          [可选]
  --out-dir DIR    本地输出目录; 会在其下写入 logs/<contactId>.log 与 index.json   [必选]

上传(可选，提供 --bucket 时逐个 Contact 上传):
  --bucket NAME    目标 S3 桶(如 ai-agent-logs<suffix>)
  --prefix P       S3 键前缀(默认空)
  --region R       S3 区域
  --profile P      AWS CLI profile

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


def load_ndjson(path, source, label):
    """流式读取 NDJSON(每行一个事件)，按字节百分比实时显示解析进度。"""
    total = os.path.getsize(path)
    rows = []
    read = 0
    last_pct = -1
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            read += len(line.encode("utf-8", "ignore"))
            s = line.strip()
            if s:
                try:
                    e = json.loads(s)
                    ts = e.get("timestamp")
                    msg = e.get("message")
                    if ts is not None and msg is not None:
                        rows.append({
                            "timestamp": int(ts),
                            "message": _parser.sanitize_message(msg),
                            "source": source,
                        })
                except (ValueError, TypeError):
                    pass
            pct = int(read * 100 / total) if total else 100
            if pct != last_pct:
                last_pct = pct
                _progress("解析 %s" % label, read, total,
                          "%s / %s · %d 条" % (_human_size(read), _human_size(total), len(rows)))
    _progress("解析 %s" % label, total, total,
              "%s · %d 条" % (_human_size(total), len(rows)))
    sys.stderr.write("\n")
    return rows


def load_input(path, source, label):
    """.ndjson 走带进度的流式读取; 其它格式回退到 parse 模块的 load_any。"""
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
    """给一行日志确定归属的 Contact ID。

    connect 行: 优先 correlate 填好的 contactId，其次从消息里解析 session_id 兜底。
    gateway 行: 用 correlate 关联到的 contactId，未关联则归入 UNATTACHED_GATEWAY。
    """
    cid = row.get("contactId") or ""
    if cid:
        return cid
    if row.get("source") == "gateway":
        return UNATTACHED_GATEWAY
    _, sid = _parser._extract_connect_ids(row.get("message", ""))
    return sid or "unknown"


def _object_exists(key, bucket, region, profile):
    """检查 S3 上是否已存在该对象(用 head-object;返回码为 0 表示存在)。"""
    cmd = ["aws"]
    if profile:
        cmd += ["--profile", profile]
    cmd += ["s3api", "head-object", "--bucket", bucket, "--key", key]
    if region:
        cmd += ["--region", region]
    res = subprocess.run(cmd, capture_output=True, text=True)
    return res.returncode == 0


def _upload(local_path, key, bucket, region, profile):
    """用 aws CLI 把单个文件上传到 S3;失败则抛出异常。"""
    ctype = "application/json" if key.endswith(".json") else "text/plain; charset=utf-8"
    cmd = ["aws"]
    if profile:
        cmd += ["--profile", profile]
    cmd += ["s3", "cp", local_path, "s3://%s/%s" % (bucket, key),
            "--content-type", ctype, "--only-show-errors"]
    if region:
        cmd += ["--region", region]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        raise RuntimeError("上传 %s 失败: %s" % (key, (res.stderr or "").strip()))


def main():
    ap = argparse.ArgumentParser(
        description="按 Contact ID 拆分 Connect AI Agent + Gateway 日志为独立 .log 文件"
    )
    ap.add_argument("--connect", required=True, help="Connect AI Agent 日志文件")
    ap.add_argument("--gateway", help="Bedrock AgentCore Gateway 日志文件(可选)")
    ap.add_argument("--out-dir", required=True, help="输出目录(将写入 logs/ 与 index.json)")
    ap.add_argument("--bucket", help="目标 S3 桶;提供后逐个 Contact 上传")
    ap.add_argument("--prefix", default="", help="S3 键前缀(默认空)")
    ap.add_argument("--region", default="", help="S3 区域")
    ap.add_argument("--profile", default="", help="AWS CLI profile")
    args = ap.parse_args()

    prefix = args.prefix or ""

    sys.stderr.write("==> 读取并解析日志 ...\n")
    connect_rows = load_input(args.connect, "connect", "Connect")
    gateway_rows = load_input(args.gateway, "gateway", "Gateway") if args.gateway else []

    # 关联: 就地给每一行补上 contactId
    sys.stderr.write("==> 按 Contact ID 关联两路日志 ...\n")
    _parser.correlate(connect_rows, gateway_rows)

    all_rows = connect_rows + gateway_rows
    all_rows.sort(key=lambda r: r["timestamp"])

    # 按 Contact ID 分组
    groups = {}
    for r in all_rows:
        cid = _resolve_contact_id(r)
        groups.setdefault(cid, []).append(r)

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
    done = 0
    uploaded = 0
    skipped = 0

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

        # 先算元信息(不依赖是否写文件)
        min_ts = min(r["timestamp"] for r in rows)
        max_ts = max(r["timestamp"] for r in rows)
        source_counts = {}
        for r in rows:
            src = r.get("source", "connect")
            source_counts[src] = source_counts.get(src, 0) + 1

        # 若该 Contact 的日志已存在于桶中，则跳过上传(也无需本地写)
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
            # 解析完这个 Contact 立即上传，再处理下一个
            if args.bucket:
                _upload(out_path, key, args.bucket, args.region, args.profile)
                uploaded += 1
                status = "已上传"
            else:
                status = "已写入"

        contacts_index.append({
            "contactId": cid,
            "file": rel_path,
            "count": len(rows),
            "minTs": min_ts,
            "maxTs": max_ts,
            "sourceCounts": source_counts,
        })

        done += 1
        _progress("上传" if args.bucket else "写入", done, total_contacts,
                  "%d/%d · %s (%d 条) [%s]" % (done, total_contacts, cid[:40], len(rows), status))

    sys.stderr.write("\n")
    if args.bucket:
        sys.stderr.write("==> Contact 上传统计: 新上传 %d 个, 已存在跳过 %d 个\n"
                         % (uploaded, skipped))

    # index.json: 本地写一份，若配置了桶再上传
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
        % (len(contacts_index), len(connect_rows), len(gateway_rows), n_gw_linked)
    )


if __name__ == "__main__":
    main()
