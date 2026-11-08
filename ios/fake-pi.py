#!/usr/bin/env python3
"""A stand-in for `pi --mode rpc`, for testing the iOS client against a real
pocketpi without a model, a key or any cost.

It speaks enough of pi's RPC protocol for pocketpi and PocketPiKit: the state
and message commands, prompts that stream back an echo (thinking, text, and a
tool call when the prompt says "tool", a workflow_run call for the run id in
~/.fake-pi-run when it says "deploy"), an extension confirm dialog when the
prompt says "ask" (with a 1.5 s timeout when it says "timeout"),
setStatus / setWidget / setTitle when it says "widgets", session names, abort. Sessions are written in pi's format
to $PI_CODING_AGENT_SESSION_DIR so pocketpi lists and reopens them.

Also the commands pocketpi allows since the pi-parity work: fork, clone,
get_fork_messages, get_tree, get_entries, export_html, bash (echoed, never
run), abort_bash, get_last_assistant_text and the global setters; and, when
started with `-e .../pocketpi-control.ts`, the extension's /pp-tools, which
answers like the real one with an `entry_appended` custom entry.

    POCKETPI_PI=ios/fake-pi.py pocketpi
"""
import json
import os
import sys
import threading
import time
import uuid

lock = threading.Lock()
answers = {}
answered = threading.Condition(lock)
aborted = threading.Event()


def out(obj):
    with lock:
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()


args = sys.argv[1:]
session_file = args[args.index("--session") + 1] if "--session" in args else None
session_dir = os.environ.get("PI_CODING_AGENT_SESSION_DIR") or os.path.expanduser("~/.pi/agent/sessions")
# pocketpi loads its companion extension into normal chats with -e.
control = any(a.endswith("pocketpi-control.ts") for a in args)
messages = []
# Message entries as (id, message): the tree pi keeps, always linear here.
entries = []
name = None
streaming = False
settings = {"steeringMode": "one-at-a-time", "followUpMode": "one-at-a-time", "autoCompaction": True, "autoRetry": True}
TOOLS = ["read", "bash", "edit", "write", "grep"]
active_tools = ["read", "bash", "edit", "write"]

if session_file:
    with open(session_file) as f:
        for line in f:
            rec = json.loads(line)
            if rec.get("type") == "message":
                messages.append(rec["message"])
                entries.append((rec.get("id") or uuid.uuid4().hex[:8], rec["message"]))
            elif rec.get("type") == "session_info":
                name = rec.get("name")


def compact(rec):
    # Compact, "type" first: pocketpi's session scanner matches substrings.
    return json.dumps(rec, separators=(",", ":")) + "\n"


def new_file(parent=None):
    os.makedirs(session_dir, exist_ok=True)
    sid = str(uuid.uuid4())
    path = os.path.join(session_dir, f"{int(time.time() * 1000)}_{sid}.jsonl")
    header = {"type": "session", "id": sid, "cwd": os.getcwd(), "version": 3}
    if parent:
        header["parentSession"] = parent
    with open(path, "w") as f:
        f.write(compact(header))
    return path


def save(rec):
    global session_file
    if not session_file:
        session_file = new_file()
    with open(session_file, "a") as f:
        f.write(compact(rec))


def add(msg):
    messages.append(msg)
    eid = uuid.uuid4().hex[:8]
    parent = entries[-1][0] if entries else None
    entries.append((eid, msg))
    save({"type": "message", "id": eid, "parentId": parent, "message": msg})


def text_of(msg):
    c = msg.get("content")
    if isinstance(c, str):
        return c
    return " ".join(b.get("text", "") for b in c or [] if b.get("type") == "text")


def branch_to(keep, parent_file):
    """fork/clone: carry on in a new session file holding `keep`."""
    global session_file, messages, entries
    path = new_file(parent_file)
    with open(path, "a") as f:
        prev = None
        for eid, msg in keep:
            f.write(compact({"type": "message", "id": eid, "parentId": prev, "message": msg}))
            prev = eid
    session_file = path
    entries = list(keep)
    messages = [m for _, m in keep]


def control_command(line):
    """/pp-<name> <reqId> [json], answered with a hidden custom entry the
    way extensions/pocketpi-control.ts does it in real pi."""
    global active_tools
    head, _, rest = line.partition(" ")
    req_id, _, raw = rest.strip().partition(" ")
    try:
        a = json.loads(raw) if raw.strip() else None
        if head != "/pp-tools":
            raise ValueError(f"unknown command {head}")
        if a and isinstance(a.get("active"), list):
            unknown = [str(n) for n in a["active"] if n not in TOOLS]
            if unknown:
                raise ValueError("unknown tools: " + ", ".join(unknown))
            active_tools = list(a["active"])
        data = {"tools": [{"name": t, "description": f"The {t} tool", "exposure": "direct", "source": "builtin",
                           "path": f"builtin:{t}", "active": t in active_tools} for t in TOOLS],
                "active": active_tools}
        reply = {"reqId": req_id, "ok": True, "data": data}
    except Exception as e:  # the extension reports every failure
        reply = {"reqId": req_id, "ok": False, "error": str(e)}
    entry = {"type": "custom", "customType": "pocketpi-control", "data": reply, "id": uuid.uuid4().hex[:8],
             "parentId": entries[-1][0] if entries else None}
    # Like pi: never creates a session file on its own.
    if session_file:
        save(entry)
    out({"type": "entry_appended", "entry": entry})


def stream_assistant(blocks, stop_reason):
    """Stream an assistant message block by block, then end it."""
    out({"type": "message_start", "message": {"role": "assistant", "content": []}})
    for i, b in enumerate(blocks):
        kind = b["type"]
        if kind in ("text", "thinking"):
            key = "text" if kind == "text" else "thinking"
            out({"type": "message_update", "assistantMessageEvent": {"type": f"{kind}_start", "contentIndex": i}})
            words = b[key].split(" ")
            for j, w in enumerate(words):
                delta = w if j == 0 else " " + w
                out({"type": "message_update", "assistantMessageEvent": {"type": f"{kind}_delta", "contentIndex": i, "delta": delta}})
                time.sleep(0.01)
            out({"type": "message_update", "assistantMessageEvent": {"type": f"{kind}_end", "contentIndex": i, "content": b[key]}})
        elif kind == "toolCall":
            out({"type": "message_update", "assistantMessageEvent": {"type": "toolcall_start", "contentIndex": i, "id": b["id"], "toolName": b["name"]}})
            out({"type": "message_update", "assistantMessageEvent": {"type": "toolcall_end", "contentIndex": i, "toolCall": b}})
    msg = {"role": "assistant", "content": blocks, "stopReason": stop_reason}
    add(msg)
    out({"type": "message_end", "message": msg})


def ext_ui(prompt, cmd_id):
    """setStatus / setWidget / setTitle, like an extension's ctx.ui. "clear
    widgets" takes the lint status and the below-editor widget away again."""
    def req(**kw):
        out({"type": "extension_ui_request", "id": f"ui-{cmd_id}-{uuid.uuid4().hex[:6]}", **kw})
    if "clear" in prompt:
        req(method="setStatus", statusKey="lint")
        req(method="setWidget", widgetKey="hint", widgetPlacement="belowEditor")
        return
    req(method="setStatus", statusKey="fake", statusText="\x1b[32mready\x1b[0m")
    req(method="setStatus", statusKey="lint", statusText="2 warnings")
    req(method="setWidget", widgetKey="todo", widgetLines=["TODO", "[x] status chips", "[ ] widgets"],
        widgetPlacement="aboveEditor")
    req(method="setWidget", widgetKey="hint", widgetLines=["tip: say 'clear widgets'"], widgetPlacement="belowEditor")
    req(method="setTitle", title="pi - fake project")


def run(prompt, cmd_id):
    global streaming
    streaming = True
    aborted.clear()
    out({"type": "agent_start"})
    user = {"role": "user", "content": [{"type": "text", "text": prompt}]}
    out({"type": "message_start", "message": user})
    add(user)
    out({"type": "message_end", "message": user})
    reply = f"Echo: {prompt}"
    if "ask" in prompt:
        rid = f"ui-{cmd_id}"
        out({"type": "extension_ui_request", "id": rid, "method": "confirm", "title": "Allow it?", "message": "The fake asks."})
        with answered:
            answered.wait_for(lambda: rid in answers, timeout=20)
            a = answers.pop(rid, {})
        reply += " · confirmed" if a.get("confirmed") else " · declined"
    if "widgets" in prompt:
        ext_ui(prompt, cmd_id)
    if "timeout" in prompt:
        # pi resolves a dialog with a timeout itself; the client only shows it.
        rid = f"ui-{cmd_id}"
        out({"type": "extension_ui_request", "id": rid, "method": "confirm", "title": "Quick question",
             "message": "Answer within a second and a half.", "timeout": 1500})
        with answered:
            answered.wait_for(lambda: rid in answers, timeout=1.5)
            a = answers.pop(rid, None)
        reply += " · timed out" if a is None else " · confirmed" if a.get("confirmed") else " · declined"
    if "tool" in prompt:
        call = {"type": "toolCall", "id": f"call-{cmd_id}", "name": "bash", "arguments": {"command": "echo hi"}}
        stream_assistant([{"type": "thinking", "thinking": "I should run something"}, call], "toolUse")
        out({"type": "tool_execution_start", "toolCallId": call["id"], "toolName": "bash", "args": call["arguments"]})
        out({"type": "tool_execution_update", "toolCallId": call["id"], "partialResult": {"content": [{"type": "text", "text": "h"}]}})
        result = {"content": [{"type": "text", "text": "hi"}], "details": {}}
        out({"type": "tool_execution_end", "toolCallId": call["id"], "toolName": "bash", "result": result, "isError": False, "durationMs": 5})
        tr = {"role": "toolResult", "toolCallId": call["id"], "toolName": "bash", "content": result["content"], "isError": False}
        out({"type": "message_start", "message": tr})
        add(tr)
        out({"type": "message_end", "message": tr})
    run_file = os.path.expanduser("~/.fake-pi-run")
    if "deploy" in prompt and os.path.exists(run_file):
        run_id = open(run_file).read().strip()
        call = {"type": "toolCall", "id": f"wf-{cmd_id}", "name": "workflow_run", "arguments": {"id": "natter-deploy"}}
        stream_assistant([call], "toolUse")
        out({"type": "tool_execution_start", "toolCallId": call["id"], "toolName": "workflow_run", "args": call["arguments"]})
        result = {"content": [{"type": "text", "text": f"Started run {run_id}."}],
                  "details": {"run_id": run_id, "workflow_id": "natter-deploy"}}
        out({"type": "tool_execution_end", "toolCallId": call["id"], "toolName": "workflow_run", "result": result, "isError": False, "durationMs": 5})
        tr = {"role": "toolResult", "toolCallId": call["id"], "toolName": "workflow_run",
              "content": result["content"], "details": result["details"], "isError": False}
        out({"type": "message_start", "message": tr})
        add(tr)
        out({"type": "message_end", "message": tr})
    if "slow" in prompt:
        for _ in range(200):
            if aborted.is_set():
                break
            time.sleep(0.05)
    if aborted.is_set():
        stream_assistant([{"type": "text", "text": "Stopped"}], "aborted")
    else:
        stream_assistant([{"type": "thinking", "thinking": "Thinking about it"}, {"type": "text", "text": reply}], "stop")
    streaming = False
    out({"type": "agent_end"})
    out({"type": "agent_settled"})


MODELS = [
    {"id": "echo-1", "name": "Echo", "provider": "fake", "reasoning": True, "contextWindow": 200000, "input": ["text", "image"]},
    {"id": "echo-mini", "name": "Echo Mini", "provider": "fake", "reasoning": False, "contextWindow": 128000, "input": ["text"]},
    {"id": "glm-5.2", "name": "GLM 5.2", "provider": "other", "reasoning": True, "contextWindow": 256000, "input": ["text"]},
]
model = MODELS[0]
thinking = "medium"


# Router models loaded when this pi started (ios/fake-llama.py), like pi's
# llama.cpp provider with --no-models-autoload.
LLAMA = []
if os.environ.get("FAKE_LLAMA_STATE") and os.path.exists(os.environ["FAKE_LLAMA_STATE"]):
    LLAMA = [{"id": m, "name": m, "provider": "llama.cpp", "reasoning": False, "contextWindow": 32768, "input": ["text"]}
             for m, s in json.load(open(os.environ["FAKE_LLAMA_STATE"])).items() if s == "loaded"]


def state():
    return {
        "sessionFile": session_file,
        "sessionName": name,
        "isStreaming": streaming,
        "thinkingLevel": thinking if model["reasoning"] else "off",
        "messageCount": len(messages),
        "model": model,
        "steeringMode": settings["steeringMode"],
        "followUpMode": settings["followUpMode"],
        "autoCompactionEnabled": settings["autoCompaction"],
    }


def respond(cmd, data=None, ok=True, error=None):
    r = {"type": "response", "id": cmd.get("id"), "command": cmd.get("type"), "success": ok}
    if data is not None:
        r["data"] = data
    if error:
        r["error"] = error
    out(r)


for line in sys.stdin:
    try:
        cmd = json.loads(line)
    except ValueError:
        continue
    t = cmd.get("type")
    if t == "prompt" and control and cmd.get("message", "").startswith("/pp-"):
        control_command(cmd["message"])
        respond(cmd, {"disposition": "handled"})
    elif t == "prompt":
        if streaming and cmd.get("streamingBehavior") != "steer":
            respond(cmd, ok=False, error="already streaming")
            continue
        respond(cmd, {})
        if not streaming:
            threading.Thread(target=run, args=(cmd.get("message", ""), cmd.get("id")), daemon=True).start()
    elif t == "get_state":
        respond(cmd, state())
    elif t == "get_messages":
        respond(cmd, {"messages": messages})
    elif t == "get_session_stats":
        respond(cmd, {"cost": 0.0012, "tokens": {"total": 1234}, "contextUsage": {"percent": 12.5, "contextWindow": 200000}})
    elif t == "get_available_thinking_levels":
        respond(cmd, {"levels": ["off", "low", "medium", "high"] if model["reasoning"] else ["off"]})
    elif t == "set_thinking_level":
        thinking = cmd.get("level", thinking)
        respond(cmd, {})
    elif t == "get_commands":
        commands = [
            {"name": "fix-tests", "description": "Fix failing tests", "source": "prompt"},
            {"name": "skill:review", "description": "Review the diff", "source": "skill"},
            {"name": "workflows", "source": "extension"},
        ]
        if control:
            commands.append({"name": "pp-tools", "description": "pocketpi: list this chat's tools", "source": "extension"})
        respond(cmd, {"commands": commands})
    elif t == "get_fork_messages":
        respond(cmd, {"messages": [{"entryId": eid, "text": text_of(m)} for eid, m in entries if m.get("role") == "user"]})
    elif t == "fork":
        idx = next((i for i, (eid, m) in enumerate(entries) if eid == cmd.get("entryId") and m.get("role") == "user"), None)
        if idx is None:
            respond(cmd, ok=False, error="entry not found")
        else:
            text = text_of(entries[idx][1])
            branch_to(entries[:idx], session_file)
            respond(cmd, {"text": text, "cancelled": False})
    elif t == "clone":
        branch_to(entries, session_file)
        respond(cmd, {"cancelled": False})
    elif t == "get_entries":
        recs = [{"type": "message", "id": eid, "parentId": entries[i - 1][0] if i else None, "message": m}
                for i, (eid, m) in enumerate(entries)]
        ids = [r["id"] for r in recs]
        if cmd.get("since") in ids:
            recs = recs[ids.index(cmd["since"]) + 1:]
        respond(cmd, {"entries": recs})
    elif t == "get_tree":
        tree = []
        for i in reversed(range(len(entries))):
            eid, m = entries[i]
            tree = [{"entry": {"type": "message", "id": eid, "parentId": entries[i - 1][0] if i else None, "message": m},
                     "children": tree}]
        respond(cmd, {"tree": tree})
    elif t == "get_last_assistant_text":
        last = next((m for m in reversed(messages) if m.get("role") == "assistant"), None)
        respond(cmd, {"text": text_of(last) if last else None})
    elif t == "export_html":
        path = cmd.get("outputPath") or os.path.join(os.getcwd(), "session.html")
        with open(path, "w") as f:
            f.write("<html><body>" + "".join(f"<p>{text_of(m)}</p>" for m in messages) + "</body></html>")
        respond(cmd, {"path": path})
    elif t == "bash":
        output = f"fake: {cmd.get('command', '')}\n"
        out({"type": "bash_execution_update", "id": cmd.get("id"), "output": output})
        respond(cmd, {"output": output, "exitCode": 0, "cancelled": False, "truncated": False})
    elif t in ("set_steering_mode", "set_follow_up_mode"):
        settings["steeringMode" if t == "set_steering_mode" else "followUpMode"] = cmd.get("mode")
        respond(cmd, {})
    elif t in ("set_auto_compaction", "set_auto_retry"):
        settings["autoCompaction" if t == "set_auto_compaction" else "autoRetry"] = bool(cmd.get("enabled"))
        respond(cmd, {})
    elif t == "get_available_models":
        respond(cmd, {"models": MODELS + LLAMA})
    elif t == "set_model":
        found = [m for m in MODELS + LLAMA if m["provider"] == cmd.get("provider") and m["id"] == cmd.get("modelId")]
        if found:
            model = found[0]
            respond(cmd, model)
        else:
            respond(cmd, ok=False, error="model not found")
    elif t == "set_session_name":
        name = cmd.get("name")
        save({"type": "session_info", "name": name})
        respond(cmd, {})
        out({"type": "session_info_changed", "name": name})
    elif t == "clear_queue":
        respond(cmd, {"steering": [], "followUp": []})
    elif t == "abort":
        aborted.set()
        respond(cmd, {})
    elif t == "extension_ui_response":
        with answered:
            answers[cmd.get("id")] = cmd
            answered.notify_all()
    else:
        respond(cmd, {})
