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
  const contactIds = Object.keys(groups).sort((a, b) => {
    const ta = Math.min.apply(null, groups[a].map((x) => x.ts));
    const tb = Math.min.apply(null, groups[b].map((x) => x.ts));
    return tb - ta; // 最近的会话排前面
  });

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

  // ---- 渲染侧栏 ----
  const contactListEl = document.getElementById("contactList");
  const searchBox = document.getElementById("searchBox");
  let activeCid = null;

  function renderSidebar(filter) {
    const f = (filter || "").trim().toLowerCase();
    contactListEl.innerHTML = "";
    const shown = contactIds.filter((c) => !f || c.toLowerCase().includes(f));
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
      item.innerHTML =
        `<div class="cid-row">` +
          `<span class="cid" title="${cid}">${cid}</span>` +
          `<span class="cid-actions">` +
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
    const header = ["timestamp_ms", "datetime", "source", "event_type", "message"];
    const lines = [header.join(",")];
    for (const e of list) {
      const dt = new Date(e.ts).toISOString();
      lines.push([
        csvEscape(e.ts),
        csvEscape(dt),
        csvEscape(e.source || ""),
        csvEscape(e.fullType || e.type || ""),
        csvEscape(e.raw != null ? e.raw : ""),
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

  // ---- 渲染单个事件 ----
  function renderEvent(e) {
    const div = document.createElement("div");
    div.className = "event t-" + e.type;

    const time = new Date(e.ts).toLocaleTimeString([], { hour12: false }) +
      "." + String(e.ts % 1000).padStart(3, "0");

    let summary = "";
    let tags = "";
    let bodyHtml = "";

    if (e.type === "UTTERANCE") {
      const u = e.obj.utterance || "";
      summary = u;
      const isCustomer = /^\[CUSTOMER\]/.test(u);
      const txt = u.replace(/^\[(CUSTOMER|AGENT|BOT|SYSTEM)\]\s*/, "");
      bodyHtml = `<div class="bubble ${isCustomer ? "customer" : "bot"}">${esc(txt)}</div>`;

    } else if (e.type === "ORCHESTRATION_MESSAGE") {
      const txt = extractMessageText(e.obj.values);
      const who = (e.obj.participant || "BOT").toLowerCase() === "customer" ? "customer" : "bot";
      summary = `[${e.obj.participant || "BOT"}] ${txt}`.replace(/\s+/g, " ");
      const parts = splitMessageThinking(txt);
      bodyHtml += `<div class="kv"><b>participant:</b> ${esc(e.obj.participant || "")} · <b>model:</b> ${esc(e.obj.model_id || "")}</div>`;
      for (const mm of parts.messages) if (mm) bodyHtml += `<div class="bubble ${who}">${esc(mm)}</div>`;
      for (const th of parts.thinking) if (th) bodyHtml += `<div class="bubble thinking">💭 ${esc(th)}</div>`;
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

    div.innerHTML =
      `<div class="event-head">` +
        `<span class="ev-time">${time}</span>` +
        srcTag +
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
          html += `<div class="toolcall">🔧 <span class="name">${esc(c.toolUse.name)}</span><div class="kv">input: ${esc(JSON.stringify(c.toolUse.input))}</div></div>`;
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
        if (v.toolUse) r.push(`<div class="toolcall">🔧 <span class="name">${esc(v.toolUse.name)}</span><div class="kv">input: ${esc(typeof v.toolUse.input === "string" ? v.toolUse.input : JSON.stringify(v.toolUse.input))}</div></div>`);
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
      </div></div>`;
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

  // ---- 初始化 ----
  function init() {
    document.getElementById("globalMeta").textContent =
      `${events.length} 条事件 · ${contactIds.length} 个 Contact`;
    renderFilters();
    renderSidebar("");
    searchBox.addEventListener("input", () => renderSidebar(searchBox.value));
    if (contactIds.length) selectContact(contactIds[0]);
  }

  init();
})();
