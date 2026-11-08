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
  spark: '<svg viewBox="0 0 24 24"><path d="M12 3.5l1.9 5.1 5.1 1.9-5.1 1.9L12 17.5l-1.9-5.1L5 10.5l5.1-1.9z"/><path d="M18.5 15.5l.7 1.8 1.8.7-1.8.7-.7 1.8-.7-1.8-1.8-.7 1.8-.7z"/></svg>',
  bell: '<svg viewBox="0 0 24 24"><path d="M6 16V11a6 6 0 0 1 12 0v5l1.5 2h-15z"/><path d="M10 20.5a2.2 2.2 0 0 0 4 0"/></svg>',
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
// Long text is trimmed by lines (and chars) with a "Show all" button. On touch
// screens these blocks are not scroll boxes of their own (nested scrollers trap
// iOS swipes), so the trim is what keeps the chat readable. `fromEnd` keeps the
// last lines instead, which is where bash errors usually are.
const coarse = matchMedia("(pointer: coarse)").matches;
function truncBlock(text, limit = 6000, fromEnd = false) {
  const maxLines = coarse ? 40 : 200;
  const lines = text.split("\n");
  const wrap = el("div");
  const pre = el("pre");
  let shown = text;
  if (lines.length > maxLines) shown = (fromEnd ? lines.slice(-maxLines) : lines.slice(0, maxLines)).join("\n");
  if (shown.length > limit) shown = fromEnd ? shown.slice(-limit) : shown.slice(0, limit);
  const trimmed = shown.length < text.length;
  if (trimmed && fromEnd) wrap.append(el("div", "trim-note", `… ${lines.length > maxLines ? `${lines.length - maxLines} earlier lines` : "earlier output"} hidden`));
  pre.textContent = shown;
  wrap.append(pre);
  if (trimmed) {
    const more = el("button", "more", `Show all · ${plural(lines.length, "line")}`);
    more.onclick = (e) => { e.preventDefault(); pre.textContent = text; more.remove(); wrap.querySelector(".trim-note")?.remove(); };
    wrap.append(more);
  }
  return wrap;
}
function diffBlock(diff) {
  const lines = diff.split("\n");
  const max = coarse ? 120 : 600;
  const wrap = el("div");
  const pre = el("pre");
  const paint = (ls) => { pre.innerHTML = ls.map((l) => {
    const c = /^\+(?!\+\+)/.test(l) ? "d-add" : /^-(?!--)/.test(l) ? "d-del" : /^@@/.test(l) ? "d-hunk" : "";
    return c ? `<span class="${c}">${esc(l)}</span>` : esc(l);
  }).join("\n"); };
  paint(lines.slice(0, max));
  wrap.append(pre);
  if (lines.length > max) {
    const more = el("button", "more", `Show all · ${plural(lines.length, "line")}`);
    more.onclick = (e) => { e.preventDefault(); paint(lines); more.remove(); };
    wrap.append(more);
  }
  return wrap;
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
      const det = r && r.details;
      if (!isError && det && (api.name === "workflow_save" || api.name === "workflow_run") && !d.querySelector(".tool-link")) {
        const wid = det.workflow?.id || det.workflow_id, rid = det.run_id;
        if (wid || rid) {
          const link = el("button", "tool-link", rid ? "Open run →" : "Open workflow →");
          link.onclick = (e) => { e.preventDefault(); e.stopPropagation(); rid ? openRun(rid) : openWorkflow(wid); };
          d.append(link);
        }
      }
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
        if (text && !(diff && !api.isError && text.length < 200)) sec(api.isError ? "Error" : api.result ? "Output" : "Output so far", truncBlock(text, 6000, api.name === "bash"));
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
  collapseTurns();
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


// ---------------------------------------------------------------- activity groups
// Within each turn (everything after a user message), the tool calls,
// thinking and in-between narration that come before pi's latest text are
// folded into one "Ran 3 commands, read 2 files" row. Nodes are hidden with a
// class rather than moved, so live tool cards keep updating in place. Steps
// after the latest text (still running) stay visible.
S.openTurns = new Set();
const VERB = {
  bash: ["ran", "command"], read: ["read", "file"], edit: ["edited", "file"], write: ["wrote", "file"],
  grep: ["searched", "time"], find: ["searched", "time"], ls: ["listed", "folder"],
  web_search: ["searched the web", "time"], web_fetch: ["fetched", "page"],
};
function activityLabel(nodes) {
  const counts = new Map(); let thoughts = 0, failed = 0, other = 0;
  for (const n of nodes) {
    if (n.classList.contains("think")) thoughts++;
    const cards = n.classList.contains("tool") ? [n] : [...n.querySelectorAll(".tool")];
    for (const c of cards) {
      const name = c.querySelector(".tname")?.textContent || "tool";
      if (c.classList.contains("err")) failed++;
      const [verb, noun] = VERB[name] || ["used", "tool"];
      const k = `${verb}|${noun}`; counts.set(k, (counts.get(k) || 0) + 1);
    }
    if (n.classList.contains("md")) other++;
  }
  const parts = [...counts].map(([k, n]) => { const [verb, noun] = k.split("|"); return `${verb} ${n} ${noun}${n === 1 ? "" : "s"}`; });
  if (!parts.length && thoughts) parts.push(`thought ${thoughts === 1 ? "once" : thoughts + " times"}`);
  let label = parts.join(", ");
  label = label.charAt(0).toUpperCase() + label.slice(1);
  return { label, failed, tools: [...counts.values()].reduce((a, b) => a + b, 0) };
}
function collapseTurns() {
  const box = $("messages");
  const turns = [[]];
  for (const child of box.children) {
    if (child.classList.contains("user")) { turns.push([]); continue; }
    if (child.classList.contains("msg")) turns[turns.length - 1].push(child);
  }
  turns.forEach((wrappers, ti) => {
    const key = String(ti);
    const items = [];
    for (const w of wrappers) for (const n of w.children) {
      if (n.classList.contains("activity") || n.classList.contains("actions") || n.classList.contains("errbox")) continue;
      items.push(n);
    }
    let last = -1;
    items.forEach((n, i) => { if (n.classList.contains("md") && n.textContent.trim()) last = i; });
    const row0 = box.querySelector(`.activity[data-turn="${key}"]`);
    if (last <= 0) { if (row0) row0.remove(); items.forEach((n) => n.classList.remove("act-hidden")); return; }
    const pre = items.slice(0, last);
    const { label, failed, tools } = activityLabel(pre);
    if (!tools) { if (row0) row0.remove(); pre.forEach((n) => n.classList.remove("act-hidden")); return; }
    const open = S.openTurns.has(key);
    let row = row0;
    if (!row) {
      row = el("button", "activity");
      row.type = "button"; row.dataset.turn = key;
      row.onclick = () => {
        S.openTurns.has(key) ? S.openTurns.delete(key) : S.openTurns.add(key);
        collapseTurns();
      };
    }
    row.classList.toggle("open", open);
    row.innerHTML = `<span class="act-icon">${ICON.tool}</span><span class="act-label">${esc(label)}</span>${failed ? `<span class="act-failed">${failed} failed</span>` : ""}<svg class="act-chev" viewBox="0 0 24 24"><path d="M9 6l6 6-6 6"/></svg>`;
    if (pre[0].previousElementSibling !== row) pre[0].parentElement.insertBefore(row, pre[0]);
    pre.forEach((n) => n.classList.toggle("act-hidden", !open));
    items.slice(last).forEach((n) => n.classList.remove("act-hidden"));
    for (const w of wrappers) w.classList.toggle("hollow", ![...w.children].some((c) => !c.classList.contains("act-hidden")));
  });
}

// ---------------------------------------------------------------- live events
let rafPending = false;
let collapseNeeded = false;
function scheduleCurRender() {
  if (rafPending) return; rafPending = true;
  requestAnimationFrame(() => {
    rafPending = false;
    const c = S.cur; if (!c) return;
    c.msg.content.forEach((b, i) => {
      if (!b) return;
      if (!c.blocks[i]) {
        const n = makeBlock(b, true); c.blocks[i] = n;
        if (n) { placeBlock(c.el, n); if (b.type === "text") collapseNeeded = true; }
      }
      else if (b.type !== "toolCall") fillBlock(c.blocks[i], b, b._live);
    });
    // a new text block means the steps before it are done: fold them away
    if (collapseNeeded && c.blocks.some((n, i) => n && c.msg.content[i]?.type === "text" && (c.msg.content[i].text || "").trim())) { collapseNeeded = false; collapseTurns(); }
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
    clearSuggestions();
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
    collapseTurns();
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
    case "pocketpi_hello": resetExtUI(ev.ui); return loadSnapshot();
    case "pocketpi_resync": loadSnapshot(); break;
    case "pocketpi_exit": {
      setStreaming(false);
      const tail = (ev.stderr || []).slice(-8).join("\n");
      S.key = null; resetExtUI();
      if (tail) banner(`pi stopped.<pre>${esc(tail)}</pre>`, true);
      break;
    }
    case "agent_start": clearSuggestions(); setStreaming(true); break;
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
  maybeSuggest();
  if (!S.path) {
    try { const st = await cmd({ type: "get_state" }); S.state = st; if (st.sessionFile) setPath(st.sessionFile); } catch {}
  }
  loadProjects();
}

// ---------------------------------------------------------------- connection
function setPath(p) {
  S.path = p;
  const url = new URL(location.href);
  url.searchParams.delete("w"); url.searchParams.delete("r");
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
    maybeSuggest();
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
  $("subtitle").textContent = S.extUI?.title || projectName(cwd);
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
  $("use-ghost").hidden = !(S.ghost && !input.value && !S.streaming);
  input.placeholder = S.ghost && !S.streaming ? S.ghost : S.streaming ? "Steer pi while it works…" : S.key || S.path ? "Reply to pi" : `Message pi in ${projectName(newChatCwd())}`;
}
input.addEventListener("input", () => { autosize(); updateSend(); updateSlash(); });
input.addEventListener("keydown", (e) => {
  if (e.key === "Enter" && !e.shiftKey && fine && !e.isComposing) { e.preventDefault(); send(); }
  if (e.key === "Escape" && S.streaming) stop();
  if (e.key === "Tab" && !e.shiftKey && S.ghost && !input.value) { e.preventDefault(); acceptGhost(); }
});
$("composer").addEventListener("submit", (e) => { e.preventDefault(); send(); });

async function send() {
  const text = input.value.trim();
  const imgs = S.attachments;
  if (!text && !imgs.length) { if (S.streaming) stop(); return; }
  $("send").disabled = true;
  clearSuggestions();
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
  $("jump").hidden = S.stick || S.view !== "chat";
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
    const sugOn = suggestionsOn();
    const sug = opt(ICON.spark, "Suggested replies", sugOn ? "On · quick answers when pi asks you something" : "Off", () => {
      localStorage.setItem("pp.suggest", sugOn ? "0" : "1"); closeSheet();
      if (sugOn) clearSuggestions(); else maybeSuggest();
      toast(sugOn ? "Suggested replies off" : "Suggested replies on");
    });
    if (sugOn) sug.append(el("span", "check", ICON.check));
    b.append(sug);
    notificationOption(b);
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
    notificationOption(b);
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
  if (setExtUI(ev)) return;
  const m = ev.method;
  if (m === "notify") return toast(ev.message, ev.notifyType === "error");
  if (m === "set_editor_text") { input.value = ev.text || ""; autosize(); updateSend(); return; }
  if (!["confirm", "select", "input", "editor"].includes(m)) return;
  pendingUI = ev.id;
  openSheet((b) => {
    b.append(el("div", "sheet-title", esc(ev.title || "pi needs input")));
    if (ev.message) b.append(el("div", "sheet-msg", esc(ev.message)));
    dialogCountdown(b, ev);
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

// ---------------------------------------------------------------- extension UI: status, widgets, title
// setStatus / setWidget / setTitle are fire-and-forget and last as long as
// the pi does: pocketpi replays what's in effect in pocketpi_hello (`ui`),
// and a pi that exits takes it all with it.
S.extUI = { status: new Map(), widgets: new Map(), title: null };
// Extensions colour their text for the terminal: drop the escapes.
function stripAnsi(t) { return String(t ?? "").replace(/\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b\[[0-?]*[ -/]*[@-~]|\x1b./g, ""); }
function resetExtUI(replay = []) {
  S.extUI = { status: new Map(), widgets: new Map(), title: null };
  for (const r of replay || []) setExtUI(r, false);
  renderExtUI();
}
/** Apply one setStatus / setWidget / setTitle; false for any other method. */
function setExtUI(ev, render = true) {
  const u = S.extUI;
  if (ev.method === "setStatus") {
    if (ev.statusText == null) u.status.delete(ev.statusKey); else u.status.set(ev.statusKey, stripAnsi(ev.statusText));
  } else if (ev.method === "setWidget") {
    if (!Array.isArray(ev.widgetLines)) u.widgets.delete(ev.widgetKey);
    else u.widgets.set(ev.widgetKey, { lines: ev.widgetLines.map(stripAnsi), below: ev.widgetPlacement === "belowEditor" });
  } else if (ev.method === "setTitle") {
    u.title = stripAnsi(ev.title).trim() || null;
  } else return false;
  if (render) renderExtUI();
  return true;
}
function renderExtUI() {
  const u = S.extUI;
  const above = $("ext-above"), below = $("ext-below");
  above.innerHTML = ""; below.innerHTML = "";
  if (u.status.size) {
    const row = el("div", "ext-status");
    for (const [k, t] of u.status) { const c = el("span", "ext-chip", esc(t)); c.dataset.key = k; c.title = t; row.append(c); }
    above.append(row);
  }
  for (const [k, w] of u.widgets) {
    const box = el("pre", "ext-widget", esc(w.lines.join("\n"))); box.dataset.key = k;
    (w.below ? below : above).append(box);
  }
  above.hidden = !above.children.length; below.hidden = !below.children.length;
  if (S.view === "chat") updateHeader();
}
// A dialog with a timeout: pi answers it itself when the time is up, so the
// sheet counts down and then just closes, without answering.
let dialogTimer = null;
function dialogCountdown(b, ev) {
  clearInterval(dialogTimer); dialogTimer = null;
  if (!(ev.timeout > 0)) return;
  const end = Date.now() + ev.timeout, id = ev.id;
  const line = el("div", "sheet-countdown"); b.append(line);
  const tick = () => {
    const left = end - Date.now();
    if (pendingUI !== id) { clearInterval(dialogTimer); dialogTimer = null; return; }
    if (left <= 0) {
      clearInterval(dialogTimer); dialogTimer = null;
      pendingUI = null; document.body.classList.remove("sheet-open");
      return;
    }
    line.textContent = `Closes in ${Math.ceil(left / 1000)} s`;
  };
  tick(); dialogTimer = setInterval(tick, 250);
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
  const wfs = S.tab === "workflows";
  $("panel-title").textContent = S.project ? (sp?.name || base(S.project)) : wfs ? "All workflows" : "All chats";
  $("panel-path").textContent = S.project ? tilde(S.project) : wfs ? `${plural((S.workflows || []).length, "workflow")} · ${plural(S.projects.length, "project")}` : `${plural(S.sessions.length, "chat")} · ${plural(S.projects.length, "project")}`;
  $("project-menu").hidden = !S.project;
  const wfTab = S.tab === "workflows";
  $("new-chat").querySelector("span").textContent = wfTab
    ? (S.project ? `New workflow in ${sp?.name || base(S.project)}` : "New workflow")
    : (S.project ? `New chat in ${sp?.name || base(S.project)}` : "New chat");
  document.querySelectorAll("#panel-tabs button").forEach((b) => b.classList.toggle("on", b.dataset.tab === S.tab));
  $("search").placeholder = wfTab ? "Search workflows" : "Search";
  if (wfTab) renderWorkflowList(); else renderSessionList();
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
$("search").addEventListener("input", () => (S.tab === "workflows" ? renderWorkflowList() : renderSessionList()));
function selectProject(path) {
  S.project = path; localStorage.setItem("pp.project", path);
  if (path) localStorage.setItem("pp.lastCwd", path);
  renderDrawer();
  if (!S.key && !S.path) { updateEmpty(); updateHeader(); updateSend(); }
}
document.querySelector(".rail-all").onclick = () => selectProject("");
function openDrawer() { document.body.classList.add("drawer-open"); loadProjects(); loadWorkflows(); }
function closeDrawer() { document.body.classList.remove("drawer-open"); }
$("menu").onclick = openDrawer; $("title-btn").onclick = openDrawer; $("scrim").onclick = closeDrawer;
$("new-chat").onclick = () => {
  closeDrawer();
  if (S.tab === "workflows") return newWorkflowChat();
  newChat();
};
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
  disconnect(); clearSuggestions();
  Object.assign(S, { key: null, path: null, cwd: null, state: null, stats: null, msgs: [], cur: null, commands: null, levels: [] });
  S.cards.clear(); setStreaming(false); renderQueue(); resetExtUI(); banner(null);
  $("messages").innerHTML = "";
}
function newChat() {
  showView("chat");
  resetChat(); setPath(null);
  updateEmpty(); updateHeader(); updateChips(); updateSend();
  $("model-name").textContent = "default";
  renderDrawer();
}
async function openSession(path, returnTo = null) {
  closeDrawer();
  S.returnTo = returnTo;
  const wasChat = S.view === "chat";
  showView("chat");
  if (path === S.path && S.key && wasChat) return;
  resetChat(); setPath(path);
  const s = S.sessions.find((x) => x.path === path);
  if (s) { S.cwd = s.cwd; }
  updateHeader(); $("empty").hidden = true;
  banner("Opening…");
  try { await reopen(); } catch {}
  if (S.returnTo) banner(`Stage chat from a workflow run. <button class="copy" id="back-to-run">Back to run</button>`);
  const back = $("back-to-run"); if (back) back.onclick = () => openRun(S.returnTo);
  renderDrawer();
}

document.addEventListener("visibilitychange", () => {
  if (document.visibilityState !== "visible") return;
  if (S.path || S.key) { if (!S.es || S.es.readyState !== 1) reopen().catch(() => {}); else loadSnapshot(); }
  loadProjects();
});



// ---------------------------------------------------------------- notifications (web push)
// iOS only allows web push for apps added to the Home Screen (16.4+), and
// permission must be requested from a tap.
const isIOS = /iPhone|iPad|iPod/.test(navigator.userAgent);
const standalone = matchMedia("(display-mode: standalone)").matches || navigator.standalone === true;
if ("serviceWorker" in navigator) navigator.serviceWorker.register("/sw.js").catch(() => {});
async function pushState() {
  if (isIOS && !standalone) return "needs-homescreen";
  if (!("serviceWorker" in navigator) || !("PushManager" in window) || !("Notification" in window)) return "unsupported";
  if (Notification.permission === "denied") return "denied";
  try {
    const reg = await navigator.serviceWorker.ready;
    const sub = await reg.pushManager.getSubscription();
    if (!sub) return "off";
    const info = await api(`/api/push?endpoint=${encodeURIComponent(sub.endpoint)}`);
    return info.subscribed ? "on" : "off";
  } catch { return "off"; }
}
function b64ToBytes(b64) {
  const pad = "=".repeat((4 - (b64.length % 4)) % 4);
  const raw = atob((b64 + pad).replace(/-/g, "+").replace(/_/g, "/"));
  return Uint8Array.from(raw, (c) => c.charCodeAt(0));
}
async function enablePush() {
  const st = await pushState();
  if (st === "needs-homescreen") return toast("Add pocketpi to your Home Screen first (Share → Add to Home Screen), then turn notifications on there.");
  if (st === "unsupported") return toast("This browser can't do push notifications.", true);
  if (st === "denied") return toast("Notifications are blocked for pocketpi in Settings.", true);
  const perm = await Notification.requestPermission();
  if (perm !== "granted") return toast("Notifications not allowed", true);
  try {
    const reg = await navigator.serviceWorker.ready;
    const { key } = await api("/api/push");
    let sub = await reg.pushManager.getSubscription();
    if (!sub) sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: b64ToBytes(key) });
    const label = isIOS ? "iPhone" : /Android/.test(navigator.userAgent) ? "Android" : "Browser";
    await api("/api/push/subscribe", { subscription: sub.toJSON(), label });
    const t = await api("/api/push/test", {});
    toast(t.delivered ? "Notifications on. Sent a test." : "Subscribed, but the test didn't go through.", !t.delivered);
  } catch (e) { toast(`Couldn't turn on notifications: ${e.message}`, true); }
}
async function disablePush() {
  try {
    const reg = await navigator.serviceWorker.ready;
    const sub = await reg.pushManager.getSubscription();
    if (sub) { await api("/api/push/unsubscribe", { endpoint: sub.endpoint }); await sub.unsubscribe(); }
    toast("Notifications off");
  } catch (e) { toast(e.message, true); }
}
async function notificationOption(b) {
  const st = await pushState();
  const sub = { on: "On · approvals, finished runs, long replies", off: "Off", denied: "Blocked in iOS Settings", unsupported: "Not supported in this browser", "needs-homescreen": "Add to Home Screen first" }[st];
  const o = opt(ICON.bell, "Notifications", sub, () => { closeSheet(); st === "on" ? disablePush() : enablePush(); });
  if (st === "on") {
    o.append(el("span", "check", ICON.check));
    const t = el("button", "copy", "Send test"); t.onclick = async (e) => { e.stopPropagation(); const r = await api("/api/push/test", {}); toast(r.delivered ? "Test sent" : "Test failed", !r.delivered); };
    o.append(t);
  }
  b.append(o);
}

// ---------------------------------------------------------------- workflows
// Views: "chat" (default), "workflow" (one workflow), "run" (one run). The
// workflow views render into #wfview and hide the composer.
S.tab = localStorage.getItem("pp.tab") || "chats";
S.view = "chat";
S.workflows = [];
S.wf = null;       // { workflow, errors, runs } for the open workflow
S.run = null;      // open run
S.runsEs = null;
const ICON_STAGE = {
  agent: '<svg viewBox="0 0 24 24"><path d="M12 3.5l1.9 5.1 5.1 1.9-5.1 1.9L12 17.5l-1.9-5.1L5 10.5l5.1-1.9z"/></svg>',
  shell: '<svg viewBox="0 0 24 24"><path d="M5 7l5 5-5 5M12 17h7"/></svg>',
  review: '<svg viewBox="0 0 24 24"><path d="M2.5 12s3.5-6.5 9.5-6.5 9.5 6.5 9.5 6.5-3.5 6.5-9.5 6.5S2.5 12 2.5 12z"/><circle cx="12" cy="12" r="2.8"/></svg>',
  approval: '<svg viewBox="0 0 24 24"><path d="M12 3l7.5 3v5.5c0 4.5-3.2 8.2-7.5 9.5-4.3-1.3-7.5-5-7.5-9.5V6z"/><path d="M8.5 12l2.5 2.5 4.5-5"/></svg>',
};
const STATUS_LABEL = { pending: "Pending", running: "Running", waiting: "Needs you", succeeded: "Done", failed: "Failed", skipped: "Skipped", cancelled: "Cancelled" };
function fmtDur(ms) {
  if (ms == null || ms < 0) return "";
  const s = Math.round(ms / 1000);
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m ${s % 60}s`;
  return `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m`;
}
function triggerLabel(t) {
  if (t.type === "manual") return null;
  if (t.type === "webhook") return "Webhook";
  if (t.type === "agent") return "pi starts it when needed";
  if (t.type === "git") return t.on === "pr" ? "New PRs" : t.on === "issue" ? "New issues" : `Commits${t.branch ? ` on ${t.branch}` : ""}`;
  if (t.type === "schedule") {
    const f = (t.cron || "").split(/\s+/);
    if (f.length === 5 && /^\d+$/.test(f[0]) && /^\d+$/.test(f[1]) && f[2] === "*" && f[3] === "*") {
      const time = `${f[1]}:${f[0].padStart(2, "0")}`;
      return f[4] === "*" ? `Daily ${time}` : f[4] === "1-5" ? `Weekdays ${time}` : `${time} (${f[4]})`;
    }
    return t.cron;
  }
  return t.type;
}
const TRIGGER_LABEL = { manual: "manual", chat: "asked in chat", agent: "started by pi", schedule: "schedule", git: "new commits", pr: "PR activity", issue: "new issue", webhook: "webhook" };
const triggerText = (t) => TRIGGER_LABEL[t] || t;
function statusPill(status) {
  return `<span class="pill st-${status}">${STATUS_LABEL[status] || status}</span>`;
}

function showView(v) {
  S.view = v;
  const chat = v === "chat";
  document.body.classList.toggle("wf-mode", !chat);
  $("wfview").hidden = chat;
  $("messages").hidden = !chat;
  $("composer-wrap").hidden = !chat;
  if (!chat) { $("empty").hidden = true; $("working").hidden = true; $("jump").hidden = true; banner(null); }
  else { $("messages").hidden = false; updateEmpty(); }
  $("model-chip").hidden = !chat;
}

async function loadWorkflows() {
  try { S.workflows = (await api("/api/workflows")).workflows || []; } catch { S.workflows = []; }
  if (S.tab === "workflows") renderDrawer();
}
function renderWorkflowList() {
  const box = $("session-list"); box.innerHTML = "";
  const term = $("search").value.trim().toLowerCase();
  const list = S.workflows.filter((w) => (!S.project || w.workflow.project === S.project) && (!term || `${w.workflow.name} ${w.workflow.description} ${w.workflow.id}`.toLowerCase().includes(term)));
  if (!list.length) {
    box.append(el("div", "list-empty", term ? "No workflows match." : "No workflows yet. Tap “New workflow” and describe what you want: stages, checks, reviews, approvals and when it should run."));
    return;
  }
  for (const w of list) {
    const wf = w.workflow;
    const trig = (wf.triggers || []).map(triggerLabel).filter(Boolean);
    const lr = w.last_run;
    const b = el("button", "sess wf-item" + (S.view === "workflow" && S.wf?.workflow.id === wf.id ? " active" : ""));
    b.innerHTML = `${S.project ? "" : badge(wf.project, "badge sm")}<div class="sess-main">
      <div class="t"><span>${esc(wf.name)}</span>${wf.enabled ? "" : '<i class="draft">draft</i>'}</div>
      <div class="m">${lr ? `${statusPill(lr.status)} ${ago(lr.created)}` : "never run"}${trig.length ? " · " + esc(trig.join(", ")) : ""} · ${plural(wf.stages.length, "stage")}</div></div>`;
    b.onclick = () => { closeDrawer(); openWorkflow(wf.id); };
    box.append(b);
  }
}
document.querySelectorAll("#panel-tabs button").forEach((b) => b.addEventListener("click", () => {
  S.tab = b.dataset.tab; localStorage.setItem("pp.tab", S.tab); renderDrawer();
  if (S.tab === "workflows") loadWorkflows();
}));

function newWorkflowChat(text) {
  newChat();
  input.value = text || `Create a workflow for this project that `;
  autosize(); updateSend();
  setTimeout(() => { input.focus(); input.setSelectionRange(input.value.length, input.value.length); }, 50);
}

function setUrl(key, val) {
  const url = new URL(location.href);
  ["s", "w", "r"].forEach((k) => url.searchParams.delete(k));
  if (val) url.searchParams.set(key, val);
  history.replaceState(null, "", url);
}

function header(title, sub, project) {
  $("title").textContent = title;
  $("subtitle").textContent = sub || "";
  if (project) $("project-badge").outerHTML = `<span id="project-badge" class="badge" style="--h:${hue(project)}">${esc(initials(projectName(project)))}</span>`;
  document.title = `${title} · pocketpi`;
}

async function openWorkflow(id) {
  if (S.view === "chat") resetChat();
  showView("workflow"); setUrl("w", id);
  $("wfview").innerHTML = '<div class="wf-loading">Loading…</div>';
  try { S.wf = await api(`/api/workflows/${encodeURIComponent(id)}`); }
  catch (e) { $("wfview").innerHTML = `<div class="errbox">${esc(e.message)}</div>`; return; }
  renderWorkflow();
  if (S.tab === "workflows") renderWorkflowList();
}
function renderWorkflow() {
  const { workflow: wf, errors, runs } = S.wf;
  header(wf.name, `${projectName(wf.project)} · workflow`, wf.project);
  const v = $("wfview"); v.innerHTML = "";
  const head = el("div", "wf-head");
  const trig = (wf.triggers || []).map(triggerLabel).filter(Boolean);
  head.innerHTML = `
    ${wf.description ? `<p class="wf-desc">${esc(wf.description)}</p>` : ""}
    <div class="wf-meta">
      <span class="chip">${ICON.folder}${esc(tilde(wf.project))}</span>
      ${wf.worktree ? `<span class="chip">branch per run${wf.base ? ` from ${esc(wf.base)}` : ""}</span>` : '<span class="chip warn">runs in place</span>'}
      ${wf.max_cost ? `<span class="chip">cap ${fmtCost(wf.max_cost)}</span>` : ""}
    </div>`;
  v.append(head);
  if (errors?.length) v.append(el("div", "errbox", `This workflow has problems:<br>${errors.map(esc).join("<br>")}`));

  // actions
  const act = el("div", "wf-actions");
  const runBtn = el("button", "btn", "Run now"); runBtn.onclick = () => startRun(wf);
  const editBtn = el("button", "btn secondary", "Edit in chat"); editBtn.onclick = () => {
    S.project = wf.project; localStorage.setItem("pp.project", wf.project);
    newWorkflowChat(`Update the workflow "${wf.id}": `);
  };
  const more = el("button", "icon-btn", '<svg viewBox="0 0 24 24"><circle cx="5" cy="12" r="1.3"/><circle cx="12" cy="12" r="1.3"/><circle cx="19" cy="12" r="1.3"/></svg>');
  more.onclick = () => openSheet((b) => {
    b.append(el("div", "sheet-title", esc(wf.name)), el("div", "sheet-sub", esc(wf.id)));
    b.append(opt(ICON.copy, "Copy JSON", "The full workflow definition", () => { copyText(JSON.stringify(wf, null, 2)); closeSheet(); toast("Copied"); }));
    b.append(opt(ICON.hide, "Delete workflow", "Runs and their branches are kept", async () => {
      closeSheet(); await api(`/api/workflows/${wf.id}/delete`, {}); toast("Deleted"); loadWorkflows(); newChat();
    }, " danger"));
  });
  act.append(runBtn, editBtn, more);
  v.append(act);

  pushState().then((st) => {
    if (st === "on" || st === "unsupported" || S.view !== "workflow") return;
    const n = el("button", "push-nudge", `${ICON.bell}<div><b>Get notified when runs need you</b><span>${st === "needs-homescreen" ? "Add pocketpi to your Home Screen first, then tap here there." : st === "denied" ? "Notifications are blocked in Settings." : "Approvals, finished and failed runs."}</span></div>`);
    n.onclick = () => enablePush().then(() => S.wf && renderWorkflow());
    act.after(n);
  });
  // sensors
  v.append(el("div", "wf-section", "Sensors"));
  const sens = el("div", "wf-card");
  const sw = el("button", "opt switch-row", `<div class="o-main"><div class="o-t">${wf.enabled ? "Sensors on" : "Draft: sensors off"}</div><div class="o-s">${trig.length ? esc(trig.join(" · ")) : "Manual runs only"}</div></div><span class="switch${wf.enabled ? " on" : ""}"><i></i></span>`);
  sw.onclick = async () => {
    try { await api(`/api/workflows/${wf.id}/enable`, { enabled: !wf.enabled }); wf.enabled = !wf.enabled; renderWorkflow(); loadWorkflows(); toast(wf.enabled ? "Sensors on" : "Sensors off"); }
    catch (e) { toast(e.message, true); }
  };
  sens.append(sw);
  (wf.triggers || []).forEach((t, i) => {
    if (t.type === "manual") return;
    const row = el("div", "sensor-row");
    const icon = { schedule: "⏱", git: "⎇", webhook: "⇢", agent: "✦" }[t.type] || "•";
    let detail = "";
    if (t.type === "schedule") detail = S.wf.next?.[i] ? `next ${esc(S.wf.next[i])}` : `<span class="mono">${esc(t.cron)}</span>`;
    if (t.type === "git") detail = `checks every ${t.poll_minutes || 10} min${t.on === "commits" ? "" : " with gh"}`;
    if (t.type === "agent") detail = `When ${esc(t.when)}${wf.enabled ? "" : " · only once sensors are on"}`;
    row.innerHTML = `<span class="sensor-icon">${icon}</span><div class="o-main"><div class="o-t">${esc(triggerLabel(t))}</div><div class="o-s">${detail}</div></div>`;
    if (t.type === "webhook" && S.wf.webhook) {
      const url = location.origin + S.wf.webhook;
      const box = el("div", "hook");
      box.innerHTML = `<code>${esc(url)}</code>`;
      const copy = el("button", "copy", "Copy"); copy.onclick = () => copyText(url, copy);
      const curl = el("button", "copy", "curl"); curl.onclick = () => copyText(`curl -X POST -H 'content-type: application/json' -d '{"note":"hello"}' ${url}`, curl);
      const rot = el("button", "copy", "New secret"); rot.onclick = async () => { await api(`/api/workflows/${wf.id}/webhook/rotate`, {}); openWorkflow(wf.id); toast("Old URL no longer works"); };
      const btns = el("div", "hook-btns"); btns.append(copy, curl, rot);
      box.append(btns);
      row.querySelector(".o-main").append(box);
    }
    sens.append(row);
  });
  v.append(sens);

  renderImprove(v, wf);

  // DAG
  v.append(el("div", "wf-section", `Stages · ${wf.stages.length}`));
  v.append(renderDag(wf, null));

  // runs
  v.append(el("div", "wf-section", "Runs"));
  const rl = el("div", "wf-card runs");
  if (!runs.length) rl.append(el("div", "list-empty", "No runs yet."));
  for (const r of runs) {
    const b = el("button", "run-row");
    const dur = r.ended ? fmtDur(r.ended - r.created) : fmtDur(Date.now() - r.created);
    b.innerHTML = `${statusPill(r.status)}<span class="rr-main">${ago(r.created)} · ${esc(triggerText(r.trigger))}</span><span class="rr-meta">${dur}${r.cost ? " · " + fmtCost(r.cost) : ""}</span>`;
    b.onclick = () => openRun(r.id);
    rl.append(b);
  }
  v.append(rl);
}

// Vertical DAG: stages in order with their dependencies, models and loop-backs.
// With a run, each node shows that stage's live status.
function renderDag(wf, run) {
  const box = el("div", "dag");
  const order = run ? run.stages.map((s) => s.id) : wf.stages.map((s) => s.id);
  const byId = Object.fromEntries(wf.stages.map((s) => [s.id, s]));
  order.forEach((id, i) => {
    const s = byId[id] || {};
    const rs = run?.stages.find((x) => x.id === id);
    const st = rs?.status || "idle";
    const node = el("div", `dag-node st-${st}`);
    const needs = (s.needs || []).filter((n) => n !== order[i - 1]);
    const model = s.model ? s.model.replace(/^.*\//, "") : s.type === "review" ? "deepseek-v4-pro" : "";
    node.innerHTML = `
      <div class="dag-rail"><span class="dag-dot">${ICON_STAGE[s.type] || ""}</span>${i < order.length - 1 ? '<span class="dag-line"></span>' : ""}</div>
      <div class="dag-body">
        <div class="dag-top"><span class="dag-name">${esc(s.name || id)}</span><span class="dag-type">${esc(s.type || "")}</span>${rs ? statusPill(st) : ""}</div>
        <div class="dag-sub">${[model && `<span class="mono">${esc(model)}</span>`, s.thinking && esc(s.thinking), s.type === "shell" && s.run && `<span class="mono">${esc(s.run.length > 60 ? s.run.slice(0, 60) + "…" : s.run)}</span>`, needs.length && `after ${needs.map(esc).join(", ")}`, s.on_fail && `↺ on fail → ${esc(s.on_fail.goto)} ×${s.on_fail.max || 2}`].filter(Boolean).join(" · ")}</div>
        ${rs ? `<div class="dag-run">${rs.attempts > 1 ? `<span class="attempts">attempt ${rs.attempts}</span>` : ""}${rs.started ? `<span>${fmtDur((rs.ended || Date.now()) - rs.started)}</span>` : ""}${rs.cost ? `<span>${fmtCost(rs.cost)}</span>` : ""}</div>${rs.summary ? `<div class="dag-summary">${esc(rs.summary)}</div>` : ""}${rs.status === "running" && rs.activity ? `<div class="dag-activity">${esc(rs.activity)}${rs.activity_at ? ` · ${fmtDur(Date.now() - rs.activity_at)}` : ""}</div>` : ""}` : ""}
      </div>`;
    if (rs) {
      node.classList.add("tappable");
      node.onclick = () => openStageSheet(wf, run, rs);
    }
    box.append(node);
  });
  return box;
}

function startRun(wf) {
  const inputs = wf.inputs || [];
  if (!inputs.length) return doRun(wf, {});
  openSheet((b) => {
    b.append(el("div", "sheet-title", `Run ${esc(wf.name)}`));
    const fields = {};
    for (const i of inputs) {
      b.append(el("div", "sheet-section", esc(i.name) + (i.required ? "" : " · optional")));
      if (i.description) b.append(el("div", "sheet-msg small", esc(i.description)));
      const f = el("div", "field"); const t = el("textarea"); t.rows = 3; t.value = i.default || ""; t.className = "input-area";
      f.append(t); b.append(f); fields[i.name] = t;
    }
    const row = el("div", "btn-row"); const go = el("button", "btn", "Start run"); row.append(go); b.append(row);
    go.onclick = () => { const vals = {}; for (const [k, t] of Object.entries(fields)) vals[k] = t.value; closeSheet(); doRun(wf, vals); };
  });
}
async function doRun(wf, inputs, force = false) {
  try { const r = await api(`/api/workflows/${wf.id}/run`, { inputs, force }); toast("Run started"); openRun(r.run_id); loadWorkflows(); }
  catch (e) {
    let d = null; try { d = JSON.parse(e.message); } catch {}
    if (e.status === 409 && d?.duplicate) {
      return openSheet((b) => {
        b.append(el("div", "sheet-title", "Already ran"), el("div", "sheet-msg", `${esc(wf.name)} already ran for this ${inputs.pr ? `PR (#${esc(inputs.pr)}) at its current commit` : "input"} ${ago(d.created)} ago, and that run is ${esc(STATUS_LABEL[d.status] || d.status)}.`));
        const row = el("div", "btn-row");
        const see = el("button", "btn secondary", "Open that run"); see.onclick = () => { closeSheet(); openRun(d.run_id); };
        const again = el("button", "btn", "Run again"); again.onclick = () => { closeSheet(); doRun(wf, inputs, true); };
        row.append(see, again); b.append(row);
      });
    }
    toast(d?.message || e.message, true);
  }
}

async function openRun(id) {
  if (S.view === "chat") resetChat();
  showView("run"); setUrl("r", id);
  try { S.run = (await api(`/api/runs/${encodeURIComponent(id)}`)).run; }
  catch (e) { $("wfview").innerHTML = `<div class="errbox">${esc(e.message)}</div>`; return; }
  if (!S.wf || S.wf.workflow.id !== S.run.workflow_id) {
    try { S.wf = await api(`/api/workflows/${encodeURIComponent(S.run.workflow_id)}`); } catch { S.wf = null; }
  }
  renderRun();
}
function renderRun() {
  const r = S.run; if (!r) return;
  const wf = S.wf?.workflow || { stages: r.stages.map((s) => ({ id: s.id, type: s.kind, name: s.name })), name: r.workflow_name, project: r.project };
  header(r.workflow_name, `Run · ${ago(r.created)} · ${triggerText(r.trigger)}`, r.project);
  const v = $("wfview"); v.innerHTML = "";
  const back = el("button", "wf-back", `<svg viewBox="0 0 24 24"><path d="M15 6l-6 6 6 6"/></svg>${esc(r.workflow_name)}`);
  back.onclick = () => openWorkflow(r.workflow_id);
  v.append(back);
  const active = ["pending", "running", "waiting"].includes(r.status);
  const head = el("div", "run-head");
  head.innerHTML = `${statusPill(r.status)}
    <div class="run-stats"><span>${fmtDur((r.ended || Date.now()) - r.created)}</span><span>${fmtCost(r.cost)}</span>${r.branch ? `<span class="mono">${esc(r.branch)}</span>` : ""}</div>`;
  v.append(head);
  if (r.error && r.status === "failed") v.append(el("div", "errbox", esc(r.error)));
  if (Object.keys(r.inputs || {}).length) {
    v.append(el("div", "wf-section", "Inputs"));
    v.append(el("div", "wf-card inputs", Object.entries(r.inputs).map(([k, val]) => `<div><b>${esc(k)}</b> ${esc(val)}</div>`).join("")));
  }
  // approval gate front and centre
  const waiting = r.stages.find((s) => s.status === "waiting");
  if (waiting) {
    const g = el("div", "gate");
    g.innerHTML = `<div class="gate-title">${ICON_STAGE.approval}<span>${esc(waiting.name)}</span></div><div class="gate-msg">${esc(waiting.prompt || "Approve to continue.")}</div>`;
    const note = el("input"); note.placeholder = "Note (optional, sent back on reject)"; note.className = "gate-note";
    const row = el("div", "btn-row");
    const no = el("button", "btn secondary", "Reject"); const yes = el("button", "btn", "Approve");
    const answer = async (ok) => { try { await api(`/api/runs/${r.id}/approve`, { stage: waiting.id, approve: ok, note: note.value }); } catch (e) { toast(e.message, true); } };
    no.onclick = () => answer(false); yes.onclick = () => answer(true);
    row.append(no, yes); g.append(note, row); v.append(g);
  }
  v.append(el("div", "wf-section", "Stages"));
  v.append(renderDag(wf, r));
  const act = el("div", "wf-actions");
  if (active) { const c = el("button", "btn danger", "Cancel run"); c.onclick = async () => { try { await api(`/api/runs/${r.id}/cancel`, {}); } catch (e) { toast(e.message, true); } }; act.append(c); }
  else if (r.worktree && r.cwd) { const c = el("button", "btn secondary", "Remove worktree"); c.onclick = async () => { try { await api(`/api/runs/${r.id}/cleanup`, {}); toast("Worktree removed (branch kept)"); } catch (e) { toast(e.message, true); } }; act.append(c); }
  const again = el("button", "btn secondary", "Run again"); again.onclick = () => S.wf && startRun(S.wf.workflow); act.append(again);
  v.append(act);
}
function openStageSheet(wf, run, rs) {
  openSheet((b) => {
    b.append(el("div", "sheet-title", esc(rs.name)), el("div", "sheet-sub", `${esc(rs.kind)} · ${STATUS_LABEL[rs.status] || rs.status}${rs.attempts > 1 ? ` · attempt ${rs.attempts}` : ""}${rs.cost ? ` · ${fmtCost(rs.cost)}` : ""}`));
    if (rs.session_file || rs.live_key) {
      const o = opt(ICON.chip, rs.status === "running" ? "Watch live" : "Open chat", "The full pi conversation for this stage", () => {
        closeSheet(); if (rs.session_file) openSession(rs.session_file, run.id); else toast("Chat not available yet");
      });
      b.append(o);
    }
    if (rs.prompt) { b.append(el("div", "sheet-section", rs.kind === "shell" ? "Command" : rs.kind === "approval" ? "Message" : "Prompt")); b.append(truncBlock(rs.prompt, 4000)); }
    if (rs.output) { b.append(el("div", "sheet-section", rs.status === "failed" ? "Failure" : "Output")); b.append(truncBlock(rs.output, 8000, rs.kind === "shell")); }
    b.querySelectorAll("pre").forEach((p) => p.classList.add("sheet-pre"));
  });
}

// live updates for runs and workflow lists
function connectRuns() {
  if (S.runsEs) S.runsEs.close();
  const es = new EventSource("/api/runs/events");
  S.runsEs = es;
  es.onmessage = (e) => {
    let ev; try { ev = JSON.parse(e.data); } catch { return; }
    if (ev.type === "run") {
      const r = ev.run;
      if (S.view === "run" && S.run?.id === r.id) { S.run = r; renderRun(); }
      if (S.view === "workflow" && S.wf?.workflow.id === r.workflow_id) {
        const i = S.wf.runs.findIndex((x) => x.id === r.id);
        if (i >= 0) S.wf.runs[i] = r; else S.wf.runs.unshift(r);
        renderWorkflow();
      }
      clearTimeout(S.wfReload); S.wfReload = setTimeout(loadWorkflows, 800);
    } else if (ev.type === "run_dropped") {
      if (S.view === "run" && S.run?.id === ev.run_id) { toast(`Nothing to do: ${ev.reason}`); openWorkflow(ev.workflow_id); }
      if (S.view === "workflow" && S.wf?.workflow.id === ev.workflow_id) { S.wf.runs = S.wf.runs.filter((r) => r.id !== ev.run_id); renderWorkflow(); }
    } else if (ev.type === "improve_done") {
      S.reflecting = null;
      const r = ev.result || "";
      toast(r.startsWith("applied") ? "Workflow improved" : r.startsWith("proposed") ? "Improvement suggested" : r.startsWith("failed") ? `Couldn't reflect: ${r.slice(8)}` : "No improvements found", r.startsWith("failed"));
      if (S.view === "workflow" && S.wf?.workflow.id === ev.workflow_id) openWorkflow(ev.workflow_id);
    } else if (ev.type === "workflows_changed") {
      loadWorkflows();
      if (S.view === "workflow" && S.wf) openWorkflow(S.wf.workflow.id);
    } else if (ev.type === "notice") {
      if (!(S.view === "run" && S.run?.id === ev.run_id)) {
        toast(`${ev.title}${ev.level === "approval" ? " · needs approval" : ""}`, ev.level === "error");
        const t = $("toast"); t.style.cursor = "pointer"; t.onclick = () => { t.hidden = true; openRun(ev.run_id); };
      }
    }
  };
  es.onerror = () => { es.close(); setTimeout(connectRuns, 3000); };
}
// keep durations ticking on an active run
setInterval(() => { if (S.view === "run" && S.run && ["running", "waiting", "pending"].includes(S.run.status) && !document.body.classList.contains("sheet-open")) renderRun(); }, 5000);


// ---------------------------------------------------------------- self-improvement
// Line diff (LCS) between two pretty-printed workflows, for proposals.
function lineDiff(a, b) {
  const A = a.split("\n"), B = b.split("\n"), n = A.length, m = B.length;
  const L = Array.from({ length: n + 1 }, () => new Uint16Array(m + 1));
  for (let i = n - 1; i >= 0; i--) for (let j = m - 1; j >= 0; j--) L[i][j] = A[i] === B[j] ? L[i + 1][j + 1] + 1 : Math.max(L[i + 1][j], L[i][j + 1]);
  const out = []; let i = 0, j = 0;
  while (i < n && j < m) {
    if (A[i] === B[j]) { out.push(" " + A[i]); i++; j++; }
    else if (L[i + 1][j] >= L[i][j + 1]) out.push("-" + A[i++]);
    else out.push("+" + B[j++]);
  }
  while (i < n) out.push("-" + A[i++]);
  while (j < m) out.push("+" + B[j++]);
  // keep changed lines plus 2 lines of context
  const keep = new Set();
  out.forEach((l, k) => { if (l[0] !== " ") for (let d = -2; d <= 2; d++) keep.add(k + d); });
  const res = []; let gap = false;
  out.forEach((l, k) => { if (keep.has(k)) { res.push(l); gap = false; } else if (!gap) { res.push("@@"); gap = true; } });
  return res.join("\n");
}
const pretty = (w) => JSON.stringify(w, null, 2);
function renderImprove(v, wf) {
  v.append(el("div", "wf-section", "Self-improvement"));
  const card = el("div", "wf-card improve");
  const seg = el("div", "seg");
  const mode = wf.improve || "suggest";
  for (const [m, label] of [["off", "Off"], ["suggest", "Suggest"], ["auto", "Auto"]]) {
    const b = el("button", m === mode ? "on" : "", label);
    b.onclick = async () => { try { await api(`/api/workflows/${wf.id}/improve`, { mode: m }); wf.improve = m; renderWorkflow(); } catch (e) { toast(e.message, true); } };
    seg.append(b);
  }
  const help = { off: "Never changes itself.", suggest: "After notable runs (failures, retries, every 5th run) a reviewer suggests improvements for you to apply.", auto: "Safe improvements are applied straight away; changes to approvals, reviews, shell commands or cost caps still wait for you." }[mode];
  const row = el("div", "improve-row");
  const now = el("button", "btn secondary small", S.reflecting === wf.id ? "Reflecting…" : "Improve now");
  now.disabled = S.reflecting === wf.id;
  now.onclick = async () => {
    try { await api(`/api/workflows/${wf.id}/reflect`, {}); S.reflecting = wf.id; toast("Reviewing the last run…"); renderWorkflow(); }
    catch (e) { toast(e.message, true); }
  };
  row.append(el("div", "improve-help", esc(help)), now);
  card.append(seg, row);
  v.append(card);

  const prop = S.wf.proposal;
  if (prop) {
    const pc = el("div", "proposal");
    pc.innerHTML = `<div class="proposal-title">✦ Suggested improvement <span>${ago(prop.created)} · ${esc((prop.model || "").replace(/^.*\//, ""))}</span></div>`;
    const ul = el("ul", "proposal-changes");
    for (const c of prop.changes || []) ul.append(el("li", "", `<b>${esc(c.summary || "")}</b>${c.why ? `<span>${esc(c.why)}</span>` : ""}`));
    pc.append(ul);
    if (prop.violations?.length) pc.append(el("div", "proposal-why", `Needs your OK because it ${prop.violations.map(esc).join("; ")}.`));
    const d = el("details", "proposal-diff");
    d.innerHTML = "<summary>Show changes</summary>";
    d.addEventListener("toggle", () => { if (d.open && !d.querySelector("pre")) d.append(diffBlock(lineDiff(pretty(wf), pretty(prop.workflow)))); });
    pc.append(d);
    const btns = el("div", "btn-row");
    const no = el("button", "btn secondary", "Dismiss"); const yes = el("button", "btn", "Apply");
    no.onclick = async () => { await api(`/api/workflows/${wf.id}/proposal/dismiss`, {}); openWorkflow(wf.id); };
    yes.onclick = async () => { try { await api(`/api/workflows/${wf.id}/proposal/apply`, {}); toast("Applied"); openWorkflow(wf.id); } catch (e) { toast(e.message, true); } };
    btns.append(no, yes); pc.append(btns);
    v.append(pc);
  }

  const hist = S.wf.history || [];
  if (hist.length) {
    const h = el("details", "history");
    h.innerHTML = `<summary>History · ${plural(hist.length, "change")}</summary>`;
    for (const it of hist) {
      const r = el("div", "hist-row");
      r.innerHTML = `<div class="o-main"><div class="o-t">${esc(it.reason || "edited")}</div><div class="o-s">${ago(it.at)} · replaced the version shown by Revert</div></div>`;
      const b = el("button", "copy", "Revert");
      b.onclick = () => openSheet((sb) => {
        sb.append(el("div", "sheet-title", "Revert this change?"), el("div", "sheet-msg", `Restores the workflow as it was before: “${esc(it.reason || "edited")}”. The current version is kept in history.`));
        const row2 = el("div", "btn-row"); const ok = el("button", "btn", "Revert");
        ok.onclick = async () => { closeSheet(); try { await api(`/api/workflows/${wf.id}/revert`, { version: it.version }); toast("Reverted"); openWorkflow(wf.id); } catch (e) { toast(e.message, true); } };
        row2.append(ok); sb.append(row2);
      });
      r.append(b); h.append(r);
    }
    v.append(h);
  }
}

// ---------------------------------------------------------------- suggested replies
// When pi's last message asks the user something, a cheap model drafts 1-3
// answers that appear as ghost reply bubbles; tapping one sends it.
const suggestCache = new Map(JSON.parse(sessionStorage.getItem("pp.sugg") || "[]"));
let suggestSeq = 0;
const suggestionsOn = () => localStorage.getItem("pp.suggest") !== "0";
function asksUser(text) {
  const tail = text.slice(-500);
  const lines = tail.split("\n").map((l) => l.trim()).filter(Boolean);
  const lastLines = lines.slice(-3).join(" ");
  if (/\?[\s*_`)\]"']*$/.test(lastLines) || /\?[*_`)\]"']*\s*$/m.test(lines.slice(-2).join("\n"))) return true;
  return /\b(want me to|should i|shall i|would you like|do you want|which (one|option|approach|do you)|let me know (if|which|whether)|your call|or would you|prefer)\b/i.test(tail);
}
// Ghost text: the most likely next message sits in the empty composer, the
// way Claude Code pre-fills a reply. "Use" (or Tab on desktop) accepts it.
function setGhost(text) {
  S.ghost = text || null;
  $("composer").classList.toggle("has-ghost", !!S.ghost);
  updateSend();
}
function acceptGhost() {
  if (!S.ghost) return;
  input.value = S.ghost; setGhost(null);
  autosize(); updateSend(); input.focus();
  input.setSelectionRange(input.value.length, input.value.length);
}
$("use-ghost").addEventListener("click", acceptGhost);
function clearSuggestions() {
  if (S.ghost) setGhost(null);
  suggestSeq++;
  document.querySelectorAll(".suggestions").forEach((n) => n.remove());
}
async function maybeSuggest() {
  clearSuggestions();
  const seq = suggestSeq;
  if (!suggestionsOn() || S.streaming) return;
  const last = [...S.msgs].reverse().find((m) => m.role === "assistant" || m.role === "user");
  if (!last || last.role !== "assistant" || last.stopReason !== "stop") return;
  const text = textOf(last.content).trim();
  if (!text) return;
  const key = `${S.path || S.key}:${last.timestamp}`;
  let replies = suggestCache.get(key);
  if (!replies) {
    const u = [...S.msgs].reverse().find((m) => m.role === "user");
    try { replies = (await api("/api/suggest", { assistant: text, user: u ? textOf(u.content) : "" })).replies || []; }
    catch { return; }
    suggestCache.set(key, replies);
    sessionStorage.setItem("pp.sugg", JSON.stringify([...suggestCache].slice(-60)));
  }
  if (seq !== suggestSeq || S.streaming || !replies.length) return;
  const last2 = [...S.msgs].reverse().find((m) => m.role === "assistant" || m.role === "user");
  if (last2 !== last) return;
  setGhost(replies[0]);
  if (!asksUser(text)) return;
  const box = el("div", "suggestions");
  box.append(el("div", "sugg-label", `${ICON.spark}<span>Suggested replies</span>`));
  replies.forEach((r, i) => {
    const b = el("button", "sugg" + (i === 0 ? " first" : ""));
    b.type = "button"; b.textContent = r; b.style.animationDelay = `${60 + i * 70}ms`;
    b.onclick = () => { input.value = r; autosize(); send(); };
    box.append(b);
  });
  $("messages").append(box);
  scrollBottom();
}

// ---------------------------------------------------------------- swipe drawer
// Swipe right anywhere to pull the drawer open (it tracks the finger), swipe
// left to push it closed. Direction is locked after a few pixels so vertical
// scrolling is untouched, and gestures that start on horizontally scrollable
// content (code blocks, tables) are left alone.
(function swipeDrawer() {
  const drawer = $("drawer"), scrim = $("scrim");
  const docked = () => matchMedia("(min-width: 960px)").matches;
  const isOpen = () => document.body.classList.contains("drawer-open");
  let g = null;
  function scrollsX(node) {
    for (let n = node; n && n !== document.body; n = n.parentElement) {
      if (n.scrollWidth > n.clientWidth + 2) {
        const o = getComputedStyle(n).overflowX;
        if (o === "auto" || o === "scroll") return true;
      }
    }
    return false;
  }
  document.addEventListener("touchstart", (e) => {
    g = null;
    if (docked() || e.touches.length !== 1 || document.body.classList.contains("sheet-open")) return;
    if (!isOpen() && scrollsX(e.target)) return;
    const t = e.touches[0];
    g = { mode: isOpen() ? "close" : "open", x0: t.clientX, y0: t.clientY, t0: performance.now(), w: drawer.offsetWidth, locked: false, x: 0, lastX: t.clientX, lastT: performance.now(), vx: 0 };
  }, { passive: true });
  document.addEventListener("touchmove", (e) => {
    if (!g) return;
    const t = e.touches[0], dx = t.clientX - g.x0, dy = t.clientY - g.y0;
    if (!g.locked) {
      if (Math.hypot(dx, dy) < 9) return;
      const horizontal = Math.abs(dx) > Math.abs(dy) * 1.25;
      if (!horizontal || (g.mode === "open" ? dx < 0 : dx > 0)) { g = null; return; }
      g.locked = true;
      drawer.style.transition = scrim.style.transition = "none";
      scrim.style.pointerEvents = "auto";
      if (g.mode === "open") loadProjects();
    }
    e.preventDefault();
    const now = performance.now();
    g.vx = (t.clientX - g.lastX) / Math.max(1, now - g.lastT);
    g.lastX = t.clientX; g.lastT = now;
    g.x = g.mode === "open" ? Math.min(0, -g.w + dx) : Math.min(0, dx);
    drawer.style.transform = `translateX(${g.x}px)`;
    scrim.style.opacity = String(1 + g.x / g.w);
  }, { passive: false });
  const end = () => {
    if (!g || !g.locked) { g = null; return; }
    const shown = 1 + g.x / g.w; // 0 = closed, 1 = open
    const open = g.vx > 0.35 ? true : g.vx < -0.35 ? false : shown > 0.4;
    drawer.style.transition = scrim.style.transition = "";
    document.body.classList.toggle("drawer-open", open);
    requestAnimationFrame(() => {
      drawer.style.transform = ""; scrim.style.opacity = ""; scrim.style.pointerEvents = "";
    });
    if (open) input.blur();
    g = null;
  };
  document.addEventListener("touchend", end);
  document.addEventListener("touchcancel", end);
})();

// ---------------------------------------------------------------- swipe keyboard away
// With the composer focused, dragging down over the conversation dismisses the
// keyboard (like the Claude app). The chat still scrolls with the finger.
(function swipeKeyboard() {
  let g = null;
  $("scroller").addEventListener("touchstart", (e) => {
    g = document.activeElement === input && e.touches.length === 1
      ? { x0: e.touches[0].clientX, y0: e.touches[0].clientY } : null;
  }, { passive: true });
  $("scroller").addEventListener("touchmove", (e) => {
    if (!g) return;
    const dx = e.touches[0].clientX - g.x0, dy = e.touches[0].clientY - g.y0;
    if (Math.abs(dx) > Math.abs(dy) && Math.abs(dx) > 12) { g = null; return; }
    if (dy > 30) { input.blur(); g = null; }
    else if (dy < -30) g = null; // scrolling the other way keeps the keyboard
  }, { passive: true });
  $("scroller").addEventListener("touchend", () => { g = null; }, { passive: true });
})();

// ---------------------------------------------------------------- swipe sheet down
// Drag a bottom sheet down to dismiss it. Starts from the grabber/title area,
// or from the content when it is already scrolled to the top.
(function swipeSheet() {
  const sheet = $("sheet"), body = $("sheet-body"), scrim = $("sheet-scrim");
  let g = null;
  sheet.addEventListener("touchstart", (e) => {
    g = null;
    if (e.touches.length !== 1 || matchMedia("(min-width: 960px)").matches) return;
    const t = e.touches[0];
    const inBody = body.contains(e.target);
    if (inBody && body.scrollTop > 0) return;
    if (e.target.closest("input, textarea, .seg")) return;
    g = { y0: t.clientY, x0: t.clientX, locked: false, dy: 0, lastY: t.clientY, lastT: performance.now(), vy: 0, h: sheet.offsetHeight };
  }, { passive: true });
  sheet.addEventListener("touchmove", (e) => {
    if (!g) return;
    const t = e.touches[0], dy = t.clientY - g.y0, dx = t.clientX - g.x0;
    if (!g.locked) {
      if (Math.hypot(dx, dy) < 8) return;
      if (dy <= 0 || Math.abs(dx) > dy) { g = null; return; }
      g.locked = true;
      sheet.style.transition = scrim.style.transition = "none";
    }
    e.preventDefault();
    const now = performance.now();
    g.vy = (t.clientY - g.lastY) / Math.max(1, now - g.lastT);
    g.lastY = t.clientY; g.lastT = now;
    g.dy = Math.max(0, dy);
    sheet.style.transform = `translateY(${g.dy}px)`;
    scrim.style.opacity = String(Math.max(0, 1 - g.dy / g.h));
  }, { passive: false });
  const end = () => {
    if (!g || !g.locked) { g = null; return; }
    const close = g.vy > 0.5 || g.dy > g.h * 0.3;
    sheet.style.transition = scrim.style.transition = "";
    if (close) closeSheet();
    requestAnimationFrame(() => { sheet.style.transform = ""; scrim.style.opacity = ""; });
    g = null;
  };
  sheet.addEventListener("touchend", end);
  sheet.addEventListener("touchcancel", end);
})();

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
  connectRuns(); loadWorkflows();
  const q = new URL(location.href).searchParams;
  if (q.get("r")) openRun(q.get("r"));
  else if (q.get("w")) openWorkflow(q.get("w"));
  else if (q.get("s")) await openSession(q.get("s"));
  else newChat();
  autosize(); updateSend();
})();
