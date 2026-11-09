"use strict";
// Settings › Safety: @gotgenes/pi-permission-system (docs/pi-parity-plan.md §6).
// Whether it's installed, its policy for chats (pi's own
// extensions/pi-permission-system/config.json, so the terminal's pi uses it
// too), each project's Off / Ask / Strict, and the policy workflow stages
// run under (pocketpi's ~/.config/pocketpi/safety/stage-policy.json).
// Auto review (@mzwing/pi-permission-auto-review): a model answers the chat
// policy's asks, so they reach the person only when its review fails. On/off
// is the policy's authorizerChain (POST /api/safety/auto-review), its settings
// are pi's extensions/pi-permission-auto-review/config.json (the
// `auto-review` config file), and its recent decisions come from the review
// log (GET /api/safety/reviews).
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

  const hasPackage = (settings, name) => (settings?.packages || []).some((p) => String(typeof p === "string" ? p : p?.source || "").includes(name));
  const isInstalled = (settings) => hasPackage(settings, "@gotgenes/pi-permission-system");

  // Auto review's settings and what each preset falls back to.
  const AR_PRESETS = { codex: ["Codex", "openai-codex", "codex-auto-review", "low"], "claude-code": ["Claude Code", "anthropic", "claude-sonnet-5", "high"] };
  const AR_LEVELS = ["off", "minimal", "low", "medium", "high", "xhigh"];
  const AR_FOLLOW = { auto: "Auto", always: "Always", off: "Off" };
  // Claude through OpenCode Go fails a continued review conversation (tested
  // 2026-11-09): each follow-up review errors and falls back to asking.
  const arClaudeViaGo = (c) => c.provider === "opencode-go" && /claude/i.test(c.model || "") && c.followUpReviews !== "off";
  function ago(iso) {
    const s = Math.max(0, (Date.now() - Date.parse(iso)) / 1000);
    if (!isFinite(s)) return "";
    if (s < 60) return "just now";
    if (s < 3600) return `${Math.round(s / 60)} min ago`;
    if (s < 86400) return `${Math.round(s / 3600)} h ago`;
    return `${Math.round(s / 86400)} d ago`;
  }
  function arOutcome(r) {
    if (r.outcome === "allow") return ["Allowed", "allow"];
    if (r.outcome === "deny") return ["Denied", "deny"];
    return [r.then ? `Asked you · you ${r.then}` : "Asked you", "ask"];
  }

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
.mp-safety .sf-warn { color: var(--warn); }
.mp-safety .opt.switch-row + .sf-row { border-top: 1px solid var(--line); }
.mp-safety .sf-row select { max-width: 55%; }
.mp-safety .sf-row .btn.small { height: 32px; padding: 0 10px; font: 500 12.5px var(--mono); border-radius: 9px; max-width: 55%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.mp-safety .sf-rv { padding: 10px 14px; }
.mp-safety .sf-rv + .sf-rv { border-top: 1px solid var(--line); }
.mp-safety .sf-rv b { font: 600 12px var(--font); text-transform: uppercase; letter-spacing: .03em; }
.mp-safety .sf-rv b.allow { color: var(--ok); } .mp-safety .sf-rv b.deny { color: var(--danger); } .mp-safety .sf-rv b.ask { color: var(--warn); }
.mp-safety .sf-rv code { display: block; font: 13px var(--mono); overflow-wrap: anywhere; margin-top: 3px; }
.mp-safety .sf-rv .sf-sub { margin-top: 3px; }`);
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
      const arInstalled = hasPackage(settings.data, "@mzwing/pi-permission-auto-review");
      const [arConfig, arReviews] = arInstalled ? await Promise.all([
        ctx.api("/api/pi/config/auto-review").catch(() => ({ data: {} })),
        ctx.api("/api/safety/reviews?limit=20").catch(() => ({ reviews: [] })),
      ]) : [{ data: {} }, { reviews: [] }];
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
      async function install(source) {
        const { id } = await ctx.api("/api/pi/jobs", { action: "install", source });
        let job;
        for (;;) { await new Promise((r) => setTimeout(r, 600)); job = (await ctx.api(`/api/pi/jobs/${id}`)).job; if (job.status !== "running") break; }
        if (job.status !== "ok") throw new Error(`pi install failed: ${(job.output || "").trim().split("\n").slice(-3).join(" ")}`);
      }
      if (!installed) {
        const b = ctx.el("button", "btn", "Install with recommended policy");
        b.onclick = async () => {
          busy(b, "Installing…");
          try {
            await install(info.package);
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

      // ---- auto review
      if (installed) {
        const ar = info.auto_review || {};
        const on = (chats.data?.authorizerChain || []).includes(ar.link || "auto-review");
        el.append(ctx.el("div", "wf-section", "Auto review"));
        const ac = ctx.el("div", "wf-card");
        ac.dataset.k = "auto-review";
        if (!arInstalled) {
          ac.append(ctx.el("div", "sf-row", `<div class="sf-main"><div>Auto review</div><div class="sf-sub">Not installed: pi's asks come to you</div></div>`));
          const r = ctx.el("div", "sf-row");
          const b = ctx.el("button", "btn", "Install auto review");
          b.onclick = async () => {
            busy(b, "Installing…");
            try {
              await install(ar.package);
              await ctx.api("/api/safety/auto-review", { enabled: true });
              ctx.toast("Installed. Restart chats to load it.");
              await ctx.needsRestart();
            } catch (e) { ctx.toast(e.message, true); }
            ctx.rerender();
          };
          r.append(b); ac.append(r);
        } else {
          const sw = ctx.el("button", "opt switch-row", `<div class="o-main"><div class="o-t">Auto review</div><div class="o-s">${on
            ? "A model answers pi's permission asks; you're asked only when its review fails."
            : "Installed and off: pi's asks come to you."}</div></div><span class="switch${on ? " on" : ""}"><i></i></span>`);
          sw.dataset.k = "auto-review-toggle";
          sw.onclick = async () => {
            sw.disabled = true;
            try { await ctx.api("/api/safety/auto-review", { enabled: !on }); await ctx.needsRestart(); ctx.toast(`Auto review ${on ? "off" : "on"}`); } catch (e) { ctx.toast(e.message, true); }
            ctx.rerender();
          };
          ac.append(sw);

          // Settings: patches to its config file (read when pi starts).
          const c = arConfig.data || {};
          const preset = AR_PRESETS[c.preset] ? c.preset : "codex";
          const [, defProvider, defModel, defLevel] = AR_PRESETS[preset];
          const save = async (patch) => {
            try { await ctx.api("/api/pi/config/auto-review", { set: patch.set || {}, unset: patch.unset || [] }); await ctx.needsRestart(); } catch (e) { ctx.toast(e.message, true); }
            ctx.rerender();
          };
          const select = (options, value, onChange) => {
            const sel = ctx.el("select");
            for (const [v, label] of options) { const o = ctx.el("option", "", ctx.esc(label)); o.value = v; sel.append(o); }
            sel.value = value; sel.onchange = () => onChange(sel.value);
            return sel;
          };
          const setting = (title, sub, control, k) => {
            const r = ctx.el("div", "sf-row", `<div class="sf-main"><div>${ctx.esc(title)}</div>${sub ? `<div class="sf-sub">${sub}</div>` : ""}</div>`);
            r.dataset.k = k;
            r.append(control);
            return r;
          };
          ac.append(setting("Rules", "Whose reviewer it copies: Codex's auto-review or Claude Code's auto mode.",
            select(Object.entries(AR_PRESETS).map(([k, v]) => [k, v[0]]), preset, (v) => save({ set: { preset: v } })), "preset"));

          const current = c.provider && c.model ? `${c.provider}/${c.model}` : "";
          const modelBtn = ctx.el("button", "btn secondary small", ctx.esc(current || `Preset default`));
          modelBtn.title = current || `${defProvider}/${defModel}`;
          // A sheet, like pi settings' model pickers: the list may take a pi
          // starting, which a native select can't wait for.
          modelBtn.onclick = async () => {
            ctx.openSheet((b) => b.append(ctx.el("div", "sheet-title", "Review model"), ctx.el("div", "sheet-sub", "Loading models…")));
            let list = [];
            try { list = await ctx.models(); } catch (e) { ctx.closeSheet(); ctx.toast(`Couldn't list models: ${e.message}`, true); return; }
            ctx.openSheet((b) => {
              b.append(ctx.el("div", "sheet-title", "Review model"), ctx.el("div", "sheet-sub", "It needs a login for its provider. A small, fast model is plenty."));
              const sf = ctx.el("div", "field model-search"); const q = ctx.el("input"); q.type = "search"; q.placeholder = "Filter models"; sf.append(q); b.append(sf);
              const box = ctx.el("div"); b.append(box);
              const draw = () => {
                box.innerHTML = "";
                const d = opt("", "Preset default", ctx.esc(`${defProvider}/${defModel}`), () => { ctx.closeSheet(); save({ unset: ["provider", "model"] }); });
                if (!current) d.append(ctx.el("span", "check", ctx.ICON.check));
                box.append(d);
                const term = q.value.toLowerCase(); let last = null;
                for (const m of list) {
                  const key = `${m.provider}/${m.id}`;
                  if (term && !`${key} ${m.name || ""}`.toLowerCase().includes(term)) continue;
                  if (m.provider !== last) { box.append(ctx.el("div", "provider-label", ctx.esc(m.provider))); last = m.provider; }
                  const o = opt("", `<span class="mono">${ctx.esc(m.id)}</span>`, ctx.esc(m.name || ""), () => { ctx.closeSheet(); save({ set: { provider: m.provider, model: m.id } }); });
                  if (current === key) o.append(ctx.el("span", "check", ctx.ICON.check));
                  box.append(o);
                }
              };
              q.oninput = draw; draw();
            });
          };
          ac.append(setting("Model", ctx.esc(current ? "Which model reviews." : `Which model reviews: ${defProvider}/${defModel} by default.`), modelBtn, "model"));

          ac.append(setting("Reasoning", "How hard the review thinks (for Claude Code's rules, only its second, careful pass).",
            select([["", `Default (${defLevel})`], ...AR_LEVELS.map((l) => [l, l])], AR_LEVELS.includes(c.reasoning) ? c.reasoning : "", (v) => save(v ? { set: { reasoning: v } } : { unset: ["reasoning"] })), "reasoning"));

          ac.append(setting("Follow-up reviews", "Continue one review conversation across asks (cheaper with caching). Off sends every review in full.",
            select([["", "Default (auto)"], ...Object.entries(AR_FOLLOW)], AR_FOLLOW[c.followUpReviews] ? c.followUpReviews : "", (v) => save(v ? { set: { followUpReviews: v } } : { unset: ["followUpReviews"] })), "followUpReviews"));
          if (arClaudeViaGo(c)) ac.append(ctx.el("div", "sf-row", `<div class="sf-main sf-warn" data-k="claude-go-warning">Claude through OpenCode Go fails continued reviews, so they fall back to asking you. Set Follow-up reviews to Off.</div>`));
        }
        el.append(ac);

        if (arInstalled) {
          el.append(ctx.el("div", "wf-section", "Recent reviews"));
          const rc = ctx.el("div", "wf-card");
          rc.dataset.k = "reviews";
          const list = arReviews.reviews || [];
          if (!list.length) rc.append(ctx.el("div", "list-empty", "No reviews yet."));
          for (const r of list) {
            const [label, cls] = arOutcome(r);
            const what = r.command || r.path || r.surface || "";
            const meta = [r.durationMs != null ? `${(r.durationMs / 1000).toFixed(1)} s` : "", r.outcome === "defer" && r.errorCategory ? r.errorCategory : r.model || "", ago(r.at)].filter(Boolean).join(" · ");
            rc.append(ctx.el("div", "sf-rv", `<b class="${cls}">${ctx.esc(label)}</b><code>${ctx.esc(what)}</code>${r.reason ? `<div class="sf-sub">${ctx.esc(r.reason)}</div>` : ""}<div class="sf-sub">${ctx.esc(meta)}</div>`));
          }
          el.append(rc);
        }
        el.append(ctx.el("div", "sf-note", "Each review sends your recent messages and the agent's recent tool calls to the review model's provider. Changes apply to chats started or restarted after them. Turning it on also stops the agent from writing pi's settings, packages and permission policies."));
      }

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
