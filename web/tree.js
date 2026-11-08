"use strict";
// pocketpi: a chat's session tree (pi's /tree) and its session info. Loaded
// after app.js and uses its globals ($, el, esc, S, api, cmd, toast,
// openSheet, closeSheet, opt, input, autosize, updateSend, loadSnapshot,
// setStreaming, setWorking, fmtTokens, fmtCost, tilde, ICON). app.js only
// calls window.ppTree?.sheetEntry(b) from the chat sheet and
// ppTree.activeForkPoints() from forkFrom.
//
// The tree comes from get_tree. Moving to another point and labels go
// through the pocketpi-control extension (POST /api/s/{key}/control with
// "goto" / "label"); the server then sends pocketpi_resync, so every open
// copy of the chat reloads its messages. The same logic is in PocketPiKit's
// Tree.swift (SessionTree, SessionSummary); keep the two in step.

window.ppTree = (() => {
  const TREE = '<svg viewBox="0 0 24 24"><circle cx="6" cy="5" r="2"/><circle cx="6" cy="19" r="2"/><circle cx="18" cy="12" r="2"/><path d="M6 7v10M6 12h3.5a3 3 0 0 0 3-3V9M12.5 15a3 3 0 0 0 3 0H16"/></svg>';
  const INFO = '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="8.5"/><path d="M12 11v5.5M12 7.6v.4"/></svg>';
  const TAG = '<svg viewBox="0 0 24 24"><path d="M3.5 12.5V4.5a1 1 0 0 1 1-1h8l8 8-9 9z"/><circle cx="8.5" cy="8.5" r="1.5"/></svg>';
  const BACK = '<svg viewBox="0 0 24 24"><path d="M15 6l-6 6 6 6"/></svg>';

  let styled = false;
  function style() {
    if (styled) return;
    styled = true;
    const s = document.createElement("style");
    s.textContent = `
.pt-head { display: flex; align-items: center; gap: 8px; }
.pt-head .sheet-title { flex: 1; }
.pt-back { width: 34px; height: 34px; border-radius: 10px; display: grid; place-items: center; color: var(--muted); }
.pt-back svg { width: 20px; height: 20px; }
.pt-list { display: flex; flex-direction: column; margin: 4px -6px 8px; }
.pt-row { display: flex; align-items: flex-start; gap: 8px; width: 100%; text-align: left; padding: 7px 8px 7px calc(8px + var(--d, 0) * 14px); border-radius: 11px; position: relative; min-height: 34px; }
.pt-row:active { background: var(--surface); }
.pt-row::before { content: ""; position: absolute; left: calc(14px + var(--d, 0) * 14px); top: 0; bottom: 0; border-left: 1.5px solid var(--line-2, var(--line)); }
.pt-row.first::before { top: 15px; }
.pt-row.last::before { bottom: calc(100% - 15px); }
.pt-dot { width: 13px; height: 13px; border-radius: 50%; flex: none; margin-top: 3px; background: var(--bg); border: 1.5px solid var(--muted); position: relative; z-index: 1; }
.pt-row.user .pt-dot { background: var(--text); border-color: var(--text); }
.pt-row.assistant .pt-dot { border-radius: 4px; }
.pt-row.compaction .pt-dot, .pt-row.branchSummary .pt-dot { border-style: dashed; }
.pt-row.path .pt-dot { border-color: var(--text); }
.pt-row.current .pt-dot { background: var(--signal); border-color: var(--signal); box-shadow: 0 0 0 3px color-mix(in srgb, var(--signal) 35%, transparent); }
.pt-row.branch::after { content: ""; position: absolute; left: calc(14px + (var(--d, 0) - 1) * 14px); top: 0; width: 14px; height: 10px; border-left: 1.5px solid var(--line-2, var(--line)); border-bottom: 1.5px solid var(--line-2, var(--line)); border-bottom-left-radius: 8px; }
.pt-main { flex: 1; min-width: 0; }
.pt-t { font-size: 14px; line-height: 1.35; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.pt-row.assistant .pt-t, .pt-row.compaction .pt-t, .pt-row.branchSummary .pt-t { color: var(--muted); font-size: 13px; }
.pt-row:not(.path) .pt-t { opacity: .72; }
.pt-row.current .pt-t { opacity: 1; font-weight: 600; color: var(--text); }
.pt-s { font: 11px var(--mono); color: var(--muted); margin-top: 1px; display: flex; gap: 6px; flex-wrap: wrap; }
.pt-label { font: 600 11px var(--mono); color: var(--signal-ink, var(--text)); background: var(--signal); border-radius: 6px; padding: 1px 6px; }
.pt-here { font: 600 10.5px var(--mono); text-transform: uppercase; letter-spacing: .05em; color: var(--text); }
.pt-quote { background: var(--surface); border-radius: 13px; padding: 10px 12px; font-size: 14px; line-height: 1.45; max-height: 30vh; overflow: auto; white-space: pre-wrap; overflow-wrap: anywhere; margin-bottom: 6px; }
.pt-instr { margin: 2px 0 6px; }
.pt-kv { display: grid; grid-template-columns: auto 1fr; gap: 6px 14px; font-size: 13.5px; }
.pt-kv .k { color: var(--muted); }
.pt-kv .v { font: 12.5px var(--mono); overflow-wrap: anywhere; text-align: right; }
.pt-models .opt { padding: 8px 10px; }
`;
    document.head.append(s);
  }

  // ------------------------------------------------------------ building the tree
  function contentText(c) {
    if (typeof c === "string") return c;
    return (c || []).filter((b) => b && b.type === "text").map((b) => b.text || "").join(" ");
  }
  function firstLine(s) {
    const l = String(s || "").trim().split("\n").find((x) => x.trim()) || "";
    return l.length > 160 ? l.slice(0, 160) + "…" : l;
  }
  function kindOf(e) {
    switch (e?.type) {
      case "message": {
        const r = e.message?.role;
        if (r === "user") return "user";
        if (r === "assistant") return "assistant";
        if (r === "bashExecution") return "bash";
        if (r === "custom") return e.message.display === false ? null : "custom";
        return null;
      }
      case "custom_message": return e.display === true ? "custom" : null;
      case "compaction": return "compaction";
      case "branch_summary": return "branchSummary";
      default: return null; // tool results, system, model/thinking changes, labels, usage, hidden custom entries
    }
  }
  const hasText = (e) => !!contentText(e.message?.content).trim();
  const toolCalls = (e) => (e.message?.role === "assistant" ? (e.message.content || []).filter((b) => b.type === "toolCall").length : 0);
  function lineOf(e) {
    const m = e.message;
    switch (kindOf(e)) {
      case "user": {
        const t = firstLine(contentText(m.content));
        return t || ((m.content || []).some?.((b) => b.type === "image") ? "(image)" : "(empty)");
      }
      case "assistant": return firstLine(contentText(m.content)) || (m.errorMessage ? firstLine(m.errorMessage) : "");
      case "bash": return "!" + firstLine(m.command);
      case "custom": return firstLine(contentText(m?.content ?? e.content));
      case "compaction": return "Context compacted" + (e.tokensBefore != null ? ` · ${fmtTokens(e.tokensBefore)} tokens` : "");
      case "branchSummary": return firstLine(e.summary || "Branch summary");
      default: return "";
    }
  }

  // get_tree's {tree, leafId} → {rows, currentId, branches}. Only what the
  // chat shows is a row; hidden entries (pocketpi-control's replies among
  // them) hand their children to the nearest row above. pi's leaf is often
  // hidden, so "current" is the nearest row above it. A reply's assistant
  // messages fold into one row, up to a branch, a label or the current entry.
  function build(data) {
    const entries = new Map(), labels = new Map(), children = new Map(), parent = new Map(), roots = [];
    const stack = (data?.tree || []).map((n) => [n, null]).reverse();
    while (stack.length) {
      const [node, p] = stack.pop();
      const e = node?.entry; const id = e?.id;
      if (!id || entries.has(id)) continue;
      entries.set(id, e);
      if (node.label) labels.set(id, node.label);
      if (p) { (children.get(p) || children.set(p, []).get(p)).push(id); parent.set(id, p); } else roots.push(id);
      for (const c of [...(node.children || [])].reverse()) stack.push([c, id]);
    }
    const kind = (id) => kindOf(entries.get(id));
    const visibleKids = (ids) => {
      const out = []; const todo = [...ids].reverse();
      while (todo.length) {
        const id = todo.pop();
        if (kind(id)) out.push(id); else todo.push(...[...(children.get(id) || [])].reverse());
      }
      return out;
    };
    const onPath = new Set(); let current = null;
    for (let id = data?.leafId; id && !onPath.has(id); id = parent.get(id)) {
      onPath.add(id);
      if (!current && kind(id)) current = id;
    }
    const rows = []; let branches = 0;
    const top = visibleKids(roots);
    const todo = top.map((id) => ({ id, depth: 0, start: top.length > 1 })).reverse();
    while (todo.length) {
      const { id: first, depth, start } = todo.pop();
      const k = kind(first); const e = entries.get(first);
      const row = { id: first, kind: k, text: lineOf(e), depth, branchStart: start, onPath: onPath.has(first),
        isCurrent: first === current, label: labels.get(first) || null, toolCalls: toolCalls(e), timestamp: e.timestamp };
      let last = first; let kids = visibleKids(children.get(first) || []);
      if (k === "assistant") {
        while (kids.length === 1 && kind(kids[0]) === "assistant" && !labels.has(kids[0]) && last !== current) {
          const next = entries.get(kids[0]); last = kids[0];
          row.toolCalls += toolCalls(next);
          if (hasText(next) || !row.text) row.text = lineOf(next);
          row.id = last; row.onPath = onPath.has(last); row.isCurrent = last === current; row.timestamp = next.timestamp;
          kids = visibleKids(children.get(last) || []);
        }
        if (!row.text) row.text = row.toolCalls ? `Used ${row.toolCalls} tool${row.toolCalls === 1 ? "" : "s"}` : "(no text)";
      }
      rows.push(row);
      if (!kids.length) branches++;
      if (kids.length === 1) todo.push({ id: kids[0], depth, start: false });
      else for (const c of [...kids].reverse()) todo.push({ id: c, depth: depth + 1, start: true });
    }
    return { rows, currentId: current, branches };
  }

  // get_entries → counts by role and cost per model (abandoned branches and
  // compacted history included, like pi's own totals).
  function summarize(entries) {
    const roles = {}; let calls = 0, compactions = 0, summaries = 0;
    const labelled = new Map(); const by = new Map();
    const tokens = (u) => (u ? u.totalTokens ?? ["input", "output", "cacheRead", "cacheWrite"].reduce((a, k) => a + (u[k] || 0), 0) : 0);
    const add = (key, u, message) => {
      const m = by.get(key) || { id: key, messages: 0, tokens: 0, cost: 0 };
      if (message) m.messages++;
      m.tokens += tokens(u); m.cost += u?.cost?.total || 0; by.set(key, m);
    };
    const model = (p, m) => [p, m].filter(Boolean).join("/") || "unknown";
    for (const e of entries || []) {
      if (e.type === "message") {
        const r = e.message?.role || "?"; roles[r] = (roles[r] || 0) + 1;
        if (r === "assistant") { calls += toolCalls(e); add(model(e.message.provider, e.message.model), e.message.usage, true); }
      } else if (e.type === "usage") add(model(e.provider, e.model), e.usage, false);
      else if (e.type === "compaction") { compactions++; if (e.usage) add("Summaries", e.usage, false); }
      else if (e.type === "branch_summary") { summaries++; if (e.usage) add("Summaries", e.usage, false); }
      else if (e.type === "label" && e.targetId) labelled.set(e.targetId, !!e.label);
    }
    const models = [...by.values()].sort((a, b) => b.cost - a.cost || b.tokens - a.tokens || a.id.localeCompare(b.id));
    return { roles, toolCalls: calls, compactions, branchSummaries: summaries, labels: [...labelled.values()].filter(Boolean).length,
      models, cost: models.reduce((a, m) => a + m.cost, 0), tokens: models.reduce((a, m) => a + m.tokens, 0) };
  }

  // ------------------------------------------------------------ server calls
  async function control(command, args) {
    if (!S.key) await reopen();
    const r = await api(`/api/s/${S.key}/control`, { command, args });
    if (r.success === false) throw new Error(r.error || `${command} failed`);
    return r.data;
  }

  // get_fork_messages lists every user message in the file, abandoned
  // branches too; narrowed to the current branch, a prompt repeated on
  // another branch can't be picked by forkEntryIds. Unnarrowed if the tree
  // can't be read.
  async function activeForkPoints() {
    const points = (await cmd({ type: "get_fork_messages" })).messages || [];
    try {
      const t = build(await cmd({ type: "get_tree" }));
      const ids = new Set(t.rows.filter((r) => r.onPath && r.kind === "user").map((r) => r.id));
      return points.filter((p) => ids.has(p.entryId));
    } catch { return points; }
  }

  // ------------------------------------------------------------ screens
  function head(b, title, back) {
    const h = el("div", "pt-head");
    if (back) { const x = el("button", "pt-back", BACK); x.setAttribute("aria-label", "Back"); x.onclick = back; h.append(x); }
    h.append(el("div", "sheet-title", esc(title)));
    b.append(h);
  }

  async function openTree() {
    style();
    openSheet((b) => { head(b, "Session tree"); b.append(el("div", "sheet-sub", "Loading…")); });
    let t;
    try { t = build(await cmd({ type: "get_tree" })); } catch (e) { toast(e.message, true); return closeSheet(); }
    openSheet((b) => {
      head(b, "Session tree");
      b.append(el("div", "sheet-sub", t.rows.length
        ? `${t.branches} branch${t.branches === 1 ? "" : "es"} · tap a point to carry on from there`
        : "Nothing here yet"));
      const list = el("div", "pt-list");
      t.rows.forEach((r, i) => {
        const next = t.rows[i + 1];
        const cls = ["pt-row", r.kind, r.onPath ? "path" : "", r.isCurrent ? "current" : "", r.branchStart && r.depth > 0 ? "branch" : "",
          i === 0 ? "first" : "", !next || next.depth < r.depth || (next.branchStart && next.depth <= r.depth) ? "last" : ""].filter(Boolean).join(" ");
        const meta = [];
        if (r.label) meta.push(`<span class="pt-label">${esc(r.label)}</span>`);
        if (r.isCurrent) meta.push('<span class="pt-here">you are here</span>');
        if (r.toolCalls) meta.push(`<span>${r.toolCalls} tool${r.toolCalls === 1 ? "" : "s"}</span>`);
        const row = el("button", cls, `<span class="pt-dot"></span><div class="pt-main"><div class="pt-t">${esc(r.text)}</div>${meta.length ? `<div class="pt-s">${meta.join("")}</div>` : ""}</div>`);
        row.style.setProperty("--d", Math.min(r.depth, 8));
        row.dataset.id = r.id;
        row.onclick = () => openNode(r);
        list.append(row);
      });
      b.append(list);
      requestAnimationFrame(() => list.querySelector(".current")?.scrollIntoView({ block: "center" }));
    });
  }

  const KIND_TITLE = { user: "Your message", assistant: "pi's reply", bash: "Shell command", custom: "Extension message", compaction: "Compaction", branchSummary: "Branch summary" };

  function openNode(r) {
    let summarizeOn = false;
    openSheet((b) => {
      head(b, KIND_TITLE[r.kind] || "Entry", openTree);
      b.append(el("div", "pt-quote", esc(r.text)));
      if (r.label) b.append(el("div", "sheet-sub", `Label: ${esc(r.label)}`));
      if (r.isCurrent) {
        b.append(el("div", "sheet-sub", "The chat is here: your next message continues from this point."));
      } else {
        const refills = r.kind === "user" || r.kind === "custom";
        const go = opt(ICON.branch, refills ? "Edit and resend from here" : "Continue from here",
          refills ? "Goes back to before this message and puts it in the message box" : "The next message continues after this point",
          () => goto(r, summarizeOn, instr.querySelector("input").value));
        if (S.streaming) { go.disabled = true; go.querySelector(".o-s").textContent = "Wait for pi to finish first"; }
        b.append(el("div", "sheet-section", "Go here"), go);
        const sw = el("button", "opt switch-row", '<div class="o-main"><div class="o-t">Summarize the branch I\'m leaving</div><div class="o-s">pi writes a summary of it into the chat (uses the model)</div></div><span class="switch"><i></i></span>');
        const instr = el("div", "field pt-instr", '<input placeholder="What the summary should focus on (optional)" autocomplete="off">');
        instr.hidden = true;
        sw.onclick = () => { summarizeOn = !summarizeOn; sw.querySelector(".switch").classList.toggle("on", summarizeOn); instr.hidden = !summarizeOn; };
        b.append(sw, instr);
      }
      b.append(el("div", "sheet-section", "Label"));
      b.append(opt(TAG, r.label ? "Change label" : "Add a label", "A bookmark shown in the tree (and in pi's /tree)", () => openLabel(r)));
    });
  }

  function openLabel(r) {
    openSheet((b) => {
      head(b, r.label ? "Change label" : "Add a label", () => openNode(r));
      const f = el("div", "field", `<input maxlength="80" placeholder="e.g. before refactor" value="${esc(r.label || "")}" autocomplete="off">`);
      const inp = f.querySelector("input");
      const row = el("div", "btn-row");
      const save = async (label) => {
        try { await control("label", label ? { entryId: r.id, label } : { entryId: r.id }); toast(label ? "Labelled" : "Label removed"); openTree(); } catch (e) { toast(e.message, true); }
      };
      if (r.label) { const clr = el("button", "btn secondary", "Remove"); clr.onclick = () => save(""); row.append(clr); }
      const ok = el("button", "btn", "Save"); ok.onclick = () => save(inp.value.trim());
      inp.onkeydown = (e) => { if (e.key === "Enter") { e.preventDefault(); ok.click(); } };
      row.append(ok);
      b.append(f, row);
      setTimeout(() => inp.focus(), 50);
    });
  }

  async function goto(r, summarizeOn, instructions) {
    if (S.streaming) return toast("Wait for pi to finish first.", true);
    closeSheet();
    if (summarizeOn) { setStreaming(true); setWorking("Summarizing the branch you're leaving"); }
    try {
      const args = { entryId: r.id };
      if (summarizeOn) { args.summarize = true; if (instructions?.trim()) args.instructions = instructions.trim(); }
      const d = await control("goto", args);
      if (d?.cancelled) return toast("An extension cancelled the move.", true);
      if (summarizeOn) setStreaming(false);
      await loadSnapshot();
      if (d?.editorText != null) { input.value = d.editorText; autosize(); updateSend(); input.focus(); toast("Back here: edit and send"); }
      else toast("Carrying on from here");
    } catch (e) { toast(e.message, true); } finally { if (summarizeOn) setStreaming(false); }
  }

  async function openInfo() {
    style();
    openSheet((b) => { head(b, "Session info"); b.append(el("div", "sheet-sub", "Loading…")); });
    let entries, stats, hdr;
    try {
      [entries, stats] = await Promise.all([cmd({ type: "get_entries" }), cmd({ type: "get_session_stats" })]);
      hdr = await api(`/api/s/${S.key}/header`);
    } catch (e) { toast(e.message, true); return closeSheet(); }
    const sum = summarize(entries.entries);
    const h = hdr.header || {};
    const parent = h.parentSession && S.sessions.find((x) => x.path === h.parentSession);
    openSheet((b) => {
      head(b, "Session info");
      const st = el("div", "stats");
      st.innerHTML = `<div class="stat"><div class="v">${sum.roles.user || 0}</div><div class="l">prompts</div></div>
        <div class="stat"><div class="v">${fmtTokens(stats?.tokens?.total)}</div><div class="l">tokens</div></div>
        <div class="stat"><div class="v">${fmtCost(stats?.cost)}</div><div class="l">cost</div></div>`;
      b.append(st);
      const kv = (rows) => { const d = el("div", "pt-kv"); d.innerHTML = rows.filter((r) => r[1] != null && r[1] !== "").map(([k, v]) => `<div class="k">${esc(k)}</div><div class="v">${esc(v)}</div>`).join(""); return d; };
      b.append(el("div", "sheet-section", "File"));
      b.append(kv([
        ["Path", hdr.file ? tilde(hdr.file) : "not saved yet"],
        ["Session id", h.id],
        ["Created", h.timestamp ? new Date(h.timestamp).toLocaleString() : null],
        ["Forked from", h.parentSession ? (parent ? `${parent.name || parent.title || "Untitled"} (${tilde(h.parentSession)})` : tilde(h.parentSession)) : null],
        ["Folder", h.cwd ? tilde(h.cwd) : null],
      ]));
      b.append(el("div", "sheet-section", "Messages"));
      const names = [["user", "Prompts"], ["assistant", "Replies"], ["toolResult", "Tool results"], ["bashExecution", "Shell commands"], ["custom", "Extension messages"]];
      const known = new Set(names.map((n) => n[0]));
      const rows = names.filter(([k]) => sum.roles[k]).map(([k, n]) => [n, String(sum.roles[k])]);
      for (const k of Object.keys(sum.roles).sort()) if (!known.has(k)) rows.push([k, String(sum.roles[k])]);
      rows.push(["Tool calls", sum.toolCalls ? String(sum.toolCalls) : null], ["Compactions", sum.compactions ? String(sum.compactions) : null],
        ["Branch summaries", sum.branchSummaries ? String(sum.branchSummaries) : null], ["Labels", sum.labels ? String(sum.labels) : null]);
      b.append(kv(rows));
      if (sum.models.length) {
        b.append(el("div", "sheet-section", "Cost by model"));
        const m = el("div", "pt-models");
        for (const x of sum.models) {
          const o = opt(ICON.chip, `<span class="mono">${esc(x.id)}</span>`, `${x.messages ? x.messages + " replies · " : ""}${fmtTokens(x.tokens)} tokens`, null, "");
          o.append(el("span", "o-r", fmtCost(x.cost))); o.disabled = true; o.style.opacity = 1;
          m.append(o);
        }
        b.append(m);
      }
      if (stats?.contextUsage) b.append(el("div", "sheet-sub", `Context now: ${stats.contextUsage.percent != null ? Math.round(stats.contextUsage.percent) + "%" : "–"} of ${fmtTokens(stats.contextUsage.contextWindow)}`));
    });
  }

  function sheetEntry(b) {
    if (!S.path) return;
    style();
    b.append(opt(TREE, "Session tree", "Branches, labels; go back to any point", () => openTree()));
    b.append(opt(INFO, "Session info", "File, counts, cost by model", () => openInfo()));
  }

  return { sheetEntry, activeForkPoints, openTree, openInfo, build, summarize };
})();
