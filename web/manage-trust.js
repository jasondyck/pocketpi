"use strict";
// Settings › Project trust (plan E5). Which projects may load their own .pi
// resources, and what happens for the rest (defaultProjectTrust).
//
// pi keeps decisions in ~/.pi/agent/trust.json: one flat object, canonical
// folder path → true / false (src/pi_resources.rs explains the format). The
// nearest saved decision for a folder or a parent applies. GET /api/pi/trust
// resolves it per project; writes are patches through POST
// /api/pi/config/trust (the key is the path with "." escaped) and
// /api/pi/config/settings.
ppManage.register({
  id: "trust",
  title: "Project trust",
  subtitle: "Which projects may load their own .pi resources",
  icon: '<svg viewBox="0 0 24 24"><path d="M12 3l7 3v5.5c0 4.4-3 8-7 9.5-4-1.5-7-5.1-7-9.5V6z"/><path d="M9 12l2 2 4-4"/></svg>',
  order: 30,
  async render(el, ctx) {
    ctx.style(`.mp-trust .tr-note { font-size: 13.5px; color: var(--text-2); line-height: 1.45; margin: 4px 2px 0; }
.mp-trust .tr-note b { font-weight: 600; color: var(--text); }
.mp-trust .tr-row { padding: 12px 14px; display: flex; flex-direction: column; gap: 8px; }
.mp-trust .tr-row + .tr-row { border-top: 1px solid var(--line); }
.mp-trust .tr-head { display: flex; align-items: baseline; gap: 8px; min-width: 0; }
.mp-trust .tr-name { font-size: 15px; font-weight: 550; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.mp-trust .tr-path { font: 11.5px var(--mono); color: var(--muted); overflow-wrap: anywhere; }
.mp-trust .tr-state { font-size: 12.5px; color: var(--text-2); }
.mp-trust .tr-state.on { color: var(--ok); } .mp-trust .tr-state.off { color: var(--warn); }
.mp-trust .tr-chips { display: flex; flex-wrap: wrap; gap: 5px; }
.mp-trust .seg button { font-family: var(--font); }
.mp-trust .tr-default .opt { border-radius: 0; padding: 12px 14px; }
.mp-trust .tr-default .opt + .opt { border-top: 1px solid var(--line); }
.mp-trust .tr-default .o-s { white-space: normal; }
.mp-trust .tr-radio { width: 20px; height: 20px; border-radius: 50%; border: 1.5px solid var(--line-2); flex: none; display: grid; place-items: center; }
.mp-trust .tr-radio.on { border-color: var(--signal); background: var(--signal); color: var(--signal-ink); }
.mp-trust .tr-radio svg { width: 12px; height: 12px; stroke-width: 3; }
.mp-trust .tr-other { display: flex; align-items: center; gap: 10px; padding: 10px 14px; }
.mp-trust .tr-other + .tr-other { border-top: 1px solid var(--line); }
.mp-trust .tr-other span { flex: 1; min-width: 0; font: 12.5px var(--mono); overflow-wrap: anywhere; }`);
    const { esc } = ctx;
    // A trust.json key as a patch path: "." is the separator, so escape it.
    const key = (p) => p.replace(/\\/g, "\\\\").replace(/\./g, "\\.");
    const CHECK = '<svg viewBox="0 0 24 24"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg>';
    const DEFAULTS = [
      ["ask", "Ask (pi's default)", "pi can't ask over pocketpi, so a project without a decision runs without its .pi resources: they are silently skipped."],
      ["always", "Always trust", "Every project's .pi extensions, skills, prompts, settings and MCP servers load. Only for folders you wrote yourself."],
      ["never", "Never trust", "Projects without a decision never load their .pi resources."],
    ];

    let data;
    async function load() {
      el.innerHTML = '<div class="wf-loading">Loading…</div>';
      try { data = await ctx.api("/api/pi/trust"); } catch (e) { el.innerHTML = `<div class="errbox">${esc(e.message)}</div>`; return; }
      draw();
    }

    async function write(file, patch, done) {
      try {
        await ctx.api(`/api/pi/config/${file}`, patch);
        await ctx.needsRestart();
        if (done) ctx.toast(done);
      } catch (e) { ctx.toast(e.message, true); }
      await load();
    }

    function setDecision(path, choice) {
      const patch = choice === "default" ? { unset: [key(path)] } : { set: { [key(path)]: choice === "trust" } };
      write("trust", patch, choice === "default" ? "Decision removed" : choice === "trust" ? "Trusted" : "Not trusted");
    }

    function stateLine(p) {
      const via = p.from && !p.explicit ? ` (from ${p.from === ctx.home ? "~" : p.from.replace(ctx.home + "/", "~/")})` : "";
      if (p.decision === true) return ["on", `Trusted${via}: its .pi resources load`];
      if (p.decision === false) return ["off", `Not trusted${via}: its .pi resources are skipped`];
      return data.default === "always" ? ["on", "No decision: loads (default is always)"] : ["off", `No decision: skipped (default is ${data.default})`];
    }

    function draw() {
      el.innerHTML = "";
      el.append(ctx.el("div", "tr-note", "A project's <b>.pi</b> folder can hold extensions (code that runs inside pi), skills, prompts, settings and MCP servers. pi only loads them for trusted projects. AGENTS.md and CLAUDE.md load either way."));
      if (data.error) el.append(ctx.el("div", "errbox", `${esc(data.error)} pocketpi won't change it until it is fixed.`));

      el.append(ctx.el("div", "wf-section", "Projects without a decision"));
      const dcard = ctx.el("div", "wf-card tr-default");
      for (const [v, t, s] of DEFAULTS) {
        const on = data.default === v;
        const row = ctx.el("button", "opt", `<span class="tr-radio${on ? " on" : ""}">${on ? CHECK : ""}</span><div class="o-main"><div class="o-t">${esc(t)}</div><div class="o-s">${esc(s)}</div></div>`);
        row.dataset.default = v;
        row.onclick = () => { if (!on) write("settings", v === "ask" ? { unset: ["defaultProjectTrust"] } : { set: { defaultProjectTrust: v } }, `Default: ${t}`); };
        dcard.append(row);
      }
      el.append(dcard);

      el.append(ctx.el("div", "wf-section", "Projects"));
      const card = ctx.el("div", "wf-card");
      const projects = data.projects || [];
      for (const p of projects) {
        const row = ctx.el("div", "tr-row");
        row.dataset.path = p.path;
        const [cls, line] = stateLine(p);
        row.append(ctx.el("div", "tr-head", `<span class="tr-name">${esc(p.name || p.path)}</span>`));
        row.append(ctx.el("div", "tr-path", esc(p.canonical)));
        row.append(ctx.el("div", `tr-state ${cls}`, esc(line)));
        if (p.needsTrust) {
          const chips = ctx.el("div", "tr-chips");
          for (const r of p.protected) chips.append(ctx.el("span", "chip", esc(r.startsWith("/") ? r.replace(ctx.home + "/", "~/") : r)));
          row.append(chips);
        } else {
          row.append(ctx.el("div", "tr-path", "Nothing in it needs trust right now."));
        }
        const choice = p.explicit ? (p.decision ? "trust" : "distrust") : "default";
        const seg = ctx.el("div", "seg");
        for (const [v, t] of [["trust", "Trust"], ["distrust", "Don't trust"], ["default", p.from && !p.explicit ? "Inherit" : "No decision"]]) {
          const b = ctx.el("button", v === choice ? "on" : "", esc(t));
          b.dataset.choice = v;
          b.onclick = () => { if (v !== choice) setDecision(p.canonical, v); };
          seg.append(b);
        }
        row.append(seg);
        card.append(row);
      }
      if (!projects.length) card.append(ctx.el("div", "list-empty", "No projects yet."));
      el.append(card);

      // Decisions for folders that aren't projects here (parents, old paths).
      const shown = new Set(projects.map((p) => p.canonical));
      const others = Object.entries(data.entries || {}).filter(([k, v]) => !shown.has(k) && v !== null);
      if (others.length) {
        el.append(ctx.el("div", "wf-section", "Other saved decisions"));
        const oc = ctx.el("div", "wf-card");
        for (const [k, v] of others) {
          const r = ctx.el("div", "tr-other", `<span>${esc(k)}</span><b class="tr-state ${v ? "on" : "off"}">${v ? "trusted" : "not trusted"}</b>`);
          const rm = ctx.el("button", "btn small secondary", "Remove");
          rm.onclick = () => setDecision(k, "default");
          r.append(rm);
          oc.append(r);
        }
        el.append(oc);
      }
      el.append(ctx.el("div", "tr-note", `Saved in <span class="tr-path">${esc(data.path)}</span>. A decision for a folder also covers the folders inside it. Chats pick changes up when they restart.`));
    }

    await load();
  },
});
