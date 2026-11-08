#!/usr/bin/env python3
"""A stand-in for a llama.cpp router (`llama-server --models-dir ...`), for
testing pocketpi's /api/llama without a GPU: GET /models, POST /models/load
and /models/unload. Loading takes half a second; "broken" fails to load.
State is kept in $FAKE_LLAMA_STATE so ios/fake-pi.py can list what's loaded
when it starts, as pi does.

    FAKE_LLAMA_STATE=/tmp/s.json ios/fake-llama.py 3473
"""
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = os.environ["FAKE_LLAMA_STATE"]
lock = threading.Lock()
models = {"tiny-chat": "loaded", "other-chat": "unloaded", "broken": "unloaded"}
failed = set()


def save():
    with open(STATE + ".tmp", "w") as f:
        json.dump(models, f)
    os.replace(STATE + ".tmp", STATE)


def finish_load(mid):
    time.sleep(0.5)
    with lock:
        if mid == "broken":
            models[mid] = "unloaded"
            failed.add(mid)
        else:
            models[mid] = "loaded"
        save()


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path != "/models":
            return self.reply(404, {"error": "not found"})
        with lock:
            data = [{"id": m, "object": "model", "status": {"value": s, **({"failed": True} if m in failed else {})}}
                    for m, s in models.items()]
        self.reply(200, {"data": data})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        mid = body.get("model")
        with lock:
            if mid not in models:
                return self.reply(404, {"error": "unknown model"})
            if self.path == "/models/load":
                failed.discard(mid)
                models[mid] = "loading"
                threading.Thread(target=finish_load, args=(mid,), daemon=True).start()
            elif self.path == "/models/unload":
                models[mid] = "unloaded"
            else:
                return self.reply(404, {"error": "not found"})
            save()
        self.reply(200, {"success": True})


save()
ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
