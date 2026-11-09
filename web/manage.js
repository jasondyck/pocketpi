"use strict";
// pocketpi Settings hub: the "Settings" view (`?m=` for the hub, `?m=<id>`
// for a page) and the "Restart to apply" banner. Loaded after app.js and uses
// its globals ($, el, esc, api, toast, openSheet, closeSheet, showView, S).
//
// ---------------------------------------------------------------- contract
// (also docs/pi-parity-plan.md §7)
//
// A page is one file, web/manage-<id>.js, plus ONE line in src/main.rs:
//
//     const MANAGE_PAGES: &[(&str, &[u8])] = &[ ..., manage_page!("<id>"), ];
//
// That embeds the file, serves it at /manage/<id>.js and lists it in
// GET /api/manage/pages; this hub loads every listed page on first open.
// Nothing in index.html, app.js or this file changes. The file calls:
//
//   ppManage.register({
//     id: "<id>",            // [a-z0-9-]+, same as the file name; the URL is ?m=<id>
//     title: "Providers",    // the hub row and the page heading
//     subtitle: "API keys",  // optional: the hub row's second line (string or () => string)
//     icon: "<svg …>",       // optional: 24×24 stroke icon, like app.js's ICON.*
//     order: 30,             // hub position, ascending (see the table in §7)
//     render(el, ctx) {},    // fill `el` (empty); may be async. Return a function
//                            // to have it called when the page is left.
//   });
//
// ctx:
//   api(path, body?)     app.js's api(): GET without body, POST JSON with
//                        X-Pocketpi: 1 when body is given; throws Error with .status.
//   toast(msg, error?)   app.js's toast.
//   openSheet(build) / closeSheet()   app.js's bottom sheet.
//   navigate(id)         go to another page ("" = the hub).
//   rerender()           render this page again from scratch.
//   needsRestart()       call after anything that changes pi's config (a
//                        config POST or a job that ends with changed:true):
//                        refetches /api/pi/status and shows "Restart to apply"
//                        if any chat's pi is behind. Returns the status.
//   status()             last /api/pi/status ({config_epoch, live, control}) or null.
//   models()             the models pi can use (get_available_models from a
//                        running chat's pi, or from one started for the purpose
//                        and closed again), sorted; kept for a minute.
//   project              the drawer's selected project path ("" = none), for
//                        project-scoped config (?cwd=).
//   home                 the server's $HOME.
//   style(css)           add CSS once per page (scope it under .mp-<id>,
//                        which `el` carries), so nobody edits app.css.
//   el, esc, ICON        app.js's helpers and icons.
//
// Pages reuse app.js's classes: .wf-section (headings), .wf-card (grouped
// rows), .opt rows (.o-main/.o-t/.o-s), .switch, .chip, .btn/.btn-row,
// .field, .errbox, .list-empty. Pages must never show secrets (the server
// redacts them) and must write config only as patches.

window.ppManage = (() => {
  const pages = new Map();
  let pageList = null;        // promise: every listed page script loaded
  let current = null;         // { id, cleanup }
  let status = null;          // /api/pi/status
  let busyLeft = [];          // keys /api/pi/reload left alone (streaming)
  let reloading = false;
  const styled = new Set();
  const GEAR = '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="3"/><path d="M12 2.8v2.4M12 18.8v2.4M2.8 12h2.4M18.8 12h2.4M5.5 5.5l1.7 1.7M16.8 16.8l1.7 1.7M5.5 18.5l1.7-1.7M16.8 7.2l1.7-1.7"/></svg>';
  const BACK = '<svg viewBox="0 0 24 24"><path d="M15 6l-6 6 6 6"/></svg>';

  function register(p) {
    if (!p || !/^[a-z0-9-]+$/.test(p.id || "") || typeof p.render !== "function" || !p.title) {
      console.error("ppManage.register: needs id, title and render", p);
      return;
    }
    pages.set(p.id, { order: 100, ...p });
    if (S.view === "manage" && !current) renderHub();
  }

  function loadPages() {
    if (!pageList) {
      pageList = api("/api/manage/pages").then((r) => Promise.all((r.pages || []).map((id) => new Promise((res) => {
        const s = document.createElement("script");
        s.src = `/manage/${id}.js`; s.onload = res; s.onerror = () => { console.error(`couldn't load page ${id}`); res(); };
        document.head.append(s);
      })))).catch((e) => { pageList = null; throw e; });
    }
    return pageList;
  }

  function setUrl(id) {
    const url = new URL(location.href);
    ["s", "w", "r"].forEach((k) => url.searchParams.delete(k));
    url.searchParams.set("m", id || "");
    history.replaceState(null, "", url);
  }

  function leave() {
    const c = current; current = null;
    if (c && typeof c.cleanup === "function") { try { c.cleanup(); } catch (e) { console.error(e); } }
  }

  // Show the hub ("") or a page. The hub's entry points call this.
  async function open(id = "") {
    closeSheet(); closeDrawer();
    if (S.view === "chat") resetChat();
    leave();
    showView("manage"); setUrl(id);
    header(id ? pages.get(id)?.title || "Settings" : "Settings", id ? "Settings" : "pi and pocketpi");
    $("project-badge").outerHTML = `<span id="project-badge" class="badge mp-badge">${GEAR}</span>`;
    const v = $("wfview"); v.innerHTML = '<div class="wf-loading">Loading…</div>';
    refreshStatus();
    try { await loadPages(); } catch (e) { v.innerHTML = `<div class="errbox">${esc(e.message)}</div>`; return; }
    if (S.view !== "manage") return;
    if (!id) return renderHub();
    const p = pages.get(id);
    if (!p) { toast(`No settings page “${id}”`, true); return open(""); }
    header(p.title, "Settings");
    renderPage(p);
  }

  function renderHub() {
    const v = $("wfview"); v.innerHTML = "";
    v.append(el("div", "wf-section", "Settings"));
    const card = el("div", "wf-card mp-list");
    const list = [...pages.values()].sort((a, z) => a.order - z.order || a.title.localeCompare(z.title));
    for (const p of list) {
      const sub = typeof p.subtitle === "function" ? p.subtitle() : p.subtitle;
      const row = opt(p.icon || GEAR, esc(p.title), sub ? esc(sub) : null, () => open(p.id));
      row.dataset.page = p.id;
      row.append(el("span", "mp-chev", ICON.chev));
      card.append(row);
    }
    if (!list.length) card.append(el("div", "list-empty", "No settings pages yet."));
    v.append(card);
  }

  // The models pi can use: get_available_models from a running chat's pi, or
  // from a pi started for the purpose (no messages, so no session file) and
  // closed again. Kept for a minute.
  let modelCache = null;
  async function availableModels() {
    if (modelCache && Date.now() - modelCache.at < 60000) return modelCache.list;
    const ask = async (key) => {
      const r = await api(`/api/s/${key}/cmd`, { type: "get_available_models" });
      if (r.success === false) throw new Error(r.error || "get_available_models failed");
      return r.data?.models || [];
    };
    let list = null;
    const live = (status?.live || []).filter((l) => l.kind !== "stage");
    const pick = live.find((l) => l.kind === "chat" && !l.stale) || live[0];
    if (pick) list = await ask(pick.key).catch(() => null);
    if (!list) {
      const t = await api("/api/new", { cwd: "~" });
      try { list = await ask(t.key); } finally { api(`/api/s/${t.key}/close`, {}).catch(() => {}); }
    }
    list.sort((a, z) => a.provider.localeCompare(z.provider) || (a.name || a.id).localeCompare(z.name || z.id));
    modelCache = { at: Date.now(), list };
    return list;
  }

  async function renderPage(p) {
    const v = $("wfview"); v.innerHTML = "";
    const back = el("button", "copy mp-back", `${BACK}Settings`); back.onclick = () => open("");
    const body = el("div", `mp-page mp-${p.id}`);
    v.append(back, el("h2", "mp-title", esc(p.title)), body);
    const me = { id: p.id, cleanup: null };
    current = me;
    const ctx = {
      api, toast, openSheet, closeSheet, el, esc, ICON,
      navigate: (id) => open(id),
      rerender: () => { if (current === me) { leave(); open(p.id); } },
      needsRestart: refreshStatus,
      status: () => status,
      models: availableModels,
      project: S.project || "",
      home: S.home || "",
      style(css) {
        if (styled.has(p.id)) return;
        styled.add(p.id);
        const st = document.createElement("style"); st.dataset.page = p.id; st.textContent = css; document.head.append(st);
      },
    };
    try {
      const r = await p.render(body, ctx);
      if (current === me) me.cleanup = r; else if (typeof r === "function") r();
    } catch (e) {
      body.append(el("div", "errbox", esc(e.message || String(e))));
    }
  }

  // ---------------------------------------------------------------- restart to apply
  // Which pis are behind the config epoch. In Settings: any chat's pi; in a
  // chat: this chat's. Busy (streaming) ones can't be restarted yet.
  function stale() { return (status?.live || []).filter((l) => l.stale && l.kind !== "stage"); }

  async function refreshStatus() {
    try { status = await api("/api/pi/status"); } catch { /* keep the last one */ }
    busyLeft = busyLeft.filter((k) => stale().some((l) => l.key === k));
    renderBanner();
    return status;
  }

  function renderBanner() {
    const b = $("pp-restart"); if (!b) return;
    let text = null;
    if (S.view === "manage") {
      const st = stale();
      if (st.length) {
        const busy = st.filter((l) => l.streaming).length;
        text = `Settings changed. ${plural(st.length, "open chat")} still ${st.length === 1 ? "uses" : "use"} the old ones${busy ? ` (${busy} busy)` : ""}.`;
      }
    } else if (S.view === "chat" && S.key) {
      const me = stale().find((l) => l.key === S.key);
      if (me) text = busyLeft.includes(S.key) || me.streaming ? "pi's settings changed. Restart this chat when it finishes to apply them." : "pi's settings changed since this chat started.";
    }
    b.hidden = !text;
    if (!text) return;
    b.innerHTML = `<span>${esc(text)}</span>`;
    const btn = el("button", "mp-apply", reloading ? "Restarting…" : "Restart to apply");
    btn.disabled = reloading;
    btn.onclick = reload;
    b.append(btn);
  }

  // POST /api/pi/reload: restarts every idle chat that's behind; busy ones
  // stay listed until they're idle and this runs again.
  async function reload() {
    reloading = true; renderBanner();
    try {
      const r = await api("/api/pi/reload", {});
      busyLeft = r.busy || [];
      const n = (r.restarted || []).length, f = (r.failed || []).length;
      const parts = [];
      if (n) parts.push(`Restarted ${plural(n, "chat")}`);
      if (busyLeft.length) parts.push(`${plural(busyLeft.length, "busy chat")} left: try again when ${busyLeft.length === 1 ? "it finishes" : "they finish"}`);
      if (f) parts.push(`${f} failed: ${r.failed[0].error}`);
      toast(parts.join(" · ") || "Nothing to restart", f > 0);
    } catch (e) { toast(e.message, true); }
    reloading = false;
    await refreshStatus();
  }

  // ---------------------------------------------------------------- hooks from app.js
  // pocketpi_hello: this chat's pi (re)started; ev.stale says if it's behind.
  function chatHello(ev) {
    const l = status?.live?.find((x) => x.key === S.key);
    if (l) { l.stale = !!ev.stale; l.epoch = ev.epoch; }
    else if (ev.stale && S.key) (status ||= { live: [] }).live.push({ key: S.key, stale: true, kind: ev.kind || "chat", streaming: !!ev.streaming });
    renderBanner();
    if (ev.stale) refreshStatus();
  }
  // config_changed on /api/runs/events.
  function configChanged() { refreshStatus(); }
  // The chat sheet (and the new-chat sheet): a way in.
  function sheetEntry(b) { b.append(opt(GEAR, "Settings", "pi's settings, providers and resources", () => open(""))); }
  // showView(v): leaving Settings runs the page's cleanup; the banner follows the view.
  function viewChanged(v) { if (v !== "manage") leave(); tile.classList.toggle("active", v === "manage"); renderBanner(); }

  // ---------------------------------------------------------------- setup
  const css = document.createElement("style");
  css.textContent = `
#pp-restart { margin: 6px 12px 0; padding: 8px 8px 8px 12px; border-radius: 12px; font-size: 13.5px; display: flex; align-items: center; gap: 10px;
  background: color-mix(in srgb, var(--warn) 12%, var(--bg)); color: var(--text); }
#pp-restart[hidden] { display: none; }
#pp-restart span { flex: 1; min-width: 0; }
#pp-restart .mp-apply { flex: none; font: 600 13px var(--font); padding: 7px 11px; border-radius: 9px; background: var(--text); color: var(--bg); }
#pp-restart .mp-apply:disabled { opacity: .6; }
.mp-badge { display: grid; place-items: center; background: var(--surface); color: var(--text-2); }
.mp-badge svg { width: 16px; height: 16px; }
.rail-settings { margin-top: auto; background: var(--surface); }
.rail-settings svg, .mp-list .opt > svg { width: 20px; height: 20px; }
.mp-list .opt { border-radius: 0; padding: 12px 14px; }
.mp-list .opt + .opt { border-top: 1px solid var(--line); }
.mp-chev { color: var(--muted); display: grid; } .mp-chev svg { width: 16px; height: 16px; }
.mp-back { display: inline-flex; align-items: center; gap: 2px; margin: 6px 0 0 -6px; }
.mp-back svg { width: 16px; height: 16px; }
.mp-title { font-size: 22px; font-weight: 650; letter-spacing: -0.02em; margin: 6px 0 10px; }`;
  document.head.append(css);
  const bar = el("div"); bar.id = "pp-restart"; bar.hidden = true;
  $("banner").after(bar);
  const tile = el("button", "rail-tile rail-settings", GEAR);
  tile.title = "Settings"; tile.setAttribute("aria-label", "Settings");
  tile.onclick = () => open("");
  $("rail").append(tile);
  refreshStatus();

  return { register, open, chatHello, configChanged, sheetEntry, viewChanged, needsRestart: refreshStatus, pages };
})();
