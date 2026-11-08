"use strict";
// Settings › Context (docs/pi-parity-plan.md E6): pi's context files
// (AGENTS.md, AGENTS.override.md; CLAUDE.md shown read only) and system
// prompt files (SYSTEM.md replaces pi's prompt, APPEND_SYSTEM.md adds to
// it), global (~/.pi/agent/) and for a project (<cwd>/ and <cwd>/.pi/), with
// what pi actually loads for that project. Server: src/pi_context.rs
// (GET /api/pi/context[?cwd=], GET/POST /api/pi/context/file?scope=&name=
// [&cwd=]; a fixed list of files, backups, size cap). The iOS twin is
// SettingsContextPage.swift with PocketPiKit's PiContext.swift.
(() => {
  const DOC = '<svg viewBox="0 0 24 24"><path d="M7 3h7l5 5v13H7z"/><path d="M14 3v5h5M10 12h6M10 16h6"/></svg>';
  let pickedCwd = null; // null: the drawer's project

  const ROLE = {
    system: "Replaces pi's system prompt",
    append: "Added to pi's system prompt",
  };
  const role = (f) => ROLE[f.kind] || (f.name === "AGENTS.override.md" ? "Used instead of AGENTS.md in this folder" : "Instructions for every chat here");
  function status(f, o) {
    if (!f.exists) return "Not created";
    if (f.loaded) return "Loaded";
    if (f.kind !== "context") return f.scope === "project" && o.trust && !o.trust.trusted ? "Ignored: pi doesn't trust this project" : "Not used: the project's file wins";
    return "Not used: another file in this folder wins";
  }
  const kb = (n) => (n == null ? "" : n < 1024 ? `${n} B` : `${(n / 1024).toFixed(n < 10240 ? 1 : 0)} KB`);

  ppManage.register({
    id: "context",
    title: "Context",
    subtitle: "AGENTS.md, SYSTEM.md: what pi reads",
    icon: DOC,
    order: 35,
    async render(root, ctx) {
      const { el, esc } = ctx;
      ctx.style(`.mp-context .cx-note { font-size: 13px; color: var(--text-2); background: var(--surface); border-radius: 12px; padding: 10px 12px; line-height: 1.4; }
.mp-context .cx-note code, .mp-context code { font: 12px var(--mono); }
.mp-context .cx-pick { display: flex; gap: 8px; margin-bottom: 10px; }
.mp-context .cx-pick select { flex: 1; min-width: 0; font: 500 14px var(--font); color: var(--text); background: var(--surface); border: 0; border-radius: 10px; height: 38px; padding: 0 10px; }
.mp-context .wf-card > * + * { border-top: 1px solid var(--line); }
.mp-context .cx-row { display: flex; align-items: center; gap: 10px; padding: 11px 14px; width: 100%; text-align: left; }
.mp-context .cx-main { flex: 1; min-width: 0; }
.mp-context .cx-t { font: 500 14px var(--mono); letter-spacing: -0.02em; overflow-wrap: anywhere; }
.mp-context .cx-s { font-size: 12.5px; color: var(--muted); margin-top: 2px; line-height: 1.35; overflow-wrap: anywhere; }
.mp-context .cx-badge { font: 600 10px var(--font); letter-spacing: .04em; border-radius: 999px; padding: 2px 7px; flex: none; text-transform: uppercase; }
.mp-context .cx-badge.on { background: var(--signal); color: var(--signal-ink, var(--text)); }
.mp-context .cx-badge.off { color: var(--muted); border: 1px solid var(--line-2); }
.mp-context .cx-badge.warn { color: var(--warn); border: 1px solid color-mix(in srgb, var(--warn) 45%, transparent); }
.mp-context .cx-step { font: 600 11px var(--mono); color: var(--muted); width: 18px; flex: none; text-align: right; }
.mp-context .mp-chev svg { width: 16px; height: 16px; }
.cx-edit textarea { height: 50vh !important; font-size: 13px !important; }
.cx-edit textarea[readonly] { background: var(--surface); }
.cx-edit-note { font-size: 12px; color: var(--muted); margin-top: 10px; line-height: 1.4; }`);
      root.append(el("div", "wf-loading", "Loading…"));
      let projects = [];
      let cwd = pickedCwd ?? ctx.project ?? "";
      let o = null;
      const tilde = (p) => (p && ctx.home && p.startsWith(ctx.home + "/") ? "~" + p.slice(ctx.home.length) : p || "");
      const q = (extra = {}) => {
        const u = new URLSearchParams(extra);
        if (cwd) u.set("cwd", cwd);
        const s = u.toString();
        return s ? `?${s}` : "";
      };

      async function load() {
        try { o = await ctx.api(`/api/pi/context${q()}`); } catch (e) {
          if (!cwd) throw e;
          ctx.toast(e.message, true); cwd = pickedCwd = ""; o = await ctx.api("/api/pi/context");
        }
      }
      await load();
      try { projects = ((await ctx.api("/api/projects")).projects || []).filter((p) => p.exists !== false); } catch { /* the picker shows only the current one */ }

      function fileRow(f) {
        const st = status(f, o);
        const cls = f.loaded ? "on" : st.startsWith("Ignored") ? "warn" : "off";
        const label = f.loaded ? "Loaded" : !f.exists ? "None" : st.startsWith("Ignored") ? "Ignored" : "Not used";
        const sub = [role(f), f.exists ? kb(f.size) : null, !f.loaded && f.exists ? st : null, f.editable ? null : "read only"].filter(Boolean).join(" · ");
        const b = el("button", "cx-row", `<div class="cx-main"><div class="cx-t">${esc(f.name)}</div><div class="cx-s">${esc(sub)}</div></div><span class="cx-badge ${cls}">${esc(label)}</span><span class="mp-chev">${ctx.ICON.chev}</span>`);
        b.dataset.file = `${f.scope}/${f.name}`;
        b.onclick = () => openFile(f);
        return b;
      }

      function draw() {
        root.innerHTML = "";
        // Project picker.
        const pick = el("div", "cx-pick");
        const s = el("select"); s.dataset.key = "project";
        const opts = [["", "No project: global files only"], ...projects.map((p) => [p.path, p.name || p.path.split("/").pop()])];
        if (cwd && !projects.some((p) => p.path === cwd)) opts.push([cwd, cwd.split("/").pop()]);
        for (const [v, l] of opts) { const op = el("option", "", esc(l)); op.value = v; s.append(op); }
        s.value = cwd;
        s.onchange = async () => { cwd = pickedCwd = s.value; await load(); draw(); };
        pick.append(s);
        root.append(pick);

        const trust = o.trust;
        root.append(el("div", "cx-note", `pi puts these files in every chat's system prompt when the chat starts, so open chats need a restart to see a change. Context files load from <code>~/.pi/agent</code>, the project and every folder above it, without project trust. A project's own <code>.pi/SYSTEM.md</code> and <code>.pi/APPEND_SYSTEM.md</code> win over the global ones (they aren't combined), but only once pi trusts the project${cwd && trust ? (trust.trusted ? " (it does)." : `: <b>this one isn't trusted</b>, see Settings › Project trust.`) : "."}`));

        // What pi loads, in order.
        root.append(el("div", "wf-section", cwd ? "What pi loads here" : "What pi loads everywhere"));
        const lc = el("div", "wf-card cx-loaded");
        const L = o.loaded || {};
        (L.context || []).forEach((c, i) => {
          lc.append(el("div", "cx-row", `<span class="cx-step">${i + 1}</span><div class="cx-main"><div class="cx-t">${esc(tilde(c.path))}</div><div class="cx-s">Context · ${esc(c.scope === "parent" ? "a folder above the project" : c.scope)}</div></div>`));
        });
        if (!(L.context || []).length) lc.append(el("div", "cx-row cx-s", "No context files."));
        lc.append(el("div", "cx-row", `<span class="cx-step">⚙</span><div class="cx-main"><div class="cx-t">${L.system ? esc(tilde(L.system.path)) : "pi's own system prompt"}</div><div class="cx-s">System prompt${L.system ? ` · ${esc(L.system.scope)} SYSTEM.md replaces pi's` : ""}</div></div>`));
        if (L.append) lc.append(el("div", "cx-row", `<span class="cx-step">+</span><div class="cx-main"><div class="cx-t">${esc(tilde(L.append.path))}</div><div class="cx-s">Appended to the system prompt · ${esc(L.append.scope)}</div></div>`));
        root.append(lc);

        for (const sc of ["global", "project"]) {
          const files = (o.files || []).filter((f) => f.scope === sc);
          if (!files.length) continue;
          const head = sc === "global" ? `Global · ${tilde(o.agentDir)}` : `Project · ${tilde(o.cwd)}`;
          root.append(el("div", "wf-section", esc(head)));
          const c = el("div", "wf-card");
          c.dataset.scope = sc;
          files.forEach((f) => c.append(fileRow(f)));
          root.append(c);
        }
      }

      async function openFile(f) {
        const fileUrl = () => {
          const u = new URLSearchParams({ scope: f.scope, name: f.name });
          if (f.scope === "project") u.set("cwd", cwd);
          return `/api/pi/context/file?${u}`;
        };
        let t;
        try { t = await ctx.api(fileUrl()); } catch (e) { return ctx.toast(e.message, true); }
        ctx.openSheet((b) => {
          const w = el("div", "cx-edit");
          w.append(el("div", "sheet-title", esc(f.name)), el("div", "sheet-sub", esc(tilde(t.path))));
          const fld = el("div", "field"); const ta = el("textarea"); ta.spellcheck = true; ta.value = t.content || "";
          if (!f.editable) ta.readOnly = true;
          if (!t.exists) ta.placeholder = f.kind === "system" ? "Your own system prompt. It replaces pi's entirely." : f.kind === "append" ? "Instructions added to the end of pi's system prompt." : "Instructions for every chat (conventions, commands, what to avoid).";
          fld.append(ta); w.append(fld);
          const row = el("div", "btn-row");
          if (f.editable && t.exists) {
            const del = el("button", "btn secondary", "Delete");
            del.onclick = async () => {
              if (!confirm(`Delete ${f.name}? The current text is kept as a .pocketpi.bak backup.`)) return;
              try { await ctx.api(fileUrl(), { delete: true }); await ctx.needsRestart(); ctx.closeSheet(); ctx.toast(`${f.name} deleted`); await load(); draw(); } catch (e) { ctx.toast(e.message, true); }
            };
            row.append(del);
          }
          if (f.editable) {
            const save = el("button", "btn", t.exists ? "Save" : "Create");
            save.onclick = async () => {
              if (ta.value.length > o.maxBytes) return ctx.toast(`At most ${Math.round(o.maxBytes / 1024)} KB`, true);
              save.disabled = true;
              try { await ctx.api(fileUrl(), { content: ta.value }); await ctx.needsRestart(); ctx.closeSheet(); ctx.toast(`${f.name} saved`); await load(); draw(); } catch (e) { ctx.toast(e.message, true); }
              save.disabled = false;
            };
            row.append(save);
          }
          w.append(row);
          const notes = [];
          if (!f.editable) notes.push(`pocketpi shows ${f.name} but doesn't edit it. An AGENTS.md in the same folder is read instead of it.`);
          if (f.kind === "system") notes.push("SYSTEM.md replaces pi's whole system prompt, tool instructions included. APPEND_SYSTEM.md is usually what you want.");
          if (f.scope === "project" && f.kind !== "context") notes.push("Only read once pi trusts the project.");
          notes.push("Saving keeps the previous version as a .pocketpi.bak backup. Open chats see it after a restart.");
          w.append(el("div", "cx-edit-note", esc(notes.join(" "))));
          b.append(w);
        });
      }

      draw();
    },
  });
})();
