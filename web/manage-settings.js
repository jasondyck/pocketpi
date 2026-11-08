"use strict";
// Settings › pi settings: typed controls for the keys in pi's global
// ~/.pi/agent/settings.json that matter to a pi under pocketpi (models,
// favourites, thinking per model, queue modes, compaction, retry, images,
// display). TUI-only keys aren't offered; they and anything else pocketpi
// doesn't know survive because every write is a patch (POST
// /api/pi/config/settings {set, unset}). Global: terminal pi and workflow
// stages see the same file. The iOS twin is SettingsPiPage.swift with
// PocketPiKit's PiSettings.swift (same keys, same defaults).
(() => {
  const LEVELS = ["off", "minimal", "low", "medium", "high", "xhigh", "max"];
  const QUEUE = [["one-at-a-time", "One at a time"], ["all", "All at once"]];
  const choice = (values, def) => ({ type: "choice", values: values.map((v) => (Array.isArray(v) ? v : [v, v])), def });
  // [group, key, title, detail, kind]: the plain settings, in page order.
  const SPECS = [
    ["models", "defaultThinkingLevel", "Default thinking", "Thinking level for new chats (clamped to what the model supports).", choice(LEVELS, "medium")],
    ["queue", "steeringMode", "Steering messages", "Messages sent while pi works: delivered one per turn, or all together.", choice(QUEUE, "one-at-a-time")],
    ["queue", "followUpMode", "Follow-up messages", "Messages queued for after the turn: one per turn, or all together.", choice(QUEUE, "one-at-a-time")],
    ["compaction", "compaction.enabled", "Auto-compact", "Summarise older messages when the context fills up.", { type: "toggle", def: true }],
    ["compaction", "compaction.reserveTokens", "Reserve tokens", "Compact when fewer free context tokens than this are left.", { type: "number", def: 16384, min: 0 }],
    ["compaction", "compaction.keepRecentTokens", "Keep recent tokens", "Recent tokens kept word for word, not summarised.", { type: "number", def: 20000, min: 0 }],
    ["retry", "retry.enabled", "Auto-retry", "Retry transient provider errors (overloaded, rate limits) with backoff.", { type: "toggle", def: true }],
    ["retry", "retry.maxRetries", "Max retries", "Attempts before giving up.", { type: "number", def: 3, min: 0, max: 100 }],
    ["images", "images.autoResize", "Resize images", "Shrink images to at most 2000×2000 before sending them.", { type: "toggle", def: true }],
    ["images", "images.blockImages", "Block images", "Never send images to models.", { type: "toggle", def: false }],
    ["display", "hideThinkingBlock", "Hide thinking", "Leave thinking blocks out of the transcript.", { type: "toggle", def: false }],
  ].map(([group, key, title, detail, kind]) => ({ group, key, title, detail, ...kind }));

  const UP = '<svg viewBox="0 0 24 24"><path d="M6 15l6-6 6 6"/></svg>';
  const DOWN = '<svg viewBox="0 0 24 24"><path d="M6 9l6 6 6-6"/></svg>';
  const SLIDERS = '<svg viewBox="0 0 24 24"><path d="M4 7h10M18 7h2M4 17h4M12 17h8"/><circle cx="16" cy="7" r="2"/><circle cx="10" cy="17" r="2"/></svg>';

  // ---------------------------------------------------------------- helpers (as in PiSettings.swift)
  const seg = (s) => s.replace(/\\/g, "\\\\").replace(/\./g, "\\.");
  const valueAt = (data, key) => { let v = data; for (const p of key.split(".")) v = v && typeof v === "object" ? v[p] : undefined; return v ?? undefined; };
  function effective(data, spec) {
    const v = valueAt(data, spec.key);
    if (spec.type === "toggle") return typeof v === "boolean" ? v : spec.def;
    if (spec.type === "number") return typeof v === "number" ? v : spec.def;
    return spec.values.some(([x]) => x === v) ? v : spec.def;
  }
  function parseNumber(text, spec) {
    const t = String(text).trim().replace(/[_,]/g, "");
    if (!t) return { value: null };
    if (!/^-?\d+$/.test(t)) return { error: "Enter a whole number" };
    const n = Number(t);
    if (spec.min != null && n < spec.min) return { error: `At least ${spec.min}` };
    if (spec.max != null && n > spec.max) return { error: `At most ${spec.max}` };
    return { value: n };
  }
  // enabledModels entries: "pattern" or "pattern:<thinking>".
  function parsePattern(raw) {
    raw = String(raw).trim();
    const i = raw.lastIndexOf(":");
    const suf = i > 0 ? raw.slice(i + 1).toLowerCase() : "";
    return LEVELS.includes(suf) ? { pattern: raw.slice(0, i), thinking: suf } : { pattern: raw, thinking: null };
  }
  const rawPattern = (p) => (p.thinking ? `${p.pattern}:${p.thinking}` : p.pattern);
  const glob = (pattern, s) => new RegExp("^" + pattern.toLowerCase().split("*").map((x) => x.replace(/[.+?^${}()|[\]\\]/g, "\\$&")).join(".*") + "$").test(s.toLowerCase());
  const matches = (p, m) => glob(p.pattern, `${m.provider}/${m.id}`) || glob(p.pattern, m.id);

  // The models pi can use: get_available_models from a running chat's pi, or
  // from a pi started for the purpose (no messages, so no session file) and
  // closed again. Kept for a minute.
  let modelCache = null;
  async function availableModels(ctx) {
    if (modelCache && Date.now() - modelCache.at < 60000) return modelCache.list;
    const ask = async (key) => {
      const r = await ctx.api(`/api/s/${key}/cmd`, { type: "get_available_models" });
      if (r.success === false) throw new Error(r.error || "get_available_models failed");
      return r.data?.models || [];
    };
    let list = null;
    const live = (ctx.status()?.live || []).filter((l) => l.kind !== "stage");
    const pick = live.find((l) => l.kind === "chat" && !l.stale) || live[0];
    if (pick) list = await ask(pick.key).catch(() => null);
    if (!list) {
      const t = await ctx.api("/api/new", { cwd: "~" });
      try { list = await ask(t.key); } finally { ctx.api(`/api/s/${t.key}/close`, {}).catch(() => {}); }
    }
    list.sort((a, z) => a.provider.localeCompare(z.provider) || (a.name || a.id).localeCompare(z.name || z.id));
    modelCache = { at: Date.now(), list };
    return list;
  }

  ppManage.register({
    id: "settings",
    title: "pi settings",
    subtitle: "Models, favourites, queue, compaction, retry",
    icon: SLIDERS,
    order: 10,
    async render(root, ctx) {
      const { el, esc } = ctx;
      ctx.style(`.mp-settings .st-global { font-size: 13px; color: var(--text-2); background: var(--surface); border-radius: 12px; padding: 10px 12px; line-height: 1.4; }
.mp-settings .st-global code { font: 12px var(--mono); }
.mp-settings .wf-section { display: flex; align-items: center; gap: 8px; }
.mp-settings .st-tag { font: 600 10px var(--font); letter-spacing: .04em; color: var(--warn); border: 1px solid color-mix(in srgb, var(--warn) 45%, transparent); border-radius: 999px; padding: 1px 6px; }
.mp-settings .st-row { display: flex; align-items: center; gap: 12px; padding: 11px 14px; }
.mp-settings .wf-card > * + * { border-top: 1px solid var(--line); }
.mp-settings .st-main { flex: 1; min-width: 0; }
.mp-settings .st-t { font-size: 15px; }
.mp-settings .st-s { font-size: 12.5px; color: var(--muted); margin-top: 1px; line-height: 1.35; }
.mp-settings .st-s.mono, .mp-settings .st-t.mono { font-family: var(--mono); letter-spacing: -0.02em; overflow-wrap: anywhere; }
.mp-settings .st-t.mono { font-size: 13.5px; }
.mp-settings select, .mp-settings input.st-num { font: 500 13.5px var(--font); color: var(--text); background: var(--surface); border: 0; border-radius: 10px; height: 34px; padding: 0 8px; max-width: 46%; flex: none; }
.mp-settings input.st-num { width: 96px; text-align: right; font-family: var(--mono); outline: 0; }
.mp-settings input.st-num:focus { box-shadow: 0 0 0 1.5px var(--text-2); }
.mp-settings .st-icon { width: 30px; height: 30px; border-radius: 9px; display: grid; place-items: center; color: var(--text-2); flex: none; }
.mp-settings .st-icon:disabled { opacity: .3; }
.mp-settings .st-icon svg { width: 17px; height: 17px; }
.mp-settings .st-add { width: 100%; padding: 12px 14px; text-align: left; font-size: 15px; font-weight: 500; color: var(--text); display: flex; align-items: center; gap: 8px; }
.mp-settings .st-add svg { width: 18px; height: 18px; }
.mp-settings .st-row.st-wrap { flex-wrap: wrap; row-gap: 6px; }
.mp-settings .st-wrap .st-main { flex-basis: 100%; }
.mp-settings .st-wrap select { margin-right: auto; max-width: 60%; }
.mp-settings .opt.switch-row .o-s { white-space: normal; }
.mp-settings .st-pick { display: flex; align-items: center; gap: 12px; width: 100%; text-align: left; padding: 11px 14px; }
.mp-settings .st-pick .st-v { font: 13px var(--mono); color: var(--text-2); max-width: 55%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.mp-settings .mp-chev svg { width: 16px; height: 16px; }`);
      root.append(el("div", "wf-loading", "Loading…"));
      let doc = (await ctx.api("/api/pi/config/settings"));
      let models = modelCache?.list || null;
      let saving = false;

      async function write(patch, done) {
        if (saving) return;
        saving = true;
        try {
          doc = await ctx.api("/api/pi/config/settings", { set: patch.set || {}, unset: patch.unset || [] });
          await ctx.needsRestart();
          if (done) ctx.toast(done);
        } catch (e) { ctx.toast(e.message, true); }
        saving = false;
        draw();
      }
      async function loadModels() {
        if (models) return models;
        try { models = await availableModels(ctx); } catch (e) { ctx.toast(`Couldn't list models: ${e.message}`, true); models = null; }
        return models || [];
      }

      // ------------------------------------------------------------ controls
      const section = (title) => {
        const h = el("div", "wf-section", `<span>${esc(title)}</span><span class="st-tag">GLOBAL</span>`);
        return h;
      };
      function select(options, value, onChange) {
        const s = el("select");
        for (const [v, label] of options) { const o = el("option", "", esc(label)); o.value = v; s.append(o); }
        s.value = value; s.onchange = () => onChange(s.value);
        return s;
      }
      function row(title, sub, control, mono = false) {
        const r = el("div", "st-row", `<div class="st-main"><div class="st-t${mono ? " mono" : ""}">${title}</div>${sub ? `<div class="st-s">${sub}</div>` : ""}</div>`);
        if (control) r.append(...[].concat(control));
        return r;
      }
      function control(spec) {
        const data = doc.data || {};
        const set = valueAt(data, spec.key) !== undefined;
        if (spec.type === "toggle") {
          const on = effective(data, spec);
          const b = el("button", "opt switch-row", `<div class="o-main"><div class="o-t">${esc(spec.title)}</div><div class="o-s">${esc(spec.detail)}</div></div><span class="switch${on ? " on" : ""}"><i></i></span>`);
          b.dataset.key = spec.key;
          b.onclick = () => write({ set: { [spec.key]: !on } }, `${spec.title} ${on ? "off" : "on"}`);
          return b;
        }
        if (spec.type === "choice") {
          const defLabel = spec.values.find(([v]) => v === spec.def)[1];
          const s = select([["", "Default"], ...spec.values], set ? effective(data, spec) : "", (v) =>
            write(v ? { set: { [spec.key]: v } } : { unset: [spec.key] }));
          s.dataset.key = spec.key;
          return row(esc(spec.title), `${esc(spec.detail)} Default: ${esc(defLabel.toLowerCase())}.`, s);
        }
        const i = el("input", "st-num"); i.type = "text"; i.inputMode = "numeric"; i.dataset.key = spec.key;
        i.placeholder = String(spec.def); i.value = set ? String(valueAt(data, spec.key)) : "";
        i.onchange = () => {
          const r = parseNumber(i.value, spec);
          if (r.error) { ctx.toast(`${spec.title}: ${r.error}`, true); i.value = set ? String(valueAt(data, spec.key)) : ""; return; }
          write(r.value == null ? { unset: [spec.key] } : { set: { [spec.key]: r.value } });
        };
        i.onkeydown = (e) => { if (e.key === "Enter") i.blur(); };
        return row(esc(spec.title), `${esc(spec.detail)} Default ${spec.def}.`, i);
      }
      const card = (...rows) => { const c = el("div", "wf-card"); c.append(...rows); return c; };
      const specs = (group) => SPECS.filter((s) => s.group === group).map(control);
      const iconBtn = (svg, label, onClick, disabled = false) => {
        const b = el("button", "st-icon", svg); b.title = label; b.setAttribute("aria-label", label); b.disabled = disabled; b.onclick = onClick; return b;
      };

      // A model picker sheet. `opts.auto` adds "Let pi choose"; `opts.pattern`
      // a field for a typed pattern (globs like anthropic/*).
      async function pickModel(title, sub, opts, onPick) {
        ctx.openSheet((b) => b.append(el("div", "sheet-title", esc(title)), el("div", "sheet-sub", "Loading models…")));
        const list = await loadModels();
        ctx.openSheet((b) => {
          b.append(el("div", "sheet-title", esc(title)), el("div", "sheet-sub", esc(sub)));
          if (opts.pattern) {
            const f = el("div", "field"); const p = el("input"); p.placeholder = "Pattern, e.g. anthropic/claude-*"; p.autocapitalize = "off"; p.spellcheck = false;
            const add = el("button", "btn secondary", "Add");
            const go = () => { const v = p.value.trim(); if (v) { ctx.closeSheet(); onPick(v); } };
            add.onclick = go; p.onkeydown = (e) => { if (e.key === "Enter") go(); };
            f.append(p, add); b.append(f, el("div", "sheet-section", "Available models"));
          }
          const sf = el("div", "field model-search"); const q = el("input"); q.type = "search"; q.placeholder = "Filter models"; sf.append(q); b.append(sf);
          const box = el("div"); b.append(box);
          const draw = () => {
            box.innerHTML = "";
            if (opts.auto) box.append(opt("", "Let pi choose", "pi picks the first available model", () => { ctx.closeSheet(); onPick(null); }));
            const term = q.value.toLowerCase(); let last = null;
            for (const m of list) {
              const key = `${m.provider}/${m.id}`;
              if (opts.exclude?.includes(key)) continue;
              if (term && !`${key} ${m.name || ""}`.toLowerCase().includes(term)) continue;
              if (m.provider !== last) { box.append(el("div", "provider-label", esc(m.provider))); last = m.provider; }
              const o = opt("", `<span class="mono">${esc(m.id)}</span>`, `${esc(m.name || "")}${m.reasoning ? " · reasoning" : ""}`, () => { ctx.closeSheet(); onPick(m); });
              if (opts.current === key) o.append(el("span", "check", ctx.ICON.check));
              box.append(o);
            }
            if (!list.length) box.append(el("div", "list-empty", "No models available. Set up a provider in pi first."));
          };
          q.oninput = draw; draw();
        });
      }

      // ------------------------------------------------------------ page
      function draw() {
        const data = doc.data || {};
        root.innerHTML = "";
        const path = ctx.home && doc.path.startsWith(ctx.home + "/") ? "~" + doc.path.slice(ctx.home.length) : doc.path;
        root.append(el("div", "st-global", `<b>Global settings.</b> These are pi's own settings in <code>${esc(path)}</code>: terminal pi and workflow stages use them too. Open chats pick changes up after a restart.`));

        // Models
        root.append(section("Models"));
        const dm = (() => {
          const m = data.defaultModel ? (data.defaultProvider ? `${data.defaultProvider}/${data.defaultModel}` : data.defaultModel) : null;
          const b = el("button", "st-pick", `<div class="st-main"><div class="st-t">Default model</div><div class="st-s">For new chats.</div></div><span class="st-v">${esc(m || "pi chooses")}</span><span class="mp-chev">${ctx.ICON.chev}</span>`);
          b.dataset.key = "defaultModel";
          b.onclick = () => pickModel("Default model", "New chats start with it (global).", { auto: true, current: m }, (x) =>
            write(x ? { set: { defaultProvider: x.provider, defaultModel: x.id } } : { unset: ["defaultProvider", "defaultModel"] },
              x ? `Default model: ${x.id}` : "pi chooses the model"));
          return b;
        })();
        root.append(card(dm, ...specs("models")));

        // Favourite models (enabledModels)
        root.append(section("Favourite models"));
        const fav = (Array.isArray(data.enabledModels) ? data.enabledModels : []).filter((x) => typeof x === "string" && x).map(parsePattern);
        const saveFav = (list, msg) => write(list.length ? { set: { enabledModels: list.map(rawPattern) } } : { unset: ["enabledModels"] }, msg);
        const favCard = card();
        favCard.classList.add("st-fav");
        fav.forEach((p, i) => {
          const hits = models ? models.filter((m) => matches(p, m)) : null;
          const sub = p.pattern.includes("*") ? (hits ? `${hits.length} model${hits.length === 1 ? "" : "s"}` : "pattern") : hits && !hits.length ? "not available now" : "";
          const th = select([["", "Thinking: default"], ...LEVELS.map((l) => [l, `Thinking: ${l}`])], p.thinking || "", (v) => {
            const l = fav.slice(); l[i] = { ...p, thinking: v || null }; saveFav(l);
          });
          const r = row(esc(p.pattern), esc(sub), [
            th,
            iconBtn(UP, "Move up", () => { const l = fav.slice(); [l[i - 1], l[i]] = [l[i], l[i - 1]]; saveFav(l); }, i === 0),
            iconBtn(DOWN, "Move down", () => { const l = fav.slice(); [l[i + 1], l[i]] = [l[i], l[i + 1]]; saveFav(l); }, i === fav.length - 1),
            iconBtn(ctx.ICON.x, "Remove", () => saveFav(fav.filter((_, j) => j !== i), `Removed ${p.pattern}`)),
          ], true);
          r.dataset.pattern = p.pattern; r.classList.add("st-wrap");
          favCard.append(r);
        });
        if (!fav.length) favCard.append(el("div", "st-row st-s", "None: pi cycles through every available model."));
        const addFav = el("button", "st-add", `${ctx.ICON.plus}Add model`);
        addFav.onclick = () => pickModel("Add a favourite", "Top of the model picker, and what pi cycles through.", { pattern: true, exclude: fav.map((p) => p.pattern) }, (x) => {
          const pattern = typeof x === "string" ? parsePattern(x) : { pattern: `${x.provider}/${x.id}`, thinking: null };
          if (fav.some((p) => p.pattern === pattern.pattern)) return ctx.toast("Already in the list");
          saveFav([...fav, pattern], `Added ${pattern.pattern}`);
        });
        favCard.append(addFav);
        root.append(favCard);

        // Thinking per model (modelThinkingLevels)
        root.append(section("Thinking per model"));
        const mtl = Object.entries(data.modelThinkingLevels && typeof data.modelThinkingLevels === "object" ? data.modelThinkingLevels : {})
          .filter(([, v]) => typeof v === "string").sort(([a], [z]) => a.localeCompare(z));
        const mtCard = card();
        for (const [m, level] of mtl) {
          const path = `modelThinkingLevels.${seg(m)}`;
          const s = select(LEVELS.map((l) => [l, l]), level, (v) => write({ set: { [path]: v } }));
          const r = row(esc(m), "", [s, iconBtn(ctx.ICON.x, "Remove", () => write({ unset: [path] }, `Removed ${m}`))], true);
          r.dataset.model = m;
          mtCard.append(r);
        }
        if (!mtl.length) mtCard.append(el("div", "st-row st-s", "None: every model starts at the default thinking level."));
        const addMt = el("button", "st-add", `${ctx.ICON.plus}Add model`);
        addMt.onclick = () => pickModel("Thinking for a model", "Its startup thinking level, instead of the default.", { exclude: mtl.map(([m]) => m) }, (x) =>
          write({ set: { [`modelThinkingLevels.${seg(`${x.provider}/${x.id}`)}`]: x.reasoning === false ? "off" : "high" } }, `${x.id}: ${x.reasoning === false ? "off" : "high"}`));
        mtCard.append(addMt);
        root.append(mtCard);

        // Queue, compaction, retry, images, display
        root.append(section("Queued messages"), card(...specs("queue")));
        root.append(section("Compaction"));
        const cc = card(...specs("compaction"));
        const ov = Object.entries(data.compaction?.modelOverrides || {}).sort(([a], [z]) => a.localeCompare(z));
        for (const [m, v] of ov) {
          const parts = [];
          if (typeof v?.reserveTokens === "number") parts.push(`reserve ${v.reserveTokens}`);
          if (typeof v?.keepRecentTokens === "number") parts.push(`keep ${v.keepRecentTokens}`);
          cc.append(row(esc(m), `Per-model override: ${esc(parts.join(" · ") || "custom")} (edit settings.json to change)`, null, true));
        }
        root.append(cc);
        root.append(section("Retry"), card(...specs("retry")));
        root.append(section("Images"), card(...specs("images")));
        root.append(section("Display"), card(...specs("display")));
      }
      draw();
      // Fill in what the favourites' patterns match, without blocking the page.
      // Only from a running chat: no pi is started just for this.
      if (!models && (ctx.status()?.live || []).some((l) => l.kind !== "stage")) loadModels().then((m) => { if (m.length && root.isConnected) draw(); });
    },
  });
})();
