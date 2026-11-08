"use strict";
// Settings › Usage (plan H1): cost and tokens across every chat, per day,
// model, provider and project, from GET /api/usage (src/usage.rs reads pi's
// session files, cached by mtime + size).
//
// Costs are what pi recorded. Subscriptions (pi's OAuth logins, Codex,
// Copilot) aren't billed per token, so their cost is an API-rate equivalent
// (often $0) and is kept out of "Spent". OpenCode Go draws from a prepaid
// dollar pool and is shown on its own.
ppManage.register({
  id: "usage",
  title: "Usage",
  subtitle: "Cost and tokens by day, model and project",
  icon: '<svg viewBox="0 0 24 24"><path d="M4 20h16"/><path d="M7 16v-5M12 16V6M17 16v-8"/></svg>',
  order: 60,
  async render(el, ctx) {
    ctx.style(`.mp-usage { --u-api: #2a78d6; --u-pool: #eb6834; --u-sub: #1baf7a; }
@media (prefers-color-scheme: dark) { .mp-usage { --u-api: #3987e5; --u-pool: #d95926; --u-sub: #199e70; } }
.mp-usage .u-top { display: flex; gap: 8px; align-items: center; }
.mp-usage .u-top .seg { flex: 1; }
.mp-usage .stats { margin-top: 12px; }
.mp-usage .u-kinds .u-kind { display: flex; align-items: center; gap: 10px; padding: 11px 14px; font-size: 14px; }
.mp-usage .u-kinds .u-kind + .u-kind { border-top: 1px solid var(--line); }
.mp-usage .u-sw { width: 10px; height: 10px; border-radius: 3px; flex: none; }
.mp-usage .u-kind .u-name { flex: 1; min-width: 0; }
.mp-usage .u-kind .u-note { display: block; font-size: 12px; color: var(--muted); }
.mp-usage .u-kind .u-val { font: 500 13.5px var(--mono); text-align: right; }
.mp-usage .u-kind .u-val small { display: block; font-size: 11.5px; color: var(--muted); font-weight: 400; }
.mp-usage .u-chart { padding: 12px 12px 8px; position: relative; }
.mp-usage .u-bars { display: flex; align-items: flex-end; gap: 2px; height: 150px; border-bottom: 1px solid var(--line-2); }
.mp-usage .u-bar { flex: 1; min-width: 0; height: 100%; display: flex; flex-direction: column-reverse; gap: 2px; cursor: default; position: relative; }
.mp-usage .u-bar:hover, .mp-usage .u-bar.on { background: var(--line); border-radius: 4px 4px 0 0; }
.mp-usage .u-seg { width: 100%; min-height: 2px; }
.mp-usage .u-seg:last-child { border-radius: 4px 4px 0 0; }
.mp-usage .u-axis { display: flex; justify-content: space-between; font: 11px var(--mono); color: var(--muted); margin-top: 5px; }
.mp-usage .u-peak { position: absolute; top: 4px; right: 14px; font: 11px var(--mono); color: var(--muted); }
.mp-usage .u-tip { min-height: 18px; font: 12px var(--mono); color: var(--text-2); margin-top: 6px; }
.mp-usage .u-legend { display: flex; flex-wrap: wrap; gap: 12px; font-size: 12px; color: var(--text-2); margin-top: 6px; }
.mp-usage .u-legend span { display: inline-flex; align-items: center; gap: 5px; }
.mp-usage table { width: 100%; border-collapse: collapse; font-size: 13.5px; }
.mp-usage th { font: 600 11px var(--font); color: var(--muted); text-align: right; padding: 9px 14px 6px; text-transform: uppercase; letter-spacing: .04em; }
.mp-usage th:first-child, .mp-usage td:first-child { text-align: left; }
.mp-usage td { padding: 9px 14px; border-top: 1px solid var(--line); text-align: right; font: 12.5px var(--mono); white-space: nowrap; }
.mp-usage td:first-child { font: 13.5px var(--font); white-space: normal; overflow-wrap: anywhere; }
.mp-usage td .u-sub { display: block; font: 11.5px var(--mono); color: var(--muted); }
.mp-usage .u-foot { font-size: 12px; color: var(--muted); margin: 10px 2px 0; line-height: 1.45; }`);
    const { esc } = ctx;
    const KINDS = [
      { id: "api", label: "API (billed)", note: "billed per token", color: "var(--u-api)" },
      { id: "pool", label: "OpenCode Go", note: "from the prepaid pool", color: "var(--u-pool)" },
      { id: "subscription", label: "Subscriptions", note: "API-rate equivalent, not billed", color: "var(--u-sub)" },
    ];
    const kindOf = (id) => KINDS.find((k) => k.id === id) || KINDS[0];
    let days = Number(localStorage.getItem("pp.usage.days")) || 30;
    let metric = localStorage.getItem("pp.usage.metric") || "cost";
    const money = (c) => (!c ? "$0" : c < 0.01 ? "<$0.01" : "$" + c.toFixed(c < 10 ? 2 : c < 1000 ? 1 : 0));
    const name = (p) => (typeof projectName === "function" ? projectName(p) : p.split("/").pop() || p);

    const load = async () => {
      el.innerHTML = "";
      const top = ctx.el("div", "u-top");
      const range = ctx.el("div", "seg");
      for (const d of [7, 30, 90]) {
        const b = ctx.el("button", d === days ? "on" : "", `${d} days`);
        b.dataset.days = d;
        b.onclick = () => { days = d; localStorage.setItem("pp.usage.days", d); load(); };
        range.append(b);
      }
      top.append(range); el.append(top);
      const body = ctx.el("div"); body.append(ctx.el("div", "wf-loading", "Adding up your sessions…")); el.append(body);
      let r;
      try { r = await ctx.api(`/api/usage?days=${days}&tz=${-new Date().getTimezoneOffset()}`); }
      catch (e) { body.innerHTML = `<div class="errbox">${esc(e.message)}</div>`; return; }
      body.innerHTML = "";
      draw(body, r);
    };

    function draw(body, r) {
      const b = r.billing || {};
      const spent = (b.api?.cost || 0) + (b.pool?.cost || 0);
      const stats = ctx.el("div", "stats");
      stats.innerHTML = `<div class="stat"><div class="v">${money(spent)}</div><div class="l">spent</div></div>
        <div class="stat"><div class="v">${fmtTokens(r.totals?.tokens || 0)}</div><div class="l">tokens</div></div>
        <div class="stat"><div class="v">${(r.totals?.count || 0).toLocaleString()}</div><div class="l">replies</div></div>`;
      body.append(stats);

      // Spent vs not: billed, the pool, subscriptions.
      body.append(ctx.el("div", "wf-section", "Cost by billing"));
      const kinds = ctx.el("div", "wf-card u-kinds");
      for (const k of KINDS) {
        const t = b[k.id] || {};
        const row = ctx.el("div", "u-kind", `<span class="u-sw" style="background:${k.color}"></span>
          <span class="u-name">${esc(k.label)}<span class="u-note">${esc(k.note)}</span></span>
          <span class="u-val">${money(t.cost)}<small>${fmtTokens(t.tokens || 0)} tokens</small></span>`);
        row.dataset.kind = k.id;
        kinds.append(row);
      }
      body.append(kinds);

      // Per day: stacked by billing; cost or tokens.
      const head = ctx.el("div", "wf-section u-top", "");
      head.style.display = "flex";
      head.innerHTML = `<span style="flex:1">Per day</span>`;
      const mseg = ctx.el("div", "seg"); mseg.style.flex = "none";
      for (const [id, label] of [["cost", "Cost"], ["tokens", "Tokens"]]) {
        const btn = ctx.el("button", id === metric ? "on" : "", label);
        btn.style.minWidth = "64px"; btn.style.height = "28px";
        btn.onclick = () => { metric = id; localStorage.setItem("pp.usage.metric", id); body.innerHTML = ""; draw(body, r); };
        mseg.append(btn);
      }
      head.append(mseg); body.append(head);
      const card = ctx.el("div", "wf-card u-chart");
      const val = (d, k) => (metric === "cost" ? d[k]?.cost || 0 : d[k]?.tokens || 0);
      const fmt = (v) => (metric === "cost" ? money(v) : fmtTokens(v));
      const dayList = r.byDay || [];
      const peak = Math.max(0, ...dayList.map((d) => KINDS.reduce((s, k) => s + val(d, k.id), 0)));
      const bars = ctx.el("div", "u-bars"); bars.setAttribute("role", "img");
      bars.setAttribute("aria-label", `${metric === "cost" ? "Cost" : "Tokens"} per day, ${r.from} to ${r.to}`);
      const tip = ctx.el("div", "u-tip", "Hover or tap a day");
      const short = (day) => new Date(day + "T12:00:00").toLocaleDateString(undefined, { month: "short", day: "numeric" });
      for (const d of dayList) {
        const bar = ctx.el("div", "u-bar");
        const total = KINDS.reduce((s, k) => s + val(d, k.id), 0);
        for (const k of KINDS) {
          const v = val(d, k.id);
          if (!v || !peak) continue;
          const seg = ctx.el("div", "u-seg"); seg.style.background = k.color; seg.style.height = `calc(${(v / peak) * 100}% - 2px)`;
          bar.append(seg);
        }
        const text = `${short(d.day)} · ${fmt(total)}` + KINDS.filter((k) => val(d, k.id)).map((k) => ` · ${k.label} ${fmt(val(d, k.id))}`).join("");
        bar.title = text;
        const show = () => { bars.querySelectorAll(".u-bar.on").forEach((x) => x.classList.remove("on")); bar.classList.add("on"); tip.textContent = text; };
        bar.onmouseenter = show; bar.onclick = show;
        bars.append(bar);
      }
      card.append(ctx.el("div", "u-peak", peak ? fmt(peak) : ""), bars);
      card.append(ctx.el("div", "u-axis", `<span>${esc(dayList[0] ? short(dayList[0].day) : "")}</span><span>${esc(dayList.length ? short(dayList[dayList.length - 1].day) : "")}</span>`));
      card.append(tip);
      const legend = ctx.el("div", "u-legend");
      for (const k of KINDS) legend.append(ctx.el("span", "", `<span class="u-sw" style="background:${k.color}"></span>${esc(k.label)}`));
      card.append(legend);
      body.append(card);

      const table = (title, rows, label) => {
        body.append(ctx.el("div", "wf-section", title));
        const c = ctx.el("div", "wf-card");
        if (!rows.length) { c.append(ctx.el("div", "list-empty", "Nothing in this range")); body.append(c); return; }
        const t = ctx.el("table");
        t.innerHTML = `<thead><tr><th>${esc(label)}</th><th>Tokens</th><th>Cost</th></tr></thead>`;
        const tb = ctx.el("tbody");
        for (const row of rows.slice(0, 25)) {
          const tr = ctx.el("tr");
          const sub = row.billing === "subscription" ? "API-rate equivalent" : row.billing === "pool" ? "OpenCode Go pool" : "";
          tr.innerHTML = `<td>${row.html}${sub ? `<span class="u-sub">${sub}</span>` : ""}</td><td>${fmtTokens(row.tokens)}</td><td>${money(row.cost)}${row.billing === "subscription" ? "*" : ""}</td>`;
          tb.append(tr);
        }
        t.append(tb); c.append(t); body.append(c);
      };
      table("By model", (r.byModel || []).map((m) => ({ ...m, html: `${esc(m.model)}<span class="u-sub">${esc(m.provider)}</span>` })), "Model");
      table("By provider", (r.byProvider || []).map((p) => ({ ...p, html: esc(p.provider) })), "Provider");
      table("By project", (r.byProject || []).map((p) => ({ ...p, html: `${esc(name(p.project))}<span class="u-sub">${esc(tilde(p.project))}</span>` })), "Project");
      body.append(ctx.el("div", "u-foot", `* Subscription costs are pi's API-rate equivalent (often $0), not money spent. ${(r.files || 0).toLocaleString()} session files · ${esc(r.from)} to ${esc(r.to)}.`));
    }

    await load();
  },
});
