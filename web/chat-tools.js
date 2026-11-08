"use strict";
// A chat's tools (docs/pi-parity-plan.md F5): the "Tools" row in the chat
// sheet opens every tool this chat's pi has (built-in, extensions, MCP
// servers) with a switch each. Reads and sets them through the
// pocketpi-control extension: POST /api/s/{key}/control {command: "tools",
// args?: {active: [...]}}. pi saves the change with the chat, so it lasts
// for this chat (also after it's reopened); new chats start from
// defaultTools (Settings › pi settings). The iOS twin is ChatToolsView.swift
// with PocketPiKit's ChatTools.swift. Uses app.js's globals (S, api, el, esc,
// opt, openSheet, closeSheet, toast, ICON).
window.ppChatTools = (() => {
  const GROUPS = [["builtin", "Built-in"], ["extensions", "Extensions"], ["mcp", "MCP servers"]];
  const NOTE = "Changes apply to this chat only. pi saves them with the chat, so they're back when it's reopened. New chats start with the default tools (Settings › pi settings).";
  const EXPOSURE = {
    codemode: "Scripts in codemode can call it even when off.",
    deferred: "tool_search can find and turn it on.",
    "model-only": "The model sees it; scripts can't call it.",
  };
  const groupOf = (t) => (t.name.startsWith("mcp__") ? "mcp" : t.source === "builtin" || t.source === "sdk" ? "builtin" : "extensions");
  const shown = (tools) => tools.filter((t) => t.exposure !== "hidden");
  const server = (t) => { const m = /^mcp__(.+?)__/.exec(t.name); return m ? m[1] : null; };
  const summary = (t) => { const s = (t.description || "").split("\n")[0].trim(); return s.length > 140 ? s.slice(0, 139) + "…" : s; };

  let key = null, tools = [], busy = false, box = null;

  const css = document.createElement("style");
  css.textContent = `
.ct-sheet .opt.switch-row { padding: 10px 4px; border-radius: 0; }
.ct-sheet .opt.switch-row + .opt.switch-row { border-top: 1px solid var(--line); }
.ct-sheet .opt.switch-row .o-s { white-space: normal; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; }
.ct-sheet .ct-head { display: flex; align-items: center; gap: 8px; }
.ct-sheet .ct-head span { flex: 1; }
.ct-sheet .ct-all { font: 600 11.5px var(--font); color: var(--text-2); text-transform: none; letter-spacing: 0; padding: 2px 4px; }
.ct-sheet .ct-note { font-size: 12.5px; color: var(--muted); line-height: 1.4; margin: 16px 2px 4px; }
.ct-sheet .ct-tag { font: 500 10.5px var(--mono); color: var(--muted); border: 1px solid var(--line-2); border-radius: 999px; padding: 0 6px; margin-left: 6px; vertical-align: 1px; }
.ct-sheet.busy .switch { opacity: .6; }`;
  document.head.append(css);

  async function call(args) {
    const r = await api(`/api/s/${key}/control`, args ? { command: "tools", args } : { command: "tools" });
    if (r.success === false) throw new Error(r.error || "pocketpi-control failed");
    return r.data?.tools || [];
  }

  // The list after switching one tool: the others keep their state and
  // order; a tool turned on goes last (same as ChatTools.active(after:)).
  function activeAfter(name, on) {
    const list = shown(tools).filter((t) => t.active && t.name !== name).map((t) => t.name);
    if (on) list.push(name);
    return list;
  }
  function activeSetting(group, on) {
    const list = shown(tools).filter((t) => t.active && groupOf(t) !== group).map((t) => t.name);
    if (on) list.push(...shown(tools).filter((t) => groupOf(t) === group).map((t) => t.name));
    return list;
  }

  async function apply(active, msg) {
    if (busy) return;
    busy = true; box?.closest(".ct-sheet")?.classList.add("busy");
    try { tools = await call({ active }); if (msg) toast(msg); } catch (e) { toast(e.message, true); }
    busy = false; box?.closest(".ct-sheet")?.classList.remove("busy");
    draw();
  }

  function draw() {
    if (!box) return;
    box.innerHTML = "";
    const all = shown(tools);
    const sub = document.querySelector(".ct-sheet .ct-count");
    if (sub) sub.textContent = `${all.filter((t) => t.active).length} of ${all.length} on`;
    for (const [g, title] of GROUPS) {
      const list = all.filter((t) => groupOf(t) === g);
      if (!list.length) continue;
      const on = list.filter((t) => t.active).length;
      const head = el("div", "sheet-section ct-head", `<span>${esc(title)} · ${on}/${list.length}</span>`);
      const allBtn = el("button", "ct-all", on === list.length ? "All off" : "All on");
      allBtn.onclick = () => apply(activeSetting(g, on !== list.length), `${title}: all ${on === list.length ? "off" : "on"}`);
      head.dataset.group = g;
      head.append(allBtn);
      box.append(head);
      for (const t of list) {
        const srv = server(t);
        const tag = t.exposure && t.exposure !== "direct" ? `<span class="ct-tag">${esc(t.exposure)}</span>` : "";
        const sub = [srv ? `${srv} · ` : "", summary(t), EXPOSURE[t.exposure] ? ` ${EXPOSURE[t.exposure]}` : ""].join("");
        const b = el("button", "opt switch-row", `<div class="o-main"><div class="o-t"><span class="mono">${esc(t.name)}</span>${tag}</div>${sub ? `<div class="o-s">${esc(sub)}</div>` : ""}</div><span class="switch${t.active ? " on" : ""}"><i></i></span>`);
        b.dataset.tool = t.name;
        b.setAttribute("role", "switch"); b.setAttribute("aria-checked", String(!!t.active));
        b.onclick = () => apply(activeAfter(t.name, !t.active));
        box.append(b);
      }
    }
    if (!all.length) box.append(el("div", "list-empty", "This chat has no tools."));
  }

  async function open() {
    key = S.key;
    if (!key) return;
    openSheet((b) => b.append(el("div", "sheet-title", "Tools"), el("div", "sheet-sub", "Loading…")));
    try { tools = await call(); } catch (e) {
      openSheet((b) => b.append(el("div", "sheet-title", "Tools"), el("div", "errbox", esc(e.message))));
      return;
    }
    openSheet((b) => {
      const w = el("div", "ct-sheet");
      w.append(el("div", "sheet-title", "Tools"), el("div", "sheet-sub ct-count", ""));
      box = el("div"); w.append(box);
      w.append(el("div", "ct-note", esc(NOTE)));
      b.append(w);
    });
    draw();
  }

  // The chat sheet's row (one line in app.js's openChatSheet).
  function sheetEntry(b) {
    if (!S.key) return;
    const row = opt(ICON.tool, "Tools", "Turn this chat's tools on or off", () => open());
    row.dataset.entry = "tools";
    b.append(row);
  }

  // Leaving the sheet: forget the box so a stale one isn't drawn into.
  document.getElementById("sheet-scrim")?.addEventListener("click", () => { box = null; });

  return { sheetEntry, open };
})();
