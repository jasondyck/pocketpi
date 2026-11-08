"use strict";
// Settings › MCP servers (plan F7, F8): the servers pi would connect to,
// globally and in the picked project, with their state, tools and errors
// (`pi mcp list --json`, GET /api/pi/mcp?cwd=, which connects to each);
// add and remove (pi CLI jobs), enable/disable and exposure (POST
// /api/pi/mcp/server, which edits mcp.json like pi's /mcp does), a
// per-project on/off override for global servers, and sign-in: POST
// /api/pi/mcp/signin runs `/mcp login <server>` in a chat for the project
// (the open one, or a new one) and answers the sign-in URL and the
// dialog asking for the address the browser ended on, which this page
// answers through that chat (POST /api/s/{key}/cmd extension_ui_response).
// Sign-out is `pi mcp logout` (a job); reconnect runs `/mcp reconnect` in
// the chat open in the project.
ppManage.register({
  id: "mcp",
  title: "MCP servers",
  subtitle: "Tools from Model Context Protocol servers",
  icon: '<svg viewBox="0 0 24 24"><rect x="3" y="4" width="18" height="6" rx="2"/><rect x="3" y="14" width="18" height="6" rx="2"/><path d="M7 7h.01M7 17h.01"/></svg>',
  order: 47,
  async render(el, ctx) {
    ctx.style(`.mp-mcp .mc-pick { border-radius: 0; padding: 12px 14px; }
.mp-mcp .mc-note { font-size: 13px; color: var(--text-2); line-height: 1.45; margin: 10px 2px 0; overflow-wrap: anywhere; }
.mp-mcp .mc-note.warn { color: var(--warn); }
.mp-mcp .mc-note button { color: var(--text); text-decoration: underline; font: inherit; }
.mp-mcp .mc-row { display: flex; align-items: center; gap: 10px; width: 100%; text-align: left; padding: 11px 14px; }
.mp-mcp .mc-row + .mc-row { border-top: 1px solid var(--line); }
.mp-mcp button.mc-row:active { background: var(--surface); }
.mp-mcp .mc-main { flex: 1; min-width: 0; }
.mp-mcp .mc-name { font: 500 14.5px var(--mono); letter-spacing: -0.02em; }
.mp-mcp .mc-sub { font: 12px var(--mono); color: var(--muted); margin-top: 2px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.mp-mcp .mc-chips { display: flex; flex-wrap: wrap; gap: 4px; margin-top: 6px; }
.mp-mcp .mc-chips .chip { font-size: 11px; padding: 2px 8px; }
.mp-mcp .chip.ok, .mc-sheet .chip.ok { color: var(--ok); }
.mp-mcp .chip.warn, .mc-sheet .chip.warn { color: var(--warn); }
.mp-mcp .chip.bad, .mc-sheet .chip.bad { color: var(--danger); }
.mp-mcp .mc-actions { display: flex; gap: 8px; margin-top: 10px; }
.mp-mcp .btn.small, .mc-sheet .btn.small { height: 34px; padding: 0 12px; font-size: 13.5px; border-radius: 10px; }
.mp-mcp .mc-log { margin-top: 10px; }
.mp-mcp .mc-log pre { margin: 0; padding: 10px 12px; font: 12px/1.45 var(--mono); white-space: pre-wrap; overflow-wrap: anywhere; max-height: 30vh; overflow: auto; background: var(--surface); border-radius: 12px; }
.mp-mcp .mc-log .mc-st { font: 12.5px var(--mono); color: var(--text-2); margin: 0 2px 6px; }
.mp-mcp .mc-log .mc-st.ok { color: var(--ok); } .mp-mcp .mc-log .mc-st.fail { color: var(--danger); }
.mc-sheet .mc-detail { font-size: 14px; display: grid; grid-template-columns: auto 1fr; gap: 6px 12px; margin: 6px 0 4px; }
.mc-sheet .mc-detail b { color: var(--muted); font-weight: 500; font-size: 12.5px; }
.mc-sheet .mc-detail span { font: 12.5px var(--mono); overflow-wrap: anywhere; }
.mc-sheet .mc-h { font-size: 12.5px; color: var(--muted); margin: 14px 0 6px; }
.mc-sheet .seg button { font-family: var(--font); }
.mc-sheet .mc-err { font: 12px/1.45 var(--mono); white-space: pre-wrap; overflow-wrap: anywhere; color: var(--danger); margin: 6px 0; max-height: 25vh; overflow: auto; }
.mc-sheet .mc-tools { font: 12.5px var(--mono); line-height: 1.6; overflow-wrap: anywhere; }
.mc-sheet .mc-tools i { color: var(--muted); font-style: normal; }
.mc-sheet .mc-text { font-size: 14px; line-height: 1.45; margin: 8px 0; overflow-wrap: anywhere; }
.mc-sheet .mc-form { display: grid; gap: 8px; margin-top: 8px; }
.mc-sheet .mc-form label { font-size: 12.5px; color: var(--muted); margin-top: 4px; }
.mc-sheet .mc-form textarea { height: 76px; }
.mc-sheet a.btn { display: inline-flex; align-items: center; text-decoration: none; }
.mc-sheet .switch-line { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-top: 12px; font-size: 14.5px; }`);
    const { esc } = ctx;
    const tilde = (p) => (p && ctx.home && p.startsWith(ctx.home + "/") ? "~" + p.slice(ctx.home.length) : p || "");
    const EXPOSURES = [["codemode", "Codemode"], ["deferred", "Deferred"], ["direct", "Direct"], ["hidden", "Hidden"]];
    const EXPOSURE_TEXT = {
      codemode: "Callable from codemode scripts; not declared to the model.",
      deferred: "Declared once tool_search finds them.",
      direct: "Declared to the model like built-in tools.",
      hidden: "Registered but unreachable.",
    };
    let project = ctx.project || "";
    let projects = [];
    let cfg = { global: null, project: null };
    let list = null;      // pi mcp list --json, or {error}
    let listing = false;
    let busy = false;
    const log = { lines: [], status: "", title: "" };

    // ------------------------------------------------------------ jobs
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
        const poll = setInterval(async () => {
          try { if ((await ctx.api(`/api/pi/jobs/${id}`)).job.status !== "running") finish(); } catch {}
        }, 3000);
      });
      busy = false;
      if (job) log.lines = job.output.replace(/\n$/, "").split("\n");
      log.status = job?.status === "ok" ? "ok" : "fail";
      drawLog();
      ctx.needsRestart();
      load(true);
      return job;
    }
    let logBox = null;
    function drawLog() {
      if (!logBox) return;
      logBox.hidden = !log.status;
      if (!log.status) return;
      const st = log.status === "running" ? `${log.title}…` : log.status === "ok" ? `${log.title}: done` : `${log.title}: failed`;
      logBox.innerHTML = "";
      logBox.append(ctx.el("div", `mc-st ${log.status}`, esc(st)), ctx.el("pre", "", esc(log.lines.join("\n") || "Waiting for pi…")));
    }

    // ------------------------------------------------------------ data
    async function load(quiet = false) {
      if (!quiet) el.innerHTML = '<div class="wf-loading">Loading…</div>';
      const q = project ? `?cwd=${encodeURIComponent(project)}` : "";
      try {
        const [g, p, pr] = await Promise.all([
          ctx.api("/api/pi/config/mcp"),
          project ? ctx.api(`/api/pi/config/mcp${q}`) : null,
          projects.length ? projects : ctx.api("/api/projects").then((r) => r.projects || []).catch(() => []),
        ]);
        cfg = { global: g, project: p };
        projects = pr;
      } catch (e) { el.innerHTML = `<div class="errbox">${esc(e.message)}</div>`; return; }
      draw();
      // pi connects to every enabled server to answer: slow, so after the files.
      listing = true;
      const want = project;
      try {
        const r = await ctx.api(`/api/pi/mcp${q}`);
        if (want !== project) return;
        list = r.json || { error: (r.stderr || r.stdout || `pi mcp list exited with ${r.code}`).trim() };
      } catch (e) { list = { error: e.message }; }
      listing = false;
      draw();
    }

    const isOverride = (s) => s && typeof s === "object" && !("command" in s || "url" in s || "type" in s);

    // Every server, from the files and (once it answers) pi's report.
    function servers() {
      const g = cfg.global?.data?.mcpServers || {};
      const p = cfg.project?.data?.mcpServers || {};
      const report = new Map((list?.servers || []).map((s) => [s.name, s]));
      const names = [...new Set([...Object.keys(p), ...Object.keys(g), ...report.keys()])];
      return names.map((name) => {
        const r = report.get(name);
        const projectDefines = name in p && !isOverride(p[name]);
        const own = projectDefines ? p[name] : g[name] || {};
        const ov = !projectDefines && name in p ? p[name] : null;
        const conf = { ...own, ...(ov || {}) };
        return {
          name,
          scope: r?.scope || (projectDefines ? "project" : "global"),
          defined: projectDefines ? "project" : name in g ? "global" : null,
          own, override: ov,
          enabled: r ? r.enabled : conf.enabled !== false,
          exposure: r?.exposure || conf.exposure || "codemode",
          transport: r?.transport || conf.url || [conf.command, ...(conf.args || [])].filter(Boolean).join(" "),
          isUrl: !!(own.url || (r?.transport || "").startsWith("http")),
          state: r?.state || (listing ? "checking" : conf.enabled === false ? "disabled" : "unknown"),
          tools: r?.tools || [], toolExposure: r?.toolExposure || {}, resources: !!r?.resources,
          error: r?.error, source: r?.source,
        };
      }).sort((a, z) => (a.scope === z.scope ? a.name.localeCompare(z.name) : a.scope === "project" ? -1 : 1));
    }

    function stateChip(s) {
      if (s.state === "connected") return [`${s.tools.length} tool${s.tools.length === 1 ? "" : "s"}`, "ok"];
      if (s.state === "needs-auth") return ["needs sign-in", "warn"];
      if (s.state === "failed") return ["failed", "bad"];
      if (s.state === "disabled") return ["off", "warn"];
      if (s.state === "checking") return ["checking…", ""];
      return [s.state, ""];
    }

    const liveChat = () => (ctx.status()?.live || []).find((l) => l.kind === "chat" && l.cwd === (project || ctx.home));

    // ------------------------------------------------------------ changes
    async function edit(body, done) {
      try {
        await ctx.api("/api/pi/mcp/server", body);
        ctx.needsRestart();
        if (done) done();
        await load(true);
      } catch (e) { ctx.toast(e.message, true); }
    }

    function openChat(r) {
      ctx.closeSheet();
      if (r.file && typeof openSession === "function") return openSession(r.file);
      if (typeof resetChat !== "function") return;
      showView("chat"); resetChat(); setPath(null);
      S.key = r.key; S.cwd = r.cwd;
      updateHeader(); connect();
    }

    // `/mcp <action> <server>` through a chat; the answer has what the chat showed.
    async function viaChat(s, action) {
      const cur = typeof S !== "undefined" && S.key && (!project || S.cwd === project) ? S.key : null;
      const body = { name: s.name, action, cwd: project || null, key: cur };
      try {
        return await ctx.api("/api/pi/mcp/signin", body);
      } catch (e) {
        if (cur && e.status === 400) return ctx.api("/api/pi/mcp/signin", { ...body, key: null });
        throw e;
      }
    }

    async function signIn(s) {
      ctx.openSheet((b) => { b.classList.add("mc-sheet"); b.append(ctx.el("div", "sheet-title", esc(`Sign in to ${s.name}`)), ctx.el("div", "mc-text", "Asking pi for the sign-in page…")); });
      let r;
      try { r = await viaChat(s, "login"); } catch (e) { ctx.closeSheet(); ctx.toast(e.message, true); return; }
      ctx.openSheet((b) => {
        b.classList.add("mc-sheet");
        b.dataset.k = "signin-sheet";
        b.append(ctx.el("div", "sheet-title", esc(`Sign in to ${s.name}`)));
        const others = (r.notices || []).filter((n) => !r.url || !n.message.includes(r.url));
        for (const n of others) b.append(ctx.el("div", "mc-text", esc(n.message)));
        if (r.error) b.append(ctx.el("div", "mc-err", esc(r.error)));
        if (r.url) {
          b.append(ctx.el("div", "mc-text", "1. Open the sign-in page and approve pi."));
          const a = ctx.el("a", "btn", "Open the sign-in page");
          a.href = r.url; a.target = "_blank"; a.rel = "noopener";
          a.dataset.k = "signin-url";
          const row = ctx.el("div", "btn-row"); row.style.justifyContent = "flex-start"; row.append(a);
          b.append(row);
        }
        if (r.dialog?.id) {
          b.append(ctx.el("div", "mc-text", `${r.url ? "2. " : ""}Your browser then goes to an address on 127.0.0.1 that won't open on this device. Copy that address and paste it here.`));
          const f = ctx.el("div", "field");
          const i = ctx.el("input");
          i.placeholder = r.dialog.placeholder || "http://127.0.0.1:…/callback?code=…";
          i.autocapitalize = "off"; i.autocomplete = "off"; i.spellcheck = false;
          i.dataset.k = "redirect";
          f.append(i); b.append(f);
          const answer = async (payload) => {
            try { await ctx.api(`/api/s/${r.key}/cmd`, { type: "extension_ui_response", id: r.dialog.id, ...payload }); }
            catch (e) { ctx.toast(e.message, true); return; }
            ctx.closeSheet();
            if (!payload.cancelled) { ctx.toast(`Signing in to ${s.name}…`); setTimeout(() => load(true), 2500); }
          };
          const row = ctx.el("div", "btn-row");
          const no = ctx.el("button", "btn secondary", "Cancel");
          no.onclick = () => answer({ cancelled: true });
          const yes = ctx.el("button", "btn", "Finish sign-in");
          yes.dataset.k = "finish-signin";
          yes.onclick = () => { if (i.value.trim()) answer({ value: i.value.trim() }); };
          row.append(no, yes);
          b.append(row);
        } else if (!r.done) {
          b.append(ctx.el("div", "mc-text", "pi is still working on it in the chat."));
        }
        const chat = ctx.el("button", "btn secondary small", "Open the chat");
        chat.onclick = () => openChat(r);
        const row2 = ctx.el("div", "btn-row"); row2.style.justifyContent = "flex-start"; row2.append(chat);
        b.append(row2);
      });
    }

    async function reconnect(s) {
      try {
        const r = await viaChat(s, "reconnect");
        const msg = (r.notices || []).map((n) => n.message).join(" ") || r.error || "Asked the chat to reconnect.";
        ctx.toast(msg, (r.notices || []).some((n) => n.type === "error"));
        ctx.closeSheet();
      } catch (e) { ctx.toast(e.message, true); }
    }

    // ------------------------------------------------------------ sheets
    function serverSheet(s) {
      ctx.openSheet((b) => {
        b.classList.add("mc-sheet");
        b.dataset.k = "server";
        b.append(ctx.el("div", "sheet-title", esc(s.name)));
        const [chip, cls] = stateChip(s);
        const chips = ctx.el("div", "mc-chips");
        chips.append(ctx.el("span", `chip ${cls}`, esc(chip)), ctx.el("span", "chip", esc(s.scope)));
        if (s.override) chips.append(ctx.el("span", "chip", "project override"));
        b.append(chips);
        const g = ctx.el("div", "mc-detail");
        const row = (k, v) => { if (v) g.append(ctx.el("b", "", esc(k)), ctx.el("span", "", esc(v))); };
        row(s.isUrl ? "URL" : "Command", s.transport);
        if (s.own.description) row("About", s.own.description);
        row("File", tilde(s.source || (s.defined === "project" ? cfg.project?.path : cfg.global?.path)));
        b.append(g);
        if (s.error) b.append(ctx.el("div", "mc-err", esc(s.error)));

        // Enabled, in the file that defines it.
        if (s.defined) {
          const scopeBody = s.defined === "project" ? { scope: "project", cwd: project } : { scope: "global" };
          const on = s.own.enabled !== false;
          const line = ctx.el("div", "switch-line", `<span>Enabled${s.defined === "global" && project ? " (everywhere)" : ""}</span>`);
          const sw = ctx.el("button", `switch${on ? " on" : ""}`, "<i></i>");
          sw.dataset.k = "enabled";
          sw.setAttribute("role", "switch"); sw.setAttribute("aria-checked", String(on));
          sw.onclick = () => { sw.classList.toggle("on"); edit({ name: s.name, ...scopeBody, enabled: !on }, () => ctx.closeSheet()); };
          line.append(sw);
          b.append(line);

          b.append(ctx.el("div", "mc-h", "How the model reaches its tools"));
          const seg = ctx.el("div", "seg");
          const curX = (s.override?.exposure || s.own.exposure || "codemode").replace("codemode-deferred", "codemode");
          for (const [v, label] of EXPOSURES) {
            const o = ctx.el("button", v === curX ? "on" : "", label);
            o.dataset.exposure = v;
            o.onclick = () => { if (v !== curX) edit({ name: s.name, ...(s.override ? { scope: "project", cwd: project } : scopeBody), exposure: v }, () => ctx.closeSheet()); };
            seg.append(o);
          }
          b.append(seg, ctx.el("div", "sheet-sub", esc(EXPOSURE_TEXT[curX] || "")));
        }

        // A global server, in this project only.
        if (project && s.defined === "global") {
          b.append(ctx.el("div", "mc-h", "In this project"));
          const cur = s.override && "enabled" in s.override ? (s.override.enabled === false ? "off" : "on") : "inherit";
          const seg = ctx.el("div", "seg");
          for (const [v, label] of [["inherit", "Like global"], ["on", "On"], ["off", "Off"]]) {
            const o = ctx.el("button", v === cur ? "on" : "", label);
            o.dataset.project = v;
            o.onclick = () => {
              if (v === cur) return;
              const body = { name: s.name, scope: "project", cwd: project };
              if (v === "inherit") edit({ ...body, clear: true }, () => ctx.closeSheet());
              else edit({ ...body, override: true, enabled: v === "on" }, () => ctx.closeSheet());
            };
            seg.append(o);
          }
          b.append(seg);
        }

        if (s.tools.length) {
          b.append(ctx.el("div", "mc-h", `Tools (${s.tools.length})`));
          const t = ctx.el("div", "mc-tools");
          for (const name of s.tools) t.append(ctx.el("div", "", `${esc(name)}${s.toolExposure[name] ? ` <i>${esc(s.toolExposure[name])}</i>` : ""}`));
          b.append(t);
        }

        const actions = ctx.el("div", "btn-row");
        actions.style.flexWrap = "wrap";
        if (s.isUrl) {
          const si = ctx.el("button", s.state === "needs-auth" ? "btn" : "btn secondary", "Sign in");
          si.dataset.k = "signin";
          si.onclick = () => signIn(s);
          const so = ctx.el("button", "btn secondary", "Sign out");
          so.dataset.k = "signout";
          so.onclick = () => { ctx.closeSheet(); runJob(`Signing out of ${s.name}`, { action: "mcp_logout", name: s.name, local: s.defined === "project", cwd: project || null }); };
          actions.append(so, si);
        }
        if (liveChat() && s.enabled) {
          const rc = ctx.el("button", "btn secondary", "Reconnect");
          rc.dataset.k = "reconnect";
          rc.onclick = () => reconnect(s);
          actions.prepend(rc);
        }
        if (actions.children.length) b.append(actions);
        if (s.defined) {
          const rm = ctx.el("button", "btn secondary small", "Remove…");
          rm.dataset.k = "remove";
          rm.style.color = "var(--danger)";
          const r2 = ctx.el("div", "btn-row");
          r2.append(rm);
          rm.onclick = () => {
            r2.innerHTML = "";
            r2.before(ctx.el("div", "mc-text", `Remove <b>${esc(s.name)}</b> from ${s.defined === "project" ? "this project's" : "the global"} mcp.json?`));
            const no = ctx.el("button", "btn secondary", "Cancel");
            no.onclick = () => { ctx.closeSheet(); serverSheet(s); };
            const yes = ctx.el("button", "btn", "Remove");
            yes.dataset.k = "confirm-remove";
            yes.style.background = "var(--danger)";
            yes.onclick = () => { ctx.closeSheet(); runJob(`Removing ${s.name}`, { action: "mcp_remove", name: s.name, local: s.defined === "project", cwd: s.defined === "project" ? project : null }); };
            r2.append(no, yes);
          };
          b.append(r2);
        }
      });
    }

    function addSheet() {
      const f = { type: "command", scope: "global", exposure: "codemode" };
      ctx.openSheet((b) => {
        b.classList.add("mc-sheet");
        b.dataset.k = "add";
        b.append(ctx.el("div", "sheet-title", "Add an MCP server"));
        const form = ctx.el("div", "mc-form");
        const input = (key, label, ph, area = false) => {
          const l = ctx.el("label", "", esc(label));
          const w = ctx.el("div", "field");
          const i = ctx.el(area ? "textarea" : "input");
          i.placeholder = ph; i.autocapitalize = "off"; i.autocomplete = "off"; i.spellcheck = false;
          i.dataset.k = key;
          w.append(i);
          form.append(l, w);
          return { l, w, i };
        };
        const segOf = (key, opts, onPick) => {
          const seg = ctx.el("div", "seg");
          for (const [v, label] of opts) {
            const o = ctx.el("button", v === f[key] ? "on" : "", label);
            o.dataset[key] = v;
            o.onclick = () => { f[key] = v; seg.querySelectorAll("button").forEach((x) => x.classList.toggle("on", x === o)); onPick?.(); };
            seg.append(o);
          }
          form.append(seg);
          return seg;
        };
        const name = input("name", "Name", "letters, digits, _ and -");
        segOf("type", [["command", "Command (stdio)"], ["url", "URL (HTTP)"]], () => show());
        const cmd = input("command", "Command", "npx");
        const args = input("args", "Arguments, one per line", "-y\n@modelcontextprotocol/server-filesystem\n.", true);
        const env = input("env", "Environment, KEY=VALUE per line", "API_KEY=${MY_API_KEY}", true);
        const url = input("url", "URL", "https://example.com/mcp");
        const headers = input("headers", "Headers, Name=Value per line", "Authorization=Bearer ${DOCS_TOKEN}", true);
        const desc = input("description", "What it offers (optional)", "Search the product docs");
        form.append(ctx.el("label", "", "Exposure"));
        segOf("exposure", EXPOSURES);
        if (project) { form.append(ctx.el("label", "", "Where")); segOf("scope", [["global", "Global"], ["project", "This project"]]); }
        const show = () => {
          for (const x of [cmd, args, env]) { x.l.hidden = x.w.hidden = f.type !== "command"; }
          for (const x of [url, headers]) { x.l.hidden = x.w.hidden = f.type !== "url"; }
        };
        show();
        b.append(form);
        b.append(ctx.el("div", "sheet-sub", "Values are saved in mcp.json as written; put secrets in environment variables (${NAME}). HTTP servers without an Authorization header can sign in with OAuth."));
        const lines = (t) => t.value.split("\n").map((x) => x.trim()).filter(Boolean);
        const row = ctx.el("div", "btn-row");
        const go = ctx.el("button", "btn", "Add");
        go.dataset.k = "add-server";
        go.onclick = () => {
          const n = name.i.value.trim();
          if (!/^[A-Za-z0-9_-]+$/.test(n)) return ctx.toast("The name can only have letters, digits, _ and -", true);
          const body = { action: "mcp_add", name: n, local: f.scope === "project", cwd: f.scope === "project" ? project : null, exposure: f.exposure === "codemode" ? null : f.exposure, description: desc.i.value.trim() || null };
          if (f.type === "command") {
            if (!cmd.i.value.trim()) return ctx.toast("Give the command", true);
            Object.assign(body, { command: cmd.i.value.trim(), args: args.i.value.split("\n").map((x) => x.trim()).filter(Boolean), env: lines(env.i) });
          } else {
            if (!/^https?:\/\//.test(url.i.value.trim())) return ctx.toast("The URL starts with https://", true);
            Object.assign(body, { url: url.i.value.trim(), headers: lines(headers.i) });
          }
          if ([...(body.env || []), ...(body.headers || [])].some((x) => !x.includes("="))) return ctx.toast("Each line is KEY=VALUE", true);
          ctx.closeSheet();
          runJob(`Adding ${n}`, body);
        };
        row.append(go);
        b.append(row);
      });
    }

    function pickProject() {
      ctx.openSheet((b) => {
        b.append(ctx.el("div", "sheet-title", "Show MCP servers for"));
        const choose = (p) => { ctx.closeSheet(); project = p; list = null; load(); };
        b.append(Object.assign(ctx.el("button", "opt", `<div class="o-main"><div class="o-t">No project</div><div class="o-s">Global servers only</div></div>`), { onclick: () => choose("") }));
        for (const p of projects) {
          const o = ctx.el("button", "opt", `<div class="o-main"><div class="o-t">${esc(p.name)}</div><div class="o-s">${esc(tilde(p.path))}</div></div>`);
          o.dataset.path = p.path;
          o.onclick = () => choose(p.path);
          b.append(o);
        }
      });
    }

    // ------------------------------------------------------------ page
    function draw() {
      el.innerHTML = "";
      const pcard = ctx.el("div", "wf-card");
      const cur = projects.find((p) => p.path === project);
      const pick = ctx.el("button", "opt mc-pick", `<div class="o-main"><div class="o-t">${esc(cur?.name || (project ? tilde(project) : "No project"))}</div><div class="o-s">${esc(project ? tilde(project) : "Global servers only")}</div></div>`);
      pick.append(ctx.el("span", "mp-chev", ctx.ICON.chev));
      pick.dataset.k = "project";
      pick.onclick = pickProject;
      pcard.append(pick);
      el.append(pcard);
      if (list?.note) el.append(ctx.el("div", "mc-note warn", esc(list.note)));

      const all = servers();
      el.append(ctx.el("div", "wf-section", "Servers"));
      const card = ctx.el("div", "wf-card");
      for (const s of all) {
        const row = ctx.el("button", "mc-row");
        row.dataset.name = s.name;
        const m = ctx.el("div", "mc-main");
        m.append(ctx.el("div", "mc-name", esc(s.name)), ctx.el("div", "mc-sub", esc(s.transport)));
        const chips = ctx.el("div", "mc-chips");
        const [chip, cls] = stateChip(s);
        chips.append(ctx.el("span", `chip ${cls}`, esc(chip)), ctx.el("span", "chip", esc(s.scope)));
        if (s.exposure !== "codemode") chips.append(ctx.el("span", "chip", esc(s.exposure)));
        if (s.override) chips.append(ctx.el("span", "chip", "project override"));
        m.append(chips);
        row.append(m, ctx.el("span", "mp-chev", ctx.ICON.chev));
        row.onclick = () => serverSheet(s);
        card.append(row);
      }
      if (!all.length) card.append(ctx.el("div", "list-empty", "No MCP servers yet."));
      el.append(card);
      for (const e of list?.errors || []) el.append(ctx.el("div", "mc-note warn", esc(e)));
      if (list?.error) el.append(ctx.el("div", "mc-note warn", `pi mcp list: ${esc(list.error)}`));
      else if (listing) el.append(ctx.el("div", "mc-note", "Connecting to each server to check it…"));

      const a = ctx.el("div", "mc-actions");
      const add = ctx.el("button", "btn small", "Add a server");
      add.dataset.k = "add";
      add.onclick = addSheet;
      const re = ctx.el("button", "btn secondary small", "Check again");
      re.onclick = () => load(true);
      a.append(add, re);
      el.append(a);
      logBox = ctx.el("div", "mc-log");
      logBox.dataset.k = "log";
      el.append(logBox);
      drawLog();
      el.append(ctx.el("div", "mc-note", "Chats load MCP changes when they restart. Sign-in runs /mcp login in a chat for this project (the open one, or a new one) and finishes here."));
    }

    await load();
    return () => { es?.close(); es = null; };
  },
});
