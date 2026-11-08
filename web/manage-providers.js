"use strict";
// Settings › Providers: which model providers pi can use (`pi auth check` for
// each, through GET /api/pi/providers), and API keys for the ones that take
// one (POST /api/pi/providers/{id}/key | /remove). Keys go in, never come
// back. OAuth sign-ins stay in a terminal: pi → /login <provider>.
// Contract: web/manage.js, docs/pi-parity-plan.md §7. iOS twin:
// ios/PocketPi/Sources/SettingsProvidersPage.swift (logic in PocketPiKit's Providers.swift).
ppManage.register({
  id: "providers",
  title: "Providers",
  subtitle: "Sign-ins and API keys",
  icon: '<svg viewBox="0 0 24 24"><circle cx="8" cy="15" r="4"/><path d="M11 12l8.5-8.5M16 7l2.5 2.5M14 9l2 2"/></svg>',
  order: 20,
  async render(el, ctx) {
    const { esc } = ctx;
    ctx.style(`.mp-providers .pv-top { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; margin: 2px 0 4px; }
.mp-providers .pv-top .chip b { font-weight: 600; color: var(--muted); font-family: var(--font); }
.mp-providers .pv-top .pv-refresh { margin-left: auto; }
.mp-providers .wf-card .opt { border-radius: 0; padding: 11px 14px; }
.mp-providers .wf-card .opt + .opt { border-top: 1px solid var(--line); }
.mp-providers .pv-more { width: 100%; padding: 12px 14px; text-align: left; color: var(--text-2); font-size: 14px; }
.mp-providers .pv-note { font-size: 12.5px; color: var(--muted); margin: 8px 2px 0; }
.pv-sheet .pv-status { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; margin: 4px 0 12px; font-size: 13.5px; color: var(--text-2); }
.pv-sheet .pv-p { font-size: 14px; color: var(--text-2); margin: 10px 0 8px; line-height: 1.45; }
.pv-sheet .pv-cmd { display: flex; align-items: center; gap: 8px; border-radius: 12px; background: var(--surface); padding: 8px 8px 8px 12px; font: 13.5px var(--mono); }
.pv-sheet .pv-cmd code { flex: 1; min-width: 0; overflow-wrap: anywhere; }
.pv-sheet .pv-warn { font-size: 13px; color: var(--warn); margin-top: 8px; }
.pv-sheet .errbox { margin-top: 10px; }
.pv-sheet .btn-row.left { justify-content: flex-start; }`);

    // ---------------------------------------------------------------- what a row says
    const PILL = { ready: ["st-succeeded", "Ready"], invalid: ["st-failed", "Invalid"], unknown: ["st-waiting", "Unchecked"], not_configured: ["st-pending", "Not set up"] };
    const isSetUp = (p) => p.status === "ready" || p.status === "invalid" || !!p.stored;
    const pill = (p) => { const [c, t] = PILL[p.status] || PILL.unknown; return `<span class="pill ${c}">${t}</span>`; };
    function how(p) {
      const s = p.stored;
      if (s?.type === "oauth") return "Signed in" + (p.subscription ? " (subscription)" : "");
      if (s?.type === "api_key" && s.hasKey) return "API key saved in pi";
      if (p.envSet?.length) return `From $${p.envSet[0]}`;
      if (p.status === "ready" && p.authType) return p.authType === "oauth" ? "Signed in" : "API key";
      if (s) return `Saved in pi (${s.type})`;
      if (p.apiKey && p.env?.length) return `Add a key, or set ${p.env[0]}`;
      if (p.apiKey) return "Add an API key";
      return p.oauth ? "Sign in from a terminal" : "Set up from a terminal";
    }
    function reasonText(p) {
      const r = p.reason;
      if (!r) return "";
      return { credentials_not_configured: "No credentials", provider_not_found: "pi's CLI can't check this provider", invalid_state: "The saved sign-in doesn't work any more (expired or revoked)" }[r] || r.replace(/_/g, " ");
    }

    // ---------------------------------------------------------------- load and draw
    let data = null;
    let showMore = false;
    el.append(ctx.el("div", "wf-loading", "Checking providers…"));
    async function load(refresh) {
      data = await ctx.api(`/api/pi/providers${refresh ? "?refresh=1" : ""}`);
      draw();
    }
    function byId(id) { return data?.providers.find((p) => p.id === id); }

    function row(p) {
      const r = ctx.el("button", "opt", `<div class="o-main"><div class="o-t">${esc(p.name)}</div><div class="o-s">${esc(how(p))}</div></div>${pill(p)}`);
      r.dataset.provider = p.id;
      r.onclick = () => openProvider(p.id);
      return r;
    }
    function card(list) { const c = ctx.el("div", "wf-card"); list.forEach((p) => c.append(row(p))); return c; }

    function draw() {
      el.innerHTML = "";
      const all = data.providers;
      const top = ctx.el("div", "pv-top");
      const m = data.models || {};
      const def = m.default?.provider && m.default?.model ? `${m.default.provider}/${m.default.model}` : null;
      if (def) top.append(ctx.el("span", "chip", `<b>Default</b> ${esc(def)}`));
      if (m.fallback?.model) {
        const fp = byId(m.fallback.provider);
        const c = ctx.el("span", "chip" + (fp && fp.status !== "ready" ? " warn" : ""), `<b>Fallback</b> ${esc(m.fallback.model)}`);
        c.title = `When ${(m.fallback.from || []).join(", ")} hit a usage limit, the subscription-fallback extension switches to this model${fp && fp.status !== "ready" ? ` — but ${fp.name} isn't ready` : ""}.`;
        top.append(c);
      }
      const again = ctx.el("button", "copy pv-refresh", "Check again");
      again.onclick = async () => { again.disabled = true; again.textContent = "Checking…"; try { await load(true); } catch (e) { ctx.toast(e.message, true); again.disabled = false; again.textContent = "Check again"; } };
      top.append(again);
      el.append(top);

      const setUp = all.filter(isSetUp);
      const common = all.filter((p) => !isSetUp(p) && p.common);
      const rest = all.filter((p) => !isSetUp(p) && !p.common);
      el.append(ctx.el("div", "wf-section", "Set up"));
      if (setUp.length) el.append(card(setUp));
      else el.append(ctx.el("div", "list-empty", "No provider is set up yet. pi can't reach a model until one is."));
      if (common.length) { el.append(ctx.el("div", "wf-section", "Popular")); el.append(card(common)); }
      if (rest.length) {
        el.append(ctx.el("div", "wf-section", "More providers"));
        if (showMore) el.append(card(rest));
        else {
          const c = ctx.el("div", "wf-card");
          const b = ctx.el("button", "pv-more", `Show ${rest.length} more`);
          b.onclick = () => { showMore = true; draw(); };
          c.append(b); el.append(c);
        }
      }
      const when = data.checked ? new Date(data.checked).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }) : "";
      el.append(ctx.el("div", "pv-note", esc(`Checked with pi auth check${when ? ` at ${when}` : ""}. Keys you save here go into pi's auth.json and are never shown again. Open chats pick changes up after a restart.`)));
    }

    // ---------------------------------------------------------------- one provider
    function openProvider(id) {
      const p = byId(id); if (!p) return;
      ctx.openSheet((b) => {
        b.classList.add("pv-sheet");
        b.append(ctx.el("div", "sheet-title", esc(p.name)), ctx.el("div", "sheet-sub mono", esc(p.id)));
        const st = ctx.el("div", "pv-status", `${pill(p)}<span>${esc(how(p))}</span>`);
        b.append(st);
        const why = reasonText(p);
        if (why && p.status !== "ready") b.append(ctx.el("div", "pv-p", esc(why)));

        if (p.apiKey) {
          const stored = p.stored?.type === "api_key" && p.stored.hasKey;
          b.append(ctx.el("div", "sheet-section", stored ? "Replace the API key" : "Add an API key"));
          const f = ctx.el("div", "field");
          const i = ctx.el("input"); i.type = "password"; i.autocomplete = "off"; i.autocapitalize = "off"; i.spellcheck = false;
          i.placeholder = stored ? "New key" : "Paste the key"; i.name = `pv-key-${p.id}`;
          f.append(i); b.append(f);
          if (p.stored?.type === "oauth") b.append(ctx.el("div", "pv-warn", esc(`Saving a key replaces your ${p.name} sign-in.`)));
          if (p.env?.length) b.append(ctx.el("div", "pv-p", `Or set <code>${esc(p.env[0])}</code> in pocketpi's environment. A saved key wins over it.`));
          const errBox = ctx.el("div"); b.append(errBox);
          const row = ctx.el("div", "btn-row");
          const save = ctx.el("button", "btn", stored ? "Replace" : "Save");
          row.append(save); b.append(row);
          const submit = async () => {
            errBox.innerHTML = "";
            const key = i.value.trim();
            const bad = !key ? "Paste a key first." : key.startsWith("!") ? "Keys starting with ! are commands pi runs. Set those up in auth.json from a terminal." : /\s/.test(key) ? "An API key has no spaces or line breaks." : null;
            if (bad) { errBox.append(ctx.el("div", "errbox", esc(bad))); return; }
            save.disabled = true; save.textContent = "Saving…";
            try {
              const r = await ctx.api(`/api/pi/providers/${encodeURIComponent(p.id)}/key`, { key });
              i.value = "";
              changed(r.provider);
              ctx.toast(`${p.name}: key saved${r.provider.status === "ready" ? "" : `, but pi says ${PILL[r.provider.status]?.[1].toLowerCase() || r.provider.status}`}`, r.provider.status === "invalid");
              ctx.closeSheet();
            } catch (e) { errBox.append(ctx.el("div", "errbox", esc(e.message))); save.disabled = false; save.textContent = stored ? "Replace" : "Save"; }
          };
          save.onclick = submit;
          i.onkeydown = (e) => { if (e.key === "Enter") submit(); };
          if (stored) {
            const rm = ctx.el("div", "btn-row left");
            const del = ctx.el("button", "btn secondary", "Remove key…");
            del.onclick = () => confirmRemove(b, p, rm);
            rm.append(del); b.append(rm);
          }
        }

        if (p.oauth || !p.apiKey) {
          b.append(ctx.el("div", "sheet-section", p.oauth ? "Sign in" : "Set up"));
          b.append(ctx.el("div", "pv-p", esc(p.oauth
            ? `${p.subscription ? "Subscription sign-ins" : "Sign-ins"} need pi's terminal UI. On the computer pocketpi runs on, start pi and run:`
            : "This provider is set up from pi's terminal UI. On the computer pocketpi runs on, start pi and run:")));
          const cmdRow = ctx.el("div", "pv-cmd", `<code>${esc(p.login)}</code>`);
          const copy = ctx.el("button", "copy", `${ctx.ICON.copy}<span>Copy</span>`);
          copy.onclick = () => (window.copyText ? window.copyText(p.login, copy) : navigator.clipboard?.writeText(p.login));
          cmdRow.append(copy); b.append(cmdRow);
          if (p.stored?.type === "oauth") b.append(ctx.el("div", "pv-p", `To sign out: <code>/logout ${esc(p.id)}</code>`));
        }
      });
    }

    function confirmRemove(b, p, rowEl) {
      rowEl.innerHTML = "";
      rowEl.append(ctx.el("span", "pv-p", esc(`Remove the ${p.name} key from pi?`)));
      const no = ctx.el("button", "btn secondary", "Cancel");
      const yes = ctx.el("button", "btn danger", "Remove");
      no.onclick = () => openProvider(p.id);
      yes.onclick = async () => {
        yes.disabled = true; yes.textContent = "Removing…";
        try {
          const r = await ctx.api(`/api/pi/providers/${encodeURIComponent(p.id)}/remove`, {});
          changed(r.provider);
          ctx.toast(`${p.name}: key removed`);
          ctx.closeSheet();
        } catch (e) { ctx.toast(e.message, true); yes.disabled = false; yes.textContent = "Remove"; }
      };
      const btns = ctx.el("div", "btn-row"); btns.append(no, yes);
      rowEl.after(btns);
    }

    function changed(row) {
      const i = data.providers.findIndex((x) => x.id === row.id);
      if (i >= 0) data.providers[i] = row; else data.providers.push(row);
      draw();
      ctx.needsRestart();
    }

    try { await load(false); }
    catch (e) { el.innerHTML = ""; el.append(ctx.el("div", "errbox", esc(e.message))); }
  },
});
