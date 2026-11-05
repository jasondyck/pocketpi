"use strict";
// pocketpi client. One pi RPC process per open chat; this page streams its
// events over SSE and sends commands through /api/s/{key}/cmd.

const $ = (id) => document.getElementById(id);
const el = (tag, cls, html) => {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (html != null) e.innerHTML = html;
  return e;
};
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const fine = matchMedia("(pointer: fine)").matches;

const ICON = {
  check: '<svg viewBox="0 0 24 24"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg>',
  x: '<svg viewBox="0 0 24 24"><path d="M6 6l12 12M18 6L6 18"/></svg>',
  chev: '<svg viewBox="0 0 24 24"><path d="M9 6l6 6-6 6"/></svg>',
  term: '<svg viewBox="0 0 24 24"><path d="M5 7l5 5-5 5M12 17h7"/></svg>',
  file: '<svg viewBox="0 0 24 24"><path d="M7 3h7l5 5v13H7z"/><path d="M14 3v5h5"/></svg>',
  pen: '<svg viewBox="0 0 24 24"><path d="M15 5l4 4L8 20H4v-4z"/></svg>',
  search: '<svg viewBox="0 0 24 24"><circle cx="11" cy="11" r="6"/><path d="M16 16l4 4"/></svg>',
  folder: '<svg viewBox="0 0 24 24"><path d="M3 7.5A1.5 1.5 0 0 1 4.5 6h4l2 2h9A1.5 1.5 0 0 1 21 9.5v8a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 17.5z"/></svg>',
  tool: '<svg viewBox="0 0 24 24"><path d="M14.5 6.5a4 4 0 0 0 5 5L12 19l-3 1 1-3 7.5-7.5z"/><path d="M4 4l6 6"/></svg>',
  globe: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="8.5"/><path d="M3.5 12h17M12 3.5c2.5 3 2.5 14 0 17M12 3.5c-2.5 3-2.5 14 0 17"/></svg>',
  copy: '<svg viewBox="0 0 24 24"><rect x="8" y="8" width="12" height="12" rx="2.5"/><path d="M16 8V5.5A1.5 1.5 0 0 0 14.5 4h-9A1.5 1.5 0 0 0 4 5.5v9A1.5 1.5 0 0 0 5.5 16H8"/></svg>',
  compact: '<svg viewBox="0 0 24 24"><path d="M4 9h16M4 15h16M9 4l3 3 3-3M9 20l3-3 3 3"/></svg>',
  rename: '<svg viewBox="0 0 24 24"><path d="M4 20h4L19 9l-4-4L4 16z"/></svg>',
  power: '<svg viewBox="0 0 24 24"><path d="M12 3v8M7 6.5a7 7 0 1 0 10 0"/></svg>',
  pin: '<svg viewBox="0 0 24 24"><path d="M9 3h6l-1 6 4 4H6l4-4zM12 13v8"/></svg>',
  hide: '<svg viewBox="0 0 24 24"><path d="M3 3l18 18M10.6 6.1A9 9 0 0 1 12 6c5 0 8.5 4.5 9 6-.3.9-1.2 2.4-2.7 3.7M6.3 7.8C4.6 9 3.4 10.7 3 12c.6 1.7 4 6 9 6 1.6 0 3-.4 4.2-1"/></svg>',
  chip: '<svg viewBox="0 0 24 24"><rect x="6" y="6" width="12" height="12" rx="2.5"/><path d="M9 3v3M15 3v3M9 18v3M15 18v3M3 9h3M3 15h3M18 9h3M18 15h3"/></svg>',
  plus: '<svg viewBox="0 0 24 24"><path d="M12 5v14M5 12h14"/></svg>',
};
const TOOL_ICON = { bash: ICON.term, read: ICON.file, write: ICON.pen, edit: ICON.pen, grep: ICON.search, find: ICON.search, ls: ICON.folder, web_search: ICON.globe, web_fetch: ICON.globe };

// ---------------------------------------------------------------- state
const S = {
  key: null,          // live process key on the server
  path: null,         // session file path (stable identity)
  cwd: null,
  state: null,        // pi get_state
  stats: null,
  msgs: [],
  streaming: false,
  es: null,
  cur: null,          // { msg, el, blocks: [] } for the streaming assistant message
  cards: new Map(),   // toolCallId -> card api
  attachments: [],
  sessions: [],
  projects: [],
  home: "",
  project: localStorage.getItem("pp.project") || "",   // "" = all chats
  models: null,
  levels: [],
  commands: null,
  stick: true,
  connecting: null,
  reconnectTimer: null,
};

// ---------------------------------------------------------------- api
async function api(path, body) {
  const opt = body === undefined ? {} : { method: "POST", headers: { "content-type": "application/json", "x-pocketpi": "1" }, body: JSON.stringify(body) };
  const r = await fetch(path, opt);
  if (!r.ok) {
    const t = await r.text();
    const e = new Error(t || r.statusText);
    e.status = r.status;
    throw e;
  }
  return r.json();
}

async function cmd(c, retry = true) {
  if (!S.key) throw new Error("no session");
  try {
    const r = await api(`/api/s/${S.key}/cmd`, c);
    if (r.success === false) throw new Error(r.error || `${c.type} failed`);
    return r.data;
  } catch (e) {
    if (retry && (e.status === 404 || e.status === 410) && S.path) {
      await reopen();
      return cmd(c, false);
    }
    throw e;
  }
}

// ---------------------------------------------------------------- helpers
const tilde = (p) => (p && S.home && (p === S.home || p.startsWith(S.home + "/")) ? "~" + p.slice(S.home.length) : p || "");
const base = (p) => (p || "").replace(/\/+$/, "").split("/").pop() || "/";
function hue(s) { let h = 0; for (const c of s || "") h = (h * 31 + c.charCodeAt(0)) >>> 0; return h % 360; }
function initials(name) {
  const w = (name || "?").split(/[-_\s.]+/).filter(Boolean);
  const s = w.length > 1 ? w[0][0] + w[1][0] : (w[0] || "?").slice(0, 2);
  return s.charAt(0).toUpperCase() + s.slice(1).toLowerCase();
}
function projectFor(path) { return S.projects.find((s) => s.path === path); }
function projectName(path) { const sp = projectFor(path); return sp ? sp.name : path === S.home ? "Home" : base(path); }
function badge(path, cls = "badge") { const n = projectName(path); return `<span class="${cls}" style="--h:${hue(path)}">${esc(initials(n))}</span>`; }
function plural(n, w) { return `${n} ${w}${n === 1 ? "" : "s"}`; }
function fmtTokens(n) { if (n == null) return "–"; if (n >= 1e6) return (n / 1e6).toFixed(n >= 1e7 ? 0 : 1) + "M"; if (n >= 1e3) return (n / 1e3).toFixed(n >= 1e4 ? 0 : 1) + "k"; return String(n); }
function fmtCost(c) { if (!c) return "$0"; return c < 0.01 ? "<$0.01" : "$" + c.toFixed(c < 1 ? 3 : 2); }
function ago(ms) {
  const d = (Date.now() - ms) / 1000;
  if (d < 60) return "now"; if (d < 3600) return Math.floor(d / 60) + "m"; if (d < 86400) return Math.floor(d / 3600) + "h";
  if (d < 604800) return Math.floor(d / 86400) + "d";
  return new Date(ms).toLocaleDateString(undefined, { month: "short", day: "numeric" });
}
function textOf(content) {
  if (typeof content === "string") return content;
  return (content || []).filter((p) => p.type === "text").map((p) => p.text).join("\n");
}
let toastTimer;
function toast(msg, error = false) {
  const t = $("toast"); t.textContent = msg; t.className = error ? "error" : ""; t.hidden = false;
  clearTimeout(toastTimer); toastTimer = setTimeout(() => (t.hidden = true), error ? 5000 : 2600);
}
function banner(html, error = false) { const b = $("banner"); if (!html) { b.hidden = true; return; } b.innerHTML = html; b.className = error ? "error" : ""; b.hidden = false; }
async function copyText(text, btn) {
  try { await navigator.clipboard.writeText(text); } catch {
    const ta = el("textarea"); ta.value = text; document.body.append(ta); ta.select(); document.execCommand("copy"); ta.remove();
  }
  if (btn) { const old = btn.innerHTML; btn.classList.add("done"); btn.textContent = "Copied"; setTimeout(() => { btn.innerHTML = old; btn.classList.remove("done"); }, 1300); }
}

// ---------------------------------------------------------------- markdown
function safeUrl(u) { return /^(https?:|mailto:|#|\/)/i.test(u); }
function inline(src) {
  const keep = [];
  const hold = (html) => `\u0000${keep.push(html) - 1}\u0000`;
  let s = src.replace(/`([^`\n]+)`/g, (_, c) => hold(`<code>${esc(c)}</code>`));
  s = s.replace(/!?\[([^\]\n]+)\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g, (m, t, u) => safeUrl(u) ? hold(`<a href="${esc(u)}" target="_blank" rel="noopener">${esc(t)}</a>`) : m);
  s = s.replace(/(^|[\s(])(https?:\/\/[^\s<>()]+[^\s<>().,;:!?'"])/g, (_, p, u) => p + hold(`<a href="${esc(u)}" target="_blank" rel="noopener">${esc(u)}</a>`));
  s = esc(s);
  s = s.replace(/\*\*([^*\n]+?)\*\*/g, "<strong>$1</strong>").replace(/__([^_\n]+?)__/g, "<strong>$1</strong>");
  s = s.replace(/(^|[^*\w])\*([^*\s][^*\n]*?)\*(?![*\w])/g, "$1<em>$2</em>").replace(/(^|[^_\w])_([^_\s][^_\n]*?)_(?![_\w])/g, "$1<em>$2</em>");
  s = s.replace(/~~([^~\n]+)~~/g, "<del>$1</del>");
  return s.replace(/\u0000(\d+)\u0000/g, (_, i) => keep[+i]);
}
const LIST_RE = /^(\s*)([-*+]|\d{1,9}[.)])\s+(.*)$/;
const indentOf = (l) => l.match(/^\s*/)[0].replace(/\t/g, "    ").length;
function isBlockStart(l) { return /^\s*(```|~~~|#{1,6}\s|>|([-*_])(\s*\2){2,}\s*$)/.test(l) || LIST_RE.test(l); }
function md(src) {
  const lines = src.replace(/\r\n?/g, "\n").split("\n");
  let out = "", i = 0;
  while (i < lines.length) {
    const line = lines[i];
    if (!line.trim()) { i++; continue; }
    const fence = line.match(/^\s*(```+|~~~+)\s*([\w+#.-]*)/);
    if (fence) {
      const close = fence[1]; const lang = fence[2]; const buf = []; i++;
      while (i < lines.length && !lines[i].trim().startsWith(close)) buf.push(lines[i++]);
      i++;
      out += `<div class="codeblock"><div class="cb-head"><span>${esc(lang || "code")}</span><button class="copy" data-copy>Copy</button></div><pre><code>${esc(buf.join("\n"))}</code></pre></div>`;
      continue;
    }
    const h = line.match(/^\s*(#{1,6})\s+(.*?)\s*#*\s*$/);
    if (h) { const n = Math.min(h[1].length, 4); out += `<h${n}>${inline(h[2])}</h${n}>`; i++; continue; }
    if (/^\s*([-*_])(\s*\1){2,}\s*$/.test(line)) { out += "<hr>"; i++; continue; }
    if (/^\s*>/.test(line)) {
      const buf = [];
      while (i < lines.length && /^\s*>/.test(lines[i])) buf.push(lines[i++].replace(/^\s*>\s?/, ""));
      out += `<blockquote>${md(buf.join("\n"))}</blockquote>`;
      continue;
    }
    if (line.includes("|") && i + 1 < lines.length && /^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$/.test(lines[i + 1])) {
      const cells = (l) => l.trim().replace(/^\||\|$/g, "").split("|").map((c) => c.trim());
      const head = cells(line); i += 2; const rows = [];
      while (i < lines.length && lines[i].includes("|") && lines[i].trim()) rows.push(cells(lines[i++]));
      out += `<table><thead><tr>${head.map((c) => `<th>${inline(c)}</th>`).join("")}</tr></thead><tbody>${rows.map((r) => `<tr>${r.map((c) => `<td>${inline(c)}</td>`).join("")}</tr>`).join("")}</tbody></table>`;
      continue;
    }
    if (LIST_RE.test(line)) {
      const baseIndent = indentOf(line);
      const ordered = /^\s*\d/.test(line);
      const start = ordered ? parseInt(line.trim(), 10) : 1;
      const items = [];
      while (i < lines.length) {
        const l = lines[i]; const m = l.match(LIST_RE);
        if (m && indentOf(l) === baseIndent) { items.push([m[3]]); i++; continue; }
        if (!l.trim()) {
          const n = lines[i + 1];
          if (n && n.trim() && (indentOf(n) > baseIndent || (LIST_RE.test(n) && indentOf(n) === baseIndent))) { items[items.length - 1].push(""); i++; continue; }
          break;
        }
        if (indentOf(l) > baseIndent || (!isBlockStart(l) && items.length)) { items[items.length - 1].push(l); i++; continue; }
        break;
      }
      const tag = ordered ? "ol" : "ul";
      out += `<${tag}${ordered && start !== 1 ? ` start="${start}"` : ""}>` + items.map((it) => {
        if (it.length === 1) return `<li>${inline(it[0])}</li>`;
        const rest = it.slice(1); const ind = Math.min(...rest.filter((x) => x.trim()).map(indentOf), 99);
        const body = [it[0], ...rest.map((x) => x.slice(Math.min(ind, indentOf(x))))].join("\n");
        const html = md(body);
        return `<li>${/^<p>/.test(html) && !rest.some((x) => !x.trim()) ? html.replace(/^<p>([\s\S]*?)<\/p>/, "$1") : html}</li>`;
      }).join("") + `</${tag}>`;
      continue;
    }
    const buf = [];
    while (i < lines.length && lines[i].trim() && !(buf.length && isBlockStart(lines[i]))) buf.push(lines[i++]);
    out += `<p>${buf.map(inline).join("<br>")}</p>`;
  }
  return out;
}

// ---------------------------------------------------------------- tool cards
function toolArgSummary(name, a) {
  if (!a || typeof a !== "object") return "";
  if (name === "bash") return a.command || "";
  const p = a.path || a.file_path || a.filePath;
  if (p) return tilde(p) + (a.pattern ? `  ${a.pattern}` : "");
  if (a.pattern) return a.pattern;
  if (a.query) return a.query;
  if (a.url) return a.url;
  const s = JSON.stringify(a); return s === "{}" ? "" : s;
}
function truncBlock(text, limit = 6000) {
  const wrap = el("div");
  const pre = el("pre");
  pre.textContent = text.length > limit ? text.slice(0, limit) : text;
  wrap.append(pre);
  if (text.length > limit) {
    const more = el("button", "more", `Show all · ${fmtTokens(text.length)} chars`);
    more.onclick = (e) => { e.preventDefault(); pre.textContent = text; more.remove(); };
    wrap.append(more);
  }
  return wrap;
}
function diffBlock(diff) {
  const pre = el("pre");
  pre.innerHTML = diff.split("\n").slice(0, 600).map((l) => {
    const c = /^\+(?!\+\+)/.test(l) ? "d-add" : /^-(?!--)/.test(l) ? "d-del" : /^@@/.test(l) ? "d-hunk" : "";
    return c ? `<span class="${c}">${esc(l)}</span>` : esc(l);
  }).join("\n");
  return pre;
}
function makeCard(call) {
  const d = el("details", "tool");
  d.innerHTML = `<summary><span class="ticon">${TOOL_ICON[call.name] || ICON.tool}</span><span class="tname"></span><span class="targ"></span><span class="tmeta"></span></summary><div class="tbody"></div>`;
  const q = (s) => d.querySelector(s);
  const api = {
    el: d, name: call.name, args: call.arguments || {}, result: null, isError: false, partial: null, duration: null,
    setCall(c) { api.name = c.name || api.name; api.args = c.arguments || api.args; q(".tname").textContent = api.name; q(".targ").textContent = toolArgSummary(api.name, api.args); if (d.open) api.renderBody(); },
    setState(s) { d.classList.toggle("run", s === "run"); d.classList.toggle("err", s === "err"); d.classList.toggle("ok", s === "ok"); },
    setPartial(r) { api.partial = r; if (d.open) api.renderBody(); },
    setResult(r, isError, ms) {
      api.result = r; api.isError = !!isError; if (ms != null) api.duration = ms;
      api.setState(isError ? "err" : "ok");
      q(".tmeta").textContent = api.duration != null ? (api.duration >= 1000 ? (api.duration / 1000).toFixed(1) + "s" : "") : "";
      if (d.open) api.renderBody();
    },
    renderBody() {
      const body = q(".tbody"); body.innerHTML = "";
      const a = api.args || {};
      const sec = (label, node) => { const s = el("div", "tsec"); s.append(el("div", "tlabel", esc(label)), node); body.append(s); };
      if (api.name === "bash" && a.command) sec("Command", truncBlock(a.command, 4000));
      else if (Array.isArray(a.edits) || a.oldText != null || a.old_string != null) { /* shown via diff below */ }
      else if (api.name === "write" && a.content != null) sec(`Content · ${tilde(a.path || "")}`, truncBlock(String(a.content), 3000));
      else if (Object.keys(a).length) sec("Arguments", truncBlock(JSON.stringify(a, null, 2), 3000));
      const r = api.result || api.partial;
      const diff = r && r.details && typeof r.details.diff === "string" ? r.details.diff : null;
      if (diff) sec("Diff", diffBlock(diff));
      else if (Array.isArray(a.edits)) sec("Edits", diffBlock(a.edits.map((e) => [...String(e.oldText ?? "").split("\n").map((l) => "-" + l), ...String(e.newText ?? "").split("\n").map((l) => "+" + l)].join("\n")).join("\n@@\n")));
      else if (a.oldText != null || a.old_string != null) sec("Edit", diffBlock([...String(a.oldText ?? a.old_string).split("\n").map((l) => "-" + l), ...String(a.newText ?? a.new_string ?? "").split("\n").map((l) => "+" + l)].join("\n")));
      if (r && Array.isArray(r.content)) {
        const text = textOf(r.content);
        if (text && !(diff && !api.isError && text.length < 200)) sec(api.isError ? "Error" : api.result ? "Output" : "Output so far", truncBlock(text));
        for (const p of r.content) if (p.type === "image") { const img = el("img"); img.src = `data:${p.mimeType};base64,${p.data}`; sec("Image", img); }
      } else if (!r) sec("Status", el("pre", "", "waiting…"));
    },
  };
  d.addEventListener("toggle", () => { if (d.open) api.renderBody(); });
  api.setCall(call);
  return api;
}

// ---------------------------------------------------------------- message rendering
function fillBlock(blockEl, b, live) {
  if (b.type === "text") {
    blockEl.innerHTML = md(b.text || "");
  } else if (b.type === "thinking") {
    const label = live ? "Thinking" : b._secs ? `Thought for ${b._secs}s` : "Thought process";
    blockEl.classList.toggle("live", !!live);
    blockEl.querySelector("summary span").textContent = b.redacted && !b.thinking ? "Reasoning (hidden)" : label;
    blockEl.querySelector(".think-body").textContent = b.thinking || "";
  }
}
function makeBlock(b, live) {
  if (b.type === "text") { const d = el("div", "md"); fillBlock(d, b, live); return d; }
  if (b.type === "thinking") {
    if (!live && !(b.thinking || "").trim()) return null;
    const d = el("details", "think"); d.innerHTML = `<summary>${ICON.chev}<span></span></summary><div class="think-body"></div>`;
    fillBlock(d, b, live); return d;
  }
  if (b.type === "toolCall") {
    let card = S.cards.get(b.id);
    if (!card) { card = makeCard(b); if (b.id) S.cards.set(b.id, card); card.setState("run"); }
    else card.setCall(b);
    return card.el;
  }
  return null;
}
// group consecutive tool cards into one .tools column
function placeBlock(container, node) {
  if (node.classList.contains("tool")) {
    let last = container.lastElementChild;
    if (!last || !last.classList.contains("tools")) { last = el("div", "tools"); container.append(last); }
    last.append(node);
  } else container.append(node);
}
function assistantActions(m) {
  const text = textOf(m.content);
  if (!text.trim()) return null;
  const row = el("div", "actions");
  const btn = el("button", "copy", `${ICON.copy}<span>Copy</span>`);
  btn.onclick = () => copyText(text, btn);
  row.append(btn);
  const u = m.usage;
  if (u && u.totalTokens) row.append(el("span", "usage", `${esc(m.model || "")} · ${fmtTokens(u.output)} out${u.cost && u.cost.total ? " · " + fmtCost(u.cost.total) : ""}`));
  return row;
}
function renderAssistant(m, live = false) {
  const wrap = el("div", "msg asst");
  const blocks = [];
  (m.content || []).forEach((b, i) => { const n = makeBlock(b, live); blocks[i] = n; if (n) placeBlock(wrap, n); });
  finishAssistant(wrap, m);
  return { el: wrap, blocks };
}
function finishAssistant(wrap, m) {
  wrap.querySelectorAll(":scope > .errbox, :scope > .actions").forEach((n) => n.remove());
  if (m.stopReason === "error") wrap.append(el("div", "errbox", esc(m.errorMessage || "The model returned an error.")));
  else if (m.stopReason === "aborted") wrap.append(el("div", "errbox soft", "Stopped."));
  else if (m.stopReason === "length") wrap.append(el("div", "errbox soft", "Hit the output limit."));
  if (m.stopReason && m.stopReason !== "pending" && m.stopReason !== "toolUse") { const a = assistantActions(m); if (a) wrap.append(a); }
}
function renderUser(m) {
  const wrap = el("div", "msg user");
  const b = el("div", "bubble");
  if (Array.isArray(m.content)) for (const p of m.content) if (p.type === "image") { const img = el("img"); img.src = `data:${p.mimeType};base64,${p.data}`; b.append(img); }
  b.append(document.createTextNode(textOf(m.content)));
  wrap.append(b);
  return wrap;
}
function renderOther(m) {
  if (m.role === "compactionSummary" || m.role === "branchSummary") {
    const d = el("details", "note-summary");
    d.innerHTML = `<summary>${m.role === "compactionSummary" ? `Earlier conversation summarized${m.tokensBefore ? ` · ${fmtTokens(m.tokensBefore)} tokens` : ""}` : "Branch summary"}</summary><div class="md">${md(m.summary || "")}</div>`;
    return d;
  }
  if (m.role === "bashExecution") {
    const card = makeCard({ name: "bash", arguments: { command: m.command } });
    card.setResult({ content: [{ type: "text", text: m.output || "" }] }, m.exitCode !== 0 && m.exitCode != null);
    const w = el("div", "msg"); placeBlock(w, card.el); return w;
  }
  if (m.role === "custom" && m.display) { const w = el("div", "msg asst"); w.append(el("div", "md", md(textOf(m.content)))); return w; }
  return null;
}
function applyToolResult(m) {
  const card = S.cards.get(m.toolCallId);
  if (card) card.setResult({ content: m.content, details: m.details }, m.isError);
}
function renderAll() {
  const box = $("messages");
  box.innerHTML = ""; S.cards.clear(); S.cur = null;
  for (const m of S.msgs) {
    if (m.role === "user") box.append(renderUser(m));
    else if (m.role === "assistant") box.append(renderAssistant(m).el);
    else if (m.role === "toolResult") applyToolResult(m);
    else { const n = renderOther(m); if (n) box.append(n); }
  }
  updateEmpty();
  scrollBottom(true);
}
function greeting() {
  const h = new Date().getHours();
  return h < 5 ? "Late one. What's up?" : h < 12 ? "Morning. What are we building?" : h < 18 ? "What are we working on?" : "Evening. What's next?";
}
function updateEmpty() {
  const empty = !S.msgs.some((m) => m.role === "user" || m.role === "assistant") && !S.cur;
  $("empty").hidden = !empty;
  if (empty) {
    const cwd = S.cwd || newChatCwd();
    $("empty-mark").innerHTML = badge(cwd);
    $("empty-title").textContent = greeting();
    $("empty-sub").textContent = tilde(cwd);
    $("project-chip-badge").outerHTML = `<span id="project-chip-badge" class="badge sm" style="--h:${hue(cwd)}">${esc(initials(projectName(cwd)))}</span>`;
    $("project-chip-name").textContent = projectName(cwd);
    $("project-chip").disabled = !!S.key;
    $("project-chip").style.opacity = S.key ? ".6" : "";
  }
}

// ---------------------------------------------------------------- live events
let rafPending = false;
function scheduleCurRender() {
  if (rafPending) return; rafPending = true;
  requestAnimationFrame(() => {
    rafPending = false;
    const c = S.cur; if (!c) return;
    c.msg.content.forEach((b, i) => {
      if (!b) return;
      if (!c.blocks[i]) { const n = makeBlock(b, true); c.blocks[i] = n; if (n) placeBlock(c.el, n); }
      else if (b.type !== "toolCall") fillBlock(c.blocks[i], b, b._live);
    });
    scrollBottom();
  });
}
function onMessageStart(m) {
  if (m.role === "system") return;
  if (m.role === "assistant") {
    const msg = { ...m, content: [] };
    const r = renderAssistant(msg, true);
    r.el.classList.add("enter");
    S.cur = { msg, el: r.el, blocks: [] };
    $("messages").append(r.el);
  } else if (m.role === "user") {
    S.msgs.push(m);
    const n = renderUser(m); n.classList.add("enter"); $("messages").append(n);
    if (!S.state?.sessionName) updateHeader();
  } else if (m.role === "toolResult") {
    // handled on message_end
  }
  updateEmpty(); scrollBottom(m.role === "user");
}
function onMessageUpdate(ev) {
  const e = ev.assistantMessageEvent || {};
  if (!S.cur) onMessageStart({ role: "assistant", content: [] });
  const c = S.cur.msg.content; const i = e.contentIndex;
  switch (e.type) {
    case "text_start": c[i] = { type: "text", text: "", _live: true }; break;
    case "text_delta": (c[i] ||= { type: "text", text: "", _live: true }).text += e.delta; break;
    case "text_end": c[i] = { type: "text", text: e.content ?? c[i]?.text ?? "" }; break;
    case "thinking_start": c[i] = { type: "thinking", thinking: "", _live: true, _t0: Date.now() }; break;
    case "thinking_delta": (c[i] ||= { type: "thinking", thinking: "", _live: true, _t0: Date.now() }).thinking += e.delta; break;
    case "thinking_end": { const t0 = c[i]?._t0; c[i] = { type: "thinking", thinking: e.content ?? c[i]?.thinking ?? "", _secs: t0 ? Math.max(1, Math.round((Date.now() - t0) / 1000)) : 0 }; break; }
    case "toolcall_start": c[i] = { type: "toolCall", id: e.id, name: e.toolName, arguments: {} }; break;
    case "toolcall_end": if (e.toolCall) { c[i] = e.toolCall; const card = S.cards.get(e.toolCall.id); if (card) card.setCall(e.toolCall); } break;
    default: return;
  }
  setWorking(e.type.startsWith("thinking") ? "Thinking" : e.type.startsWith("toolcall") ? "Preparing tool call" : "Writing");
  scheduleCurRender();
}
function onMessageEnd(m) {
  if (m.role === "assistant") {
    const c = S.cur;
    // keep measured thinking durations
    if (c) (m.content || []).forEach((b, i) => { if (b.type === "thinking" && c.msg.content[i]?._secs) b._secs = c.msg.content[i]._secs; });
    S.msgs.push(m);
    if (c) {
      const fresh = renderAssistant(m);
      // keep open/closed state of details elements
      c.el.replaceWith(fresh.el);
      fresh.el.classList.add("enter");
    } else $("messages").append(renderAssistant(m).el);
    S.cur = null;
    scrollBottom();
  } else if (m.role === "toolResult") {
    S.msgs.push(m); applyToolResult(m);
  } else if (m.role !== "user" && m.role !== "system") {
    S.msgs.push(m); const n = renderOther(m); if (n) $("messages").append(n);
  }
  updateEmpty();
}
function setWorking(text) { if (!S.streaming) return; $("working").hidden = false; $("working-text").textContent = text; }
function setStreaming(on) {
  S.streaming = on;
  document.body.classList.toggle("streaming", on);
  $("working").hidden = !on;
  if (on) $("working-text").textContent = "Working";
  updateSend();
}
function renderQueue(steering = [], followUp = []) {
  const q = $("queue"); q.innerHTML = "";
  for (const t of steering) q.append(el("div", "qitem", `<b>next</b>${esc(t)}`));
  for (const t of followUp) q.append(el("div", "qitem", `<b>after</b>${esc(t)}`));
  q.hidden = !(steering.length + followUp.length);
}

function onEvent(ev) {
  switch (ev.type) {
    case "pocketpi_hello": return loadSnapshot();
    case "pocketpi_resync": loadSnapshot(); break;
    case "pocketpi_exit": {
      setStreaming(false);
      const tail = (ev.stderr || []).slice(-8).join("\n");
      S.key = null;
      if (tail) banner(`pi stopped.<pre>${esc(tail)}</pre>`, true);
      break;
    }
    case "agent_start": setStreaming(true); break;
    case "agent_settled": setStreaming(false); afterRun(); break;
    case "message_start": onMessageStart(ev.message); break;
    case "message_update": onMessageUpdate(ev); break;
    case "message_end": onMessageEnd(ev.message); break;
    case "tool_execution_start": { const c = S.cards.get(ev.toolCallId); if (c) c.setState("run"); setWorking(`Running ${ev.toolName}`); break; }
    case "tool_execution_update": { const c = S.cards.get(ev.toolCallId); if (c) c.setPartial(ev.partialResult); break; }
    case "tool_execution_end": { const c = S.cards.get(ev.toolCallId); if (c) c.setResult(ev.result, ev.isError, ev.durationMs); setWorking("Working"); break; }
    case "queue_update": renderQueue(ev.steering, ev.followUp); break;
    case "compaction_start": setWorking("Compacting context"); break;
    case "compaction_end":
      if (ev.result) { $("messages").append(el("div", "note", `Context compacted · ${fmtTokens(ev.result.tokensBefore)} → ${fmtTokens(ev.result.estimatedTokensAfter)}`)); refreshStats(); }
      else if (ev.errorMessage) toast("Compaction failed: " + ev.errorMessage, true);
      break;
    case "auto_retry_start": setWorking(`Retrying ${ev.attempt}/${ev.maxAttempts} · ${ev.errorMessage || ""}`); break;
    case "auto_retry_end": if (!ev.success) $("messages").append(el("div", "msg", `<div class="errbox">${esc(ev.finalError || "Retries failed")}</div>`)); break;
    case "thinking_level_changed": if (S.state) S.state.thinkingLevel = ev.level; updateChips(); break;
    case "session_info_changed": if (S.state) S.state.sessionName = ev.name; updateHeader(); break;
    case "extension_ui_request": extensionUI(ev); break;
    case "extension_error": toast(`Extension error: ${ev.error}`, true); break;
  }
}

async function afterRun() {
  refreshStats();
  if (!S.path) {
    try { const st = await cmd({ type: "get_state" }); S.state = st; if (st.sessionFile) setPath(st.sessionFile); } catch {}
  }
  loadProjects();
}

// ---------------------------------------------------------------- connection
function setPath(p) {
  S.path = p;
  const url = new URL(location.href);
  if (p) url.searchParams.set("s", p); else url.searchParams.delete("s");
  history.replaceState(null, "", url);
  if (p) localStorage.setItem("pp.last", p);
}
function disconnect() {
  if (S.es) { S.es.onerror = null; S.es.onmessage = null; S.es.close(); S.es = null; }
  clearTimeout(S.reconnectTimer);
}
function connect() {
  disconnect();
  return new Promise((resolve) => {
    const es = new EventSource(`/api/s/${S.key}/events`);
    S.es = es;
    let first = true;
    es.onmessage = (e) => {
      let ev; try { ev = JSON.parse(e.data); } catch { return; }
      if (first) { first = false; banner(null); Promise.resolve(onEvent(ev)).finally(resolve); return; }
      onEvent(ev);
    };
    es.onerror = () => {
      if (S.es !== es) return;
      es.close(); S.es = null;
      if (first) resolve();
      banner("Reconnecting…");
      S.reconnectTimer = setTimeout(() => reopen().catch(() => {}), 1500);
    };
  });
}
async function reopen() {
  if (S.connecting) return S.connecting;
  S.connecting = (async () => {
    try {
      if (S.path) {
        const r = await api("/api/open", { path: S.path });
        S.key = r.key; S.cwd = r.cwd;
      } else if (!S.key) throw new Error("This chat was never saved.");
      await connect();
    } catch (e) {
      banner(esc(e.message), true);
      if (e.status !== 404) S.reconnectTimer = setTimeout(() => reopen().catch(() => {}), 5000);
      throw e;
    } finally { S.connecting = null; }
  })();
  return S.connecting;
}
let snapshotSeq = 0;
async function loadSnapshot() {
  const seq = ++snapshotSeq;
  try {
    const [m, st] = await Promise.all([cmd({ type: "get_messages" }), cmd({ type: "get_state" })]);
    if (seq !== snapshotSeq) return;
    S.msgs = m.messages || []; S.state = st;
    if (st.sessionFile && !S.path && st.messageCount) setPath(st.sessionFile);
    setStreaming(!!st.isStreaming);
    renderAll();
    updateHeader(); updateChips();
    refreshStats(); loadLevels();
  } catch (e) { banner(esc(e.message), true); }
}
async function refreshStats() {
  try { S.stats = await cmd({ type: "get_session_stats" }); updateChips(); } catch {}
}
async function loadLevels() {
  try { S.levels = (await cmd({ type: "get_available_thinking_levels" })).levels || []; updateChips(); } catch {}
}

// ---------------------------------------------------------------- header + chips
function chatTitle() {
  if (S.state?.sessionName) return S.state.sessionName;
  const u = S.msgs.find((m) => m.role === "user");
  if (u) return textOf(u.content).split("\n")[0].slice(0, 80) || "Chat";
  const s = S.sessions.find((x) => x.path === S.path);
  return s?.name || s?.title || "New chat";
}
function updateHeader() {
  const cwd = S.cwd || newChatCwd();
  $("title").textContent = chatTitle();
  $("subtitle").textContent = projectName(cwd);
  $("project-badge").outerHTML = `<span id="project-badge" class="badge" style="--h:${hue(cwd)}">${esc(initials(projectName(cwd)))}</span>`;
  document.title = `${chatTitle()} · pocketpi`;
}
function modelLabel(m) { return m ? (m.id || m.name || "").replace(/^.*\//, "") : "no model"; }
function updateChips() {
  $("model-name").textContent = S.state?.model ? modelLabel(S.state.model) : S.key ? "…" : "model";
  const ring = $("ctx-ring"); const cu = S.stats?.contextUsage;
  const p = cu && cu.percent != null ? cu.percent : 0;
  ring.style.setProperty("--p", Math.min(100, p));
  ring.className = "ctx-ring" + (p > 85 ? " hot" : p > 65 ? " warn" : "");
  const lvl = S.state?.thinkingLevel;
  $("think-chip").textContent = S.state?.model?.reasoning && lvl ? lvl : "";
}

// ---------------------------------------------------------------- composer
const input = $("input");
function autosize() { input.style.height = "auto"; input.style.height = Math.min(input.scrollHeight, innerHeight * 0.38) + "px"; }
function updateSend() {
  const has = input.value.trim() || S.attachments.length;
  const btn = $("send");
  btn.classList.toggle("stop", S.streaming && !has);
  btn.disabled = !has && !S.streaming;
  btn.setAttribute("aria-label", S.streaming && !has ? "Stop" : S.streaming ? "Steer" : "Send");
  input.placeholder = S.streaming ? "Steer pi while it works…" : S.key || S.path ? "Reply to pi" : `Message pi in ${projectName(newChatCwd())}`;
}
input.addEventListener("input", () => { autosize(); updateSend(); updateSlash(); });
input.addEventListener("keydown", (e) => {
  if (e.key === "Enter" && !e.shiftKey && fine && !e.isComposing) { e.preventDefault(); send(); }
  if (e.key === "Escape" && S.streaming) stop();
});
$("composer").addEventListener("submit", (e) => { e.preventDefault(); send(); });

async function send() {
  const text = input.value.trim();
  const imgs = S.attachments;
  if (!text && !imgs.length) { if (S.streaming) stop(); return; }
  $("send").disabled = true;
  try {
    if (!S.key && S.path) await reopen();
    if (!S.key) {
      const r = await api("/api/new", { cwd: newChatCwd() });
      S.key = r.key; S.cwd = r.cwd; S.msgs = [];
      await connect();
    }
    const c = { type: "prompt", message: text };
    if (imgs.length) c.images = imgs.map((a) => ({ type: "image", data: a.data, mimeType: a.mime }));
    if (S.streaming) c.streamingBehavior = "steer";
    input.value = ""; S.attachments = []; renderAttachments(); autosize(); $("slash").hidden = true;
    S.stick = true;
    const r = await cmd(c);
    if (r && r.disposition === "handled") { refreshStats(); loadSnapshot(); }
  } catch (e) {
    if (!input.value) input.value = text;
    autosize(); toast(e.message, true);
  } finally { updateSend(); }
}
async function stop() {
  try {
    const q = await cmd({ type: "clear_queue" });
    const back = [...(q?.steering || []), ...(q?.followUp || [])].join("\n");
    if (back && !input.value.trim()) { input.value = back; autosize(); }
    await cmd({ type: "abort" });
  } catch (e) { toast(e.message, true); }
  updateSend();
}

// image attachments, downscaled on the phone before upload
$("file").addEventListener("change", async (e) => {
  for (const f of e.target.files) {
    try { S.attachments.push(await shrink(f)); } catch { toast(`Couldn't read ${f.name}`, true); }
  }
  e.target.value = ""; renderAttachments(); updateSend();
});
function shrink(file) {
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(file); const img = new Image();
    img.onload = () => {
      const max = 1600; const k = Math.min(1, max / Math.max(img.width, img.height));
      const c = document.createElement("canvas"); c.width = Math.round(img.width * k); c.height = Math.round(img.height * k);
      c.getContext("2d").drawImage(img, 0, 0, c.width, c.height); URL.revokeObjectURL(url);
      const dataUrl = c.toDataURL("image/jpeg", 0.85);
      resolve({ url: dataUrl, data: dataUrl.split(",")[1], mime: "image/jpeg" });
    };
    img.onerror = reject; img.src = url;
  });
}
function renderAttachments() {
  const box = $("attachments"); box.innerHTML = "";
  S.attachments.forEach((a, i) => {
    const t = el("div", "thumb"); const img = el("img"); img.src = a.url;
    const x = el("button", "", ICON.x); x.type = "button"; x.onclick = () => { S.attachments.splice(i, 1); renderAttachments(); updateSend(); };
    t.append(img, x); box.append(t);
  });
  box.hidden = !S.attachments.length;
}

// slash commands (prompt templates, skills, extension commands)
async function updateSlash() {
  const v = input.value; const box = $("slash");
  if (!/^\/\S*$/.test(v) || !S.key) { box.hidden = true; return; }
  if (!S.commands) { try { S.commands = (await cmd({ type: "get_commands" })).commands || []; } catch { S.commands = []; } }
  const q = v.slice(1).toLowerCase();
  const hits = S.commands.filter((c) => c.name.toLowerCase().includes(q)).slice(0, 30);
  box.innerHTML = "";
  for (const c of hits) {
    const b = el("button", "slash-item", `<b>/${esc(c.name)}</b>${c.description ? `<div>${esc(c.description)}</div>` : ""}`);
    b.type = "button"; b.onclick = () => { input.value = `/${c.name} `; box.hidden = true; input.focus(); updateSend(); };
    box.append(b);
  }
  box.hidden = !hits.length;
}
$("think-chip").addEventListener("click", async () => {
  const levels = S.levels.length ? S.levels : ["off", "low", "medium", "high"];
  const i = levels.indexOf(S.state?.thinkingLevel);
  const next = levels[(i + 1) % levels.length];
  try { await cmd({ type: "set_thinking_level", level: next }); S.state.thinkingLevel = next; updateChips(); } catch (e) { toast(e.message, true); }
});

// ---------------------------------------------------------------- scrolling
const scroller = $("scroller");
function nearBottom() { return scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 90; }
function scrollBottom(force) { if (force || S.stick) { scroller.scrollTop = scroller.scrollHeight; $("jump").hidden = true; } }
scroller.addEventListener("scroll", () => {
  S.stick = nearBottom();
  $("jump").hidden = S.stick;
  $("topbar").classList.toggle("scrolled", scroller.scrollTop > 4);
}, { passive: true });
$("jump").onclick = () => { S.stick = true; scroller.scrollTo({ top: scroller.scrollHeight, behavior: "smooth" }); };
new ResizeObserver(() => document.documentElement.style.setProperty("--composer-h", $("composer-wrap").offsetHeight + "px")).observe($("composer-wrap"));
document.addEventListener("click", (e) => {
  const b = e.target.closest("[data-copy]");
  if (b) { const pre = b.closest(".codeblock")?.querySelector("pre"); if (pre) copyText(pre.textContent, b); }
});

// iOS: keep the layout inside the visual viewport when the keyboard opens
if (window.visualViewport) {
  const vv = window.visualViewport; const app = $("app");
  const fit = () => { app.style.height = vv.height + "px"; app.style.transform = `translateY(${vv.offsetTop}px)`; if (S.stick) scrollBottom(); };
  vv.addEventListener("resize", fit); vv.addEventListener("scroll", fit); fit();
}

// ---------------------------------------------------------------- sheets
function openSheet(build) {
  const body = $("sheet-body"); body.innerHTML = ""; build(body);
  document.body.classList.add("sheet-open");
}
function closeSheet() { document.body.classList.remove("sheet-open"); if (pendingUI) { respondUI(pendingUI, { cancelled: true }); } }
$("sheet-scrim").onclick = closeSheet;
function opt(icon, title, sub, onClick, extra = "") {
  const b = el("button", "opt" + extra, `${icon || ""}<div class="o-main"><div class="o-t">${title}</div>${sub ? `<div class="o-s">${sub}</div>` : ""}</div>`);
  b.onclick = onClick; return b;
}

async function openChatSheet() {
  if (!S.key && !S.path) return openNewChatSettings();
  if (!S.key) await reopen().catch(() => {});
  openSheet((b) => {
    b.append(el("div", "sheet-title", esc(chatTitle())), el("div", "sheet-sub", esc(tilde(S.cwd))));
    const st = S.stats; const cu = st?.contextUsage;
    const stats = el("div", "stats");
    stats.innerHTML = `<div class="stat"><div class="v">${cu?.percent != null ? Math.round(cu.percent) + "%" : "–"}</div><div class="l">context${cu ? " of " + fmtTokens(cu.contextWindow) : ""}</div></div>
      <div class="stat"><div class="v">${fmtTokens(st?.tokens?.total)}</div><div class="l">tokens</div></div>
      <div class="stat"><div class="v">${fmtCost(st?.cost)}</div><div class="l">cost</div></div>`;
    b.append(stats);
    if (S.state?.model?.reasoning && S.levels.length > 1) {
      b.append(el("div", "sheet-section", "Thinking"));
      const seg = el("div", "seg");
      for (const l of S.levels) {
        const btn = el("button", l === S.state.thinkingLevel ? "on" : "", esc(l));
        btn.onclick = async () => { try { await cmd({ type: "set_thinking_level", level: l }); S.state.thinkingLevel = l; updateChips(); seg.querySelectorAll("button").forEach((x) => x.classList.toggle("on", x === btn)); } catch (e) { toast(e.message, true); } };
        seg.append(btn);
      }
      b.append(seg);
    }
    b.append(el("div", "sheet-section", "Model"));
    b.append(opt(ICON.chip, `<span class="mono">${esc(modelLabel(S.state?.model))}</span>`, esc(S.state?.model?.provider || ""), () => openModelSheet()));
    b.append(el("div", "sheet-section", "Chat"));
    b.append(opt(ICON.rename, "Rename", null, () => renameChat()));
    b.append(opt(ICON.compact, "Compact context", "Summarize older messages to free up context", async () => {
      closeSheet(); setStreaming(true); setWorking("Compacting context");
      try { await cmd({ type: "compact" }); await loadSnapshot(); toast("Context compacted"); } catch (e) { toast(e.message, true); } finally { setStreaming(false); }
    }));
    b.append(opt(ICON.power, "Stop pi process", "Frees memory; reopening the chat restarts it", async () => {
      closeSheet(); try { await api(`/api/s/${S.key}/close`, {}); toast("Stopped"); } catch (e) { toast(e.message, true); }
    }, " danger"));
  });
}
async function openModelSheet() {
  openSheet((b) => b.append(el("div", "sheet-title", "Model"), el("div", "sheet-sub", "Loading…")));
  try { S.models = (await cmd({ type: "get_available_models" })).models || []; } catch (e) { toast(e.message, true); return closeSheet(); }
  openSheet((b) => {
    b.append(el("div", "sheet-title", "Model"));
    const f = el("div", "field model-search"); const q = el("input"); q.type = "search"; q.placeholder = "Filter models"; f.append(q); b.append(f);
    const list = el("div"); b.append(list);
    const cur = S.state?.model;
    const draw = () => {
      list.innerHTML = ""; const term = q.value.toLowerCase(); let lastProv = null;
      const sorted = [...S.models].sort((a, z) => a.provider.localeCompare(z.provider) || a.id.localeCompare(z.id));
      for (const m of sorted) {
        if (term && !(`${m.provider}/${m.id} ${m.name || ""}`.toLowerCase().includes(term))) continue;
        if (m.provider !== lastProv) { list.append(el("div", "provider-label", esc(m.provider))); lastProv = m.provider; }
        const on = cur && cur.id === m.id && cur.provider === m.provider;
        const o = opt("", `<span class="mono">${esc(m.id)}</span>`, `${fmtTokens(m.contextWindow)} ctx${m.reasoning ? " · reasoning" : ""}${m.input?.includes("image") ? " · vision" : ""}`, async () => {
          try { const r = await cmd({ type: "set_model", provider: m.provider, modelId: m.id }); S.state.model = r; S.commands = null; await loadLevels(); const st = await cmd({ type: "get_state" }); S.state = st; updateChips(); refreshStats(); closeSheet(); toast(`Switched to ${m.id}`); } catch (e) { toast(e.message, true); }
        });
        if (on) o.append(el("span", "check", ICON.check));
        list.append(o);
      }
      if (!list.children.length) list.append(el("div", "list-empty", "No models match. Is your API key set up in pi?"));
    };
    q.oninput = draw; draw();
  });
}
function openNewChatSettings() {
  openSheet((b) => {
    b.append(el("div", "sheet-title", "New chat"), el("div", "sheet-sub", "Model and thinking can be changed after the chat starts. pi's defaults from settings.json apply."));
    b.append(opt(ICON.folder, "Project", esc(projectName(newChatCwd())), () => openProjectPicker()));
  });
}
function renameChat() {
  openSheet((b) => {
    b.append(el("div", "sheet-title", "Rename chat"));
    const f = el("div", "field"); const i = el("input"); i.value = S.state?.sessionName || chatTitle(); f.append(i); b.append(f);
    const row = el("div", "btn-row"); const ok = el("button", "btn", "Save"); row.append(ok); b.append(row);
    const save = async () => { try { await cmd({ type: "set_session_name", name: i.value.trim() }); S.state.sessionName = i.value.trim(); updateHeader(); closeSheet(); loadSessions(); } catch (e) { toast(e.message, true); } };
    ok.onclick = save; i.onkeydown = (e) => { if (e.key === "Enter") save(); };
    setTimeout(() => i.select(), 300);
  });
}
$("model-chip").onclick = openChatSheet;

// ---------------------------------------------------------------- extension UI dialogs
let pendingUI = null;
function respondUI(id, payload) { pendingUI = null; cmd({ type: "extension_ui_response", id, ...payload }).catch(() => {}); }
function extensionUI(ev) {
  const m = ev.method;
  if (m === "notify") return toast(ev.message, ev.notifyType === "error");
  if (m === "set_editor_text") { input.value = ev.text || ""; autosize(); updateSend(); return; }
  if (!["confirm", "select", "input", "editor"].includes(m)) return;
  pendingUI = ev.id;
  openSheet((b) => {
    b.append(el("div", "sheet-title", esc(ev.title || "pi needs input")));
    if (ev.message) b.append(el("div", "sheet-msg", esc(ev.message)));
    const finish = (payload) => { const id = pendingUI; pendingUI = null; document.body.classList.remove("sheet-open"); if (id) respondUI(id, payload); };
    if (m === "confirm") {
      const row = el("div", "btn-row"); const no = el("button", "btn secondary", "Cancel"); const yes = el("button", "btn", "Confirm");
      no.onclick = () => finish({ confirmed: false }); yes.onclick = () => finish({ confirmed: true }); row.append(no, yes); b.append(row);
    } else if (m === "select") {
      for (const o of ev.options || []) b.append(opt("", esc(o), null, () => finish({ value: o })));
    } else {
      const f = el("div", "field"); const i = el(m === "editor" ? "textarea" : "input"); i.value = ev.prefill || ""; if (ev.placeholder) i.placeholder = ev.placeholder; f.append(i); b.append(f);
      const row = el("div", "btn-row"); const no = el("button", "btn secondary", "Cancel"); const yes = el("button", "btn", "Submit");
      no.onclick = () => finish({ cancelled: true }); yes.onclick = () => finish({ value: i.value }); row.append(no, yes); b.append(row);
    }
  });
}

// ---------------------------------------------------------------- projects + drawer
function newChatCwd() { return S.project || localStorage.getItem("pp.lastCwd") || S.home || "~"; }
async function loadProjects() {
  try {
    const [sp, ss] = await Promise.all([api("/api/projects"), api("/api/sessions")]);
    S.projects = sp.projects; S.home = sp.home; S.sessions = ss.sessions;
    renderDrawer(); updateHeader(); updateEmpty(); updateSend();
  } catch (e) { console.warn(e); }
}
const loadSessions = loadProjects;
function renderDrawer() {
  const rail = $("rail-projects"); rail.innerHTML = "";
  document.querySelector(".rail-all").classList.toggle("active", !S.project);
  for (const sp of S.projects) {
    const t = el("button", "rail-tile" + (sp.path === S.project ? " active" : "") + (sp.live ? " has-live" : "") + (sp.streaming ? " busy" : ""));
    t.title = `${sp.name} — ${tilde(sp.path)}`;
    t.innerHTML = `<span class="badge" style="--h:${hue(sp.path)}">${esc(initials(sp.name))}</span>`;
    t.onclick = () => selectProject(sp.path);
    rail.append(t);
  }
  const sp = projectFor(S.project);
  $("panel-title").textContent = S.project ? (sp?.name || base(S.project)) : "All chats";
  $("panel-path").textContent = S.project ? tilde(S.project) : `${plural(S.sessions.length, "chat")} · ${plural(S.projects.length, "project")}`;
  $("project-menu").hidden = !S.project;
  $("new-chat").querySelector("span").textContent = S.project ? `New chat in ${sp?.name || base(S.project)}` : "New chat";
  renderSessionList();
}
function renderSessionList() {
  const box = $("session-list"); box.innerHTML = "";
  const term = $("search").value.trim().toLowerCase();
  const list = S.sessions.filter((s) => (!S.project || s.cwd === S.project) && (!term || `${s.name || ""} ${s.title} ${s.cwd}`.toLowerCase().includes(term)));
  if (!list.length) { box.append(el("div", "list-empty", term ? "No chats match." : S.projects.length ? "No chats here yet." : "No chats yet. Tap + on the left to add a project folder, or just start a new chat.")); return; }
  const day = 86400000; const today = new Date(); today.setHours(0, 0, 0, 0); const t0 = today.getTime();
  const bucket = (ms) => ms >= t0 ? "Today" : ms >= t0 - day ? "Yesterday" : ms >= t0 - 6 * day ? "This week" : ms >= t0 - 29 * day ? "This month" : "Older";
  let last = null;
  for (const s of list) {
    const g = bucket(s.modified);
    if (g !== last) { box.append(el("div", "group-label", g)); last = g; }
    const b = el("button", "sess" + (s.path === S.path ? " active" : ""));
    b.innerHTML = `${S.project ? "" : badge(s.cwd, "badge sm")}<div class="sess-main"><div class="t">${s.live ? `<i class="live-dot${s.streaming ? " busy" : ""}"></i>` : ""}<span>${esc(s.name || s.title || "Untitled")}</span></div><div class="m">${S.project ? "" : esc(projectName(s.cwd)) + " · "}${ago(s.modified)} · ${s.messages} msgs</div></div>`;
    b.onclick = () => openSession(s.path);
    box.append(b);
  }
}
$("search").addEventListener("input", renderSessionList);
function selectProject(path) {
  S.project = path; localStorage.setItem("pp.project", path);
  if (path) localStorage.setItem("pp.lastCwd", path);
  renderDrawer();
  if (!S.key && !S.path) { updateEmpty(); updateHeader(); updateSend(); }
}
document.querySelector(".rail-all").onclick = () => selectProject("");
function openDrawer() { document.body.classList.add("drawer-open"); loadProjects(); }
function closeDrawer() { document.body.classList.remove("drawer-open"); }
$("menu").onclick = openDrawer; $("title-btn").onclick = openDrawer; $("scrim").onclick = closeDrawer;
$("new-chat").onclick = () => { newChat(); closeDrawer(); };
$("project-chip").onclick = () => openProjectPicker();
$("add-project").onclick = () => openProjectPicker(true);
$("project-menu").onclick = () => {
  const sp = projectFor(S.project); if (!sp) return;
  openSheet((b) => {
    b.append(el("div", "sheet-title", esc(sp.name)), el("div", "sheet-sub", esc(tilde(sp.path))));
    b.append(opt(ICON.rename, sp.pinned ? "Rename project" : "Pin and rename", null, () => renameProject(sp)));
    if (!sp.pinned) b.append(opt(ICON.pin, "Pin to rail", "Keeps it in place even with no recent chats", async () => { await api("/api/projects/save", { path: sp.path }); closeSheet(); loadProjects(); }));
    b.append(opt(ICON.hide, sp.pinned ? "Unpin and hide" : "Hide project", "Chats stay on disk; adding the folder again brings it back", async () => {
      await api("/api/projects/hide", { path: sp.path }); closeSheet(); selectProject(""); loadProjects();
    }, " danger"));
  });
};
function renameProject(sp) {
  openSheet((b) => {
    b.append(el("div", "sheet-title", "Project name"), el("div", "sheet-sub", esc(tilde(sp.path))));
    const f = el("div", "field"); const i = el("input"); i.value = sp.name; f.append(i); b.append(f);
    const row = el("div", "btn-row"); const ok = el("button", "btn", "Save"); row.append(ok); b.append(row);
    const save = async () => { try { await api("/api/projects/save", { path: sp.path, name: i.value }); closeSheet(); loadProjects(); } catch (e) { toast(e.message, true); } };
    ok.onclick = save; i.onkeydown = (e) => { if (e.key === "Enter") save(); };
  });
}
async function openProjectPicker(adding = false) {
  let dirs = [];
  try { dirs = (await api("/api/dirs")).dirs; } catch {}
  openSheet((b) => {
    b.append(el("div", "sheet-title", adding ? "Add a project" : "Choose a project"), el("div", "sheet-sub", "Pick a folder. pi runs this project's chats there."));
    const f = el("div", "field"); const i = el("input"); i.placeholder = "~/projects/something"; i.autocapitalize = "off"; i.spellcheck = false; f.append(i);
    const go = el("button", "btn", "Use"); f.append(go); b.append(f);
    const pick = async (path, pin) => {
      try {
        let p = path;
        if (pin) p = (await api("/api/projects/save", { path })).path;
        else if (!S.projects.some((s) => s.path === path)) p = (await api("/api/projects/save", { path })).path;
        closeSheet(); await loadProjects(); selectProject(p);
        if (!S.key && !S.path) { updateEmpty(); updateHeader(); } else if (!adding) { newChat(); }
      } catch (e) { toast(e.message, true); }
    };
    go.onclick = () => i.value.trim() && pick(i.value.trim(), true);
    i.onkeydown = (e) => { if (e.key === "Enter" && i.value.trim()) pick(i.value.trim(), true); };
    if (S.projects.length && !adding) {
      b.append(el("div", "sheet-section", "Projects"));
      for (const sp of S.projects) b.append(opt(badge(sp.path), esc(sp.name), esc(tilde(sp.path)), () => pick(sp.path, false)));
    }
    const others = dirs.filter((d) => !S.projects.some((s) => s.path === d));
    if (others.length) {
      b.append(el("div", "sheet-section", "Folders"));
      const draw = () => {
        b.querySelectorAll(".dir-opt").forEach((n) => n.remove());
        const term = i.value.trim().toLowerCase();
        for (const d of others.filter((d) => !term || tilde(d).toLowerCase().includes(term)).slice(0, 60)) {
          const o = opt(ICON.folder, esc(base(d)), esc(tilde(d)), () => pick(d, true), " dir-opt"); b.append(o);
        }
      };
      i.oninput = draw; draw();
    }
  });
}

// ---------------------------------------------------------------- navigation
function resetChat() {
  disconnect();
  Object.assign(S, { key: null, path: null, cwd: null, state: null, stats: null, msgs: [], cur: null, commands: null, levels: [] });
  S.cards.clear(); setStreaming(false); renderQueue(); banner(null);
  $("messages").innerHTML = "";
}
function newChat() {
  resetChat(); setPath(null);
  updateEmpty(); updateHeader(); updateChips(); updateSend();
  $("model-name").textContent = "default";
  renderDrawer();
}
async function openSession(path) {
  closeDrawer();
  if (path === S.path && S.key) return;
  resetChat(); setPath(path);
  const s = S.sessions.find((x) => x.path === path);
  if (s) { S.cwd = s.cwd; }
  updateHeader(); $("empty").hidden = true;
  banner("Opening…");
  try { await reopen(); } catch {}
  renderDrawer();
}

document.addEventListener("visibilitychange", () => {
  if (document.visibilityState !== "visible") return;
  if (S.path || S.key) { if (!S.es || S.es.readyState !== 1) reopen().catch(() => {}); else loadSnapshot(); }
  loadProjects();
});

// ---------------------------------------------------------------- live updates
// The server's build id changes on every deploy; reload into the new version
// as soon as that won't throw away a draft or interrupt a stream.
let buildId = null;
async function checkBuild() {
  try {
    const { build } = await api("/api/version");
    if (buildId === null) { buildId = build; return; }
    if (build === buildId) return;
    const safe = !input.value.trim() && !S.attachments.length && !S.streaming && !document.body.classList.contains("sheet-open");
    if (safe) { location.reload(); return; }
    banner('pocketpi was updated. <button class="copy" id="reload-now">Reload</button>');
    $("reload-now").onclick = () => location.reload();
  } catch {}
}
setInterval(() => document.visibilityState === "visible" && checkBuild(), 4000);

// ---------------------------------------------------------------- boot
(async function boot() {
  checkBuild();
  await loadProjects();
  const p = new URL(location.href).searchParams.get("s");
  if (p) await openSession(p);
  else newChat();
  autosize(); updateSend();
})();
