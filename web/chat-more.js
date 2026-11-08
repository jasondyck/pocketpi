"use strict";
// Chat extras, loaded after app.js and using its globals (S, $, el, esc, api,
// cmd, opt, openSheet, closeSheet, toast, ICON, …). app.js only calls in
// through one-line hooks (`window.ppChat?.…`):
//
//   chatSheet(b)           chat sheet: Export as HTML, Download JSONL
//   compactSheet()         Compact context, with "Focus the summary on…"
//   localModels(b, q)      model sheet: the llama.cpp router's models (Local)
//
// Routes: POST /api/s/{key}/export → {url}, GET /api/exports/{name}
// [?download=1&title=], GET /api/sessions/file?path=&title=, /api/llama,
// /api/llama/load (src/exports.rs, src/llama.rs).

window.ppChat = (() => {
  const IC = {
    page: '<svg viewBox="0 0 24 24"><path d="M7 3h7l5 5v13H7z"/><path d="M14 3v5h5M10 13h6M10 17h6"/></svg>',
    down: '<svg viewBox="0 0 24 24"><path d="M12 4v11M7 10.5l5 5 5-5M5 20h14"/></svg>',
    open: '<svg viewBox="0 0 24 24"><path d="M14 4h6v6M20 4l-8.5 8.5M18 14v5.5a.5.5 0 0 1-.5.5h-13a.5.5 0 0 1-.5-.5v-13a.5.5 0 0 1 .5-.5H10"/></svg>',
    cpu: '<svg viewBox="0 0 24 24"><rect x="4" y="5" width="16" height="11" rx="2"/><path d="M8 20h8M12 16v4"/></svg>',
  };

  const title = () => (typeof chatTitle === "function" ? chatTitle() : "");
  function download(href) {
    const a = el("a"); a.href = href; a.download = ""; document.body.append(a); a.click(); a.remove();
  }
  async function ensureKey() {
    if (!S.key && S.path) await reopen();
    if (!S.key) throw new Error("This chat has nothing to export yet.");
  }

  // ------------------------------------------------------------ export
  async function exportHTML() {
    openSheet((b) => b.append(el("div", "sheet-title", "Export as HTML"), el("div", "sheet-sub", "pi is writing the page…")));
    let r;
    try {
      await ensureKey();
      try { r = await api(`/api/s/${S.key}/export`, {}); }
      catch (e) { if ((e.status === 404 || e.status === 410) && S.path) { await reopen(); r = await api(`/api/s/${S.key}/export`, {}); } else throw e; }
    } catch (e) { closeSheet(); return toast("Export failed: " + e.message, true); }
    const t = encodeURIComponent(title());
    openSheet((b) => {
      b.append(el("div", "sheet-title", "Export as HTML"), el("div", "sheet-sub", "pi's page of this chat, kept on the server for a day"));
      const openA = el("a", "opt", `${IC.open}<div class="o-main"><div class="o-t">Open in a new tab</div><div class="o-s">View, print or save from the browser</div></div>`);
      openA.href = r.url; openA.target = "_blank"; openA.rel = "noopener"; openA.id = "pp-export-open";
      openA.onclick = () => setTimeout(closeSheet, 100);
      const dl = el("a", "opt", `${IC.down}<div class="o-main"><div class="o-t">Download</div><div class="o-s">An .html file that works offline</div></div>`);
      dl.href = `${r.url}?download=1&title=${t}`; dl.download = ""; dl.id = "pp-export-download";
      dl.onclick = () => setTimeout(closeSheet, 100);
      for (const a of [openA, dl]) { a.style.color = "inherit"; a.style.textDecoration = "none"; }
      b.append(openA, dl);
    });
  }

  function downloadJSONL() {
    if (!S.path) return toast("This chat isn't saved yet", true);
    closeSheet();
    download(`/api/sessions/file?path=${encodeURIComponent(S.path)}&title=${encodeURIComponent(title())}`);
  }

  function chatSheet(b) {
    if (!S.key && !S.path) return;
    b.append(opt(IC.page, "Export as HTML", "Open or download pi's page of this chat", () => exportHTML()));
    if (S.path) b.append(opt(IC.down, "Download JSONL", "The session file, as pi saves it", downloadJSONL));
  }

  // ------------------------------------------------------------ compact
  function compactSheet() {
    openSheet((b) => {
      b.append(el("div", "sheet-title", "Compact context"), el("div", "sheet-sub", "pi summarizes older messages to free up context"));
      const f = el("div", "field"); const ta = el("textarea", "input-area");
      ta.id = "pp-compact-focus"; ta.rows = 3; ta.placeholder = "Focus the summary on… (optional)";
      f.append(ta); b.append(f);
      const row = el("div", "btn-row"); const go = el("button", "btn", "Compact"); go.id = "pp-compact-go"; row.append(go); b.append(row);
      go.onclick = () => run(ta.value.trim());
      ta.onkeydown = (e) => { if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) run(ta.value.trim()); };
    });
  }
  async function run(focus) {
    closeSheet(); setStreaming(true); setWorking("Compacting context");
    const c = { type: "compact" }; if (focus) c.customInstructions = focus;
    try { await cmd(c); await loadSnapshot(); toast("Context compacted"); } catch (e) { toast(e.message, true); } finally { setStreaming(false); }
  }

  // ------------------------------------------------------------ llama.cpp
  const STATE = { loaded: "Loaded", sleeping: "Loaded · asleep", loading: "Loading…" };
  const isLoaded = (m) => m.status === "loaded" || m.status === "sleeping";

  // The router's models under the model list; the filter applies to them too.
  async function localModels(b, q) {
    const box = el("div"); box.id = "pp-local"; b.append(box);
    let router;
    try { router = await api("/api/llama"); } catch { return; }
    if (!router.available) return;
    const draw = () => {
      box.innerHTML = "";
      const term = (q?.value || "").toLowerCase();
      const ms = (router.models || []).filter((m) => !term || m.id.toLowerCase().includes(term) || "llama.cpp local".includes(term));
      if (!ms.length && !router.error) return;
      box.append(el("div", "sheet-section", "Local · llama.cpp"));
      if (router.error) box.append(el("div", "list-empty", esc(router.error)));
      const cur = S.state?.model;
      for (const m of ms) {
        const sub = STATE[m.status] || (m.failed ? "Failed to load last time" : "Not loaded · tap to load");
        const o = opt(IC.cpu, `<span class="mono">${esc(m.id)}</span>`, esc(sub), () => useLocal(m));
        o.dataset.local = m.id;
        if (m.status === "loading") o.disabled = true;
        if (cur && cur.provider === "llama.cpp" && cur.id === m.id) o.append(el("span", "check", ICON.check));
        box.append(o);
      }
      box.append(el("div", "sheet-sub", "Loading a model unloads the router's others; they share the GPU."));
    };
    q?.addEventListener("input", draw);
    draw();
  }

  async function piModel(id) {
    const ms = (await cmd({ type: "get_available_models" })).models || [];
    return ms.find((x) => x.provider === "llama.cpp" && x.id === id);
  }

  // Load on the router if needed (the server unloads the others), restart
  // this chat's pi when it doesn't list the model yet (pi asks the router as
  // it starts), then switch to it.
  async function useLocal(m) {
    closeSheet();
    const note = el("div", "note", `Loading ${esc(m.id)} on the llama.cpp router…`); note.id = "pp-local-note";
    $("messages").append(note);
    try {
      if (!isLoaded(m)) await api("/api/llama/load", { model: m.id });
      let found = await piModel(m.id).catch(() => null);
      if (!found) {
        note.textContent = `Restarting pi to pick up ${m.id}…`;
        // Same key, new pi on the same file. Off the old event stream first,
        // so its pocketpi_exit can't clear the key.
        if (!S.key) await reopen();
        const key = S.key; disconnect();
        const r = await api(`/api/s/${key}/restart`, {});
        S.key = r.key || key; await connect();
        for (let i = 0; i < 20 && !found; i++) {
          found = await piModel(m.id).catch(() => null);
          if (!found) await new Promise((ok) => setTimeout(ok, 500));
        }
      }
      if (!found) throw new Error(`pi doesn't list ${m.id} yet. Try again in a moment.`);
      S.state.model = await cmd({ type: "set_model", provider: found.provider, modelId: found.id });
      S.commands = null; await loadLevels();
      S.state = await cmd({ type: "get_state" }); updateChips(); refreshStats();
      toast(`Switched to ${m.id}`);
    } catch (e) { toast(`Couldn't load ${m.id}: ${e.message}`, true); }
    finally { note.remove(); }
  }

  return { chatSheet, compactSheet, localModels };
})();
