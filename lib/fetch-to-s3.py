#!/usr/bin/env python3
"""
fetch-to-s3.py — 把一个 CloudWatch 日志组的全部事件以 NDJSON 流式归档到 S3。

特点:
  - 边翻页(filter-log-events)边把每个事件写入 `aws s3 cp - s3://<bucket>/<key>` 的 stdin，
    原始数据直接流式进入 S3，本地不落文件、内存占用极小(不累积事件);
  - 归档的是"原始 message"(不做任何改写)，作为原始数据长期保存;
    后续解析/清洗由云端 Lambda 完成。
  - 控制台实时显示已获取条数;结束后把总条数打印到 stdout 供调用方读取。

用法:
  python3 fetch-to-s3.py --region <r> --log-group <lg> --bucket <b> --key <k> \
      [--s3-region <r>] [--start-ms <ms>] [--profile <p>] [--label <name>]
"""
import argparse
import json
import subprocess
import sys


def main():
    ap = argparse.ArgumentParser(description="流式归档 CloudWatch 日志组到 S3")
    ap.add_argument("--region", required=True, help="日志组所在区域")
    ap.add_argument("--log-group", required=True, help="日志组名")
    ap.add_argument("--bucket", required=True, help="目标 S3 桶")
    ap.add_argument("--key", required=True, help="目标对象键(如 raw/connect.ndjson)")
    ap.add_argument("--s3-region", default="", help="S3 区域")
    ap.add_argument("--start-ms", default="", help="起始时间(epoch 毫秒);空=全部历史")
    ap.add_argument("--profile", default="", help="AWS CLI profile")
    ap.add_argument("--label", default="", help="进度显示用的名称")
    args = ap.parse_args()

    def aws_base():
        c = ["aws"]
        if args.profile:
            c += ["--profile", args.profile]
        return c

    label = args.label or args.log_group

    # 目标: 流式上传到 S3(读取 stdin)
    up_cmd = aws_base() + [
        "s3", "cp", "-", "s3://%s/%s" % (args.bucket, args.key),
        "--content-type", "text/plain; charset=utf-8", "--only-show-errors",
    ]
    if args.s3_region:
        up_cmd += ["--region", args.s3_region]
    proc = subprocess.Popen(up_cmd, stdin=subprocess.PIPE,
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                            text=True, encoding="utf-8")

    next_token, count = None, 0
    try:
        while True:
            cmd = aws_base() + [
                "logs", "filter-log-events", "--region", args.region,
                "--log-group-name", args.log_group, "--output", "json",
            ]
            if args.start_ms:
                cmd += ["--start-time", args.start_ms]
            if next_token:
                cmd += ["--next-token", next_token]
            res = subprocess.run(cmd, capture_output=True, text=True)
            if res.returncode != 0:
                try:
                    proc.stdin.close()
                except (BrokenPipeError, ValueError):
                    pass
                proc.wait()
                sys.stderr.write("\n错误: 拉取失败: %s\n" % (res.stderr or "").strip())
                sys.exit(1)
            data = json.loads(res.stdout or "{}")
            for ev in data.get("events", []):
                ts, msg = ev.get("timestamp"), ev.get("message")
                if ts is None or msg is None:
                    continue
                proc.stdin.write(json.dumps({"timestamp": ts, "message": msg},
                                            ensure_ascii=False))
                proc.stdin.write("\n")
                count += 1
            sys.stderr.write("\r  拉取 %s… 已获取 %d 条" % (label, count))
            sys.stderr.flush()
            next_token = data.get("nextToken")
            if not next_token:
                break
    finally:
        try:
            proc.stdin.close()
        except (BrokenPipeError, ValueError):
            pass
        rc = proc.wait()

    if rc != 0:
        err = ""
        try:
            err = (proc.stderr.read() or "").strip()
        except Exception:  # noqa: BLE001
            pass
        sys.stderr.write("\n错误: 归档到 s3://%s/%s 失败(退出码 %d) %s\n"
                         % (args.bucket, args.key, rc, err))
        sys.exit(1)

    sys.stderr.write("\r  拉取 %s 完成: %d 条; 已归档到 s3://%s/%s\n"
                     % (label, count, args.bucket, args.key))
    print(count)  # 供调用方读取


if __name__ == "__main__":
    main()
