#!/usr/bin/env python3
"""
serve.py

本地预览服务器: 既提供静态站点(dist 目录)，又提供按需翻译的接口。

  GET  /                 -> 静态文件(index.html / app.js / data.js ...)
  GET  /api/config       -> {"available": bool, "lang": "中文", "model": "...", "region": "..."}
  POST /api/translate    -> 请求 {"texts": ["...", ...], "lang": "中文"}
                            返回 {"translations": ["...", ...]}

翻译通过 Bedrock Nova(见 bedrock_translate.py)，需要 aws CLI(已配置凭证)。
翻译不可用时(缺 aws CLI 等)，/api/config 会返回 available=false，前端隐藏翻译按钮。
"""
import argparse
import json
import os
import subprocess
import sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from functools import partial

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bedrock_translate import BedrockTranslator, command_exists  # noqa: E402


class Handler(SimpleHTTPRequestHandler):
    # 由 main() 注入
    translator = None
    default_lang = "中文"
    model_id = ""
    region = ""
    connect_instance_id = ""   # DescribeContact 默认 instanceId
    connect_region = ""        # DescribeContact 默认 region(缺省用 region)

    def _send_json(self, code, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?", 1)[0].rstrip("/")
        if path == "/api/config":
            self._send_json(200, {
                "available": self.translator is not None,
                "lang": self.default_lang,
                "model": self.model_id,
                "region": self.region,
                "describeContact": command_exists("aws"),
            })
            return
        if path == "/api/describe-contact":
            self._handle_describe_contact()
            return
        return super().do_GET()

    def _handle_describe_contact(self):
        """实时调用 Amazon Connect DescribeContact 并返回其 JSON 结果。

        入参(query string): contactId(必填), instanceId(可选, 缺省用启动参数)。
        """
        from urllib.parse import urlparse, parse_qs
        qs = parse_qs(urlparse(self.path).query)
        contact_id = (qs.get("contactId") or [""])[0].strip()
        instance_id = (qs.get("instanceId") or [""])[0].strip() or self.connect_instance_id
        region = (qs.get("region") or [""])[0].strip() or self.connect_region or self.region

        if not command_exists("aws"):
            self._send_json(503, {"error": "未找到 aws CLI，无法调用 DescribeContact。"})
            return
        if not contact_id:
            self._send_json(400, {"error": "缺少 contactId。"})
            return
        if not instance_id:
            self._send_json(400, {"error": "缺少 instanceId(未能从日志推断，请用 --connect-instance-id 指定)。"})
            return

        cmd = ["aws", "connect", "describe-contact",
               "--instance-id", instance_id, "--contact-id", contact_id,
               "--region", region, "--output", "json"]
        try:
            res = subprocess.run(cmd, capture_output=True, text=True, check=True)
        except subprocess.CalledProcessError as e:
            self._send_json(502, {"error": (e.stderr or "describe-contact 调用失败").strip()[:500]})
            return
        try:
            data = json.loads(res.stdout or "{}")
        except ValueError:
            self._send_json(502, {"error": "DescribeContact 返回的不是合法 JSON。"})
            return
        self._send_json(200, data)

    def do_POST(self):
        if self.path.rstrip("/") != "/api/translate":
            self.send_error(404, "Not Found")
            return
        if self.translator is None:
            self._send_json(503, {"error": "翻译不可用: 未找到 aws CLI 或未配置 Nova 模型。"})
            return
        try:
            length = int(self.headers.get("Content-Length") or 0)
            data = json.loads(self.rfile.read(length) or b"{}")
        except (ValueError, TypeError):
            self._send_json(400, {"error": "请求体不是合法 JSON。"})
            return

        texts = data.get("texts") or []
        lang = (data.get("lang") or self.default_lang).strip() or self.default_lang
        if not isinstance(texts, list):
            self._send_json(400, {"error": "texts 必须是字符串数组。"})
            return

        translations = []
        error = None
        for t in texts:
            try:
                translations.append(self.translator.translate(str(t), lang))
            except Exception as e:  # noqa: BLE001
                error = str(e)
                translations.append("")
        if error:
            sys.stderr.write("  翻译出错: %s\n" % error)
            self._send_json(502, {"error": "调用 Bedrock 翻译失败: " + error,
                                   "translations": translations})
            return
        self._send_json(200, {"translations": translations, "lang": lang})

    def log_message(self, fmt, *args):
        # 静默访问日志，避免刷屏;仅保留 stderr 上的翻译错误
        pass


def main():
    ap = argparse.ArgumentParser(description="本地预览 + 按需翻译服务器")
    ap.add_argument("--dir", required=True, help="站点目录(dist)")
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--lang", default=os.environ.get("TRANSLATE_TARGET_LANG", "中文"),
                    help="默认目标翻译语种")
    ap.add_argument("--model", default=os.environ.get("NOVA_TRANSLATE_MODEL_ID",
                                                       "amazon.nova-lite-v1:0"),
                    help="Bedrock Nova 模型 ID")
    ap.add_argument("--region", default=os.environ.get("NOVA_TRANSLATE_REGION", "us-east-1"),
                    help="调用 Bedrock 的 region")
    ap.add_argument("--max-tokens", type=int,
                    default=int(os.environ.get("NOVA_TRANSLATE_MAX_TOKENS", "2000")),
                    help="单次翻译生成的最大 token 数")
    ap.add_argument("--temperature", type=float,
                    default=float(os.environ.get("NOVA_TRANSLATE_TEMPERATURE", "0.0")),
                    help="采样温度(0.0~1.0)")
    ap.add_argument("--top-p", type=float,
                    default=float(os.environ.get("NOVA_TRANSLATE_TOP_P", "0.9")),
                    help="核采样 top_p(0.0~1.0)")
    ap.add_argument("--connect-instance-id",
                    default=os.environ.get("CONNECT_INSTANCE_ID", ""),
                    help="DescribeContact 默认使用的 Amazon Connect 实例 ID")
    ap.add_argument("--connect-region",
                    default=os.environ.get("CONNECT_REGION", ""),
                    help="DescribeContact 调用的 region(缺省用 --region)")
    args = ap.parse_args()

    Handler.default_lang = args.lang or "中文"
    Handler.model_id = args.model
    Handler.region = args.region
    Handler.connect_instance_id = args.connect_instance_id
    Handler.connect_region = args.connect_region
    try:
        Handler.translator = BedrockTranslator(
            args.region, args.model,
            max_tokens=args.max_tokens, temperature=args.temperature, top_p=args.top_p,
        )
        sys.stderr.write(
            "翻译已启用: model=%s region=%s 默认语种=%s "
            "(maxTokens=%d temperature=%s topP=%s)\n"
            % (args.model, args.region, Handler.default_lang,
               args.max_tokens, args.temperature, args.top_p)
        )
    except RuntimeError as e:
        Handler.translator = None
        sys.stderr.write("翻译未启用(%s) — 页面将隐藏翻译按钮。\n" % e)

    handler = partial(Handler, directory=args.dir)
    httpd = ThreadingHTTPServer(("", args.port), handler)
    sys.stderr.write("Serving %s at http://localhost:%d\n" % (args.dir, args.port))
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
