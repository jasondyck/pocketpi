"use strict";
// Settings › About: which pi and which pocketpi build, and the config epoch.
// The smallest page that follows the Settings hub contract (web/manage.js,
// docs/pi-parity-plan.md §7): this file plus `manage_page!("about")` in
// src/main.rs.
ppManage.register({
  id: "about",
  title: "About",
  subtitle: "pi version, pocketpi build, config epoch",
  icon: '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="8.5"/><path d="M12 11v5.5M12 7.6v.1"/></svg>',
  order: 1000,
  async render(el, ctx) {
    ctx.style(`.mp-about .ab-row { display: flex; justify-content: space-between; gap: 12px; padding: 12px 14px; font-size: 14.5px; }
.mp-about .ab-row + .ab-row { border-top: 1px solid var(--line); }
.mp-about .ab-row b { font-weight: 500; color: var(--text-2); }
.mp-about .ab-row span { font: 13px var(--mono); color: var(--text); text-align: right; overflow-wrap: anywhere; }`);
    el.append(ctx.el("div", "wf-loading", "Loading…"));
    const [pi, build, status] = await Promise.all([
      ctx.api("/api/pi/version").catch((e) => ({ version: `unavailable (${e.message})` })),
      ctx.api("/api/version").catch(() => ({})),
      ctx.needsRestart(),
    ]);
    const live = (status?.live || []).filter((l) => l.kind !== "stage");
    const rows = [
      ["pi", pi.version || "unknown"],
      ["pocketpi build", build.build ? `${build.build} · started ${new Date(build.build).toLocaleString()}` : "unknown"],
      ["Config epoch", String(status?.config_epoch ?? "–")],
      ["Running chats", `${live.length}${live.some((l) => l.stale) ? ` · ${live.filter((l) => l.stale).length} with old settings` : ""}`],
      ["Control extension", status?.control ? "on" : "off"],
    ];
    el.innerHTML = "";
    const card = ctx.el("div", "wf-card");
    for (const [k, v] of rows) {
      const r = ctx.el("div", "ab-row", `<b>${ctx.esc(k)}</b><span>${ctx.esc(v)}</span>`);
      r.dataset.k = k;
      card.append(r);
    }
    el.append(card);
  },
});
