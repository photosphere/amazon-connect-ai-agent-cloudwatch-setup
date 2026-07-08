#!/usr/bin/env python3
"""
bedrock_translate.py

用 Amazon Bedrock Nova 模型做文本翻译的小工具，供本地预览服务器(serve.py)
按需调用。通过 aws CLI 的 bedrock-runtime invoke-model 完成，避免额外依赖 boto3。
带本地内存缓存，重复文本只翻译一次。
"""
import json
import os
import re
import subprocess
import sys
import tempfile
from shutil import which


def command_exists(name):
    return which(name) is not None


def _nova_output_text(data):
    """从 Nova invoke-model 的响应里取出文本。"""
    try:
        content = data["output"]["message"]["content"]
        return "".join(c.get("text", "") for c in content if isinstance(c, dict))
    except (KeyError, TypeError):
        return ""


def _strip_src_tags(text):
    """兜底: 去掉模型有时误回显的 <src>/</src> 分隔标记。"""
    if not text:
        return ""
    text = text.strip()
    m = re.match(r"^\s*<src>\s*(.*?)\s*</src>\s*$", text, re.S | re.I)
    if m:
        text = m.group(1)
    text = re.sub(r"</?src>", "", text, flags=re.I)
    return text.strip()


class BedrockTranslator:
    """通过 aws CLI 调用 Bedrock Nova 模型做翻译，带内存缓存。"""

    def __init__(self, region, model_id, max_tokens=2000, temperature=0.0, top_p=0.9):
        self.region = region
        self.model_id = model_id
        self.max_tokens = int(max_tokens)
        self.temperature = float(temperature)
        self.top_p = float(top_p)
        self.cache = {}  # (lang, text) -> translation
        if not command_exists("aws"):
            raise RuntimeError("翻译功能需要 aws CLI(已配置凭证)，但未找到 aws。")

    def translate(self, text, lang):
        text = (text or "").strip()
        if not text:
            return ""
        key = (lang, text)
        if key in self.cache:
            return self.cache[key]
        result = self._invoke(text, lang)
        self.cache[key] = result
        return result

    def _invoke(self, text, lang):
        prompt = (
            "You are a professional translator. The text to translate is provided "
            f"between the <src> and </src> markers below. Translate it into {lang}. "
            "The <src> and </src> markers are delimiters only: never include them in "
            "your output. Preserve any XML-like tags that appear inside the text, such "
            "as <message> and <thinking>, exactly as they are, and translate only the "
            "text within them. Output ONLY the translation, with no explanations, "
            "notes, or the original text.\n<src>\n" + text + "\n</src>"
        )
        body = {
            "messages": [{"role": "user", "content": [{"text": prompt}]}],
            "inferenceConfig": {
                "maxTokens": self.max_tokens,
                "temperature": self.temperature,
                "topP": self.top_p,
            },
        }
        body_path = None
        out_path = None
        try:
            with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False,
                                             encoding="utf-8") as bf:
                json.dump(body, bf, ensure_ascii=False)
                body_path = bf.name
            out_fd, out_path = tempfile.mkstemp(suffix=".json")
            os.close(out_fd)
            cmd = [
                "aws", "bedrock-runtime", "invoke-model",
                "--region", self.region,
                "--model-id", self.model_id,
                "--body", "fileb://" + body_path,
                "--cli-binary-format", "raw-in-base64-out",
                "--content-type", "application/json",
                "--accept", "application/json",
                out_path,
            ]
            res = subprocess.run(cmd, capture_output=True, text=True)
            if res.returncode != 0:
                raise RuntimeError((res.stderr or "invoke-model 调用失败").strip())
            with open(out_path, "r", encoding="utf-8") as f:
                data = json.load(f)
            return _strip_src_tags(_nova_output_text(data))
        finally:
            for p in (body_path, out_path):
                if p and os.path.exists(p):
                    try:
                        os.unlink(p)
                    except OSError:
                        pass
