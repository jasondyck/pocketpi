"use strict";
// Terminal panel (docs/dsh-features-plan.md §3.6): "Terminal" in the chat
// sheet opens shells in the side panel, one tab each, started in the chat's
// folder. The server side is src/term.rs (GET /api/term/ws).
//
// - xterm.js and its fit addon (web/vendor/xterm, MIT) load on first open.
// - Open terminals are saved in localStorage ("pp.terms": [{id, root}]), so a
//   reload or reopening the panel reattaches; the server replays the last
//   256 KiB of output.
// - Typed input goes out only while connected; anything typed while the
//   socket is down is dropped, never queued and replayed later.
// - A dropped socket reconnects with backoff (0.5 s doubling to 15 s).
// Plugs into app.js through window.pp (see "feature hooks" there).

window.ppTerm = (() => {
  const XT = "/vendor/xterm-5.5.0";
  const STORE = "pp.terms", ACTIVE = "pp.term.active";
  const MAX = 8, CHUNK = 16384, MAX_TRIES = 8;
  const KEYS = [["Esc", "\x1b"], ["Tab", "\t"], ["^C", "\x03"], ["^D", "\x04"], ["↑", "\x1b[A"], ["↓", "\x1b[B"], ["←", "\x1b[D"], ["→", "\x1b[C"]];

  let loading = null;   // Promise for the xterm scripts
  let ui = null;        // { panel, bar, stage, status, ro } while the panel is open
  let tabs = [];        // { id, root, term, fit, host, btn, ws, ready, tries, timer, ended, shown }
  let active = null;

  // ------------------------------------------------------------ storage
  function saved() {
    try {
      const v = JSON.parse(localStorage.getItem(STORE) || "[]");
      return Array.isArray(v) ? v.filter((x) => x && typeof x.id === "string" && typeof x.root === "string") : [];
    } catch { return []; }
  }
  function savedActive() { try { return localStorage.getItem(ACTIVE) || ""; } catch { return ""; } }
  function save() {
    try {
      localStorage.setItem(STORE, JSON.stringify(tabs.filter((t) => t.id && !t.ended).map((t) => ({ id: t.id, root: t.root }))));
      localStorage.setItem(ACTIVE, active?.id || "");
    } catch { /* private mode: no reattach after a reload */ }
  }

  // ------------------------------------------------------------ xterm
  function loadXterm() {
    if (window.Terminal && window.FitAddon) return Promise.resolve();
    return loading ||= new Promise((resolve, reject) => {
      const css = document.createElement("link");
      css.rel = "stylesheet"; css.href = `${XT}/xterm.css`;
      document.head.append(css);
      const script = (src) => new Promise((ok, no) => {
        const s = document.createElement("script");
        s.src = src; s.onload = ok; s.onerror = () => no(new Error(`Couldn't load ${src}`));
        document.head.append(s);
      });
      script(`${XT}/xterm.js`).then(() => script(`${XT}/addon-fit.js`)).then(resolve, (e) => { loading = null; reject(e); });
    });
  }

  function theme() {
    const cs = getComputedStyle(document.body);
    const v = (n, d) => cs.getPropertyValue(n).trim() || d;
    return { background: v("--bg", "#121314"), foreground: v("--text", "#ededea"), cursor: v("--text", "#ededea"), selectionBackground: "rgba(128,128,128,0.35)" };
  }

  // ------------------------------------------------------------ styles
  function injectStyle() {
    if (document.getElementById("term-style")) return;
    const s = document.createElement("style");
    s.id = "term-style";
    s.textContent = `
.term-panel { height: 100%; display: flex; flex-direction: column; min-height: 0; }
.term-bar { flex: none; display: flex; gap: 4px; padding: 6px 8px; border-bottom: 1px solid var(--line); overflow-x: auto; }
.term-tab { flex: none; display: flex; align-items: center; gap: 6px; max-width: 180px; padding: 4px 6px 4px 10px; border-radius: 8px; border: 1px solid var(--line); background: none; color: var(--text-2); font: inherit; font-size: 13px; cursor: pointer; }
.term-tab.on { background: var(--bg-2); color: var(--text); }
.term-tab .t-name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.term-tab .t-dot { width: 7px; height: 7px; border-radius: 50%; background: var(--text-2); flex: none; opacity: .5; }
.term-tab.live .t-dot { background: #2fa36b; opacity: 1; }
.term-tab.ended .t-dot { background: #c0453a; opacity: 1; }
.term-tab .t-x { border: 0; background: none; color: inherit; padding: 0 2px; font-size: 15px; line-height: 1; cursor: pointer; }
.term-new { flex: none; border: 1px dashed var(--line); background: none; color: var(--text-2); border-radius: 8px; padding: 2px 10px; font-size: 16px; cursor: pointer; }
.term-stage { flex: 1; min-height: 0; position: relative; }
.term-host { position: absolute; inset: 6px 4px 4px 8px; }
.term-host[hidden] { display: none; }
.term-status { flex: none; display: flex; align-items: center; gap: 8px; padding: 4px 10px; font-size: 12px; color: var(--text-2); border-top: 1px solid var(--line); min-height: 26px; }
.term-status .s-msg { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.term-status button { border: 1px solid var(--line); background: none; color: var(--text); border-radius: 6px; padding: 1px 8px; font: inherit; cursor: pointer; }
.term-keys { flex: none; display: flex; gap: 4px; padding: 4px 8px; overflow-x: auto; border-top: 1px solid var(--line); }
.term-keys button { flex: none; min-width: 38px; padding: 5px 8px; border-radius: 6px; border: 1px solid var(--line); background: var(--bg-2); color: var(--text); font-family: var(--mono); font-size: 13px; }
.term-empty { padding: 24px 16px; color: var(--text-2); display: flex; flex-direction: column; gap: 12px; align-items: flex-start; }
@media (hover: hover) and (pointer: fine) { .term-keys { display: none; } }`;
    document.head.append(s);
  }

  // ------------------------------------------------------------ panel
  function rootNow() { return pp.chatInfo().cwd || S.project || active?.root || ""; }

  function sheetEntry(b) {
    const chat = pp.chatInfo();
    if (!chat.cwd) return;
    b.append(opt(ICON.term, "Terminal", "A shell in this chat's folder", () => { closeSheet(); open(chat.cwd); }));
  }

  /** Opens the panel; with `root`, shows a terminal in that folder (a new one if none is open there). */
  async function open(root) {
    root = root || rootNow();
    const panel = el("div", "term-panel");
    panel.append(el("div", "term-empty", "Loading terminal…"));
    pp.panel.open("Terminal", panel, teardown);
    try { await loadXterm(); } catch (e) { panel.innerHTML = ""; panel.append(el("div", "term-empty", esc(e.message))); return; }
    if (!panel.isConnected) return; // closed or replaced while loading
    injectStyle();
    let alive = null;
    try { alive = new Set((await api("/api/term/list")).terms.map((t) => t.id)); } catch { /* reattach blindly */ }
    if (!panel.isConnected) return;
    build(panel);
    for (const s of saved()) if (!alive || alive.has(s.id)) addTab(s);
    const want = root && tabs.find((t) => t.root === root);
    if (root && !want) { if (tabs.length < MAX) addTab({ id: null, root }); else toast(`At most ${MAX} terminals can be open.`, true); }
    const pick = (root && tabs.find((t) => t.root === root && !t.id)) || want || tabs.find((t) => t.id === savedActive()) || tabs[0];
    if (pick) show(pick); else empty();
    save();
  }

  function build(panel) {
    panel.innerHTML = "";
    const bar = el("div", "term-bar");
    const stage = el("div", "term-stage");
    const status = el("div", "term-status", '<span class="s-msg"></span>');
    const keys = el("div", "term-keys");
    for (const [label, seq] of KEYS) {
      const k = el("button", "", esc(label));
      k.type = "button";
      k.onmousedown = (e) => e.preventDefault(); // keep the keyboard up
      k.onclick = () => { if (active) { input(active, seq); active.term.focus(); } };
      keys.append(k);
    }
    panel.append(bar, stage, status, keys);
    const ro = new ResizeObserver(() => fitActive());
    ro.observe(stage);
    ui = { panel, bar, stage, status, ro };
    renderBar();
  }

  function empty() {
    if (!ui) return;
    active = null;
    renderBar();
    const root = rootNow();
    const box = el("div", "term-empty", "No terminals open.");
    if (root) {
      const b = el("button", "btn", "New terminal");
      b.onclick = () => { box.remove(); newTab(); };
      box.append(b);
    }
    ui.stage.append(box);
    setStatus("");
    save();
  }

  function teardown() {
    save();
    for (const t of tabs) dropTab(t);
    tabs = []; active = null;
    ui?.ro.disconnect();
    ui = null;
  }

  function renderBar() {
    if (!ui) return;
    ui.bar.innerHTML = "";
    for (const t of tabs) ui.bar.append(t.btn);
    const plus = el("button", "term-new", "+");
    plus.type = "button"; plus.title = "New terminal";
    plus.onclick = newTab;
    ui.bar.append(plus);
    for (const t of tabs) t.btn.classList.toggle("on", t === active);
  }

  function setStatus(msg, action) {
    if (!ui) return;
    const s = ui.status;
    s.querySelector(".s-msg").textContent = msg;
    s.querySelector("button")?.remove();
    if (action) {
      const b = el("button", "", esc(action[0]));
      b.onclick = action[1];
      s.append(b);
    }
  }

  function tabState(t, state) {
    t.state = state;
    t.btn.classList.toggle("live", state === "live");
    t.btn.classList.toggle("ended", state === "ended");
    if (t !== active) return;
    if (state === "live") setStatus(tilde(t.root));
    else if (state === "connecting") setStatus("Connecting…");
    else if (state === "reconnecting") setStatus("Disconnected; reconnecting… (typing is ignored until then)");
    else if (state === "failed") setStatus(t.error || "Couldn't connect.", ["Retry", () => { t.tries = 0; t.error = null; connect(t); }]);
    else if (state === "ended") setStatus(t.error || "The shell has ended.", ["Close", () => closeTab(t, true)]);
  }

  // ------------------------------------------------------------ tabs
  function newTab() {
    const root = rootNow();
    if (!root) return toast("Open a chat or a project first.", true);
    if (tabs.length >= MAX) return toast(`At most ${MAX} terminals can be open.`, true);
    ui?.stage.querySelector(".term-empty")?.remove();
    const t = addTab({ id: null, root });
    show(t);
  }

  function addTab({ id, root }) {
    const host = el("div", "term-host");
    host.hidden = true;
    ui.stage.append(host);
    const term = new Terminal({
      fontFamily: getComputedStyle(document.body).getPropertyValue("--mono").trim() || "monospace",
      fontSize: 13, cursorBlink: true, scrollback: 5000, theme: theme(),
    });
    const fit = new FitAddon.FitAddon();
    term.loadAddon(fit);
    const btn = el("button", "term-tab", `<span class="t-dot"></span><span class="t-name"></span>`);
    btn.type = "button";
    btn.querySelector(".t-name").textContent = base(root) || root;
    btn.title = root;
    const x = el("span", "t-x", "×");
    x.setAttribute("role", "button"); x.setAttribute("aria-label", "Close terminal");
    btn.append(x);
    const t = { id, root, term, fit, host, btn, ws: null, ready: false, tries: 0, timer: null, ended: false, shown: false, state: "" };
    btn.onclick = (e) => { if (e.target === x) closeTab(t); else show(t); };
    term.onData((d) => input(t, d));
    term.onResize(({ cols, rows }) => { if (t.ready) send(t, { type: "resize", cols, rows }); });
    tabs.push(t);
    renderBar();
    return t;
  }

  function show(t) {
    active = t;
    for (const o of tabs) o.host.hidden = o !== t;
    renderBar();
    if (!t.shown) { t.shown = true; t.term.open(t.host); }
    fitActive();
    if (!t.ws && !t.ended && !t.timer) connect(t);
    tabState(t, t.state || "connecting");
    t.term.focus();
    save();
  }

  function fitActive() {
    const t = active;
    if (!t || !t.shown || !t.host.clientWidth || !t.host.clientHeight) return;
    try { t.fit.fit(); } catch { /* not measurable yet */ }
  }

  async function closeTab(t, quiet) {
    if (!t.ended && t.id && !quiet && !confirm("Close this terminal? Its shell and anything running in it will be stopped.")) return;
    if (!t.ended && t.id) {
      if (t.ready) send(t, { type: "close" });
      else api("/api/term/close", { id: t.id }).catch(() => {});
    }
    dropTab(t);
    t.host.remove();
    tabs = tabs.filter((o) => o !== t);
    if (active === t) { active = null; if (tabs.length) show(tabs[tabs.length - 1]); else empty(); }
    renderBar();
    save();
  }

  /** Forgets a tab on this page (the server's terminal is left alone). */
  function dropTab(t) {
    clearTimeout(t.timer); t.timer = null;
    const ws = t.ws; t.ws = null; t.ready = false;
    try { ws?.close(); } catch { /* already closed */ }
    try { t.term.dispose(); } catch { /* fine */ }
    t.dropped = true;
  }

  // ------------------------------------------------------------ socket
  function send(t, msg) {
    if (t.ws?.readyState === WebSocket.OPEN) t.ws.send(JSON.stringify(msg));
  }

  function input(t, data) {
    if (!t.ready || t.ws?.readyState !== WebSocket.OPEN) return; // dropped, never replayed
    for (let i = 0; i < data.length; i += CHUNK) send(t, { type: "input", data: data.slice(i, i + CHUNK) });
  }

  function connect(t) {
    clearTimeout(t.timer); t.timer = null;
    if (t.dropped || t.ended) return;
    const q = new URLSearchParams({ root: t.root, cols: String(t.term.cols), rows: String(t.term.rows) });
    if (t.id) q.set("id", t.id);
    const ws = new WebSocket(`${location.protocol === "https:" ? "wss:" : "ws:"}//${location.host}/api/term/ws?${q}`);
    ws.binaryType = "arraybuffer";
    t.ws = ws; t.ready = false;
    tabState(t, t.tries ? "reconnecting" : "connecting");
    ws.onmessage = (e) => {
      if (t.ws !== ws) return;
      if (typeof e.data !== "string") { t.term.write(new Uint8Array(e.data)); return; }
      let m; try { m = JSON.parse(e.data); } catch { return; }
      if (m.type === "hello") {
        const had = t.id;
        t.id = m.id; t.root = m.root; t.ready = true; t.tries = 0;
        t.term.reset(); // the replay that follows redraws the screen
        tabState(t, "live");
        if (had && m.new && t === active) setStatus("The earlier shell had ended; this is a new one.");
        fitActive();
        send(t, { type: "resize", cols: t.term.cols, rows: t.term.rows });
        save();
      } else if (m.type === "reset") {
        t.term.reset();
      } else if (m.type === "exit") {
        t.ended = true; t.ready = false;
        const how = m.signal ? `ended (${m.signal})` : m.code ? `exited with code ${m.code}` : "exited";
        t.term.write(`\r\n\x1b[2m[shell ${how}]\x1b[0m\r\n`);
        tabState(t, "ended");
        save();
      } else if (m.type === "error") {
        t.ended = true; t.ready = false; t.error = m.message;
        tabState(t, "ended");
        save();
      }
    };
    ws.onclose = () => {
      if (t.ws !== ws) return;
      t.ws = null; t.ready = false;
      if (t.dropped || t.ended) return;
      if (++t.tries > MAX_TRIES) { t.error = "Couldn't reach the terminal."; return tabState(t, "failed"); }
      tabState(t, "reconnecting");
      t.timer = setTimeout(() => connect(t), Math.min(15000, 500 * 2 ** (t.tries - 1)));
    };
  }

  /** Reconnects at once when the page comes back (phones drop sockets in the background). */
  function wake() {
    if (document.visibilityState !== "visible") return;
    for (const t of tabs) if (!t.ws && !t.ended && !t.dropped && t.shown) { t.tries = 0; connect(t); }
  }
  document.addEventListener("visibilitychange", wake);
  window.addEventListener("online", wake);

  pp.sheet.push(sheetEntry);
  return { open };
})();
