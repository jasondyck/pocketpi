"use strict";
// Settings › Safety: @gotgenes/pi-permission-system (docs/pi-parity-plan.md §6).
// Whether it's installed, its policy for chats (pi's own
// extensions/pi-permission-system/config.json, so the terminal's pi uses it
// too), each project's Off / Ask / Strict, and the policy workflow stages
// run under (pocketpi's ~/.config/pocketpi/safety/stage-policy.json).
// Rule lists are ordered: the last matching rule wins. The server hands them
// out as `rules: {surface: [[pattern, action], ...]}` and takes them back
// that way (src/pi_admin.rs). The iOS twin is SettingsSafetyPage.swift.
(() => {
  const ACTIONS = ["allow", "ask", "deny"];
  const MAIN = ["bash", "path", "external_directory"];
  const DIRECTIONAL = ["path_read", "path_write", "external_directory_read", "external_directory_write"];
  const LABEL = {
    bash: "Commands (bash)", path: "Files (path)", external_directory: "Outside the project",
    path_read: "Reading files", path_write: "Writing files",
    external_directory_read: "Reading outside the project", external_directory_write: "Writing outside the project",
  };
  const MODES = {
    standard: ["Ask", "The global policy: asks before risky commands."],
    off: ["Off", "Never asks: what would ask is allowed. Hard denies (secrets, sudo) still apply."],
    strict: ["Strict", "Asks before every command, write and edit, unless a global rule allows it by name."],
    custom: ["Custom", "This project's policy file has its own rules."],
  };
  const expanded = new Set();
  const STRICT_KEYS = ["permission.bash.*", "permission.write", "permission.edit"];

  const isInstalled = (settings) => (settings?.packages || []).some((p) => String(typeof p === "string" ? p : p?.source || "").includes("@gotgenes/pi-permission-system"));

  // A surface's rules: the ordered pairs, or a plain action as `* -> action`.
  function rulesOf(doc, surface) {
    if (doc.rules?.[surface]) return doc.rules[surface].map(([pattern, v]) => typeof v === "string" ? { pattern, action: v } : { pattern, action: v?.action || "deny", reason: v?.reason });
    const s = doc.data?.permission?.[surface];
    return typeof s === "string" ? [{ pattern: "*", action: s }] : [];
  }
  const pairs = (rules) => rules.filter((r) => r.pattern.trim()).map((r) => [r.pattern, r.action === "deny" && r.reason?.trim() ? { action: "deny", reason: r.reason.trim() } : r.action]);

  function summary(rules) {
    if (!rules.length) return "not set (uses the default)";
    const parts = [];
    const fallback = [...rules].reverse().find((r) => r.pattern === "*");
    if (fallback) parts.push(`${fallback.action} by default`);
    for (const a of ACTIONS) { const n = rules.filter((r) => r.pattern !== "*" && r.action === a).length; if (n) parts.push(`${n} ${a}`); }
    return parts.join(" · ");
  }

  function modeOf(doc) {
    if (!doc?.exists) return "standard";
    const d = doc.data || {}, p = d.permission || {};
    if (d.yoloMode === true) return "off";
    const bashAsks = p.bash === "ask" || p.bash?.["*"] === "ask";
    if (bashAsks && p.write === "ask" && p.edit === "ask") return "strict";
    const managed = "yoloMode" in d || (p.bash && (typeof p.bash === "string" || "*" in p.bash)) || "write" in p || "edit" in p;
    const other = Object.keys(d).some((k) => !["$schema", "permission", "yoloMode"].includes(k))
      || Object.values(p).some((v) => !(v && typeof v === "object" && !Object.keys(v).length));
    return managed || other ? "custom" : "standard";
  }
  function modePatch(mode) {
    if (mode === "off") return { set: { yoloMode: true }, unset: STRICT_KEYS };
    if (mode === "strict") return { set: { "permission.bash.*": "ask", "permission.write": "ask", "permission.edit": "ask" }, unset: ["yoloMode"] };
    return { set: {}, unset: ["yoloMode", ...STRICT_KEYS] };
  }
  // pi's trust.json: the nearest saved decision for the folder or a parent.
  function trusted(path, trust, def) {
    let d = path.length > 1 ? path.replace(/\/$/, "") : path;
    for (;;) {
      if (typeof trust?.[d] === "boolean") return trust[d];
      if (d === "/" || !d.includes("/")) break;
      d = d.slice(0, d.lastIndexOf("/")) || "/";
    }
    return def === "always";
  }
  const timeoutText = (ms) => !ms ? "Unanswered prompts wait forever" : ms % 60000 === 0 ? `Unanswered prompts are denied after ${ms / 60000} min` : `Unanswered prompts are denied after ${Math.round(ms / 1000)} s`;

  ppManage.register({
    id: "safety",
    title: "Safety",
    subtitle: "What pi may run without asking",
    icon: '<svg viewBox="0 0 24 24"><path d="M12 3l7.5 3v5.5c0 4.6-3.2 8.3-7.5 9.5-4.3-1.2-7.5-4.9-7.5-9.5V6z"/><path d="M8.8 12.2l2.3 2.3 4.3-4.6"/></svg>',
    order: 50,
    async render(el, ctx) {
      ctx.style(`.mp-safety .sf-note { font-size: 13px; color: var(--text-2); margin: 8px 2px 0; line-height: 1.45; }
.mp-safety .sf-row { display: flex; align-items: center; gap: 10px; padding: 11px 14px; font-size: 14.5px; }
.mp-safety .sf-row + .sf-row, .mp-safety .sf-rule + .sf-rule, .mp-safety .sf-add { border-top: 1px solid var(--line); }
.mp-safety .sf-row .sf-main { flex: 1; min-width: 0; }
.mp-safety .sf-row .sf-sub { font-size: 12.5px; color: var(--muted); overflow-wrap: anywhere; }
.mp-safety .sf-ok { color: var(--text); font-weight: 600; }
.mp-safety .sf-head { display: flex; align-items: center; justify-content: space-between; gap: 8px; padding: 12px 10px 12px 14px; width: 100%; text-align: left; }
.mp-safety .sf-head .mp-chev { flex: none; transition: transform .2s; } .mp-safety .sf-card.open .sf-head .mp-chev { transform: rotate(90deg); }
.mp-safety .sf-card.open .sf-head { border-bottom: 1px solid var(--line); }
.mp-safety .sf-head b { font-weight: 600; font-size: 14.5px; }
.mp-safety .sf-head span { flex: 1; font: 11.5px var(--mono); color: var(--muted); text-align: right; }
.mp-safety .sf-rule { display: flex; align-items: center; gap: 8px; padding: 6px 8px 6px 14px; }
.mp-safety .sf-rule code { flex: 1; min-width: 0; font: 13px var(--mono); overflow-wrap: anywhere; }
.mp-safety .sf-rule small { display: block; font: 11.5px var(--font); color: var(--muted); }
.mp-safety select { font: 500 12.5px var(--mono); height: 30px; border-radius: 9px; border: 1px solid var(--line-2); background: var(--bg); color: var(--text); padding: 0 6px; }
.mp-safety select.deny { color: var(--danger); } .mp-safety select.ask { color: var(--warn); }
.mp-safety .sf-x { width: 30px; height: 30px; display: grid; place-items: center; color: var(--muted); border-radius: 9px; flex: none; }
.mp-safety .sf-x svg { width: 15px; height: 15px; }
.mp-safety .sf-add { display: flex; gap: 6px; padding: 8px; }
.mp-safety .sf-add input { flex: 1; min-width: 0; height: 34px; border-radius: 10px; border: 1px solid var(--line-2); background: var(--bg); padding: 0 10px; font: 13px var(--mono); }
.mp-safety .sf-add .btn { height: 34px; padding: 0 12px; font-size: 13.5px; border-radius: 10px; }
.mp-safety .sf-card { margin-top: 10px; }
.mp-safety .sf-proj .seg { margin-top: 8px; }
.mp-safety .sf-warn { color: var(--warn); }`);
      el.append(ctx.el("div", "wf-loading", "Loading…"));
      const q = (cwd) => cwd ? `?cwd=${encodeURIComponent(cwd)}` : "";
      const [settings, chats, stages, info, trust, projects] = await Promise.all([
        ctx.api("/api/pi/config/settings"),
        ctx.api("/api/pi/config/permissions"),
        ctx.api("/api/pi/config/stage-policy"),
        ctx.api("/api/safety"),
        ctx.api("/api/pi/config/trust").catch(() => ({ data: {} })),
        ctx.api("/api/projects").catch(() => ({ projects: [] })),
      ]);
      el.innerHTML = "";
      const installed = isInstalled(settings.data);

      // ---- status and install
      el.append(ctx.el("div", "wf-section", "Permission system"));
      const card = ctx.el("div", "wf-card");
      const status = ctx.el("div", "sf-row", `<div class="sf-main"><div>@gotgenes/pi-permission-system</div><div class="sf-sub">${installed
        ? `<span class="sf-ok">Installed</span> · ${chats.exists ? ctx.esc(timeoutText(chats.data?.promptTimeoutMs)) : "no policy yet: everything asks"}`
        : "Not installed: pi runs every command without asking"}</div></div>`);
      status.dataset.k = "status";
      card.append(status);
      const act = ctx.el("div", "sf-row");
      const busy = (b, text) => { b.disabled = true; b.textContent = text; };
      if (!installed) {
        const b = ctx.el("button", "btn", "Install with recommended policy");
        b.onclick = async () => {
          busy(b, "Installing…");
          try {
            const { id } = await ctx.api("/api/pi/jobs", { action: "install", source: info.package });
            let job;
            for (;;) { await new Promise((r) => setTimeout(r, 600)); job = (await ctx.api(`/api/pi/jobs/${id}`)).job; if (job.status !== "running") break; }
            if (job.status !== "ok") throw new Error(`pi install failed: ${(job.output || "").trim().split("\n").slice(-3).join(" ")}`);
            await ctx.api("/api/safety/recommended", { file: "permissions" });
            ctx.toast("Installed. Restart chats to load it.");
            await ctx.needsRestart();
          } catch (e) { ctx.toast(e.message, true); }
          ctx.rerender();
        };
        act.append(b);
      } else if (!chats.exists) {
        const b = ctx.el("button", "btn", "Use the recommended policy");
        b.onclick = async () => { busy(b, "Writing…"); try { await ctx.api("/api/safety/recommended", { file: "permissions" }); } catch (e) { ctx.toast(e.message, true); } ctx.rerender(); };
        act.append(b);
      }
      if (act.childNodes.length) card.append(act);
      el.append(card);
      el.append(ctx.el("div", "sf-note", "This is pi's own policy file, so it applies to pi in the terminal too, not only to chats here. When pi asks and nobody has the chat open, your phone gets a notification. Changes apply from pi's next tool call."));

      // ---- rule lists
      // Collapsed to its summary until tapped (the bash list is long).
      function ruleCard(doc, surface, file, cwd) {
        let rules = rulesOf(doc, surface);
        const c = ctx.el("div", "wf-card sf-card");
        c.dataset.surface = surface;
        const id = `${file}:${surface}`;
        const draw = () => {
          c.innerHTML = "";
          const open = expanded.has(id);
          c.classList.toggle("open", open);
          const head = ctx.el("button", "sf-head", `<b>${ctx.esc(LABEL[surface] || surface)}</b><span>${ctx.esc(summary(rules))}</span><span class="mp-chev">${ctx.ICON.chev}</span>`);
          head.onclick = () => { if (open) expanded.delete(id); else expanded.add(id); draw(); };
          c.append(head);
          if (!open) return;
          const save = async (next) => {
            try {
              const d = await ctx.api(`/api/pi/config/${file}${q(cwd)}`, { set: { [`permission.${surface}`]: pairs(next) } });
              rules = rulesOf(d, surface);
            } catch (e) { ctx.toast(e.message, true); }
            draw();
          };
          rules.forEach((r, i) => {
            const row = ctx.el("div", "sf-rule", `<code>${ctx.esc(r.pattern)}${r.reason ? `<small>${ctx.esc(r.reason)}</small>` : ""}</code>`);
            const sel = ctx.el("select", r.action);
            for (const a of ACTIONS) { const o = ctx.el("option", "", a); o.value = a; sel.append(o); }
            sel.value = r.action;
            sel.onchange = () => save(rules.map((x, j) => j === i ? { ...x, action: sel.value } : x));
            const x = ctx.el("button", "sf-x", ctx.ICON.x); x.title = "Remove"; x.setAttribute("aria-label", `Remove ${r.pattern}`);
            x.onclick = () => save(rules.filter((_, j) => j !== i));
            row.append(sel, x);
            c.append(row);
          });
          const add = ctx.el("div", "sf-add");
          const input = ctx.el("input"); input.placeholder = surface === "bash" ? "git push *" : "~/secrets/*";
          input.setAttribute("autocapitalize", "off"); input.spellcheck = false;
          const sel = ctx.el("select", "ask");
          for (const a of ACTIONS) { const o = ctx.el("option", "", a); o.value = a; sel.append(o); }
          sel.value = "ask"; sel.onchange = () => (sel.className = sel.value);
          const b = ctx.el("button", "btn secondary", "Add");
          b.onclick = () => { if (input.value.trim()) save([...rules.filter((r) => r.pattern !== input.value.trim()), { pattern: input.value.trim(), action: sel.value }]); };
          input.onkeydown = (e) => { if (e.key === "Enter") b.click(); };
          add.append(input, sel, b);
          c.append(add);
        };
        draw();
        return c;
      }
      // The directional surfaces only when the file uses them (the stage
      // policy does), and then not the bare one they replace unless it's set.
      const surfacesOf = (doc) => {
        const p = doc.data?.permission || {};
        const dir = DIRECTIONAL.filter((s) => p[s] !== undefined);
        return [...MAIN.filter((m) => p[m] !== undefined || !dir.some((d) => d.startsWith(m + "_"))), ...dir];
      };

      if (installed || chats.exists) {
        el.append(ctx.el("div", "wf-section", "Chats"));
        for (const s of surfacesOf(chats)) el.append(ruleCard(chats, s, "permissions"));
        el.append(ctx.el("div", "sf-note", "Later rules win. A pattern's * matches anything, slashes included; ~ is your home folder."));
      }

      // ---- projects
      el.append(ctx.el("div", "wf-section", "Projects"));
      const pc = ctx.el("div", "wf-card sf-proj");
      const defTrust = settings.data?.defaultProjectTrust;
      const list = (projects.projects || []).slice(0, 30);
      if (!list.length) pc.append(ctx.el("div", "list-empty", "No projects yet."));
      const docs = await Promise.all(list.map((p) => ctx.api(`/api/pi/config/permissions${q(p.path)}`).catch(() => null)));
      list.forEach((p, i) => {
        let doc = docs[i];
        const ok = trusted(p.path, trust.data, defTrust);
        const row = ctx.el("div", "sf-row");
        row.dataset.project = p.path;
        const draw = () => {
          const m = modeOf(doc);
          row.innerHTML = `<div class="sf-main"><div>${ctx.esc(p.name || p.path.split("/").pop())}</div><div class="sf-sub">${ctx.esc(MODES[m][1])}${ok ? "" : ` <span class="sf-warn">Not trusted: pi ignores this project's policy, so the global one applies.</span>`}</div></div>`;
          const seg = ctx.el("div", "seg");
          for (const k of ["off", "standard", "strict"]) {
            const b = ctx.el("button", m === k ? "on" : "", MODES[k][0]);
            b.onclick = async () => {
              try { doc = await ctx.api(`/api/pi/config/permissions${q(p.path)}`, modePatch(k)); } catch (e) { ctx.toast(e.message, true); }
              draw();
            };
            seg.append(b);
          }
          row.querySelector(".sf-main").append(seg);
        };
        draw();
        pc.append(row);
      });
      el.append(pc);
      el.append(ctx.el("div", "sf-note", "A project's policy lives in its .pi/extensions/pi-permission-system/config.json and only counts once pi trusts the project (Settings › Trust). It changes the global policy for that project; Off keeps the hard denies."));

      // ---- workflow stages
      el.append(ctx.el("div", "wf-section", "Workflow stages"));
      const sc = ctx.el("div", "wf-card");
      sc.append(ctx.el("div", "sf-row", `<div class="sf-main"><div>${stages.exists ? "Own policy" : "Same policy as chats"}</div><div class="sf-sub">${stages.exists
        ? `Stages can't answer questions, so this policy never asks. ${ctx.esc(stages.path)}`
        : "Stages can't answer questions: whatever would ask is denied. A stage policy allows normal build, test and commit work and denies the dangerous things."}</div></div>`));
      if (!stages.exists) {
        const r = ctx.el("div", "sf-row");
        const b = ctx.el("button", "btn", "Use the recommended stage policy");
        b.onclick = async () => { busy(b, "Writing…"); try { await ctx.api("/api/safety/recommended", { file: "stage-policy" }); } catch (e) { ctx.toast(e.message, true); } ctx.rerender(); };
        r.append(b); sc.append(r);
      }
      el.append(sc);
      if (stages.exists) for (const s of surfacesOf(stages)) el.append(ruleCard(stages, s, "stage-policy"));
    },
  });
})();
