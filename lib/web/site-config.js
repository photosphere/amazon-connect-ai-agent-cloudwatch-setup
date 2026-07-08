/* 站点运行时配置(默认值)
 *
 * 构建脚本 setup-connect-ai-agent-logs-analysis.sh 会依据 config.env 的
 * UI_DEFAULT_LANG，在输出目录(dist)里重新生成此文件以覆盖默认值。
 *
 * defaultLang: 页面首次打开时的界面语言。
 *   支持 中文 / English / Español / Italiano / Deutsch,
 *   也接受语言代码 zh / en / es / it / de。
 */
window.__UI_CONFIG__ = { defaultLang: "中文" };
