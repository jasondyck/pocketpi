// Goal mode (docs/dsh-features-plan.md §3.1): the goal strip (pp.status["pp-goal"]), "Start a goal…" in the chat sheet.
// Filled in by its wave; plugs into app.js through window.pp (see "feature hooks" there).
//
// The state comes from extensions/pocketpi-goal.ts as JSON in the "pp-goal"
// status: {id, revision, objective, phase, rounds, maxRounds, cost, maxCost,
// blockedReason, armed}. Commands go through pp.control("goal", {action, …}).
// Defaults (rounds and cost cap) live in features.json under "goal"
// (GET/POST /api/features). Uses app.js's globals (S, api, el, esc, opt,
// openSheet, closeSheet, toast, fmtCost).
"use strict";
window.ppGoal = (() => {
  const FLAG = '<svg viewBox="0 0 24 24"><path d="M5 21V4M5 4h11l-2 4 2 4H5"/></svg>';
  const parse = (t) => { try { const g = JSON.parse(t); return g && typeof g === "object" ? g : null; } catch { return null; } };
  const current = () => parse(pp.chatInfo().status.get("pp-goal"));
  const money = (c) => "$" + (Number(c) || 0).toFixed(2);

  /** The phase as a person reads it. */
  function phaseLabel(g) {
    if (g.phase === "active") return g.armed ? "Running" : "Waiting";
    if (g.phase === "blocked") {
      if (g.blockedReason === "round-limit") return "Round cap reached";
      if (g.blockedReason === "cost-limit") return "Cost cap reached";
      return "Blocked";
    }
    return g.phase === "complete" ? "Complete" : "Paused";
  }
  const phaseClass = (g) => (g.phase === "active" ? (g.armed ? "run" : "wait") : g.phase);

  async function act(args, msg) {
    try { const r = await pp.control("goal", args); if (msg) toast(msg); return r; } catch (e) { toast(e.message, true); return null; }
  }
  const pauseResume = (g) => (g.phase === "complete" ? null : g.phase === "active" && g.armed ? "pause" : "resume");
  function clearGoal() {
    if (!confirm("Clear this chat's goal?")) return false;
    act({ action: "clear" }, "Goal cleared"); return true;
  }

  // ------------------------------------------------------------ strip
  pp.status["pp-goal"] = (text) => {
    const g = parse(text); if (!g) return null;
    const s = el("div", "goal-strip " + phaseClass(g));
    const main = el("button", "goal-main");
    main.title = g.objective;
    main.innerHTML = `<span class="goal-dot"></span><span class="goal-obj">${esc(g.objective)}</span>`;
    main.onclick = () => openGoalSheet();
    const meta = el("div", "goal-meta");
    const why = g.phase === "blocked" && !["round-limit", "cost-limit"].includes(g.blockedReason) && g.blockedReason ? ` · ${esc(g.blockedReason)}` : "";
    meta.innerHTML = `<span class="goal-phase">${esc(phaseLabel(g))}${why}</span><span>Round ${g.rounds}/${g.maxRounds}</span><span>${money(g.cost)} of ${money(g.maxCost)}</span>`;
    const btns = el("span", "goal-btns");
    const pr = pauseResume(g);
    if (pr) {
      const b = el("button", "chip-btn", pr === "pause" ? "Pause" : "Resume");
      b.onclick = () => act({ action: pr }, pr === "pause" ? "Goal paused" : "Goal resumed");
      btns.append(b);
    }
    const c = el("button", "chip-btn", "Clear"); c.onclick = () => clearGoal(); btns.append(c);
    meta.append(btns);
    s.append(main, meta);
    return s;
  };

  // ------------------------------------------------------------ chat sheet entry
  pp.sheet.push((b) => {
    if (!S.key && !S.path) return;
    const g = current();
    b.append(opt(FLAG, g ? "Goal…" : "Start a goal…",
      g ? esc(`${phaseLabel(g)} · round ${g.rounds}/${g.maxRounds} · ${g.objective}`) : "pi keeps working in rounds until it's done",
      () => openGoalSheet()));
  });

  async function defaults() {
    try { const f = await api("/api/features"); return { maxRounds: f.goal?.maxRounds ?? 30, maxCost: f.goal?.maxCost ?? 5 }; } catch { return { maxRounds: 30, maxCost: 5 }; }
  }
  function numField(label, value, step) {
    const w = el("label", "goal-num"); w.append(el("span", "", esc(label)));
    const i = el("input"); i.type = "number"; i.min = step < 1 ? "0.01" : "1"; i.step = String(step); i.inputMode = step < 1 ? "decimal" : "numeric"; i.value = value;
    w.append(i); return [w, i];
  }

  /** Start a goal, or look at and change the one this chat has. */
  async function openGoalSheet() {
    const g = current();
    const d = g ? { maxRounds: g.maxRounds, maxCost: g.maxCost } : await defaults();
    openSheet((root) => {
      const b = el("div", "goal-sheet"); root.append(b);
      b.append(el("div", "sheet-title", g ? "Goal" : "Start a goal"));
      b.append(el("div", "sheet-sub", g
        ? esc(`${phaseLabel(g)} · round ${g.rounds}/${g.maxRounds} · ${money(g.cost)} of ${money(g.maxCost)}`)
        : "pi works on the objective in rounds until it marks it complete, gets blocked, or hits a cap."));
      b.append(el("div", "sheet-section", "Objective"));
      const f = el("div", "field"); const obj = el("textarea", "input-area"); obj.rows = 4; obj.value = g?.objective || "";
      obj.placeholder = "What should be true when pi is done?"; f.append(obj); b.append(f);
      b.append(el("div", "sheet-section", "Caps"));
      const caps = el("div", "goal-caps");
      const [rw, rounds] = numField("Max rounds", d.maxRounds, 1);
      const [cw, cost] = numField("Max cost ($)", d.maxCost, 0.5);
      caps.append(rw, cw); b.append(caps);
      let saveDef = null;
      if (!g) {
        const l = el("label", "goal-default"); saveDef = el("input"); saveDef.type = "checkbox";
        l.append(saveDef, el("span", "", "Save caps as the default for new goals")); b.append(l);
      }
      const read = () => {
        const r = parseInt(rounds.value, 10), c = parseFloat(cost.value);
        if (!(r >= 1)) { toast("Max rounds must be at least 1", true); return null; }
        if (!(c > 0)) { toast("Max cost must be more than $0", true); return null; }
        return { maxRounds: r, maxCost: c };
      };
      const row = el("div", "btn-row");
      if (g) {
        const pr = pauseResume(g);
        const clear = el("button", "btn danger", "Clear"); clear.onclick = () => { if (clearGoal()) closeSheet(); };
        row.append(clear);
        if (pr) {
          const p = el("button", "btn secondary", pr === "pause" ? "Pause" : "Resume");
          p.onclick = async () => { closeSheet(); await act({ action: pr }, pr === "pause" ? "Goal paused" : "Goal resumed"); };
          row.append(p);
        }
        const save = el("button", "btn", "Save");
        save.onclick = async () => {
          const caps = read(); if (!caps) return;
          const o = obj.value.trim(); if (!o) return toast("The objective can't be empty", true);
          const args = { action: "edit", id: g.id, revision: g.revision, ...caps };
          if (o !== g.objective) args.objective = o;
          if (await act(args, "Goal saved")) closeSheet();
        };
        row.append(save);
      } else {
        const start = el("button", "btn", "Start");
        start.onclick = async () => {
          const caps = read(); if (!caps) return;
          const o = obj.value.trim(); if (!o) return toast("Write the objective first", true);
          if (saveDef?.checked) {
            try { await api("/api/features", { key: "goal", value: caps }); } catch (e) { toast(e.message, true); return; }
          }
          if (await act({ action: "create", objective: o, ...caps }, "Goal started")) closeSheet();
        };
        row.append(start);
      }
      b.append(row);
      if (!g) setTimeout(() => obj.focus(), 300);
    });
  }

  // ------------------------------------------------------------ tool cards
  function toolCard(api, body) {
    const r = api.result || api.partial;
    if (!r) return false;
    if (api.isError) return false; // the default card shows the error text
    const g = r.details?.goal;
    const a = api.args || {};
    const head = api.name === "goal_update" ? `${a.action || "update"}` : api.name === "goal_create" ? "created" : "read";
    const box = el("div", "goal-card");
    if (!g) { box.append(el("div", "goal-card-line", "No goal in this chat.")); body.append(box); return true; }
    box.innerHTML = `<div class="goal-card-line"><span class="goal-card-act">${esc(head)}</span> ${esc(phaseLabel(g))}${g.blockedReason && !["round-limit", "cost-limit"].includes(g.blockedReason) ? ` · ${esc(g.blockedReason)}` : ""}</div>
      <div class="goal-card-obj">${esc(g.objective)}</div>
      <div class="goal-card-meta">Round ${g.rounds}/${g.maxRounds} · ${money(g.cost)} of ${money(g.maxCost)} · rev ${g.revision}</div>`;
    body.append(box);
    return true;
  }
  for (const n of ["goal_get", "goal_create", "goal_update"]) pp.tools[n] = toolCard;

  return { open: openGoalSheet };
})();
