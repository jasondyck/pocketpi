// A fake pi for pocketpi-goal.ts's tests: records the handlers, tools and
// commands an extension registers, the entries it appends and the user
// messages it sends, and keeps a session branch the extension reads back.

export interface Fake {
  pi: any;
  ctx: any;
  handlers: Map<string, Function[]>;
  tools: Map<string, any>;
  commands: Map<string, any>;
  /** The session branch: custom entries the extension appended, plus messages added by the test. */
  branch: any[];
  sent: string[];
  statuses: (string | undefined)[];
  notes: { msg: string; type?: string }[];
  idle: boolean;
  pending: boolean;
  emit(event: string, payload?: any): Promise<any[]>;
  /** Runs a tool like pi would, returning its result or throwing its error. */
  tool(name: string, params?: any): Promise<any>;
  /** Runs /pp-<name> the way the server does; resolves to the reply entry's data. */
  control(name: string, args?: any): Promise<any>;
  /** The last published pp-goal status, parsed (null when cleared). */
  status(): any;
  entries(type: string): any[];
  /** An assistant message on the branch with this cost. */
  addAssistant(cost: number, stopReason?: string): void;
  /** Lets setTimeout(0) work (the extension's kick) run. */
  tick(): Promise<void>;
}

let seq = 0;

export function makeFake(): Fake {
  const f: any = {
    handlers: new Map(),
    tools: new Map(),
    commands: new Map(),
    branch: [],
    sent: [],
    statuses: [],
    notes: [],
    idle: true,
    pending: false,
  };
  const at = () => new Date().toISOString();
  f.pi = {
    on(ev: string, h: Function) {
      if (!f.handlers.has(ev)) f.handlers.set(ev, []);
      f.handlers.get(ev).push(h);
    },
    registerTool(t: any) { f.tools.set(t.name, t); },
    registerCommand(name: string, c: any) { f.commands.set(name, c); },
    appendEntry(customType: string, data: any) {
      f.branch.push({ type: "custom", id: `e${++seq}`, customType, data: structuredClone(data), timestamp: at() });
    },
    sendUserMessage(text: string) { f.sent.push(text); f.idle = false; }, // pi starts a run
  };
  f.ctx = {
    ui: {
      setStatus(key: string, t: string | undefined) { if (key === "pp-goal") f.statuses.push(t); },
      notify(msg: string, type?: string) { f.notes.push({ msg, type }); },
    },
    sessionManager: { getBranch: () => f.branch, getEntries: () => f.branch },
    isIdle: () => f.idle,
    hasPendingMessages: () => f.pending,
  };
  f.emit = async (event: string, payload: any = {}) => {
    const out = [];
    for (const h of f.handlers.get(event) || []) out.push(await h(payload, f.ctx));
    return out;
  };
  f.tool = async (name: string, params: any = {}) => f.tools.get(name).execute("call1", params, undefined, undefined, f.ctx);
  f.control = async (name: string, args?: any) => {
    const req = `r${++seq}`;
    await f.commands.get(`pp-${name}`).handler(args === undefined ? req : `${req} ${JSON.stringify(args)}`, f.ctx);
    const reply = f.branch.filter((e: any) => e.customType === "pocketpi-control" && e.data.reqId === req).pop();
    if (!reply) throw new Error("no reply");
    if (!reply.data.ok) throw new Error(reply.data.error);
    return reply.data.data;
  };
  f.status = () => {
    const s = f.statuses[f.statuses.length - 1];
    return s == null ? null : JSON.parse(s);
  };
  f.entries = (type: string) => f.branch.filter((e: any) => e.customType === type);
  f.addAssistant = (cost: number, stopReason = "stop") => {
    f.branch.push({
      type: "message",
      id: `m${++seq}`,
      timestamp: at(),
      message: { role: "assistant", stopReason, timestamp: Date.now(), usage: { cost: { total: cost } } },
    });
  };
  f.tick = () => new Promise((r) => setTimeout(r, 5));
  return f as Fake;
}
