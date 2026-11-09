"use strict";
// Subagent progress (server: src/subagents.rs; iOS: SubagentsView.swift).
// pi-subagents writes live run state to <tmp>/pi-subagents-*/async-subagent-runs/
// <id>/status.json; the server reads those files and this module draws them:
//
//   - an "agents" chip in the top bar while something runs,
//   - a Subagents sheet for the open chat (or every chat), with each run's
//     steps, current tool, last output lines, tokens and cost, a log tail,
//     and a tap into a child's own chat while it works,
//   - a live line in the chat's `subagent` tool card plus that run's steps in
//     the card body, matched by the tool call id pi recorded.
//
// Uses app.js globals (S, $, el, esc, api, opt, openSheet, closeSheet,
// openSession, fmtTokens, fmtCost, fmtDur, plural, tilde, ICON).

window.ppAgents = (() => {
  const IC = {
    agents: '<svg viewBox="0 0 24 24"><circle cx="9" cy="8" r="3"/><path d="M3.5 19c0-3 2.5-5 5.5-5s5.5 2 5.5 5"/><circle cx="17.5" cy="10" r="2.2"/><path d="M16.4 14.3c2.6.3 4.1 2.1 4.1 4.7"/></svg>',
  };
  const TERMINAL = ["complete", "completed", "succeeded", "failed", "error", "stopped", "cancelled", "canceled", "aborted", "timed-out", "timeout"];

  const A = {
    runs: [], at: 0, total: 0, all: false, error: null,
    open: false, body: null, seq: 0, timer: null, lastLoad: 0,
    openRuns: new Set(), sig: "",
  };

  const isActive = (r) => !!r.active;
  const active = () => A.runs.filter(isActive);
  const byCall = (id) => A.runs.find((r) => r.toolCallId && r.toolCallId === id);

  // ------------------------------------------------------------ styles
  const css = document.createElement("style");
  css.textContent = `
.ag-run { border: 1px solid var(--line); border-radius: 14px; margin-top: 10px; background: var(--bg); overflow: hidden; }
.ag-run > summary { list-style: none; display: flex; align-items: center; gap: 10px; padding: 11px 12px; cursor: pointer; }
.ag-run > summary::-webkit-details-marker { display: none; }
.ag-run.live { border-color: color-mix(in srgb, var(--signal-text) 45%, var(--line)); }
.ag-run > summary:active { background: var(--surface); }
.ag-head-main { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 2px; }
.ag-title { font: 600 13.5px var(--font); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.ag-sub { font-size: 11.5px; color: var(--muted); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.ag-time { font: 500 11.5px var(--mono); color: var(--text-2); flex: none; }
.ag-state { width: 8px; height: 8px; border-radius: 50%; background: var(--muted); flex: none; }
.ag-state.run { background: var(--signal); animation: pulse 1.1s ease-in-out infinite; box-shadow: 0 0 10px var(--signal); }
.ag-state.done { background: var(--ok); }
.ag-state.err { background: var(--danger); }
.ag-state.warn { background: var(--warn); }
.ag-state.idle { background: var(--muted); }
.ag-body { padding: 0 12px 12px; }
.ag-meta { display: flex; flex-wrap: wrap; gap: 6px; font: 500 11px var(--mono); color: var(--muted); margin: 0 0 8px; }
.ag-meta span { background: var(--surface); border-radius: 999px; padding: 2px 8px; }
.ag-step { display: flex; gap: 10px; width: 100%; text-align: left; padding: 9px 4px; border-radius: 10px; align-items: flex-start; }
.ag-step:active { background: var(--surface); }
.ag-step + .ag-step { border-top: 1px solid var(--line); }
.ag-step:disabled { opacity: 1; cursor: default; }
.ag-step-main { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: 3px; }
.ag-step-top { display: flex; align-items: baseline; gap: 7px; font-size: 13px; min-width: 0; }
.ag-step-top b { font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.ag-label { font: 500 10.5px var(--mono); color: var(--muted); border: 1px solid var(--line-2); border-radius: 999px; padding: 0 5px; flex: none; }
.ag-step-time { margin-left: auto; font: 500 11px var(--mono); color: var(--muted); flex: none; }
.ag-step-line { font: 500 11.5px var(--mono); color: var(--text-2); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.ag-step-out { margin: 2px 0 0; font: 400 10.8px/1.5 var(--mono); color: var(--muted); white-space: pre-wrap; overflow-wrap: anywhere; display: -webkit-box; -webkit-line-clamp: 3; -webkit-box-orient: vertical; overflow: hidden; }
.ag-open { font: 600 10.5px var(--mono); color: var(--signal-text); align-self: center; flex: none; }
.ag-log { margin-top: 10px; border-top: 1px solid var(--line); padding-top: 6px; }
.ag-log > summary { cursor: pointer; font: 600 11.5px var(--font); color: var(--text-2); padding: 4px 2px; list-style: none; }
.ag-log > summary::-webkit-details-marker { display: none; }
.ag-log-name { font: 600 10.5px var(--mono); color: var(--muted); margin: 8px 2px 4px; text-transform: uppercase; letter-spacing: .04em; }
.ag-pre { margin: 0; font: 400 10.8px/1.45 var(--mono); white-space: pre-wrap; overflow-wrap: anywhere; color: var(--text-2); background: var(--code); border-radius: 10px; padding: 8px 10px; max-height: 240px; overflow: auto; }
.ag-note { font-size: 12.5px; color: var(--muted); line-height: 1.45; margin: 10px 2px; }
.ag-note.err { color: var(--danger); }
.ag-card { margin-top: 4px; }
.ag-foot { display: flex; justify-content: flex-end; margin-top: 6px; }
.ag-link { font: 600 12px var(--font); color: var(--signal-text); padding: 4px 0; }
.ag-inline { font: 500 10.5px var(--mono); color: var(--muted); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 44%; flex: none; }
.ag-inline.run { color: var(--signal-text); }
@media (pointer: coarse) { .ag-pre { max-height: none; overflow: visible; } }`;
  document.head.append(css);

  // ------------------------------------------------------------ data
  function query() {
    const q = new URLSearchParams();
    if (A.all) q.set("all", "1");
    else if (S.path) q.set("session", S.path);
    return `/api/subagents?${q}`;
  }

  async function load() {
    clearTimeout(A.timer);
    const seq = ++A.seq;
    A.lastLoad = Date.now();
    try {
      const r = await api(query());
      if (seq !== A.seq) return;
      A.runs = r.runs || []; A.at = r.at || Date.now(); A.total = r.total ?? A.runs.length; A.error = null;
    } catch (e) {
      if (seq === A.seq) A.error = e.message;
    }
    paint();
    poll();
  }

  // Live while something runs or the sheet is open; lazy otherwise. Nothing
  // polls in a hidden tab (visibilitychange below catches up).
  function poll() {
    clearTimeout(A.timer);
    if (document.visibilityState !== "visible") return;
    const ms = A.open || active().length ? 1000 : 15000;
    A.timer = setTimeout(load, ms);
  }

  function sync() {
    if (document.visibilityState !== "visible") return;
    if (Date.now() - A.lastLoad < 350) { clearTimeout(A.timer); A.timer = setTimeout(load, 350); return; }
    load();
  }

  // ------------------------------------------------------------ formatting
  const stateLabel = (s) => ({
    running: "running", starting: "starting", pending: "pending", queued: "queued",
    complete: "done", completed: "done", succeeded: "done",
    failed: "failed", error: "failed", stopped: "stopped", cancelled: "cancelled",
    paused: "needs you", waiting: "waiting",
  }[String(s || "").toLowerCase()] || String(s || "unknown"));
  const stateClass = (s) => {
    const v = String(s || "").toLowerCase();
    if (v.includes("fail") || v === "error") return "err";
    if (v === "paused" || v === "waiting") return "warn";
    if (v === "stopped" || v === "cancelled" || v === "canceled" || v === "aborted") return "idle";
    if (TERMINAL.includes(v)) return "done";
    return "run";
  };
  const modeLabel = (run) => {
    const agents = [...new Set(run.steps.map((s) => s.agent).filter(Boolean))];
    const n = run.steps.length;
    if (run.mode === "workflow") return `Workflow · ${plural(n, "step")}`;
    if (run.mode === "parallel") return `Parallel · ${plural(n, "agent")}`;
    if (run.mode === "chain") return `Chain · ${plural(n, "step")}`;
    return agents.length ? agents.join(" + ") : "Subagent";
  };
  const elapsed = (ms) => (ms == null ? "" : fmtDur(ms));
  // Live times tick locally: an unchanged status file must not re-render the
  // sheet (that would reset its scroll every second).
  function timeAttrs(startedAt, endedAt, durationMs) {
    if (startedAt == null && durationMs == null) return "";
    return ` data-start="${startedAt || 0}" data-end="${endedAt || ""}" data-dur="${durationMs ?? ""}"`;
  }
  function tickTimes() {
    const now = Date.now();
    for (const n of document.querySelectorAll("#sheet-body [data-start]")) {
      const start = Number(n.dataset.start) || 0;
      const end = Number(n.dataset.end) || 0;
      const dur = n.dataset.dur === "" ? null : Number(n.dataset.dur);
      const ms = dur != null ? dur : end ? end - start : now - start;
      n.textContent = ms >= 0 ? fmtDur(ms) : "";
    }
  }
  function stepElapsed(step) {
    if (step.durationMs != null) return fmtDur(step.durationMs);
    if (step.startedAt) return fmtDur(Math.max(0, (A.at || Date.now()) - step.startedAt));
    return "";
  }
  const stepLine = (step) => {
    const t = (step.recentTools || []).slice(-1)[0];
    if (t) return t;
    const out = (step.recentOutput || []).slice(-1)[0];
    return out || (step.status === "pending" ? "waiting for a slot" : "");
  };
  const tokenCount = (t) => (t == null ? "" : fmtTokens(typeof t === "number" ? t : t.total));
  function runMeta(run) {
    const bits = [];
    if (run.tokens) bits.push(fmtTokens(run.tokens) + " tokens");
    if (run.cost) bits.push(fmtCost(run.cost));
    if (run.cwd) bits.push(tilde(run.cwd));
    return bits;
  }

  // ------------------------------------------------------------ painting
  function paint() {
    const chip = $("agents-chip");
    if (chip) {
      const n = active().length;
      // The workflow views have their own header; don't float a chat's runs there.
      const show = n > 0 && (!S.view || S.view === "chat");
      chip.hidden = !show;
      chip.setAttribute("aria-label", `${n} subagent run${n === 1 ? "" : "s"}`);
      if (show) $("agents-count").textContent = n === 1 ? "1 agent" : `${n} agents`;
    }
    if (A.open && A.body) {
      const sig = JSON.stringify(A.runs);
      if (sig !== A.sig) { A.sig = sig; renderSheet(); }
      tickTimes();
    }
    paintCards();
  }

  function link(text, onClick) {
    const b = el("button", "ag-link", esc(text));
    b.type = "button"; b.onclick = onClick; return b;
  }

  function stepRow(run, step) {
    const row = el("button", "ag-step");
    row.type = "button";
    const canOpen = !!(step.sessionFile && typeof openSession === "function");
    if (canOpen) row.onclick = () => { closeSheet(); openSession(step.sessionFile); };
    else row.disabled = true;
    const out = (step.recentOutput || []).slice(-2).join("\n");
    row.innerHTML = `<span class="ag-state ${stateClass(step.status)}"></span>
      <span class="ag-step-main">
        <span class="ag-step-top"><b>${esc(step.agent || "agent")}</b>${step.label ? `<span class="ag-label">${esc(step.label)}</span>` : ""}<span class="ag-step-time"${timeAttrs(step.startedAt, step.endedAt, step.durationMs)}>${esc(stepElapsed(step))}</span></span>
        ${stepLine(step) ? `<span class="ag-step-line">${esc(stepLine(step))}</span>` : ""}
        ${out ? `<span class="ag-step-out">${esc(out)}</span>` : ""}
      </span>${canOpen ? '<span class="ag-open">open ›</span>' : ""}`;
    return row;
  }

  function runCard(run) {
    const det = document.createElement("details");
    det.className = "ag-run" + (isActive(run) ? " live" : "");
    det.open = isActive(run) || A.openRuns.has(run.id);
    det.addEventListener("toggle", () => { det.open ? A.openRuns.add(run.id) : A.openRuns.delete(run.id); });
    const sum = document.createElement("summary");
    sum.innerHTML = `<span class="ag-state ${stateClass(run.state)}"></span>
      <span class="ag-head-main">
        <span class="ag-title">${esc(modeLabel(run))}</span>
        <span class="ag-sub">${esc([stateLabel(run.state), run.tokens ? fmtTokens(run.tokens) + " tokens" : "", run.cost ? fmtCost(run.cost) : ""].filter(Boolean).join(" · "))}</span>
      </span>
      <span class="ag-time"${timeAttrs(run.startedAt, run.endedAt, run.durationMs)}>${esc(elapsed(run.durationMs) || (run.startedAt ? fmtDur(Math.max(0, (A.at || Date.now()) - run.startedAt)) : ""))}</span>`;
    det.append(sum);

    const body = el("div", "ag-body");
    body.append(el("div", "ag-meta", runMeta(run).map((x) => `<span>${esc(x)}</span>`).join("")));
    for (const step of run.steps) body.append(stepRow(run, step));
    if (!run.steps.length) body.append(el("div", "ag-note", "Starting… no step recorded yet."));

    if (isActive(run) || run.steps.some((s) => s.sessionFile)) {
      const log = document.createElement("details");
      log.className = "ag-log";
      log.innerHTML = `<summary>Output tail</summary><div class="ag-log-body"></div>`;
      const box = log.querySelector(".ag-log-body");
      log.addEventListener("toggle", () => { if (log.open) fillLog(box, run.id); });
      body.append(log);
    }
    det.append(body);
    return det;
  }

  async function fillLog(box, id) {
    if (box.dataset.done) return;
    box.dataset.done = "1";
    box.append(el("div", "ag-note", "Reading…"));
    try {
      const r = await api(`/api/subagents/${encodeURIComponent(id)}`);
      box.innerHTML = "";
      const outputs = r.outputs || [];
      if (!outputs.length) return box.append(el("div", "ag-note", "No output log yet."));
      for (const o of outputs) {
        box.append(el("div", "ag-log-name", esc(o.name.replace(/^output-|\.log$/g, "child "))));
        box.append(el("pre", "ag-pre", esc(o.text || "(empty)")));
      }
    } catch (e) {
      box.innerHTML = "";
      box.append(el("div", "ag-note err", esc(e.message)));
    }
  }

  function renderSheet() {
    const b = A.body;
    if (!b) return;
    b.innerHTML = "";
    b.append(el("div", "sheet-title", "Subagents"));
    b.append(el("div", "sheet-sub", A.all ? "Every live and recent pi-subagents run" : "Live and recent runs from this chat"));
    const seg = el("div", "seg");
    for (const [id, label] of [["chat", "This chat"], ["all", "All chats"]]) {
      const on = A.all === (id === "all");
      const btn = el("button", on ? "on" : "", esc(label));
      btn.id = `ag-tab-${id}`;
      btn.onclick = () => { if (A.all === (id === "all")) return; A.all = !A.all; A.sig = ""; load(); renderSheet(); };
      seg.append(btn);
    }
    b.append(seg);

    if (A.error) b.append(el("div", "ag-note err", esc(A.error)));
    const runs = A.runs;
    if (!runs.length) {
      b.append(el("div", "ag-note", A.error ? "" : "No subagent runs here. When pi runs one (a `subagent` tool call), its steps, tool use and output show up here while it works."));
      return;
    }
    const live = runs.filter(isActive), done = runs.filter((r) => !isActive(r));
    if (live.length) {
      b.append(el("div", "sheet-section", `Running · ${live.length}`));
      live.forEach((r) => b.append(runCard(r)));
    }
    if (done.length) {
      b.append(el("div", "sheet-section", `Finished · ${done.length}`));
      done.slice(0, 20).forEach((r) => b.append(runCard(r)));
    }
    b.append(el("div", "ag-note", "Read from pi-subagents' own run files; finished runs are kept for a day."));
  }

  function open() {
    // A chat with no session file yet has no runs of its own to narrow to.
    if (!S.path) A.all = true;
    A.open = true; A.sig = "";
    openSheet((b) => { A.body = b; renderSheet(); });
    load();
  }

  // ------------------------------------------------------------ chat tool cards
  // The card body asks for its run by pi's tool call id. It renders even
  // before the run's status file exists, then fills in on the next poll.
  function cardBody(body, card) {
    if (card.name !== "subagent") return;
    const wrap = el("div", "ag-card");
    card.agBox = wrap;
    fillCard(wrap, card);
    body.append(wrap);
  }

  function fillCard(box, card) {
    box.innerHTML = "";
    const run = byCall(card.id);
    if (!run) {
      box.append(el("div", "ag-note", active().length ? "This run isn't in the status files yet." : "No run recorded for this call."));
    } else {
      for (const step of run.steps) box.append(stepRow(run, step));
      if (!run.steps.length) box.append(el("div", "ag-note", "Starting…"));
    }
    const foot = el("div", "ag-foot");
    foot.append(link("All subagents →", open));
    box.append(foot);
  }

  function paintCards() {
    if (typeof S === "undefined" || !S.cards) return;
    for (const card of S.cards.values()) {
      if (card.name !== "subagent") continue;
      const run = byCall(card.id);
      const inline = card.el.querySelector(".ag-inline");
      if (inline) {
        if (!run) { inline.textContent = ""; inline.className = "ag-inline"; }
        else {
          const step = run.steps.find((s) => s.active) || run.steps[run.steps.length - 1] || {};
          inline.className = "ag-inline " + (isActive(run) ? "run" : "done");
          inline.textContent = `${isActive(run) ? "●" : "✓"} ${step.agent || ""}${isActive(run) ? " · " + elapsed(run.durationMs) : ""}`;
        }
      }
      if (card.agBox && card.agBox.isConnected) fillCard(card.agBox, card);
    }
  }

  // ------------------------------------------------------------ hooks
  function sheetEntry(b) {
    const n = active().length;
    b.append(opt(IC.agents, "Subagents", n ? `${plural(n, "run")} now · progress, logs, child chats` : "Live progress, logs and child chats", open));
  }

  const chip = $("agents-chip");
  if (chip) chip.onclick = open;

  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") sync();
    else clearTimeout(A.timer);
  });

  const sheetWatch = new MutationObserver(() => {
    if (!document.body.classList.contains("sheet-open") && A.open) { A.open = false; A.body = null; }
  });
  sheetWatch.observe(document.body, { attributes: true, attributeFilter: ["class"] });

  setTimeout(load, 250);

  return { open, sync, sheetEntry, cardBody };
})();
