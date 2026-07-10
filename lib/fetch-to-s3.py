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
import threading


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

    # 用后台线程持续排空上传进程的 stderr:
    # 大文件上传耗时长，若我们在翻页期间一直不读 stderr，一旦 aws s3 cp 往
    # stderr 写满约 64KB 的管道缓冲，它就会阻塞写、进而停止读取 stdin，与主线程
    # 形成死锁。持续排空可彻底避免这个隐患，出错信息也保留下来供最后报错用。
    stderr_buf = []

    def _drain_stderr(pipe, buf):
        try:
            for line in pipe:
                buf.append(line)
        except Exception:  # noqa: BLE001
            pass

    stderr_thread = threading.Thread(target=_drain_stderr,
                                     args=(proc.stderr, stderr_buf),
                                     daemon=True)
    stderr_thread.start()

    next_token, count = None, 0
    # 超时/重试参数说明:
    #   filter-log-events 拉取"全部历史"时(无 --limit)需要在服务端扫描整个
    #   日志组，单次调用可能耗时数十秒甚至更久，期间连接可能长时间没有数据返回。
    #   - CLI_READ_TIMEOUT 需足够大，避免把"慢但正常"的扫描误判为超时;
    #   - HARD_TIMEOUT 是最后一道防线: 即便底层 SSL socket 读取彻底卡死
    #     (在部分环境如 Python 3.14 + 捆绑版 aws CLI 下确有发生)，也会强制结束
    #     子进程并重试，从而保证脚本不会永久停在"拉取日志"这一步。
    CLI_CONNECT_TIMEOUT = "15"
    CLI_READ_TIMEOUT = "180"
    HARD_TIMEOUT = 300
    MAX_ATTEMPTS = 4

    try:
        while True:
            cmd = aws_base() + [
                "logs", "filter-log-events", "--region", args.region,
                "--log-group-name", args.log_group, "--output", "json",
                "--cli-connect-timeout", CLI_CONNECT_TIMEOUT,
                "--cli-read-timeout", CLI_READ_TIMEOUT,
            ]
            if args.start_ms:
                cmd += ["--start-time", args.start_ms]
            if next_token:
                cmd += ["--next-token", next_token]

            # 慢扫描期间给出"仍在拉取"的心跳，避免看起来像卡死。
            sys.stderr.write("\r  拉取 %s… 已获取 %d 条(正在查询下一页，请稍候)"
                             % (label, count))
            sys.stderr.flush()

            # 拉取当前页；对超时/瞬时错误做有限次重试。
            #   - stdin 显式指向 /dev/null: 否则子进程会继承本脚本的 stdin
            #     (交互式 TTY 或来自管道的 fd)，在上述环境下可能导致 CLI
            #     网络读取死锁挂起。
            res = None
            last_err = ""
            for attempt in range(1, MAX_ATTEMPTS + 1):
                try:
                    res = subprocess.run(cmd, capture_output=True, text=True,
                                         stdin=subprocess.DEVNULL,
                                         timeout=HARD_TIMEOUT)
                except subprocess.TimeoutExpired:
                    last_err = ("单次拉取超过 %ds 仍无响应(第 %d 次)，"
                                "重试中…" % (HARD_TIMEOUT, attempt))
                    sys.stderr.write("\n  %s\n" % last_err)
                    continue
                if res.returncode == 0:
                    break
                last_err = (res.stderr or "").strip()
                sys.stderr.write("\n  拉取出错(第 %d 次): %s；重试中…\n"
                                 % (attempt, last_err))
                res = None

            if res is None or res.returncode != 0:
                try:
                    proc.stdin.close()
                except (BrokenPipeError, ValueError):
                    pass
                proc.wait()
                sys.stderr.write("\n错误: 拉取失败(已重试 %d 次): %s\n"
                                 % (MAX_ATTEMPTS, last_err))
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

    stderr_thread.join(timeout=5)
    if rc != 0:
        err = ("".join(stderr_buf)).strip()
        sys.stderr.write("\n错误: 归档到 s3://%s/%s 失败(退出码 %d) %s\n"
                         % (args.bucket, args.key, rc, err))
        sys.exit(1)

    sys.stderr.write("\r  拉取 %s 完成: %d 条; 已归档到 s3://%s/%s\n"
                     % (label, count, args.bucket, args.key))
    print(count)  # 供调用方读取


if __name__ == "__main__":
    main()
