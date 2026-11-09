// Files panel (docs/dsh-features-plan.md §3.5): "Files" in the chat sheet
// opens the side panel on the chat's folder, as a tree (GET
// /api/files/list), with previews: text and code with line numbers, loaded
// a page at a time as it scrolls (/api/files/read), markdown through app.js's
// md(), images and PDFs from /api/files/raw, anything else as a download.
// Its "Changed" tab lists the files each turn changed (/api/files/changes),
// each with its diff through diffBlock. A "Changed 3 files" line closes each
// turn in the transcript, and `@` in the composer opens a search picker
// (/api/files/search) that inserts `@path` (the model reads the file itself:
// pocketpi-control.ts tells it so).
// Plugs into app.js through window.pp (see "feature hooks" there) and uses
// its globals (S, $, api, el, esc, opt, closeSheet, toast, md, diffBlock,
// ICON, ago, newChatCwd).
"use strict";
window.ppFiles = (() => {
  const UP = '<svg viewBox="0 0 24 24"><path d="M15 6l-6 6 6 6"/></svg>';
  const DL = '<svg viewBox="0 0 24 24"><path d="M12 4v11M7 10l5 5 5-5M5 20h14"/></svg>';
  const AT = '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="3.5"/><path d="M15.5 12v1.5a2.5 2.5 0 0 0 5 0V12a8.5 8.5 0 1 0-3.3 6.7"/></svg>';
  const IMAGE = /\.(png|jpe?g|gif|webp|avif|bmp|ico|svg|heic)$/i;
  const MD = /\.(md|markdown|mdx)$/i;
  const qs = (o) => new URLSearchParams(Object.entries(o).filter(([, v]) => v != null && v !== "")).toString();
  const rawUrl = (root, path, download) => `/api/files/raw?${qs({ root, path, download: download ? "1" : "" })}`;
  function size(n) {
    if (n == null) return "";
    if (n < 1024) return n + " B";
    if (n < 1048576) return (n / 1024).toFixed(n < 10240 ? 1 : 0) + " KB";
    return (n / 1048576).toFixed(1) + " MB";
  }
  const when = (ms) => { const a = ago(ms); return /^\d+[mhd]$/.test(a) ? a + " ago" : a; };
  const counts = (f) => (f.added == null ? "" : `<span class="d-add">+${f.added}</span> <span class="d-del">−${f.removed}</span>`);

  // ------------------------------------------------------------ the panel
  const F = { root: null, tab: "files", open: new Set([""]), dirs: new Map(), shown: false, body: null, focusTurn: null };
  const rootOf = () => pp.chatInfo().cwd || null;

  function sheetEntry(b) {
    if (!rootOf()) return;
    b.append(opt(ICON.folder, "Files", "Browse this chat's folder and what each turn changed", () => { closeSheet(); open("files"); }));
  }

  /** Opens the panel on a tab ("files" or "changed"), optionally at a turn. */
  function open(tab = F.tab, turn = null) {
    const root = rootOf();
    if (!root) return toast("Open a chat first.", true);
    if (root !== F.root) { F.root = root; F.dirs.clear(); F.open = new Set([""]); }
    F.tab = tab; F.focusTurn = turn;
    F.body = el("div", "fp");
    pp.panel.open("Files", F.body, () => { F.shown = false; });
    F.shown = true;
    render();
  }

  function render() {
    const b = F.body; b.innerHTML = "";
    const seg = el("div", "seg fp-tabs");
    for (const [id, label] of [["files", "Files"], ["changed", "Changed"]]) {
      const t = el("button", F.tab === id ? "on" : "", label); t.type = "button";
      t.onclick = () => { F.tab = id; F.focusTurn = null; render(); };
      seg.append(t);
    }
    b.append(seg);
    const pane = el("div", "fp-pane"); b.append(pane);
    if (F.tab === "files") renderTree(pane); else renderChanged(pane);
  }

  // ------------------------------------------------------------ tree
  async function loadDir(dir) {
    if (F.dirs.has(dir)) return F.dirs.get(dir);
    const r = await api(`/api/files/list?${qs({ root: F.root, dir })}`);
    F.dirs.set(dir, r); return r;
  }

  async function renderTree(pane) {
    const head = el("div", "fp-root");
    head.innerHTML = `<span class="fp-root-path">${esc(tilde(F.root))}</span>`;
    const refresh = el("button", "chip-btn", "Refresh"); refresh.type = "button";
    refresh.onclick = () => { F.dirs.clear(); render(); };
    head.append(refresh);
    const tree = el("div", "fp-tree");
    pane.append(head, tree);
    try { await drawDir(tree, "", 0); } catch (e) { tree.append(el("div", "list-empty", esc(e.message))); }
  }

  async function drawDir(box, dir, depth) {
    const r = await loadDir(dir);
    if (!r.entries.length && !depth) box.append(el("div", "list-empty", "This folder is empty."));
    for (const e of r.entries) {
      const path = dir ? `${dir}/${e.name}` : e.name;
      const isDir = e.kind === "dir" || e.target === "dir";
      const row = el("button", "fp-row" + (isDir ? " dir" : "") + (e.kind === "link" && !e.target ? " dead" : ""));
      row.type = "button"; row.style.setProperty("--d", depth);
      const open = isDir && F.open.has(path);
      row.innerHTML = `<span class="fp-chev">${isDir ? ICON.chev : ""}</span><span class="fp-ic">${isDir ? ICON.folder : ICON.file}</span><span class="fp-name">${esc(e.name)}${e.kind === "link" ? ' <span class="fp-link">↪</span>' : ""}</span><span class="fp-meta">${isDir ? "" : size(e.size)}</span>`;
      row.classList.toggle("open", open);
      box.append(row);
      if (isDir) {
        const kids = el("div", "fp-kids"); box.append(kids);
        const fill = async () => { kids.innerHTML = ""; try { await drawDir(kids, path, depth + 1); } catch (err) { kids.append(el("div", "fp-err", esc(err.message))); } };
        if (open) fill();
        row.onclick = () => {
          const now = !F.open.has(path);
          now ? F.open.add(path) : F.open.delete(path);
          row.classList.toggle("open", now);
          if (now) fill(); else kids.innerHTML = "";
        };
      } else if (e.kind === "link" && !e.target) {
        row.disabled = true; row.title = "A link that leaves this folder";
      } else {
        row.onclick = () => preview(path, e.kind === "link");
      }
    }
    if (r.truncated) box.append(el("div", "fp-err", `Only the first ${r.entries.length} entries are shown.`));
  }

  // ------------------------------------------------------------ preview
  function mention(path, isDir) {
    const p = isDir ? path.replace(/\/?$/, "/") : path;
    const m = /\s/.test(p) ? (isDir ? `@"${p}` : `@"${p}"`) : `@${p}`;
    const inp = $("input");
    const v = inp.value;
    inp.value = v + (v && !/\s$/.test(v) ? " " : "") + m + " ";
    inp.dispatchEvent(new Event("input"));
    if (matchMedia("(max-width: 959px)").matches) pp.panel.close();
    inp.focus();
  }

  function preview(path, isLink) {
    const b = F.body; b.innerHTML = "";
    const head = el("div", "fp-phead");
    const back = el("button", "icon-btn", UP); back.type = "button"; back.setAttribute("aria-label", "Back");
    back.onclick = () => render();
    const name = el("div", "fp-pname"); name.textContent = path; name.title = path;
    const at = el("button", "icon-btn", AT); at.type = "button"; at.title = "Mention in the message"; at.setAttribute("aria-label", "Mention in the message");
    at.onclick = () => mention(path, false);
    const dl = el("a", "icon-btn", DL); dl.href = rawUrl(F.root, path, true); dl.title = "Download"; dl.setAttribute("aria-label", "Download");
    head.append(back, name, at, dl);
    const body = el("div", "fp-pbody");
    b.append(head, body);
    if (isLink) { body.append(el("div", "list-empty", "This is a link; links aren't opened here.")); return; }
    if (IMAGE.test(path)) {
      const img = el("img", "fp-img"); img.alt = path; img.src = rawUrl(F.root, path);
      img.onerror = () => { body.innerHTML = ""; body.append(downloadCard(path, "Couldn't show this image.")); };
      body.append(img); return;
    }
    if (/\.pdf$/i.test(path)) {
      const f = el("iframe", "fp-pdf"); f.src = rawUrl(F.root, path); f.title = path;
      const link = el("a", "fp-open", "Open in a new tab"); link.href = rawUrl(F.root, path); link.target = "_blank"; link.rel = "noopener";
      body.append(f, link); return;
    }
    showText(body, path);
  }

  function downloadCard(path, why) {
    const c = el("div", "fp-card");
    c.append(el("div", "fp-why", esc(why)));
    const a = el("a", "chip-btn", `${DL}<span>Download</span>`); a.href = rawUrl(F.root, path, true);
    c.append(a); return c;
  }

  async function page(path, from) { return api(`/api/files/read?${qs({ root: F.root, path, from })}`); }

  async function showText(body, path) {
    body.append(el("div", "fp-loading", "Loading…"));
    let p;
    try { p = await page(path, 1); } catch (e) {
      body.innerHTML = "";
      const why = e.status === 422 ? "Not a text file." : e.status === 413 ? "Too large to show here." : e.message;
      return body.append(downloadCard(path, why));
    }
    body.innerHTML = "";
    body.append(el("div", "fp-ver", `${esc(size(p.size))} · changed ${esc(when(p.mtime))}`));
    if (MD.test(path)) return showMarkdown(body, path, p);
    const wrap = el("div", "fp-code");
    const gut = el("pre", "fp-gut"), code = el("pre", "fp-src");
    wrap.append(gut, code); body.append(wrap);
    let next = null, loading = false, any = false;
    const add = (pg) => {
      if (pg.lines.length) {
        gut.append(document.createTextNode((any ? "\n" : "") + pg.lines.map((_, i) => pg.from + i).join("\n")));
        code.append(document.createTextNode((any ? "\n" : "") + pg.lines.join("\n")));
        any = true;
      }
      next = pg.next;
    };
    add(p);
    if (!p.lines.length) wrap.replaceWith(el("div", "list-empty", "Empty file."));
    const more = el("div", "fp-more"); body.append(more);
    const io = new IntersectionObserver(async (es) => {
      if (!es.some((x) => x.isIntersecting) || loading || next == null) return;
      loading = true; more.textContent = "Loading…";
      try {
        const pg = await page(path, next);
        if (pg.version !== p.version) more.textContent = "The file changed since it was opened.";
        add(pg); if (pg.version === p.version) more.textContent = "";
      } catch (e) { more.textContent = e.message; next = null; }
      loading = false;
      if (next == null) io.disconnect();
    }, { root: $("side-body"), rootMargin: "600px" });
    if (next != null) io.observe(more);
  }

  function showMarkdown(body, path, first) {
    let text = first.lines.join("\n"), next = first.next;
    const box = el("div", "md fp-md"); body.append(box);
    const draw = () => { box.innerHTML = md(text); };
    draw();
    if (next != null) {
      const b = el("button", "more", "Load the rest"); b.type = "button";
      b.onclick = async () => {
        b.disabled = true;
        try { while (next != null) { const pg = await page(path, next); text += "\n" + pg.lines.join("\n"); next = pg.next; } draw(); b.remove(); }
        catch (e) { toast(e.message, true); b.disabled = false; }
      };
      body.append(b);
    }
  }

  // ------------------------------------------------------------ changed
  function changesQuery(extra = {}) {
    const c = pp.chatInfo();
    return qs({ path: c.path || "", key: c.path ? "" : c.key || "", ...extra });
  }

  async function renderChanged(pane) {
    const c = pp.chatInfo();
    if (!c.path && !c.key) { pane.append(el("div", "list-empty", "Nothing changed yet.")); return; }
    pane.append(el("div", "fp-loading", "Loading…"));
    let r;
    try { r = await api(`/api/files/changes?${changesQuery()}`); } catch (e) { pane.innerHTML = ""; pane.append(el("div", "list-empty", esc(e.message))); return; }
    pane.innerHTML = "";
    const turns = (r.turns || []).filter((t) => (t.files || []).length || t.error).reverse();
    if (!turns.length) { pane.append(el("div", "list-empty", r.turns?.length ? "No turn changed a file yet." : "Nothing changed yet.")); return; }
    const git = r.git !== false;
    if (!git) pane.append(el("div", "fp-why", "Not a git folder: these are the files pi's edit and write tools named, without diffs."));
    if (git && turns.length > 1) pane.append(turnBlock({ turn: "all", files: null }, git, "Since this chat opened", false));
    for (const t of turns) pane.append(turnBlock(t, git, `Turn ${t.turn}`, F.focusTurn == null ? t === turns[0] : String(F.focusTurn) === String(t.turn)));
    const f = pane.querySelector(".fp-turn.open"); if (f && F.focusTurn != null) f.scrollIntoView({ block: "start" });
  }

  function turnBlock(t, git, title, openNow) {
    const d = el("details", "fp-turn"); d.open = openNow;
    const files = t.files;
    const sum = el("summary");
    const n = files ? files.length : null;
    sum.innerHTML = `<span class="fp-chev">${ICON.chev}</span><span class="fp-tt">${esc(title)}</span><span class="fp-meta">${n != null ? `${n} file${n === 1 ? "" : "s"}` : ""}${t.end ? ` · ${esc(when(t.end))}` : ""}</span>`;
    d.append(sum);
    const list = el("div", "fp-files"); d.append(list);
    const fill = async () => {
      let fs = files;
      if (!fs) {
        list.append(el("div", "fp-loading", "Loading…"));
        try { fs = (await api(`/api/files/changes?${changesQuery({ turn: t.turn })}`)).files || []; } catch (e) { list.innerHTML = ""; list.append(el("div", "fp-err", esc(e.message))); return; }
        list.innerHTML = "";
        sum.querySelector(".fp-meta").textContent = `${fs.length} file${fs.length === 1 ? "" : "s"}`;
      }
      if (t.error) list.append(el("div", "fp-err", esc(t.error)));
      if (!fs.length && !t.error) list.append(el("div", "fp-why", "No changes."));
      for (const f of fs) list.append(fileRow(t, f, git));
    };
    if (openNow) fill(); else d.addEventListener("toggle", function once() { if (d.open) { d.removeEventListener("toggle", once); fill(); } });
    return d;
  }

  function fileRow(t, f, git) {
    const wrap = el("div", "fp-cf");
    const row = el("button", "fp-row"); row.type = "button";
    row.innerHTML = `<span class="fp-name">${esc(f.path)}${f.from ? ` <span class="fp-meta">← ${esc(f.from)}</span>` : ""}</span><span class="fp-meta">${f.added == null && git ? "binary" : counts(f)}</span>`;
    wrap.append(row);
    if (!git) { row.onclick = () => preview(f.path.replace(/^\.\//, ""), false); return wrap; }
    let box = null;
    row.onclick = async () => {
      if (box) { box.remove(); box = null; return; }
      box = el("div", "tbody fp-diff"); box.append(el("div", "fp-loading", "Loading…")); wrap.append(box);
      try {
        const r = await api(`/api/files/changes?${changesQuery({ turn: t.turn, file: f.path })}`);
        box.innerHTML = "";
        box.append(r.diff ? diffBlock(r.diff) : el("div", "fp-why", "No text changes."));
        if (!f.path.startsWith("../")) {
          const o = el("button", "more", "Open the file"); o.type = "button"; o.onclick = () => preview(f.path, false); box.append(o);
        }
      } catch (e) { box.innerHTML = ""; box.append(el("div", "fp-err", esc(e.message))); }
    };
    return wrap;
  }

  // ------------------------------------------------------------ turn lines in the transcript
  function turnLine(t) {
    const fs = t.files || [];
    const b = el("button", "files-line"); b.type = "button"; b.dataset.turn = t.turn;
    const add = fs.reduce((a, f) => a + (f.added || 0), 0), del = fs.reduce((a, f) => a + (f.removed || 0), 0);
    const names = fs.length <= 2 ? fs.map((f) => f.path.split("/").pop()).join(", ") : `${fs.length} files`;
    b.innerHTML = `<span class="fl-ic">${ICON.pen}</span><span class="fl-t">Changed ${esc(names)}</span>${fs.some((f) => f.added != null) ? `<span class="fl-n"><span class="d-add">+${add}</span> <span class="d-del">−${del}</span></span>` : ""}`;
    b.onclick = () => open("changed", t.turn);
    return b;
  }

  let placeSeq = 0;
  /** After the transcript is drawn: a line after each turn that changed files. */
  async function placeLines() {
    const seq = ++placeSeq;
    const c = pp.chatInfo();
    if (!c.path && !c.key) return;
    let r;
    try { r = await api(`/api/files/changes?${changesQuery()}`); } catch { return; }
    if (seq !== placeSeq) return;
    const box = $("messages");
    box.querySelectorAll(":scope > .files-line").forEach((n) => n.remove());
    const users = S.msgs.filter((m) => m.role === "user");
    const nodes = [...box.querySelectorAll(":scope > .msg.user")];
    const first = S.msgs.find((m) => m.timestamp)?.timestamp;
    // Without timestamps (not pi's own messages) a turn can't be placed:
    // only the last one, at the end.
    const turns = users.every((m) => m.timestamp) ? r.turns || [] : (r.turns || []).slice(-1);
    for (const t of turns) {
      if (!(t.files || []).length || !t.end) continue;
      if (first && t.end < first) continue; // compacted away
      // The end of the turn: before the first prompt sent after it.
      const i = users.findIndex((m) => (m.timestamp || 0) > t.end);
      const before = i >= 0 && nodes.length === users.length ? nodes[i] : null;
      if (i >= 0 && !before) continue;
      box.insertBefore(turnLine(t), before);
    }
  }

  pp.events.push((ev) => {
    if (ev.type !== "pocketpi_turn_files") return;
    F.dirs.clear();
    if (F.shown && F.tab === "changed") render();
    if (!(ev.files || []).length) return;
    const box = $("messages");
    if (box.querySelector(`:scope > .files-line[data-turn="${CSS.escape(String(ev.turn))}"]`)) return;
    box.append(turnLine(ev));
    scrollBottom();
  });
  pp.rendered.push(() => { placeLines(); });
  pp.chat.push((c) => {
    if (!F.shown) return;
    if (!c.cwd) return pp.panel.close();
    if (c.cwd !== F.root) open(F.tab);
  });
  pp.sheet.push(sheetEntry);

  // ------------------------------------------------------------ @ picker
  // dsh's grammar: `@path` or `@"path with spaces` ending at the caret, not
  // inside another word (an email address isn't a mention).
  function activeToken(text, caret) {
    const before = text.slice(0, caret);
    const quoted = /(?:^|\s)(@"([^"]*))$/u.exec(before);
    if (quoted) return { prefix: quoted[1], query: quoted[2], quoted: true };
    const plain = /(?:^|\s)(@([^\s]*))$/u.exec(before);
    return plain ? { prefix: plain[1], query: plain[2], quoted: false } : null;
  }
  function format(c, keepQuote) {
    const path = c.kind === "dir" ? `${c.path}/` : c.path;
    if (/[\u0000-\u001f\u007f-\u009f"]/u.test(path)) return null;
    if (!(keepQuote || /\s/u.test(path))) return `@${path}`;
    return c.kind === "dir" ? `@"${path}` : `@"${path}"`;
  }

  const inp = $("input");
  const box = el("div", "at-pick"); box.id = "at-pick"; box.hidden = true; box.setAttribute("role", "listbox");
  $("composer").before(box);
  const P = { tok: null, items: [], sel: 0, timer: 0, seq: 0 };
  const hide = () => { box.hidden = true; P.items = []; P.tok = null; };

  function draw() {
    box.innerHTML = "";
    P.items.forEach((c, i) => {
      const b = el("button", "slash-item at-item" + (i === P.sel ? " sel" : ""));
      b.type = "button"; b.setAttribute("role", "option");
      const name = c.path.split("/").pop(), dir = c.path.slice(0, c.path.length - name.length);
      b.innerHTML = `<span class="fp-ic">${c.kind === "dir" ? ICON.folder : ICON.file}</span><b>${esc(name)}${c.kind === "dir" ? "/" : ""}</b><span class="at-dir">${esc(dir)}</span>`;
      b.onmousedown = (e) => e.preventDefault(); // keep the keyboard up
      b.onclick = () => choose(c);
      box.append(b);
    });
    box.hidden = !P.items.length;
  }

  async function lookup(tok) {
    const root = pp.chatInfo().cwd || (typeof newChatCwd === "function" ? newChatCwd() : null);
    if (!root || root === "~") return hide();
    const seq = ++P.seq;
    let r;
    try { r = await api(`/api/files/search?${qs({ root, q: tok.query })}`); } catch { if (seq === P.seq) hide(); return; }
    if (seq !== P.seq) return;
    P.tok = tok; P.items = r.results || []; P.sel = 0; draw();
  }

  function onInput() {
    const tok = activeToken(inp.value, inp.selectionStart ?? inp.value.length);
    if (!tok || S.view !== "chat") { P.seq++; return hide(); }
    clearTimeout(P.timer);
    P.timer = setTimeout(() => lookup(tok), 90);
  }

  function choose(c) {
    const tok = P.tok; if (!tok) return;
    const m = format(c, tok.quoted); if (!m) return;
    const caret = inp.selectionStart ?? inp.value.length;
    const start = caret - tok.prefix.length;
    const tail = inp.value.slice(caret);
    const sep = c.kind === "dir" || /^\s/.test(tail) ? "" : " ";
    inp.value = inp.value.slice(0, start) + m + sep + tail;
    const at = start + m.length + sep.length;
    inp.setSelectionRange(at, at);
    inp.focus();
    hide();
    inp.dispatchEvent(new Event("input")); // app.js resizes; a folder lists its insides
  }

  inp.addEventListener("input", onInput);
  inp.addEventListener("blur", () => setTimeout(() => { if (document.activeElement !== inp) hide(); }, 150));
  // Capture, so the picker's keys win over app.js's Enter-to-send.
  inp.addEventListener("keydown", (e) => {
    if (box.hidden || !P.items.length || e.isComposing) return;
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault(); e.stopImmediatePropagation();
      P.sel = (P.sel + (e.key === "ArrowDown" ? 1 : P.items.length - 1)) % P.items.length; draw();
    } else if ((e.key === "Enter" && !e.shiftKey && !e.altKey) || e.key === "Tab") {
      e.preventDefault(); e.stopImmediatePropagation(); choose(P.items[P.sel]);
    } else if (e.key === "Escape") {
      e.preventDefault(); e.stopImmediatePropagation(); hide();
    }
  }, true);

  return { open, activeToken, format };
})();
