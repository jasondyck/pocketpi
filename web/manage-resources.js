"use strict";
// Settings › Resources (plan F1, F2): pi's extensions, skills and prompt
// templates for a project, with where each comes from (global, project,
// package, built-in) and whether it loads, each with an on/off switch.
// Data: GET /api/pi/resources?cwd= (src/pi_resources.rs), which scans the
// folders and settings like pi does, asks `pi list` for packages and, when
// a chat is open in the project, that pi's get_commands. Switches go to
// POST /api/pi/resources/toggle (src/pi_packages.rs), which writes the
// `+`/`-` entries `pi config` would; a global resource can also be turned
// on or off in one project only (from its details).
ppManage.register({
  id: "resources",
  title: "Resources",
  subtitle: "Extensions, skills and prompt templates",
  icon: '<svg viewBox="0 0 24 24"><path d="M12 3l8 4.5-8 4.5-8-4.5z"/><path d="M4 12l8 4.5 8-4.5"/><path d="M4 16.5l8 4.5 8-4.5"/></svg>',
  order: 40,
  async render(el, ctx) {
    ctx.style(`.mp-resources .rs-pick { border-radius: 0; padding: 12px 14px; }
.mp-resources .rs-note { font-size: 13px; color: var(--text-2); line-height: 1.45; margin: 10px 2px 0; }
.mp-resources .rs-note.warn { color: var(--warn); }
.mp-resources .rs-note button { color: var(--text); text-decoration: underline; font: inherit; }
.mp-resources .seg { margin-top: 14px; }
.mp-resources .seg button { font-family: var(--font); }
.mp-resources .rs-row { display: flex; align-items: center; gap: 10px; padding-right: 14px; }
.mp-resources .rs-row + .rs-row { border-top: 1px solid var(--line); }
.mp-resources .rs-main { display: block; flex: 1; min-width: 0; text-align: left; padding: 11px 0 11px 14px; }
.mp-resources .rs-main:active { background: var(--surface); }
.mp-resources .rs-row .switch:disabled { opacity: .5; }
.rs-scope { margin-top: 14px; }
.rs-scope .seg { margin-top: 8px; }
.rs-scope .rs-note { margin-top: 6px; }
.mp-resources .rs-t { display: flex; align-items: baseline; gap: 8px; min-width: 0; }
.mp-resources .rs-name { font: 500 14.5px var(--mono); letter-spacing: -0.02em; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.mp-resources .rs-hint { font: 12px var(--mono); color: var(--muted); white-space: nowrap; }
.mp-resources .rs-row.off .rs-name { color: var(--muted); text-decoration: line-through; }
.mp-resources .rs-d { font-size: 13px; color: var(--text-2); margin-top: 2px; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
.mp-resources .rs-chips { display: flex; flex-wrap: wrap; gap: 4px; margin-top: 6px; }
.mp-resources .rs-chips .chip { font-size: 11px; padding: 2px 8px; }
.mp-resources .chip.on { color: var(--ok); }
.mp-resources .rs-pkg { padding: 10px 14px; font: 12.5px var(--mono); overflow-wrap: anywhere; }
.mp-resources .rs-pkg + .rs-pkg { border-top: 1px solid var(--line); }
.mp-resources .rs-pkg div { color: var(--muted); font-size: 11.5px; margin-top: 2px; }
.rs-detail { font-size: 14px; display: grid; grid-template-columns: auto 1fr; gap: 6px 12px; margin: 6px 0 4px; }
.rs-detail b { color: var(--muted); font-weight: 500; font-size: 12.5px; }
.rs-detail span { font: 12.5px var(--mono); overflow-wrap: anywhere; }`);
    const { esc } = ctx;
    const tilde = (p) => (p && ctx.home && p.startsWith(ctx.home + "/") ? "~" + p.slice(ctx.home.length) : p || "");
    const KINDS = [["extension", "Extensions", "Extensions"], ["skill", "Skills", "Skills"], ["prompt", "Prompt templates", "Prompts"]];
    const SCOPES = { global: "global", project: "project", package: "package", builtin: "built-in", temporary: "-e" };
    let project = ctx.project || "";
    let filter = "all";
    let projects = [];
    let data = null;

    async function load(quiet = false) {
      if (!quiet) el.innerHTML = '<div class="wf-loading">Loading…</div>';
      try {
        const q = project ? `?cwd=${encodeURIComponent(project)}` : "";
        [data, projects] = await Promise.all([
          ctx.api(`/api/pi/resources${q}`),
          projects.length ? projects : ctx.api("/api/projects").then((r) => r.projects || []).catch(() => []),
        ]);
      } catch (e) { el.innerHTML = `<div class="errbox">${esc(e.message)}</div>`; return; }
      draw();
    }

    function pickProject() {
      ctx.openSheet((b) => {
        b.append(ctx.el("div", "sheet-title", "Show resources for"));
        const choose = (p) => { ctx.closeSheet(); project = p; load(); };
        b.append(Object.assign(ctx.el("button", "opt", `<div class="o-main"><div class="o-t">No project</div><div class="o-s">Only what every chat loads</div></div>`), { onclick: () => choose("") }));
        for (const p of projects) {
          const o = ctx.el("button", "opt", `<div class="o-main"><div class="o-t">${esc(p.name)}</div><div class="o-s">${esc(tilde(p.path))}</div></div>`);
          o.dataset.path = p.path;
          o.onclick = () => choose(p.path);
          b.append(o);
        }
      });
    }

    // A global file a project's settings name to override it (`pi config
    // --local`): the scan lists it as the project's.
    const overridden = (r) => r.scope === "project" && r.origin === "settings" && data.cwd && !r.path.startsWith(data.cwd + "/");
    // Whether the switch can change it: not -e extensions or what only the live chat reported.
    const switchable = (r) => !!r.toggle && r.scope !== "temporary";

    // The toggle request for a resource. `projectOnly`: a global resource's
    // project override ("on"/"off"/"inherit").
    function toggleBody(r, state, projectOnly = false) {
      const b = { cwd: data.cwd || project || null, kind: r.kind, path: r.path, state };
      if (r.toggle.key === "packages") {
        b.scope = r.toggle.scope;
        b.package = { source: r.toggle.package, scope: r.toggle.scope === "project" ? "project" : "user", entry: r.toggle.entry };
      } else if (projectOnly || overridden(r)) {
        b.scope = "project";
        b.override = r.scope !== "builtin";
      } else {
        b.scope = r.toggle.scope;
      }
      return b;
    }

    async function setState(r, state, projectOnly = false) {
      try {
        await ctx.api("/api/pi/resources/toggle", toggleBody(r, state, projectOnly));
        ctx.closeSheet();
        ctx.needsRestart();
        await load(true);
      } catch (e) { ctx.toast(e.message, true); draw(); }
    }

    function details(r) {
      ctx.openSheet((b) => {
        b.append(ctx.el("div", "sheet-title", esc(r.name)), ctx.el("div", "sheet-sub", esc(r.kind)));
        if (r.description) b.append(ctx.el("div", "rs-note", esc(r.description)));
        const g = ctx.el("div", "rs-detail");
        const row = (k, v) => { if (v) g.append(ctx.el("b", "", esc(k)), ctx.el("span", "", esc(v))); };
        row("Command", r.kind === "prompt" ? `/${r.name}${r.argumentHint ? " " + r.argumentHint : ""}` : r.kind === "skill" ? `/skill:${r.name}` : (r.commands || []).map((c) => "/" + c).join(" "));
        row("Path", tilde(r.path));
        row("Scope", SCOPES[r.scope] || r.scope);
        row("Found by", { auto: "folder scan", settings: "settings entry", package: "package", builtin: "built in", live: "the running chat" }[r.origin] || r.origin);
        if (r.package) row("Package", `${r.package.source} (${r.package.scope})`);
        row("Loads", r.loads ? "yes" : r.skipped ? `no: ${r.skipped}` : "no: turned off in settings");
        if (r.disabledBy) row("Turned off by", r.disabledBy);
        if (r.toggle?.entry && r.toggle.key !== "packages") row("Settings entry", `${r.toggle.scope} ${r.toggle.key}: ${r.toggle.entry}`);
        b.append(g);
        if (!switchable(r)) return;
        const btn = ctx.el("button", "btn secondary", r.enabled ? "Turn off" : "Turn on");
        btn.dataset.k = "toggle";
        btn.onclick = () => setState(r, r.enabled ? "off" : "on");
        const where = r.toggle.key === "packages" ? "in the package's settings" : overridden(r) || r.toggle.scope === "project" ? "in this project's settings" : "in global settings";
        const row1 = ctx.el("div", "btn-row");
        row1.append(btn);
        b.append(row1, ctx.el("div", "sheet-sub", esc(`Changes it ${where}.`)));
        // A global resource (or built-in) with a project picked: only here.
        const globalOne = (r.scope === "global" || r.scope === "builtin" || overridden(r)) && project;
        if (!globalOne) return;
        const cur = overridden(r) || (r.scope === "builtin" && r.toggle.scope === "project") ? (r.enabled ? "on" : "off") : "inherit";
        const box = ctx.el("div", "rs-scope");
        box.append(ctx.el("div", "sheet-sub", "In this project only"));
        const seg = ctx.el("div", "seg");
        for (const [v, label] of [["inherit", "Like global"], ["on", "On"], ["off", "Off"]]) {
          const o = ctx.el("button", v === cur ? "on" : "", label);
          o.dataset.project = v;
          o.onclick = () => { if (v !== cur) setState(r, v, true); };
          seg.append(o);
        }
        box.append(seg);
        if (data.trust && !data.trust.trusted) box.append(ctx.el("div", "rs-note", "pi ignores this project's settings until it's trusted."));
        b.append(box);
      });
    }

    function chips(r) {
      const c = ctx.el("div", "rs-chips");
      const add = (t, cls = "") => c.append(ctx.el("span", `chip ${cls}`, esc(t)));
      if (overridden(r)) { add("global"); add(r.enabled ? "on in this project" : "off in this project", r.enabled ? "on" : "warn"); }
      else add(SCOPES[r.scope] || r.scope);
      if (r.scope === "builtin" && r.toggle?.scope === "project") add(r.enabled ? "on in this project" : "off in this project", r.enabled ? "on" : "warn");
      if (r.package) add(r.package.source.replace(/^npm:/, "").split("/").pop());
      const here = overridden(r) || (r.scope === "builtin" && r.toggle?.scope === "project");
      if (!r.enabled && !here) add("off", "warn");
      else if (r.skipped) add(r.skipped === "project not trusted" ? "skipped: not trusted" : r.skipped, "warn");
      if (r.live) add("running", "on");
      for (const cmd of r.commands || []) add("/" + cmd);
      return c;
    }

    function draw() {
      el.innerHTML = "";
      const pcard = ctx.el("div", "wf-card");
      const cur = projects.find((p) => p.path === project);
      const pick = ctx.el("button", "opt rs-pick", `<div class="o-main"><div class="o-t">${esc(cur?.name || (project ? tilde(project) : "No project"))}</div><div class="o-s">${esc(project ? tilde(data.cwd || project) : "Global resources and packages only")}</div></div>`);
      pick.append(ctx.el("span", "mp-chev", ctx.ICON.chev));
      pick.dataset.k = "project";
      pick.onclick = pickProject;
      pcard.append(pick);
      el.append(pcard);

      const t = data.trust;
      if (t && t.needsTrust && !t.trusted) {
        const n = ctx.el("div", "rs-note warn", `This project isn't trusted, so pi skips its .pi resources${t.decision === null ? ` (no decision; the default is “${esc(data.defaultTrust)}”)` : ""}. `);
        const go = ctx.el("button", "", "Project trust"); go.onclick = () => ctx.navigate("trust");
        n.append(go);
        el.append(n);
      }
      if (data.live) el.append(ctx.el("div", "rs-note", `An open chat here reports ${data.live.commands} command${data.live.commands === 1 ? "" : "s"}; “running” marks what its pi loaded.`));
      else if (data.liveError) el.append(ctx.el("div", "rs-note warn", `Couldn't ask the open chat: ${esc(data.liveError)}`));
      else if (project) el.append(ctx.el("div", "rs-note", "From the files. Open a chat in this project to also see what pi really loaded."));

      const list = data.resources || [];
      const seg = ctx.el("div", "seg");
      for (const [v, label] of [["all", "All"], ...KINDS.map(([k, , short]) => [k, short])]) {
        const n = v === "all" ? list.length : list.filter((r) => r.kind === v).length;
        const b = ctx.el("button", v === filter ? "on" : "", `${esc(label)} ${n}`);
        b.dataset.filter = v;
        b.onclick = () => { filter = v; draw(); };
        seg.append(b);
      }
      el.append(seg);

      const order = { project: 0, global: 1, package: 2, temporary: 3, builtin: 4 };
      for (const [kind, label] of KINDS) {
        if (filter !== "all" && filter !== kind) continue;
        const rows = list.filter((r) => r.kind === kind).sort((a, z) => (order[a.scope] ?? 9) - (order[z.scope] ?? 9) || a.name.localeCompare(z.name));
        el.append(ctx.el("div", "wf-section", esc(label)));
        const card = ctx.el("div", "wf-card");
        for (const r of rows) {
          const row = ctx.el("div", `rs-row${r.loads ? "" : " off"}`);
          row.dataset.kind = r.kind; row.dataset.name = r.name;
          const main = ctx.el("button", "rs-main");
          const shown = r.kind === "prompt" ? `/${r.name}` : r.kind === "skill" ? `/skill:${r.name}` : r.name;
          main.append(ctx.el("div", "rs-t", `<span class="rs-name">${esc(shown)}</span>${r.argumentHint ? `<span class="rs-hint">${esc(r.argumentHint)}</span>` : ""}`));
          if (r.description) main.append(ctx.el("div", "rs-d", esc(r.description)));
          main.append(chips(r));
          main.onclick = () => details(r);
          row.append(main);
          if (switchable(r)) {
            const sw = ctx.el("button", `switch${r.enabled ? " on" : ""}`, "<i></i>");
            sw.dataset.k = "switch";
            sw.setAttribute("role", "switch");
            sw.setAttribute("aria-checked", String(!!r.enabled));
            sw.setAttribute("aria-label", `${shown} ${r.enabled ? "on" : "off"}`);
            sw.onclick = async () => { sw.disabled = true; sw.classList.toggle("on"); await setState(r, r.enabled ? "off" : "on"); };
            row.append(sw);
          }
          card.append(row);
        }
        if (!rows.length) card.append(ctx.el("div", "list-empty", `No ${label.toLowerCase()}.`));
        el.append(card);
      }

      if (filter === "all") {
        el.append(ctx.el("div", "wf-section", "Packages"));
        const card = ctx.el("div", "wf-card");
        for (const p of data.packages || []) {
          const r = ctx.el("div", "rs-pkg", esc(p.source));
          r.append(ctx.el("div", "", esc(`${p.scope === "project" ? "project" : "global"}${p.filtered ? " · filtered" : ""} · ${p.installedPath ? tilde(p.installedPath) : "not installed"}`)));
          card.append(r);
        }
        if (!(data.packages || []).length) card.append(ctx.el("div", "list-empty", "No packages."));
        el.append(card);
        const more = ctx.el("div", "rs-note", "Install, update and remove them in ");
        const go = ctx.el("button", "", "Packages"); go.onclick = () => ctx.navigate("packages");
        more.append(go, ".");
        el.append(more);
        if (data.packagesError) el.append(ctx.el("div", "rs-note warn", `pi list: ${esc(data.packagesError)}`));
      }
    }

    await load();
  },
});
