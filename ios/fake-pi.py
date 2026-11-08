#!/usr/bin/env python3
"""A stand-in for `pi --mode rpc`, for testing the iOS client against a real
pocketpi without a model, a key or any cost.

It speaks enough of pi's RPC protocol for pocketpi and PocketPiKit: the state
and message commands, prompts that stream back an echo (thinking, text, and a
tool call when the prompt says "tool", a workflow_run call for the run id in
~/.fake-pi-run when it says "deploy"), an extension confirm dialog when the
prompt says "ask", session names, abort. Sessions are written in pi's format
to $PI_CODING_AGENT_SESSION_DIR so pocketpi lists and reopens them.

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
messages = []
name = None
streaming = False

if session_file:
    with open(session_file) as f:
        for line in f:
            rec = json.loads(line)
            if rec.get("type") == "message":
                messages.append(rec["message"])
            elif rec.get("type") == "session_info":
                name = rec.get("name")


def save(rec):
    global session_file
    if not session_file:
        os.makedirs(session_dir, exist_ok=True)
        sid = str(uuid.uuid4())
        session_file = os.path.join(session_dir, f"{int(time.time() * 1000)}_{sid}.jsonl")
        with open(session_file, "w") as f:
            f.write(json.dumps({"type": "session", "id": sid, "cwd": os.getcwd(), "version": 3}, separators=(",", ":")) + "\n")
    with open(session_file, "a") as f:
        f.write(json.dumps(rec, separators=(",", ":")) + "\n")


def add(msg):
    messages.append(msg)
    save({"type": "message", "message": msg})


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
    if t == "prompt":
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
        respond(cmd, {"commands": [
            {"name": "fix-tests", "description": "Fix failing tests", "source": "prompt"},
            {"name": "skill:review", "description": "Review the diff", "source": "skill"},
            {"name": "workflows", "source": "extension"},
        ]})
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
