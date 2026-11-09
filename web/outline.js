"use strict";
// Turn outline (docs/dsh-features-plan.md §3.7): "Outline" in the chat sheet
// opens a sheet with one line per prompt of the active branch (the server's
// GET /api/sessions/outline). Tapping one scrolls the transcript to that
// message. Plugs into app.js through window.pp (see "feature hooks" there).
//
// The transcript is drawn from get_messages, which has no entry ids, so an
// outline line is found on screen the way "Fork from here" finds its entry:
// app.js's forkEntryIds lines the user messages on screen up with pi's fork
// points (narrowed to the current branch by tree.js). A turn compacted away
// isn't on screen; that gets a toast instead.

window.ppOutline = (() => {
  const LIST = '<svg viewBox="0 0 24 24"><path d="M9 6.5h11M9 12h11M9 17.5h11"/><circle cx="4.5" cy="6.5" r="1.2"/><circle cx="4.5" cy="12" r="1.2"/><circle cx="4.5" cy="17.5" r="1.2"/></svg>';

  function sheetEntry(b) {
    const chat = pp.chatInfo();
    if (!chat.path) return; // nothing written yet
    b.append(opt(LIST, "Outline", "Every prompt in this chat; tap one to jump to it", () => open(chat.path)));
  }

  async function open(path) {
    openSheet((b) => b.append(el("div", "sheet-title", "Outline"), el("div", "sheet-sub", "Loading…")));
    let items;
    try { items = await api(`/api/sessions/outline?path=${encodeURIComponent(path)}`); }
    catch (e) { closeSheet(); return toast(e.status === 404 ? "This chat has no outline yet." : e.message, true); }
    openSheet((b) => {
      b.append(el("div", "sheet-title", "Outline"), el("div", "sheet-sub", `${items.length} prompt${items.length === 1 ? "" : "s"} on this branch`));
      if (!items.length) { b.append(el("div", "list-empty", "No prompts yet.")); return; }
      const list = el("div", "ol-list");
      items.forEach((it, i) => {
        const row = el("button", "ol-turn");
        row.type = "button";
        row.innerHTML = `<span class="ol-n">${i + 1}</span><span class="ol-main"><span class="ol-p">${esc(it.prompt)}</span>${it.response ? `<span class="ol-r">${esc(it.response)}</span>` : ""}</span>`;
        row.onclick = () => { closeSheet(); jump(it.entryId); };
        list.append(row);
      });
      b.append(list);
    });
  }

  /** The user message element on screen for a session entry, or null. */
  async function messageFor(entryId) {
    const users = S.msgs.filter((m) => m.role === "user");
    const shown = users.map((m) => forkText(m.content));
    const points = window.ppTree ? await ppTree.activeForkPoints() : (await cmd({ type: "get_fork_messages" })).messages || [];
    const n = forkEntryIds(shown, points).indexOf(entryId);
    if (n < 0) return null;
    return $("messages").querySelectorAll(":scope > .msg.user")[n] || null;
  }

  async function jump(entryId) {
    let node = null;
    try { node = await messageFor(entryId); } catch (e) { return toast(e.message, true); }
    if (!node) return toast("That turn isn't loaded here: it was compacted away.", true);
    S.stick = false;
    node.scrollIntoView({ block: "start", behavior: "smooth" });
    node.classList.remove("ol-flash"); void node.offsetWidth; node.classList.add("ol-flash");
    setTimeout(() => node.classList.remove("ol-flash"), 1800);
  }

  pp.sheet.push(sheetEntry);
  return { open, jump };
})();
