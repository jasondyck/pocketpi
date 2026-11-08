"use strict";
// Settings › Packages (plan F3, F4): pi packages installed globally and in
// the picked project, with what each one provides; install by source
// (npm:, git:, a URL or a path), update one or all, remove; and the
// gallery (npm packages with the `pi-package` keyword, searched by the
// server). Installs, updates and removals are pi CLI jobs (POST
// /api/pi/jobs), whose output streams on /api/runs/events as `job` events.
// Data: GET /api/pi/resources?cwd= (packages from `pi list` and the
// settings, and the resources each provides), GET /api/pi/gallery?q=.
ppManage.register({
  id: "packages",
  title: "Packages",
  subtitle: "Install, update and remove pi packages",
  icon: '<svg viewBox="0 0 24 24"><path d="M12 3l8 4.5v9L12 21l-8-4.5v-9z"/><path d="M4 7.5l8 4.5 8-4.5M12 12v9"/></svg>',
  order: 45,
  async render(el, ctx) {
    ctx.style(`.mp-packages .pk-pick { border-radius: 0; padding: 12px 14px; }
.mp-packages .pk-note { font-size: 13px; color: var(--text-2); line-height: 1.45; margin: 10px 2px 0; }
.mp-packages .pk-note.warn { color: var(--warn); }
.mp-packages .pk-note button { color: var(--text); text-decoration: underline; font: inherit; }
.mp-packages .pk-row { display: flex; align-items: center; gap: 10px; width: 100%; text-align: left; padding: 11px 14px; }
.mp-packages .pk-row + .pk-row { border-top: 1px solid var(--line); }
.mp-packages button.pk-row:active { background: var(--surface); }
.mp-packages .pk-main { flex: 1; min-width: 0; }
.mp-packages .pk-name { font: 500 14.5px var(--mono); letter-spacing: -0.02em; overflow-wrap: anywhere; }
.mp-packages .pk-sub { font-size: 12.5px; color: var(--muted); margin-top: 2px; overflow-wrap: anywhere; }
.mp-packages .pk-d { font-size: 13px; color: var(--text-2); margin-top: 2px; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
.mp-packages .pk-form { padding: 12px 14px; display: grid; gap: 10px; }
.mp-packages .pk-form .btn-row { margin-top: 0; }
.mp-packages .pk-log { margin-top: 10px; }
.mp-packages .pk-log pre { margin: 0; padding: 10px 12px; font: 12px/1.45 var(--mono); white-space: pre-wrap; overflow-wrap: anywhere; max-height: 40vh; overflow: auto; background: var(--surface); border-radius: 12px; }
.mp-packages .pk-log .pk-st { font: 12.5px var(--mono); color: var(--text-2); margin: 0 2px 6px; }
.mp-packages .pk-log .pk-st.ok { color: var(--ok); } .mp-packages .pk-log .pk-st.fail { color: var(--danger); }
.mp-packages .btn.small { height: 34px; padding: 0 12px; font-size: 13.5px; border-radius: 10px; }
.mp-packages .pk-actions { display: flex; gap: 8px; margin-top: 10px; }
.pk-res { font: 12.5px var(--mono); line-height: 1.6; margin: 6px 0 2px; overflow-wrap: anywhere; }
.pk-res .off { color: var(--muted); text-decoration: line-through; }
.pk-sheet-detail { font-size: 14px; display: grid; grid-template-columns: auto 1fr; gap: 6px 12px; margin: 6px 0 4px; }
.pk-sheet-detail b { color: var(--muted); font-weight: 500; font-size: 12.5px; }
.pk-sheet-detail span { font: 12.5px var(--mono); overflow-wrap: anywhere; }
.pk-confirm { margin-top: 12px; font-size: 14px; }`);
    const { esc } = ctx;
    const tilde = (p) => (p && ctx.home && p.startsWith(ctx.home + "/") ? "~" + p.slice(ctx.home.length) : p || "");
    let project = ctx.project || "";
    let projects = [];
    let data = null;
    let gallery = null;
    let galleryQuery = "";
    let installScope = "global";
    let busy = false;
    const log = { lines: [], status: "", title: "" };

    // ------------------------------------------------------------ jobs
    // One stream for the page's life; events for a job that started before
    // its id came back are kept until it does.
    let es = null;
    const waiting = new Map();
    const early = new Map();
    function stream() {
      if (es) return;
      es = new EventSource("/api/runs/events");
      es.onmessage = (e) => {
        let ev; try { ev = JSON.parse(e.data); } catch { return; }
        if (ev.type !== "job") return;
        const w = waiting.get(ev.id);
        if (w) w(ev);
        else { if (!early.has(ev.id)) early.set(ev.id, []); early.get(ev.id).push(ev); }
      };
    }
    async function runJob(title, body) {
      if (busy) return null;
      stream();
      busy = true;
      Object.assign(log, { lines: [], status: "running", title });
      drawLog();
      let id;
      try { id = (await ctx.api("/api/pi/jobs", body)).id; }
      catch (e) { busy = false; Object.assign(log, { status: "fail", lines: [e.message] }); drawLog(); return null; }
      const job = await new Promise((resolve) => {
        let done = false;
        const finish = async () => {
          if (done) return; done = true;
          waiting.delete(id); clearInterval(poll);
          try { resolve((await ctx.api(`/api/pi/jobs/${id}`)).job); } catch { resolve(null); }
        };
        const handle = (ev) => {
          if (ev.event === "output") { log.lines.push(ev.line); drawLog(); }
          else if (ev.event === "end") finish();
        };
        waiting.set(id, handle);
        (early.get(id) || []).forEach(handle); early.delete(id);
        // If the stream dropped the end (a reconnect), the job still ends.
        const poll = setInterval(async () => {
          try { if ((await ctx.api(`/api/pi/jobs/${id}`)).job.status !== "running") finish(); } catch {}
        }, 3000);
      });
      busy = false;
      if (job) log.lines = job.output.replace(/\n$/, "").split("\n").filter((l, i, a) => l || a.length > 1);
      log.status = job?.status === "ok" ? "ok" : "fail";
      drawLog();
      ctx.needsRestart();
      await load(true);
      return job;
    }

    let logBox = null;
    function drawLog() {
      if (!logBox) return;
      logBox.hidden = !log.status;
      if (!log.status) return;
      const st = log.status === "running" ? `${log.title}…` : log.status === "ok" ? `${log.title}: done` : `${log.title}: failed`;
      logBox.innerHTML = "";
      logBox.append(ctx.el("div", `pk-st ${log.status}`, esc(st)));
      const pre = ctx.el("pre", "", esc(log.lines.join("\n") || (log.status === "running" ? "Waiting for pi…" : "(no output)")));
      logBox.append(pre);
      pre.scrollTop = pre.scrollHeight;
    }

    // ------------------------------------------------------------ data
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
      if (!gallery) searchGallery(galleryQuery);
    }

    async function searchGallery(q) {
      galleryQuery = q;
      gallery = { loading: true, packages: [] };
      drawGallery();
      try { gallery = await ctx.api(`/api/pi/gallery?q=${encodeURIComponent(q)}`); }
      catch (e) { gallery = { error: e.message, packages: [] }; }
      drawGallery();
    }

    // "npm:@a/b@1.2" → "@a/b"; "git:github.com/x/y@v1" → "x/y"; a path → its folder name.
    function shortName(src) {
      if (src.startsWith("npm:")) { const s = src.slice(4); const at = s.indexOf("@", 1); return at > 0 ? s.slice(0, at) : s; }
      const g = /^(?:git:|https?:\/\/|ssh:\/\/|git@)([^@]*?)(?:\.git)?(?:@[^/]*)?$/.exec(src);
      if (g) return g[1].split(/[/:]/).slice(-2).join("/");
      return src.replace(/\/+$/, "").split("/").pop() || src;
    }
    const isInstalled = (name) => (data?.packages || []).some((p) => p.source === `npm:${name}` || p.source.startsWith(`npm:${name}@`));
    const provides = (p) => (data.resources || []).filter((r) => r.package && r.package.source === p.source && r.package.scope === p.scope);
    function summary(list) {
      const n = (k) => list.filter((r) => r.kind === k).length;
      const parts = [[n("extension"), "extension"], [n("skill"), "skill"], [n("prompt"), "prompt"]].filter(([c]) => c).map(([c, w]) => `${c} ${w}${c === 1 ? "" : "s"}`);
      const off = list.filter((r) => !r.enabled).length;
      return (parts.join(" · ") || "nothing pi loads") + (off ? ` (${off} off)` : "");
    }
    const fmtNum = (n) => (n >= 1e6 ? (n / 1e6).toFixed(1).replace(/\.0$/, "") + "M" : n >= 1e3 ? (n / 1e3).toFixed(1).replace(/\.0$/, "") + "k" : String(n));

    // ------------------------------------------------------------ sheets
    function pickProject() {
      ctx.openSheet((b) => {
        b.append(ctx.el("div", "sheet-title", "Show packages for"));
        const choose = (p) => { ctx.closeSheet(); project = p; if (!p) installScope = "global"; load(); };
        b.append(Object.assign(ctx.el("button", "opt", `<div class="o-main"><div class="o-t">No project</div><div class="o-s">Global packages only</div></div>`), { onclick: () => choose("") }));
        for (const p of projects) {
          const o = ctx.el("button", "opt", `<div class="o-main"><div class="o-t">${esc(p.name)}</div><div class="o-s">${esc(tilde(p.path))}</div></div>`);
          o.dataset.path = p.path;
          o.onclick = () => choose(p.path);
          b.append(o);
        }
      });
    }

    function packageSheet(p) {
      const local = p.scope === "project";
      ctx.openSheet((b) => {
        b.append(ctx.el("div", "sheet-title", esc(shortName(p.source))), ctx.el("div", "sheet-sub", esc(local ? "Installed in this project" : "Installed globally")));
        const g = ctx.el("div", "pk-sheet-detail");
        const row = (k, v) => { if (v) g.append(ctx.el("b", "", esc(k)), ctx.el("span", "", esc(v))); };
        row("Source", p.source);
        row("Installed at", p.installedPath ? tilde(p.installedPath) : "not installed yet (pi installs it when it starts)");
        if (p.filtered) row("Filter", "only some resources load (settings object form)");
        b.append(g);
        const list = provides(p);
        b.append(ctx.el("div", "sheet-sub", list.length ? `Provides ${esc(summary(list))}` : "pi found nothing to load in it"));
        if (list.length) {
          const res = ctx.el("div", "pk-res");
          for (const r of list) {
            const label = r.kind === "prompt" ? `/${r.name}` : r.kind === "skill" ? `/skill:${r.name}` : `${r.name} (extension)`;
            res.append(ctx.el("div", r.enabled ? "" : "off", esc(label)));
          }
          b.append(res);
          const go = ctx.el("button", "btn secondary small", "Turn resources on or off");
          go.onclick = () => { ctx.closeSheet(); ctx.navigate("resources"); };
          const r1 = ctx.el("div", "btn-row"); r1.append(go); b.append(r1);
        }
        const actions = ctx.el("div", "btn-row");
        const upd = ctx.el("button", "btn secondary", "Update");
        upd.dataset.k = "update";
        upd.onclick = () => { ctx.closeSheet(); runJob(`Updating ${shortName(p.source)}`, { action: "update", source: p.source, cwd: project || null }); };
        const rm = ctx.el("button", "btn secondary", "Remove…");
        rm.dataset.k = "remove";
        rm.style.color = "var(--danger)";
        rm.onclick = () => {
          actions.hidden = true;
          const c = ctx.el("div", "pk-confirm", `Remove <b>${esc(p.source)}</b> from ${local ? "this project's" : "the global"} settings? Its extensions, skills and prompts stop loading after a restart.`);
          const r2 = ctx.el("div", "btn-row");
          const no = ctx.el("button", "btn secondary", "Cancel");
          no.onclick = () => { c.remove(); r2.remove(); actions.hidden = false; };
          const yes = ctx.el("button", "btn", "Remove");
          yes.dataset.k = "confirm-remove";
          yes.style.background = "var(--danger)";
          yes.onclick = () => { ctx.closeSheet(); runJob(`Removing ${shortName(p.source)}`, { action: "remove", source: p.source, local, cwd: local ? project : null }); };
          r2.append(no, yes);
          b.append(c, r2);
        };
        actions.append(upd, rm);
        b.append(actions);
      });
    }

    function installSheet(source, description) {
      ctx.openSheet((b) => {
        b.append(ctx.el("div", "sheet-title", esc(`Install ${shortName(source)}`)), ctx.el("div", "sheet-sub", esc(source)));
        if (description) b.append(ctx.el("div", "pk-confirm", esc(description)));
        b.append(ctx.el("div", "pk-confirm", "Packages run code as you, with pi's permissions. Look at its source before installing."));
        const r = ctx.el("div", "btn-row");
        if (project) {
          const lp = ctx.el("button", "btn secondary", "In this project");
          lp.dataset.k = "install-project";
          lp.onclick = () => { ctx.closeSheet(); install(source, true); };
          r.append(lp);
        }
        const gl = ctx.el("button", "btn", "Globally");
        gl.dataset.k = "install-global";
        gl.onclick = () => { ctx.closeSheet(); install(source, false); };
        r.append(gl);
        b.append(r);
      });
    }

    function install(source, local) {
      source = source.trim();
      if (!source) return;
      return runJob(`Installing ${shortName(source)}`, { action: "install", source, local, cwd: local ? project : null });
    }

    // ------------------------------------------------------------ page
    let galleryBox = null;
    function draw() {
      el.innerHTML = "";
      const pcard = ctx.el("div", "wf-card");
      const cur = projects.find((p) => p.path === project);
      const pick = ctx.el("button", "opt pk-pick", `<div class="o-main"><div class="o-t">${esc(cur?.name || (project ? tilde(project) : "No project"))}</div><div class="o-s">${esc(project ? tilde(data.cwd || project) : "Global packages only")}</div></div>`);
      pick.append(ctx.el("span", "mp-chev", ctx.ICON.chev));
      pick.dataset.k = "project";
      pick.onclick = pickProject;
      pcard.append(pick);
      el.append(pcard);
      const untrusted = project && data.trust && !data.trust.trusted;
      if (untrusted) {
        const n = ctx.el("div", "pk-note warn", "pi doesn't trust this project, so it neither installs nor loads its packages. ");
        const go = ctx.el("button", "", "Project trust"); go.onclick = () => ctx.navigate("trust");
        n.append(go);
        el.append(n);
      }

      const pkgs = (data.packages || []).slice().sort((a, z) => (a.scope === "project" ? 0 : 1) - (z.scope === "project" ? 0 : 1) || shortName(a.source).localeCompare(shortName(z.source)));
      el.append(ctx.el("div", "wf-section", "Installed"));
      const card = ctx.el("div", "wf-card");
      for (const p of pkgs) {
        const row = ctx.el("button", "pk-row");
        row.dataset.source = p.source;
        const m = ctx.el("div", "pk-main");
        m.append(ctx.el("div", "pk-name", esc(shortName(p.source))));
        m.append(ctx.el("div", "pk-sub", esc(`${p.scope === "project" ? "project" : "global"} · ${summary(provides(p))}${p.installedPath ? "" : " · not installed"}`)));
        row.append(m, ctx.el("span", "mp-chev", ctx.ICON.chev));
        row.onclick = () => packageSheet(p);
        card.append(row);
      }
      if (!pkgs.length) card.append(ctx.el("div", "list-empty", "No packages yet."));
      el.append(card);
      if (data.packagesError) el.append(ctx.el("div", "pk-note warn", `pi list: ${esc(data.packagesError)}`));
      if (pkgs.length) {
        const a = ctx.el("div", "pk-actions");
        const all = ctx.el("button", "btn secondary small", "Update all");
        all.dataset.k = "update-all";
        all.onclick = () => runJob("Updating packages", { action: "update", extensions: true, cwd: project || null });
        a.append(all);
        el.append(a);
      }

      el.append(ctx.el("div", "wf-section", "Install"));
      const form = ctx.el("div", "wf-card pk-form");
      const f = ctx.el("div", "field");
      const input = ctx.el("input");
      input.placeholder = "npm:name, git:github.com/x/y, https://…, ./path";
      input.autocapitalize = "off"; input.autocomplete = "off"; input.spellcheck = false;
      input.dataset.k = "source";
      f.append(input);
      form.append(f);
      if (project) {
        const seg = ctx.el("div", "seg");
        for (const [v, label] of [["global", "Global"], ["project", "This project"]]) {
          const o = ctx.el("button", v === installScope ? "on" : "", label);
          o.dataset.scope = v;
          o.onclick = () => { installScope = v; seg.querySelectorAll("button").forEach((x) => x.classList.toggle("on", x === o)); };
          seg.append(o);
        }
        form.append(seg);
      }
      const r = ctx.el("div", "btn-row");
      const go = ctx.el("button", "btn", "Install");
      go.dataset.k = "install";
      go.onclick = () => install(input.value, !!project && installScope === "project");
      input.onkeydown = (e) => { if (e.key === "Enter") go.click(); };
      r.append(go);
      form.append(r);
      el.append(form);
      el.append(ctx.el("div", "pk-note", "Packages run code as you. A path is relative to the settings file (~/.pi/agent, or the project's .pi)."));
      logBox = ctx.el("div", "pk-log");
      logBox.dataset.k = "log";
      el.append(logBox);
      drawLog();

      el.append(ctx.el("div", "wf-section", "Gallery"));
      const sf = ctx.el("div", "field");
      const sq = ctx.el("input");
      sq.type = "search"; sq.placeholder = "Search pi packages on npm"; sq.value = galleryQuery;
      sq.dataset.k = "search";
      let t = null;
      sq.oninput = () => { clearTimeout(t); t = setTimeout(() => searchGallery(sq.value.trim()), 400); };
      sf.append(sq);
      el.append(sf);
      galleryBox = ctx.el("div", "wf-card");
      galleryBox.style.marginTop = "10px";
      el.append(galleryBox);
      drawGallery();
    }

    function drawGallery() {
      if (!galleryBox) return;
      galleryBox.innerHTML = "";
      if (!gallery || gallery.loading) { galleryBox.append(ctx.el("div", "list-empty", "Searching npm…")); return; }
      if (gallery.error) { galleryBox.append(ctx.el("div", "list-empty", `Couldn't search npm: ${esc(gallery.error)}`)); return; }
      for (const g of gallery.packages || []) {
        const row = ctx.el("div", "pk-row");
        row.dataset.name = g.name;
        const m = ctx.el("div", "pk-main");
        const nameEl = ctx.el("a", "pk-name", esc(g.name));
        if (g.npm) { nameEl.href = g.npm; nameEl.target = "_blank"; nameEl.rel = "noopener"; }
        m.append(nameEl);
        if (g.description) m.append(ctx.el("div", "pk-d", esc(g.description)));
        const bits = [g.version && `v${g.version}`, g.monthly != null && `${fmtNum(g.monthly)}/month`, g.publisher, g.date && g.date.slice(0, 10)].filter(Boolean);
        m.append(ctx.el("div", "pk-sub", esc(bits.join(" · "))));
        row.append(m);
        if (isInstalled(g.name)) row.append(ctx.el("span", "chip", "installed"));
        else {
          const b = ctx.el("button", "btn secondary small", "Install");
          b.dataset.k = "gallery-install";
          b.onclick = () => installSheet(g.source, g.description);
          row.append(b);
        }
        galleryBox.append(row);
      }
      if (!(gallery.packages || []).length) galleryBox.append(ctx.el("div", "list-empty", "Nothing found."));
      else if (gallery.total > (gallery.packages || []).length) galleryBox.append(ctx.el("div", "list-empty", esc(`${fmtNum(gallery.total)} packages in all; search to narrow them down.`)));
    }

    await load();
    return () => { es?.close(); es = null; };
  },
});
