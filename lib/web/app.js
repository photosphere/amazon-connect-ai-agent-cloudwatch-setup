/* Connect AI Agent 日志排查前端逻辑
 *
 * 数据来源: window.__CONNECT_AI_LOG_DATA__ = [{timestamp, message}]
 * message 是 AI Agent 写入 CloudWatch 的原始 JSON 字符串。
 *
 * 关键映射:
 *   - Amazon Connect 的 contactId 在日志里体现为 `session_name`
 *     (也出现在 span 的 session_name=...)。
 *   - `session_id` 是底层 Q in Connect 的内部会话 ID。
 *   一个 contactId 可能对应一个或多个 session_id，这里以 contactId 为主键分组。
 */
(function () {
  "use strict";

  const RAW = window.__CONNECT_AI_LOG_DATA__ || [];

  // ---- 按需翻译状态 ----
  let TRANSLATE_CFG = { available: false, lang: "中文" };
  const translatedContacts = new Set();   // 已翻译过的 Contact
  const translatingContacts = new Set();  // 正在翻译中的 Contact

  // ---- 工具: 安全 JSON 解析 ----
  function tryParse(s) {
    if (typeof s !== "string") return s;
    try { return JSON.parse(s); } catch (e) { return null; }
  }

  // ---- 解析 span 字符串 "{k=v, k=v, nested=[...]}" ----
  // 这是 OpenTelemetry 风格的非 JSON 文本，做一个容错的浅解析。
  function parseSpan(spanStr) {
    const out = {};
    if (typeof spanStr !== "string") return out;
    let s = spanStr.trim();
    if (s.startsWith("{")) s = s.slice(1);
    if (s.endsWith("}")) s = s.slice(0, -1);
    // 顶层按逗号切分，但要跳过中括号 / 大括号内部的逗号
    const parts = [];
    let depth = 0, cur = "";
    for (let i = 0; i < s.length; i++) {
      const c = s[i];
      if (c === "[" || c === "{") depth++;
      else if (c === "]" || c === "}") depth--;
      if (c === "," && depth === 0) { parts.push(cur); cur = ""; }
      else cur += c;
    }
    if (cur.trim()) parts.push(cur);
    for (const p of parts) {
      const eq = p.indexOf("=");
      if (eq === -1) continue;
      const k = p.slice(0, eq).trim();
      const v = p.slice(eq + 1).trim();
      out[k] = v;
    }
    return out;
  }

  const SHORT_TYPE = (t) => (t || "").replace(/^TRANSCRIPT_/, "");

  // ---- 归一化每条日志 ----
  const events = [];
  for (const row of RAW) {
    const source = row.source || "connect";

    // Gateway 日志: 来自 Bedrock AgentCore Gateway，可能是 JSON 也可能是纯文本。
    // 关联用的 contactId 由后端预先计算并写在 row.contactId 上。
    if (source === "gateway") {
      const gobj = tryParse(row.message); // 可能为 null(纯文本)
      events.push({
        ts: row.timestamp,
        source: "gateway",
        type: "GATEWAY",
        fullType: "GATEWAY",
        contactId: row.contactId || "",
        sessionId: "",
        span: null,
        obj: gobj,
        raw: row.message,
      });
      continue;
    }

    const obj = tryParse(row.message);
    if (!obj || !obj.event_type) {
      events.push({
        ts: row.timestamp, source: "connect", type: "UNKNOWN", contactId: row.contactId || "(unparsed)",
        sessionId: "", raw: row.message, obj: null,
      });
      continue;
    }
    let contactId = row.contactId || "";
    let span = null;
    if (!contactId && obj.session_name) contactId = obj.session_name;
    if (obj.span) {
      span = parseSpan(obj.span);
      if (!contactId && span.session_name) contactId = span.session_name;
    }
    // 没有 session_name 的事件(如 UTTERANCE / ORCHESTRATION)先记下 session_id，
    // 之后用 session_id -> contactId 的映射补全。
    events.push({
      ts: row.timestamp,
      source: "connect",
      type: SHORT_TYPE(obj.event_type),
      fullType: obj.event_type,
      contactId: contactId,
      sessionId: obj.session_id || "",
      span: span,
      obj: obj,
      raw: row.message,
      // 运行时点击「翻译」按钮后，由 /api/translate 填充
      translation: "",
      translationLang: "",
    });
  }

  // ---- 构建 session_id -> contactId 映射 ----
  const sidToCid = {};
  for (const e of events) {
    if (e.contactId && e.sessionId) sidToCid[e.sessionId] = e.contactId;
  }
  // 补全缺失 contactId
  for (const e of events) {
    if (!e.contactId && e.sessionId && sidToCid[e.sessionId]) {
      e.contactId = sidToCid[e.sessionId];
    }
    if (!e.contactId) {
      // gateway 没关联到会话的，单独归入一个分组，避免污染真实 Contact 列表
      e.contactId = e.source === "gateway"
        ? "(未关联的 Gateway 日志)"
        : (e.sessionId || "(unknown)");
    }
  }

  // ---- 按 contactId 分组 ----
  const groups = {};
  for (const e of events) {
    (groups[e.contactId] = groups[e.contactId] || []).push(e);
  }
  // 每个 Contact 的元信息(最早时间 / 事件数)，供侧栏排序使用
  const contactMeta = {};
  for (const cid of Object.keys(groups)) {
    const list = groups[cid];
    let mn = Infinity;
    for (const x of list) { if (x.ts < mn) mn = x.ts; }
    contactMeta[cid] = { minTs: mn, count: list.length };
  }
  const contactIds = Object.keys(groups);

  // 侧栏排序: 时间(最早时间戳) 或 事件数，可切换升/降序
  let currentSort = "time_desc";
  function getOrderedContactIds() {
    return contactIds.slice().sort((a, b) => {
      const ma = contactMeta[a], mb = contactMeta[b];
      switch (currentSort) {
        case "time_asc":   return ma.minTs - mb.minTs;
        case "count_desc": return (mb.count - ma.count) || (mb.minTs - ma.minTs);
        case "count_asc":  return (ma.count - mb.count) || (ma.minTs - mb.minTs);
        case "time_desc":
        default:           return mb.minTs - ma.minTs; // 最近的会话排前面
      }
    });
  }

  // ---- 会话级统计(用于侧栏徽标) ----
  function summarize(list) {
    let errors = 0, escalations = 0, toolCalls = 0, llmCalls = 0;
    let guardrailBlocks = 0, gateway = 0;
    for (const e of list) {
      if (e.source === "gateway") {
        gateway++;
        if (isGatewayError(e)) errors++;
        continue;
      }
      if (e.span) {
        if (e.span.status && e.span.status !== "OK") errors++;
        if (e.span.span_name === "escalate_agent") escalations++;
        if (e.span.span_name === "execute_tool") toolCalls++;
        if (e.span.span_name === "inference") llmCalls++;
      }
      if (e.obj && e.obj.guardrail_blocked === true) guardrailBlocks++;
    }
    return { errors, escalations, toolCalls, llmCalls, guardrailBlocks, gateway };
  }

  // gateway 日志的错误判定: level/status 字段或文本含 ERROR/Exception
  function isGatewayError(e) {
    if (e.obj) {
      const lvl = (e.obj.level || e.obj.severity || e.obj.status || "").toString().toUpperCase();
      if (/ERROR|FATAL|CRITICAL/.test(lvl)) return true;
    }
    return /\b(ERROR|Exception|Traceback|FATAL)\b/.test(e.raw || "");
  }

  // ---- Dashboard 用: 计算单个 Contact 的详细指标 ----
  //   duration      通话时间(该 Contact 最早/最晚事件的时间跨度, ms)
  //   aiAgentCalls  AI Agent 调用次数(AGENTIC_MESSAGE / LLM 调用事件)
  //   turns         对话轮次(ORCHESTRATION_MESSAGE 对话消息数, 无则回退到 UTTERANCE)
  //   toolCounts    每个 MCP 工具的调用次数 {toolName: count}
  //   guardrailBlocks 护栏 guardrail_blocked 拦截数
  //   errors        错误数(span 非 OK + gateway 错误)
  function computeMetrics(list) {
    let agentic = 0, llm = 0, om = 0, ut = 0, guardrailBlocks = 0, errors = 0;
    const toolCounts = {};
    let minTs = Infinity, maxTs = -Infinity;
    for (const e of list) {
      if (typeof e.ts === "number") {
        if (e.ts < minTs) minTs = e.ts;
        if (e.ts > maxTs) maxTs = e.ts;
      }
      if (e.source === "gateway") {
        if (isGatewayError(e)) errors++;
        continue;
      }
      if (e.span) {
        if (e.span.status && e.span.status !== "OK") errors++;
        if (e.span.span_name === "execute_tool") {
          const n = toolNameFromSpan(e.span) || "(unknown)";
          toolCounts[n] = (toolCounts[n] || 0) + 1;
        }
      }
      // AGENTIC_MESSAGE 与 LARGE_LANGUAGE_MODEL_INVOCATION 往往是同一次 LLM 调用的
      // 两种日志表现(数量 1:1)，取二者较大值避免重复计数。
      if (e.type === "AGENTIC_MESSAGE") agentic++;
      if (e.type === "LARGE_LANGUAGE_MODEL_INVOCATION") llm++;
      if (e.type === "ORCHESTRATION_MESSAGE") om++;
      if (e.type === "UTTERANCE") ut++;
      if (e.obj && e.obj.guardrail_blocked === true) guardrailBlocks++;
    }
    const hasTs = minTs !== Infinity;
    if (!hasTs) { minTs = 0; maxTs = 0; }
    return {
      startTs: hasTs ? minTs : null,
      endTs: hasTs ? maxTs : null,
      duration: Math.max(0, maxTs - minTs),
      aiAgentCalls: Math.max(agentic, llm),
      turns: om || ut,
      toolCounts: toolCounts,
      guardrailBlocks: guardrailBlocks,
      errors: errors,
      count: list.length,
    };
  }

  // ---- Dashboard 用: 汇总所有真实 Contact 的指标 ----
  function computeAggregate() {
    const realCids = contactIds.filter((c) => c !== "(未关联的 Gateway 日志)");
    let totalDuration = 0, totalAi = 0, totalTurns = 0, totalGuard = 0, totalErr = 0;
    const toolTotals = {};
    for (const cid of realCids) {
      const m = computeMetrics(groups[cid]);
      totalDuration += m.duration;
      totalAi += m.aiAgentCalls;
      totalTurns += m.turns;
      totalGuard += m.guardrailBlocks;
      totalErr += m.errors;
      for (const n of Object.keys(m.toolCounts)) {
        toolTotals[n] = (toolTotals[n] || 0) + m.toolCounts[n];
      }
    }
    return {
      totalContacts: realCids.length,
      totalDuration: totalDuration,
      totalAi: totalAi,
      totalTurns: totalTurns,
      toolTotals: toolTotals,
      totalGuard: totalGuard,
      totalErr: totalErr,
    };
  }

  // ---- 把毫秒时长格式化为易读文本 ----
  function formatDuration(ms) {
    if (!ms || ms < 0) return "0秒";
    const totalSec = Math.round(ms / 1000);
    const h = Math.floor(totalSec / 3600);
    const m = Math.floor((totalSec % 3600) / 60);
    const s = totalSec % 60;
    const parts = [];
    if (h) parts.push(h + "时");
    if (m) parts.push(m + "分");
    parts.push(s + "秒");
    return parts.join("");
  }

  // ---- 把 epoch 毫秒格式化为本地日期时间 ----
  function formatDateTime(ts) {
    if (ts == null) return "—";
    return new Date(ts).toLocaleString([], {
      year: "numeric", month: "2-digit", day: "2-digit",
      hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false,
    });
  }

  // ---- 渲染侧栏 ----
  const contactListEl = document.getElementById("contactList");
  const searchBox = document.getElementById("searchBox");
  let activeCid = null;

  function renderSidebar(filter) {
    const f = (filter || "").trim().toLowerCase();
    contactListEl.innerHTML = "";
    const shown = getOrderedContactIds().filter((c) => !f || c.toLowerCase().includes(f));
    if (shown.length === 0) {
      contactListEl.innerHTML = '<div class="empty" style="margin-top:30px;font-size:13px">无匹配的 Contact ID</div>';
      return;
    }
    for (const cid of shown) {
      const list = groups[cid];
      const s = summarize(list);
      const tmin = new Date(Math.min.apply(null, list.map((x) => x.ts)));
      const item = document.createElement("div");
      item.className = "contact-item" + (cid === activeCid ? " active" : "");
      let badges = `<span class="badge">${list.length} 事件</span>`;
      if (s.toolCalls) badges += `<span class="badge">${s.toolCalls} 工具</span>`;
      if (s.gateway) badges += `<span class="badge gw">网关 ${s.gateway}</span>`;
      if (s.escalations) badges += `<span class="badge esc">转人工 ${s.escalations}</span>`;
      if (s.errors) badges += `<span class="badge err">错误 ${s.errors}</span>`;
      if (s.guardrailBlocks) badges += `<span class="badge err">护栏 ${s.guardrailBlocks}</span>`;
      if (!s.errors && !s.escalations) badges += `<span class="badge ok">正常</span>`;
      // 翻译按钮(仅当本地服务器提供翻译接口时显示)，并反映"未译/翻译中/已译"三态
      let transBtn = "";
      if (TRANSLATE_CFG.available && cid !== "(未关联的 Gateway 日志)") {
        if (translatingContacts.has(cid)) {
          transBtn = `<button class="icon-btn js-translate busy" title="翻译中…" disabled>⏳</button>`;
        } else if (translatedContacts.has(cid)) {
          transBtn = `<button class="icon-btn js-translate ok" title="重新翻译该会话">✓译</button>`;
        } else {
          transBtn = `<button class="icon-btn js-translate" title="翻译该会话的客户/机器人对话(${esc(TRANSLATE_CFG.lang)})">译</button>`;
        }
      }

      item.innerHTML =
        `<div class="cid-row">` +
          `<span class="cid" title="${cid}">${cid}</span>` +
          `<span class="cid-actions">` +
            transBtn +
            `<button class="icon-btn js-copy" title="拷贝 Contact ID">⧉</button>` +
            `<button class="icon-btn js-download" title="下载该 Contact 的日志 CSV">⬇</button>` +
          `</span>` +
        `</div>` +
        `<div class="sub">${tmin.toLocaleString()}</div>` +
        `<div class="badges">${badges}</div>`;

      // 点击整行选中会话
      item.addEventListener("click", () => selectContact(cid));

      // 拷贝按钮(阻止冒泡，避免触发选中)
      const copyBtn = item.querySelector(".js-copy");
      copyBtn.addEventListener("click", (ev) => {
        ev.stopPropagation();
        copyToClipboard(cid, copyBtn);
      });

      // 下载按钮
      const dlBtn = item.querySelector(".js-download");
      dlBtn.addEventListener("click", (ev) => {
        ev.stopPropagation();
        downloadContactCsv(cid);
      });

      // 翻译按钮
      const trBtn = item.querySelector(".js-translate");
      if (trBtn) {
        trBtn.addEventListener("click", (ev) => {
          ev.stopPropagation();
          translateContact(cid);
        });
      }

      contactListEl.appendChild(item);
    }
  }

  // ---- 拷贝 Contact ID 到剪贴板 ----
  function copyToClipboard(text, btn) {
    const done = () => {
      if (!btn) return;
      const old = btn.textContent;
      btn.textContent = "✓";
      btn.classList.add("ok");
      setTimeout(() => { btn.textContent = old; btn.classList.remove("ok"); }, 1200);
    };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(done).catch(() => fallbackCopy(text, done));
    } else {
      fallbackCopy(text, done);
    }
  }

  function fallbackCopy(text, done) {
    try {
      const ta = document.createElement("textarea");
      ta.value = text;
      ta.style.position = "fixed";
      ta.style.opacity = "0";
      document.body.appendChild(ta);
      ta.focus();
      ta.select();
      document.execCommand("copy");
      document.body.removeChild(ta);
      if (done) done();
    } catch (e) {
      window.prompt("复制下面的 Contact ID:", text);
    }
  }

  // ---- 下载该 Contact 的日志为 CSV(含 connect + gateway) ----
  function csvEscape(v) {
    const s = String(v == null ? "" : v);
    if (/[",\r\n]/.test(s)) return '"' + s.replace(/"/g, '""') + '"';
    return s;
  }

  function downloadContactCsv(cid) {
    const list = groups[cid].slice().sort((a, b) => a.ts - b.ts);
    const header = ["timestamp_ms", "datetime", "source", "event_type", "message", "原文", "翻译"];
    const lines = [header.join(",")];
    for (const e of list) {
      const dt = new Date(e.ts).toISOString();
      lines.push([
        csvEscape(e.ts),
        csvEscape(dt),
        csvEscape(e.source || ""),
        csvEscape(e.fullType || e.type || ""),
        csvEscape(e.raw != null ? e.raw : ""),
        csvEscape(getTranslatableText(e) || ""),
        csvEscape(e.translation || ""),
      ].join(","));
    }
    // 加 BOM，便于 Excel 正确识别 UTF-8
    const blob = new Blob(["\ufeff" + lines.join("\r\n")], { type: "text/csv;charset=utf-8;" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    const safeCid = String(cid).replace(/[^a-zA-Z0-9_-]+/g, "_");
    a.href = url;
    a.download = `contact-${safeCid}-logs.csv`;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }

  // ---- 渲染消息气泡的辅助 ----
  function extractMessageText(values) {
    // values 可能是数组 [{type:"text", value:"..."}] 或字符串
    if (typeof values === "string") {
      const p = tryParse(values);
      if (p) values = p; else return values;
    }
    if (Array.isArray(values)) {
      return values.map((v) => v.value || v.text || "").join("\n").trim();
    }
    return "";
  }

  function esc(s) {
    return String(s == null ? "" : s)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }

  // 从 AI Agent 回复中拆出 <message> 与 <thinking>
  function splitMessageThinking(text) {
    const msgs = [];
    const thinks = [];
    const re = /<(message|thinking)>([\s\S]*?)<\/\1>/g;
    let m, matched = false;
    while ((m = re.exec(text)) !== null) {
      matched = true;
      if (m[1] === "message") msgs.push(m[2].trim());
      else thinks.push(m[2].trim());
    }
    if (!matched) return { messages: [text.trim()], thinking: [] };
    return { messages: msgs, thinking: thinks };
  }

  // ---- 判定事件的角色(客户/机器人/工具)与严重度(错误/护栏)，用于高亮 ----
  function eventRoleInfo(e) {
    let role = "", badge = "", sev = "";
    if (e.type === "UTTERANCE") {
      const u = (e.obj && e.obj.utterance) || "";
      role = /^\[CUSTOMER\]/.test(u) ? "customer" : "bot";
      badge = role === "customer" ? "CUSTOMER" : "BOT";
    } else if (e.type === "ORCHESTRATION_MESSAGE") {
      role = ((e.obj && e.obj.participant) || "BOT").toLowerCase() === "customer" ? "customer" : "bot";
      badge = role === "customer" ? "CUSTOMER" : "BOT";
      if (e.obj && e.obj.guardrail_blocked) sev = "guard";
    } else if (e.type === "AI_AGENT_TRACE" && e.span && e.span.span_name === "execute_tool") {
      role = "tool"; badge = "TOOL";
      if (e.span.status && e.span.status !== "OK") sev = "err";
    } else if (e.type === "GATEWAY") {
      role = "tool"; badge = "网关";
      if (isGatewayError(e)) sev = "err";
    } else if (e.type === "AI_AGENT_TRACE") {
      if (e.span && e.span.status && e.span.status !== "OK") sev = "err";
    }
    return { role: role, badge: badge, sev: sev };
  }

  // ---- 渲染单个事件 ----
  function renderEvent(e) {
    const div = document.createElement("div");
    const ri = eventRoleInfo(e);
    div.className = "event t-" + e.type +
      (ri.role ? " role-" + ri.role : "") +
      (ri.sev ? " sev-" + ri.sev : "");

    const time = new Date(e.ts).toLocaleTimeString([], { hour12: false }) +
      "." + String(e.ts % 1000).padStart(3, "0");

    let summary = "";
    let tags = "";
    let bodyHtml = "";

    if (e.type === "UTTERANCE") {
      const u = e.obj.utterance || "";
      summary = u;
      const isCustomer = /^\[CUSTOMER\]/.test(u);
      const who = isCustomer ? "customer" : "bot";
      const txt = u.replace(/^\[(CUSTOMER|AGENT|BOT|SYSTEM)\]\s*/, "");
      bodyHtml = `<div class="bubble ${who}">${esc(txt)}</div>`;
      if (e.translation) bodyHtml += renderTranslationBubble(e.translation, e.translationLang, who);

    } else if (e.type === "ORCHESTRATION_MESSAGE") {
      const txt = extractMessageText(e.obj.values);
      const who = (e.obj.participant || "BOT").toLowerCase() === "customer" ? "customer" : "bot";
      summary = `[${e.obj.participant || "BOT"}] ${txt}`.replace(/\s+/g, " ");
      const parts = splitMessageThinking(txt);
      bodyHtml += `<div class="kv"><b>participant:</b> ${esc(e.obj.participant || "")} · <b>model:</b> ${esc(e.obj.model_id || "")}</div>`;
      for (const mm of parts.messages) if (mm) bodyHtml += `<div class="bubble ${who}">${esc(mm)}</div>`;
      for (const th of parts.thinking) if (th) bodyHtml += `<div class="bubble thinking">💭 ${esc(th)}</div>`;
      if (e.translation) bodyHtml += renderTranslationBubble(e.translation, e.translationLang, who);
      if (e.obj.guardrail_blocked) tags += `<span class="ev-tag err">guardrail</span>`;

    } else if (e.type === "AGENTIC_MESSAGE" || e.type === "LARGE_LANGUAGE_MODEL_INVOCATION") {
      const prompt = tryParse(e.obj.prompt) || {};
      const msgs = prompt.messages || [];
      summary = `${e.type === "AGENTIC_MESSAGE" ? "Agentic" : "LLM"} 调用 · model=${prompt.modelId || e.obj.model_id || "?"} · ${msgs.length} 轮消息`;
      bodyHtml += `<div class="kv"><b>modelId:</b> ${esc(prompt.modelId || "")}</div>`;
      bodyHtml += renderConversation(msgs);
      // 工具配置
      if (prompt.toolConfig && prompt.toolConfig.tools) {
        const names = prompt.toolConfig.tools.map((t) => (t.toolSpec && t.toolSpec.name) || "").filter(Boolean);
        bodyHtml += `<details><summary>可用工具 (${names.length})</summary><div class="kv">${esc(names.join(", "))}</div></details>`;
      }

    } else if (e.type === "AI_AGENT_TRACE") {
      const sp = e.span || {};
      const dur = (sp.start_timestamp && sp.end_timestamp)
        ? (Number(sp.end_timestamp) - Number(sp.start_timestamp)) + "ms" : "";
      summary = `${sp.span_name || "span"} · ${sp.status || ""} ${dur ? "· " + dur : ""}`;
      if (sp.ai_agent_name) summary += ` · ${sp.ai_agent_name.trim()}`;
      if (sp.status && sp.status !== "OK") tags += `<span class="ev-tag err">${esc(sp.status)}</span>`;
      else tags += `<span class="ev-tag ok">OK</span>`;
      if (sp.span_name === "execute_tool") {
        const tn = toolNameFromSpan(sp);
        tags += `<span class="ev-tag mcp">🔌 MCP${tn ? ": " + esc(tn) : ""}</span>`;
      }

      const interesting = ["span_name", "span_type", "status", "operation_name",
        "ai_agent_type", "ai_agent_name", "ai_agent_version", "provider_name",
        "request_id", "span_id", "parent_span_id"];
      for (const k of interesting) {
        if (sp[k] !== undefined) bodyHtml += `<div class="kv"><b>${k}:</b> ${esc(String(sp[k]).trim())}</div>`;
      }
      // token 使用
      const tokenKeys = Object.keys(sp).filter((k) => /usage_|tokens|finish_reason/.test(k));
      if (tokenKeys.length) {
        bodyHtml += `<div class="kv" style="margin-top:6px"><b>用量:</b> ` +
          tokenKeys.map((k) => `${k}=${esc(sp[k])}`).join(" · ") + `</div>`;
      }
      // 工具调用 input/output
      if (sp.span_name === "execute_tool") {
        const im = tryParse(sp.input_messages);
        const om = tryParse(sp.output_messages);
        bodyHtml += renderToolSpan(im, om);
      }

    } else if (e.type === "CREATE_SESSION") {
      summary = `创建会话 session_name=${e.obj.session_name || ""}`;
      bodyHtml += `<div class="kv"><b>session_id:</b> ${esc(e.obj.session_id || "")}</div>`;
      bodyHtml += `<div class="kv"><b>session_name:</b> ${esc(e.obj.session_name || "")}</div>`;

    } else if (e.type === "SESSION_POLLED") {
      summary = `会话轮询 · ${e.obj.connect_user_arn ? "已分配坐席" : ""}`;
      if (e.obj.connect_user_arn) bodyHtml += `<div class="kv"><b>connect_user_arn:</b> ${esc(e.obj.connect_user_arn)}</div>`;

    } else if (e.type === "GATEWAY") {
      // Bedrock AgentCore Gateway 应用日志: 结构化或纯文本都兼容
      const o = e.obj;
      if (o && typeof o === "object") {
        const msgText = o.message || o.msg || o.body || "";
        const lvl = o.level || o.severity || o.status || "";
        summary = `${lvl ? "[" + lvl + "] " : ""}${typeof msgText === "string" ? msgText : JSON.stringify(msgText)}`.replace(/\s+/g, " ");
        const interesting = ["level", "severity", "status", "logger", "tool", "tool_name",
          "method", "operation", "requestId", "request_id", "duration", "durationMs", "latency"];
        for (const k of interesting) {
          if (o[k] !== undefined) bodyHtml += `<div class="kv"><b>${k}:</b> ${esc(typeof o[k] === "string" ? o[k] : JSON.stringify(o[k]))}</div>`;
        }
        if (msgText) bodyHtml += `<div class="bubble" style="background:#1a1f2b;border:1px solid var(--border)">${esc(typeof msgText === "string" ? msgText : JSON.stringify(msgText))}</div>`;
      } else {
        summary = (e.raw || "").replace(/\s+/g, " ");
        bodyHtml += `<div class="bubble" style="background:#1a1f2b;border:1px solid var(--border)">${esc(e.raw || "")}</div>`;
      }
      if (isGatewayError(e)) tags += `<span class="ev-tag err">error</span>`;

    } else {
      summary = e.fullType || e.type;
    }

    bodyHtml += `<details><summary>原始 JSON</summary><pre class="raw">${esc(prettyRaw(e.raw))}</pre></details>`;

    const srcTag = `<span class="src-tag src-${e.source}">${e.source === "gateway" ? "Gateway" : "Connect"}</span>`;
    const whoBadge = ri.badge ? `<span class="who ${ri.role}">${ri.badge}</span>` : "";

    div.innerHTML =
      `<div class="event-head">` +
        `<span class="ev-time">${time}</span>` +
        srcTag +
        whoBadge +
        `<span class="ev-type">${esc(e.type)}</span>` +
        `<span class="ev-summary">${esc(summary)}</span>` +
        tags +
      `</div>` +
      `<div class="event-body">${bodyHtml}</div>`;

    div.querySelector(".event-head").addEventListener("click", () => {
      div.classList.toggle("open");
    });
    return div;
  }

  function prettyRaw(raw) {
    const o = tryParse(raw);
    if (o) { try { return JSON.stringify(o, null, 2); } catch (e) {} }
    return raw;
  }

  // ---- 渲染高亮的译文气泡(原文保留在上方，译文高亮显示在下方) ----
  function renderTranslationBubble(translation, lang, who) {
    const label = lang ? `译文 · ${esc(lang)}` : "译文";
    return (
      `<div class="bubble ${who} translated">` +
        `<span class="trans-badge">${label}</span>` +
        esc(translation) +
      `</div>`
    );
  }

  // ---- 取一条事件里可翻译的对话正文(客户/机器人) ----
  function getTranslatableText(e) {
    if (e.source !== "connect") return "";
    if (e.type === "UTTERANCE") {
      const u = e.obj && e.obj.utterance || "";
      return u.replace(/^\[(CUSTOMER|AGENT|BOT|SYSTEM)\]\s*/, "").trim();
    }
    if (e.type === "ORCHESTRATION_MESSAGE") {
      return (e.obj ? extractMessageText(e.obj.values) : "").trim();
    }
    return "";
  }

  // ---- 从 execute_tool span 里取工具名 ----
  function toolNameFromSpan(sp) {
    const im = tryParse(sp.input_messages);
    if (Array.isArray(im)) {
      for (const m of im) {
        for (const v of (m.values || [])) {
          if (v.toolUse && v.toolUse.name) return v.toolUse.name;
        }
      }
    }
    return sp.tool_name || sp.tool || "";
  }

  // ---- 收集某会话里被调用的 MCP 工具名 ----
  function collectToolNames(list) {
    const set = new Set();
    for (const e of list) {
      if (e.source === "connect" && e.span && e.span.span_name === "execute_tool") {
        const n = toolNameFromSpan(e.span);
        if (n) set.add(n);
      }
      if (e.obj && e.obj.prompt) {
        const prompt = tryParse(e.obj.prompt) || {};
        for (const m of (prompt.messages || [])) {
          for (const c of (m.content || [])) {
            if (c.toolUse && c.toolUse.name) set.add(c.toolUse.name);
          }
        }
      }
    }
    return Array.from(set);
  }

  function renderConversation(msgs) {
    let html = "";
    for (const m of msgs) {
      const role = m.role || "?";
      const content = m.content || [];
      for (const c of content) {
        if (c.text !== undefined) {
          const parts = splitMessageThinking(c.text);
          for (const mm of parts.messages) if (mm) html += `<div class="bubble ${role === "user" ? "customer" : "bot"}">${esc(mm)}</div>`;
          for (const th of parts.thinking) if (th) html += `<div class="bubble thinking">💭 ${esc(th)}</div>`;
        } else if (c.guardContent && c.guardContent.text) {
          const t = c.guardContent.text.text || c.guardContent.text;
          html += `<div class="bubble ${role === "user" ? "customer" : "bot"}">${esc(typeof t === "string" ? t : JSON.stringify(t))}</div>`;
        } else if (c.toolUse) {
          html += `<div class="toolcall mcp">🔌 <span class="mcp-label">MCP 工具</span> <span class="name">${esc(c.toolUse.name)}</span><div class="kv">input: ${esc(JSON.stringify(c.toolUse.input))}</div></div>`;
        } else if (c.toolResult) {
          const rc = (c.toolResult.content || []).map((x) => x.text || JSON.stringify(x)).join("\n");
          html += `<div class="toolcall">↩️ 工具结果<pre class="raw">${esc(rc)}</pre></div>`;
        }
      }
    }
    return html;
  }

  function renderToolSpan(im, om) {
    let html = "";
    const collect = (arr) => {
      const r = [];
      (arr || []).forEach((msg) => (msg.values || []).forEach((v) => {
        if (v.toolUse) r.push(`<div class="toolcall mcp">🔌 <span class="mcp-label">MCP 工具</span> <span class="name">${esc(v.toolUse.name)}</span><div class="kv">input: ${esc(typeof v.toolUse.input === "string" ? v.toolUse.input : JSON.stringify(v.toolUse.input))}</div></div>`);
        if (v.toolResult) {
          const rc = (v.toolResult.content || []).map((x) => x.text || JSON.stringify(x)).join("\n");
          r.push(`<div class="toolcall">↩️ 结果<pre class="raw">${esc(rc)}</pre></div>`);
        }
      }));
      return r.join("");
    };
    html += collect(im);
    html += collect(om);
    return html;
  }

  // ---- 过滤器 ----
  const ALL_TYPES = ["UTTERANCE", "ORCHESTRATION_MESSAGE", "AGENTIC_MESSAGE",
    "LARGE_LANGUAGE_MODEL_INVOCATION", "AI_AGENT_TRACE", "CREATE_SESSION", "SESSION_POLLED", "GATEWAY"];
  const activeFilters = new Set(ALL_TYPES);

  const filtersEl = document.getElementById("filters");
  function renderFilters() {
    filtersEl.innerHTML = "";
    ALL_TYPES.forEach((t) => {
      const chip = document.createElement("span");
      chip.className = "filter-chip" + (activeFilters.has(t) ? " on" : "");
      chip.textContent = t;
      chip.addEventListener("click", () => {
        if (activeFilters.has(t)) activeFilters.delete(t); else activeFilters.add(t);
        renderFilters();
        if (activeCid) renderTimeline(activeCid);
      });
      filtersEl.appendChild(chip);
    });
  }

  // ---- 渲染时间线 ----
  const timelineEl = document.getElementById("timeline");
  const selectedTitle = document.getElementById("selectedTitle");

  function renderTimeline(cid) {
    const list = groups[cid].slice().sort((a, b) => a.ts - b.ts);
    const s = summarize(list);
    timelineEl.innerHTML = "";

    const toolNames = collectToolNames(list);
    const toolsHtml = toolNames.length
      ? `<div class="tool-list">🔌 <b>调用的 MCP 工具:</b> ` +
          toolNames.map((n) => `<span class="tool-chip">${esc(n)}</span>`).join("") + `</div>`
      : "";

    const stat = document.createElement("div");
    stat.className = "event";
    stat.style.borderColor = "var(--accent)";
    stat.innerHTML = `<div class="event-body" style="display:block;padding:12px">
      <div class="stat-row">
        <span>事件总数 <b>${list.length}</b></span>
        <span>LLM 调用 <b>${s.llmCalls}</b></span>
        <span>工具调用 <b>${s.toolCalls}</b></span>
        <span>网关日志 <b>${s.gateway}</b></span>
        <span>转人工 <b>${s.escalations}</b></span>
        <span>错误 <b style="color:${s.errors ? "var(--red)" : "inherit"}">${s.errors}</b></span>
        <span>护栏拦截 <b>${s.guardrailBlocks}</b></span>
      </div>${toolsHtml}</div>`;
    timelineEl.appendChild(stat);

    let shown = 0;
    for (const e of list) {
      if (!activeFilters.has(e.type) && ALL_TYPES.includes(e.type)) continue;
      timelineEl.appendChild(renderEvent(e));
      shown++;
    }
    if (shown === 0) {
      const d = document.createElement("div");
      d.className = "empty";
      d.textContent = "当前过滤条件下没有事件";
      timelineEl.appendChild(d);
    }
  }

  function selectContact(cid) {
    activeCid = cid;
    selectedTitle.textContent = cid;
    renderSidebar(searchBox.value);
    renderTimeline(cid);
  }

  // ---- 按需翻译某个 Contact 的客户/机器人对话 ----
  async function translateContact(cid) {
    if (translatingContacts.has(cid)) return;
    const list = groups[cid] || [];
    // 收集尚未翻译、且有正文的对话事件
    const items = [];
    for (const e of list) {
      const text = getTranslatableText(e);
      if (text && !e.translation) items.push({ e: e, text: text });
    }
    if (!items.length) {
      // 没有新内容需要翻译(可能已全部翻译过)
      translatedContacts.add(cid);
      renderSidebar(searchBox.value);
      if (activeCid === cid) renderTimeline(cid);
      return;
    }
    translatingContacts.add(cid);
    renderSidebar(searchBox.value);
    try {
      const resp = await fetch("./api/translate", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ texts: items.map((i) => i.text), lang: TRANSLATE_CFG.lang }),
      });
      const data = await resp.json().catch(() => ({}));
      if (!resp.ok) throw new Error((data && data.error) || ("HTTP " + resp.status));
      const translations = data.translations || [];
      items.forEach((it, i) => {
        it.e.translation = translations[i] || "";
        it.e.translationLang = data.lang || TRANSLATE_CFG.lang;
      });
      translatedContacts.add(cid);
    } catch (err) {
      window.alert("翻译失败: " + (err && err.message ? err.message : err));
    } finally {
      translatingContacts.delete(cid);
      renderSidebar(searchBox.value);
      if (activeCid === cid) renderTimeline(cid);
    }
  }

  // ---- 读取本地服务器的翻译配置(可用性 / 默认语种) ----
  function loadTranslateConfig() {
    return fetch("./api/config")
      .then((r) => (r.ok ? r.json() : null))
      .then((cfg) => {
        if (cfg) TRANSLATE_CFG = { available: !!cfg.available, lang: cfg.lang || "中文" };
      })
      .catch(() => { /* 非翻译服务器(如 file:// 或 http.server) -> 隐藏翻译按钮 */ });
  }

  // ---- 渲染 Dashboard ----
  const dashCardsEl = document.getElementById("dashCards");
  const dashToolCountsEl = document.getElementById("dashToolCounts");
  const dashContactRowsEl = document.getElementById("dashContactRows");

  // Dashboard Contact 列表的排序状态: key = cid | start | end, dir = asc | desc
  let dashSort = { key: "start", dir: "desc" };

  function dashComparator(a, b) {
    const dir = dashSort.dir === "asc" ? 1 : -1;
    if (dashSort.key === "cid") {
      return dir * String(a.cid).localeCompare(String(b.cid));
    }
    let av = dashSort.key === "end" ? a.m.endTs : a.m.startTs;
    let bv = dashSort.key === "end" ? b.m.endTs : b.m.startTs;
    av = av == null ? -Infinity : av;
    bv = bv == null ? -Infinity : bv;
    if (av === bv) return String(a.cid).localeCompare(String(b.cid));
    return dir * (av - bv);
  }

  // 点击表头切换排序: 同列切换升/降序，换列则默认降序
  function setDashSort(key) {
    if (dashSort.key === key) {
      dashSort.dir = dashSort.dir === "asc" ? "desc" : "asc";
    } else {
      dashSort = { key: key, dir: "desc" };
    }
    renderDashboard();
  }

  // 更新表头的排序指示箭头与高亮
  function updateSortIndicators() {
    document.querySelectorAll(".contact-table th.sortable").forEach((th) => {
      const key = th.getAttribute("data-sort");
      const ind = th.querySelector(".sort-ind");
      const active = key === dashSort.key;
      th.classList.toggle("active", active);
      if (ind) ind.textContent = active ? (dashSort.dir === "asc" ? "▲" : "▼") : "";
    });
  }

  function renderDashboard() {
    const agg = computeAggregate();

    // 顶部汇总卡片
    dashCardsEl.innerHTML =
      card("总通话数", agg.totalContacts) +
      card("总通话时间", formatDuration(agg.totalDuration)) +
      card("总 AI Agent 调用次数", agg.totalAi) +
      card("总对话轮次", agg.totalTurns) +
      card("总护栏拦截数", agg.totalGuard, agg.totalGuard ? "warn" : "") +
      card("总错误数", agg.totalErr, agg.totalErr ? "danger" : "");

    // 各 MCP 工具总调用次数
    const toolNames = Object.keys(agg.toolTotals).sort((a, b) => agg.toolTotals[b] - agg.toolTotals[a]);
    if (toolNames.length) {
      dashToolCountsEl.innerHTML = toolNames.map((n) =>
        `<span class="tool-count-chip"><span class="tname">🔌 ${esc(n)}</span><span class="tnum">${agg.toolTotals[n]}</span></span>`
      ).join("");
    } else {
      dashToolCountsEl.innerHTML = `<span class="tool-counts-empty">未发现 MCP 工具调用</span>`;
    }

    // Contact 列表(支持按 Contact ID / Start Time / End Time 升降序)
    const rows = contactIds
      .filter((c) => c !== "(未关联的 Gateway 日志)")
      .map((cid) => ({ cid: cid, m: computeMetrics(groups[cid]) }));
    rows.sort(dashComparator);
    updateSortIndicators();

    dashContactRowsEl.innerHTML = "";
    if (!rows.length) {
      dashContactRowsEl.innerHTML = `<tr><td colspan="5" style="color:var(--muted)">暂无 Contact 数据</td></tr>`;
      return;
    }
    for (const row of rows) {
      const cid = row.cid;
      const mm = row.m;

      // Tools 列: 该会话涉及的工具调用(名称 + 次数)
      const toolNames = Object.keys(mm.toolCounts).sort((a, b) => mm.toolCounts[b] - mm.toolCounts[a]);
      const toolsCell = toolNames.length
        ? toolNames.map((n) => `<span class="tool-chip" title="${esc(n)}">${esc(n)}×${mm.toolCounts[n]}</span>`).join(" ")
        : `<span style="color:var(--muted)">—</span>`;

      // 主行
      const tr = document.createElement("tr");
      tr.className = "contact-row";
      tr.innerHTML =
        `<td class="cid-cell" title="${esc(cid)}">${esc(cid)}</td>` +
        `<td class="time-cell">${esc(formatDateTime(mm.startTs))}</td>` +
        `<td class="time-cell">${esc(formatDateTime(mm.endTs))}</td>` +
        `<td class="tools-cell">${toolsCell}</td>` +
        `<td class="act-cell">` +
          `<button class="act-btn stats">统计</button>` +
          `<button class="act-btn logs">日志</button>` +
        `</td>`;

      // 展开/收缩的统计明细行(默认隐藏)
      const detailTr = document.createElement("tr");
      detailTr.className = "detail-row";
      detailTr.style.display = "none";
      detailTr.innerHTML = `<td colspan="5" class="detail-cell">${renderStatsHtml(mm)}</td>`;

      const statsBtn = tr.querySelector(".act-btn.stats");
      statsBtn.addEventListener("click", () => {
        const open = detailTr.style.display !== "none";
        detailTr.style.display = open ? "none" : "table-row";
        statsBtn.classList.toggle("on", !open);
        tr.classList.toggle("expanded", !open);
      });
      tr.querySelector(".act-btn.logs").addEventListener("click", () => openContactLogs(cid));

      dashContactRowsEl.appendChild(tr);
      dashContactRowsEl.appendChild(detailTr);
    }
  }

  // ---- 生成单个 Contact 的统计明细 HTML(用于展开行) ----
  function renderStatsHtml(m) {
    let html = `<div class="cards" style="margin-bottom:14px">` +
      card("总通话时间", formatDuration(m.duration)) +
      card("AI Agent 调用次数", m.aiAgentCalls) +
      card("对话轮次", m.turns) +
      card("护栏拦截数", m.guardrailBlocks, m.guardrailBlocks ? "warn" : "") +
      card("错误数", m.errors, m.errors ? "danger" : "") +
      `</div>`;
    html += `<div class="dash-section-title" style="margin:4px 0 10px">各 MCP 工具调用次数</div>`;
    const toolNames = Object.keys(m.toolCounts).sort((a, b) => m.toolCounts[b] - m.toolCounts[a]);
    if (toolNames.length) {
      html += `<div class="tool-counts" style="margin-bottom:0">` +
        toolNames.map((n) =>
          `<span class="tool-count-chip"><span class="tname">🔌 ${esc(n)}</span><span class="tnum">${m.toolCounts[n]}</span></span>`
        ).join("") + `</div>`;
    } else {
      html += `<div class="tool-counts-empty">未发现 MCP 工具调用</div>`;
    }
    return html;
  }

  function card(label, value, cls) {
    return `<div class="card"><div class="label">${esc(label)}</div>` +
      `<div class="value ${cls || ""}">${esc(value)}</div></div>`;
  }

  // ---- 视图切换(Dashboard / 日志排查) ----
  const viewDashboard = document.getElementById("viewDashboard");
  const viewLog = document.getElementById("viewLog");
  const navDashboard = document.getElementById("navDashboard");
  const navLog = document.getElementById("navLog");

  function showView(name) {
    const dash = name === "dashboard";
    viewDashboard.classList.toggle("show", dash);
    viewLog.style.display = dash ? "none" : "flex";
    navDashboard.classList.toggle("active", dash);
    navLog.classList.toggle("active", !dash);
  }

  // 从 Dashboard 点击「日志」: 切到日志排查视图并选中该 Contact
  function openContactLogs(cid) {
    showView("log");
    selectContact(cid);
  }

  // ---- 初始化 ----
  function init() {
    document.getElementById("globalMeta").textContent =
      `${events.length} 条事件 · ${contactIds.length} 个 Contact`;
    renderFilters();
    renderSidebar("");
    renderDashboard();
    searchBox.addEventListener("input", () => renderSidebar(searchBox.value));
    const sortSelect = document.getElementById("sortSelect");
    if (sortSelect) {
      sortSelect.value = currentSort;
      sortSelect.addEventListener("change", () => {
        currentSort = sortSelect.value;
        renderSidebar(searchBox.value);
        renderDashboard();
      });
    }

    // 导航事件
    navDashboard.addEventListener("click", () => showView("dashboard"));
    navLog.addEventListener("click", () => showView("log"));

    // Dashboard 表头点击排序
    document.querySelectorAll(".contact-table th.sortable").forEach((th) => {
      th.addEventListener("click", () => setDashSort(th.getAttribute("data-sort")));
    });

    if (contactIds.length) selectContact(getOrderedContactIds()[0]);
    // 探测翻译能力，成功后重绘侧栏以显示翻译按钮
    loadTranslateConfig().then(() => renderSidebar(searchBox.value));

    // 默认展示 Dashboard
    showView("dashboard");
  }

  init();
})();
