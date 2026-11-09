// Plan mode, todos and permission presets (docs/dsh-features-plan.md §3.2–3.3): the plan and preset chips, the todo dock (pp.status["pp-todo"]), exit_plan_mode / todo_write cards.
// Plugs into app.js through window.pp (see "feature hooks" there); state comes
// from extensions/pocketpi-modes.ts's setStatus("pp-mode" / "pp-todo", JSON).
"use strict";
(() => {
  const pp = window.pp;
  const MI = {
    plan: '<svg viewBox="0 0 24 24"><path d="M8 4h8M6 8h12v12H6z"/><path d="M9 12h6M9 16h4"/></svg>',
    lock: '<svg viewBox="0 0 24 24"><rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/></svg>',
    ask: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="8.5"/><path d="M9.6 9.5a2.5 2.5 0 1 1 3.4 2.3c-.6.3-1 .8-1 1.5v.4M12 16.8v.2"/></svg>',
    auto: '<svg viewBox="0 0 24 24"><path d="M13 3L5 14h6l-1 7 8-11h-6z"/></svg>',
    shield: '<svg viewBox="0 0 24 24"><path d="M12 3l7 3v5c0 4.5-3 8.5-7 10-4-1.5-7-5.5-7-10V6z"/></svg>',
    box: '<svg viewBox="0 0 24 24"><rect x="5" y="5" width="14" height="14" rx="3.5"/></svg>',
    dot: '<svg viewBox="0 0 24 24"><rect x="5" y="5" width="14" height="14" rx="3.5"/><circle cx="12" cy="12" r="2.6" class="fill"/></svg>',
    done: '<svg viewBox="0 0 24 24"><rect x="5" y="5" width="14" height="14" rx="3.5"/><path d="M8.5 12.2l2.4 2.4 4.6-5"/></svg>',
  };
  const PRESETS = [
    { id: "auto", label: "Auto", icon: MI.auto, sub: "pi edits and runs commands without asking (the safety rules still apply)" },
    { id: "ask", label: "Ask", icon: MI.ask, sub: "Each edit, write and command that changes something asks first" },
    { id: "read-only", label: "Read-only", icon: MI.lock, sub: "pi can read and run read-only commands; changes are blocked" },
  ];
  const presetOf = (id) => PRESETS.find((p) => p.id === id) || PRESETS[0];
  const parse = (t) => { try { return t ? JSON.parse(t) : null; } catch { return null; } };
  const modeOf = (chat) => parse(chat?.status?.get("pp-mode")) || { preset: "auto", plan: false, allow: { tools: [], bash: [] } };

  async function setPlan(on, message) {
    try { await pp.control("plan", message ? { on, message } : { on }); toast(on ? "Plan mode on" : "Plan mode off"); }
    catch (e) { toast(e.message, true); }
  }
  async function setPreset(preset) {
    try { await pp.control("mode", { preset }); toast(`Permissions: ${presetOf(preset).label}`); }
    catch (e) { toast(e.message, true); }
  }

  // ---------------------------------------------------------- composer chips
  pp.chips.push((chat) => {
    const m = modeOf(chat);
    if (!m.plan) return null;
    const c = el("button", "chip-btn on mode-plan-chip", `${MI.plan}<span>Plan</span>`);
    c.type = "button";
    c.title = "Plan mode: pi plans and asks before changing anything. Tap to turn it off.";
    c.setAttribute("aria-label", "Plan mode on; turn off");
    c.onclick = () => setPlan(false);
    return c;
  });
  pp.chips.push((chat) => {
    const m = modeOf(chat);
    if (m.preset === "auto" && !m.plan) return null; // keep the composer clean
    const p = presetOf(m.preset);
    const c = el("button", `chip-btn mode-preset-chip preset-${p.id}`, `${p.icon}<span>${esc(p.label)}</span>`);
    c.type = "button";
    c.setAttribute("aria-label", `Permissions: ${p.label}`);
    c.onclick = () => openPermissions();
    return c;
  });

  // ---------------------------------------------------------- chat sheet
  pp.sheet.push((b) => {
    if (!pp.chatInfo().key) return;
    const m = modeOf(pp.chatInfo());
    const plan = opt(MI.plan, "Plan mode", m.plan ? "On · pi plans, then asks you to approve" : "Off · plan first, approve, then build", () => {
      closeSheet(); setPlan(!m.plan);
    });
    if (m.plan) plan.append(el("span", "check", ICON.check));
    b.append(plan);
    b.append(opt(presetOf(m.preset).icon, "Permissions…", esc(presetOf(m.preset).label), () => openPermissions()));
  });

  async function openPermissions() {
    let def = "auto";
    try { def = (await api("/api/features"))?.modes?.defaultPreset || "auto"; } catch {}
    const m = modeOf(pp.chatInfo());
    openSheet((b) => {
      b.append(el("div", "sheet-title", "Permissions"), el("div", "sheet-sub", "For this chat"));
      for (const p of PRESETS) {
        const o = opt(p.icon, esc(p.label), esc(p.sub), () => { closeSheet(); if (p.id !== m.preset) setPreset(p.id); });
        o.classList.add("mode-preset-opt");
        if (p.id === m.preset) o.append(el("span", "check", ICON.check));
        b.append(o);
      }
      const allowed = [...(m.allow?.tools || []), ...(m.allow?.bash || []).map((x) => `${x} …`)];
      if (allowed.length) {
        b.append(el("div", "sheet-section", "Allowed for this chat"));
        const row = el("div", "mode-allowed");
        for (const a of allowed) row.append(el("span", "mode-allow-tag", esc(a)));
        b.append(row);
        b.append(opt(ICON.x, "Forget these", "Ask again next time", async () => {
          closeSheet();
          try { await pp.control("mode", { clearAllow: true }); toast("Allowances cleared"); } catch (e) { toast(e.message, true); }
        }));
      }
      b.append(el("div", "sheet-section", "Default for new chats"));
      const seg = el("div", "seg mode-default-seg");
      for (const p of PRESETS) {
        const btn = el("button", p.id === def ? "on" : "", esc(p.label));
        btn.type = "button";
        btn.onclick = async () => {
          try {
            const all = await api("/api/features").catch(() => ({}));
            await api("/api/features", { key: "modes", value: { ...(all?.modes || {}), defaultPreset: p.id } });
            seg.querySelectorAll("button").forEach((x) => x.classList.toggle("on", x === btn));
            toast(`New chats start in ${p.label}`);
          } catch (e) { toast(e.message, true); }
        };
        seg.append(btn);
      }
      b.append(seg);
      b.append(el("div", "sheet-msg small mode-note", "pocketpi's safety rules (Settings › Safety) apply under every preset: a preset can add questions and blocks, never remove them."));
    });
  }

  // ---------------------------------------------------------- todo dock
  let dockOpen = false;
  const checkbox = (s) => s === "completed" ? MI.done : s === "in_progress" ? MI.dot : MI.box;
  function checklist(todos) {
    const ul = el("ul", "mode-todos");
    for (const t of todos || []) {
      const li = el("li", `todo-${t.status}`, `${checkbox(t.status)}<span>${esc(t.content)}</span>`);
      ul.append(li);
    }
    return ul;
  }
  pp.status["pp-todo"] = (text) => {
    const s = parse(text);
    if (!s || !Array.isArray(s.todos) || !s.todos.length) return null;
    const cur = s.todos.find((t) => t.status === "in_progress") || s.todos.find((t) => t.status === "pending");
    const box = el("div", "mode-dock" + (dockOpen ? " open" : ""));
    const head = el("button", "mode-dock-head",
      `<span class="mode-dock-count">${s.done}/${s.total}</span><span class="mode-dock-cur">${esc(cur ? cur.content : "All done")}</span>${ICON.chev}`);
    head.type = "button";
    head.setAttribute("aria-expanded", String(dockOpen));
    head.setAttribute("aria-label", `Todos: ${s.done} of ${s.total} done${cur ? "; now: " + cur.content : ""}`);
    const list = checklist(s.todos);
    list.hidden = !dockOpen;
    head.onclick = () => {
      dockOpen = !dockOpen; box.classList.toggle("open", dockOpen); list.hidden = !dockOpen;
      head.setAttribute("aria-expanded", String(dockOpen));
    };
    box.append(head, list);
    return box;
  };

  // ---------------------------------------------------------- tool cards
  // The card's one-line summary: the plan's title and the todo count instead
  // of their JSON. toolArgSummary is a global function in app.js, looked up
  // when a card is drawn; wrapping it here saves a hook in app.js.
  const baseSummary = window.toolArgSummary;
  if (typeof baseSummary === "function") {
    window.toolArgSummary = (name, a) => {
      if (name === "exit_plan_mode") return String(a?.plan || "").trim().split("\n")[0].replace(/^#\s*/, "");
      if (name === "todo_write" && Array.isArray(a?.todos)) return `${a.todos.filter((t) => t?.status === "completed").length}/${a.todos.length} done`;
      return baseSummary(name, a);
    };
  }
  const sec = (body, label, node) => { const s = el("div", "tsec"); s.append(el("div", "tlabel", esc(label)), node); body.append(s); };
  const resultText = (a) => (a.result || a.partial) && Array.isArray((a.result || a.partial).content) ? textOf((a.result || a.partial).content) : "";

  pp.tools.exit_plan_mode = (a, body) => {
    const plan = String(a.args?.plan || a.result?.details?.plan || "");
    const doc = el("div", "md mode-plan-md");
    doc.innerHTML = md(plan || "_(no plan)_");
    sec(body, "Plan", doc);
    const outcome = a.result?.details?.outcome;
    const label = outcome === "approved" ? "Approved" : outcome === "keep-planning" ? "Kept planning" : outcome === "dismissed" ? "Not answered" : a.result ? (a.isError ? "Error" : "Result") : "Waiting for approval";
    const t = resultText(a);
    if (t || !a.result) sec(body, label, el("pre", a.isError && outcome !== "keep-planning" ? "mode-err" : "", esc(t || "…")));
    return true;
  };

  pp.tools.todo_write = (a, body) => {
    const todos = a.result?.details?.todos && !a.isError ? a.result.details.todos : a.args?.todos;
    if (Array.isArray(todos) && todos.length) sec(body, `Todos · ${todos.filter((t) => t.status === "completed").length}/${todos.length}`, checklist(todos));
    const t = resultText(a);
    if (t) sec(body, a.isError ? "Error" : "Result", el("pre", a.isError ? "mode-err" : "", esc(t)));
    return true;
  };
})();
