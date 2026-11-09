#!/usr/bin/env bash
# Build and test PocketPiKit on Linux, in the official Swift container, and
# run its integration tests against a scratch pocketpi built from this
# checkout, with ios/fake-pi.py standing in for pi (no model, no cost).
#
#   ios/test-linux.sh            # unit and integration tests
#   ios/test-linux.sh --unit     # unit tests only, no server
#
# Needs docker, cargo and python3. The scratch server's home, config, data and
# sessions live in a temporary directory removed on the way out; nothing here
# touches the real pocketpi or its chats.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO=$PWD
SWIFT_IMAGE=${SWIFT_IMAGE:-swift:6.4}
PORT=${PORT:-3471}
SCRATCH=$(mktemp -d)
SERVER=""
LLAMA=""
cleanup() {
  [ -n "$SERVER" ] && kill "$SERVER" 2>/dev/null || true
  [ -n "$LLAMA" ] && kill "$LLAMA" 2>/dev/null || true
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

ENVS=()
if [ "${1:-}" != "--unit" ]; then
  cargo build --release --quiet
  mkdir -p "$SCRATCH/home/project" "$SCRATCH/sessions" "$SCRATCH/home/.config/pocketpi/apns"
  mkdir -p "$SCRATCH/home/.pi/agent"
  # Resources for Settings › Resources and project trust: one global
  # extension, skill and prompt (the ones fake-pi's get_commands names), and a
  # project prompt that only loads once the project is trusted.
  A="$SCRATCH/home/.pi/agent"
  mkdir -p "$A/extensions" "$A/skills/review" "$A/prompts" "$SCRATCH/home/project/.pi/prompts"
  echo 'export default function () {}' > "$A/extensions/hello.ts"
  printf -- '---\nname: review\ndescription: Review the staged diff\n---\nReview it.\n' > "$A/skills/review/SKILL.md"
  printf -- '---\ndescription: Fix failing tests\nargument-hint: "<file>"\n---\nFix $1\n' > "$A/prompts/fix-tests.md"
  printf -- '---\ndescription: Deploy this project\n---\nDeploy.\n' > "$SCRATCH/home/project/.pi/prompts/deploy.md"
  # Settings › Context and project settings: a project of their own with a CLAUDE.md.
  mkdir -p "$SCRATCH/home/ctx-project" && echo 'Claude notes' > "$SCRATCH/home/ctx-project/CLAUDE.md"
  # Settings › Resources switches turn this one off and on; Packages
  # installs, filters and removes the local package.
  printf -- '---\ndescription: For the switch test\n---\nToggle.\n' > "$A/prompts/toggle-me.md"
  PKG="$SCRATCH/home/pkg-demo"
  mkdir -p "$PKG/skills/demo-skill" "$PKG/prompts" "$PKG/extensions"
  echo '{"name":"pkg-demo","version":"1.0.0","keywords":["pi-package"]}' > "$PKG/package.json"
  printf -- '---\nname: demo-skill\ndescription: From the demo package\n---\nDo it.\n' > "$PKG/skills/demo-skill/SKILL.md"
  printf -- '---\ndescription: Hello from the package\n---\nHello\n' > "$PKG/prompts/hello-pkg.md"
  echo 'export default function () {}' > "$PKG/extensions/demo.ts"
  mkdir -p "$SCRATCH/home/.config/pocketpi/workflows"
  cat > "$SCRATCH/home/.config/pocketpi/workflows/approve-test.json" <<JSON
{"id":"approve-test","name":"Approve test","project":"$SCRATCH/home/project","worktree":false,"enabled":true,
 "triggers":[{"type":"manual"}],"inputs":[],"improve":"off",
 "stages":[{"id":"prep","type":"shell","name":"Prep","needs":[],"run":"echo ready"},
           {"id":"ask","type":"approval","name":"Ship?","needs":["prep"],"prompt":"Ship it?"},
           {"id":"ship","type":"shell","name":"Ship","needs":["ask"],"run":"echo shipped"}]}
JSON
  # Inputs, duplicates (same issue), force and cancel (the sleep).
  cat > "$SCRATCH/home/.config/pocketpi/workflows/slow-test.json" <<JSON
{"id":"slow-test","name":"Slow test","description":"Waits, for cancelling.","project":"$SCRATCH/home/project","worktree":false,"enabled":false,
 "triggers":[{"type":"manual"},{"type":"schedule","cron":"*/30 * * * *"}],
 "inputs":[{"name":"issue","description":"Issue number","required":true},{"name":"wait","description":"Seconds","required":false,"default":"0"}],
 "improve":"off",
 "stages":[{"id":"nap","type":"shell","name":"Nap","needs":[],"run":"sleep {{input.wait}}; echo rested for issue {{input.issue}}"}]}
JSON
  # A suggested improvement for slow-test (apply, history, revert) and a
  # workflow to delete.
  mkdir -p "$SCRATCH/home/.config/pocketpi/workflows/.proposals"
  python3 - "$SCRATCH/home/.config/pocketpi/workflows" <<'PY'
import json, sys
d = sys.argv[1]
w = json.load(open(f"{d}/slow-test.json"))
w["description"] = "Waits, so a run can be cancelled."
json.dump({"created": 1794000000000, "run_id": "x", "model": "fake/echo-1",
           "changes": [{"summary": "Clearer description", "why": "Says what it's for."}],
           "violations": [], "workflow": w}, open(f"{d}/.proposals/slow-test.json", "w"))
w2 = dict(w, id="delete-me", name="Delete me")
json.dump(w2, open(f"{d}/delete-me.json", "w"))
PY
  # A session with known usage for /api/usage (project "/usage-seed"):
  # billed, pool, subscription and a usage entry this week; one reply 40 days ago.
  mkdir -p "$SCRATCH/sessions/--usage-seed--"
  python3 - "$SCRATCH/sessions/--usage-seed--/seed.jsonl" <<'PY'
import json, sys, time
now = int(time.time() * 1000)
def iso(ms): return time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(ms / 1000))
def reply(i, ms, provider, model, inp, out, cost):
    return {"type": "message", "id": f"seed{i}", "parentId": None, "timestamp": iso(ms), "message": {
        "role": "assistant", "content": [{"type": "text", "text": "ok"}], "provider": provider, "model": model,
        "usage": {"input": inp, "output": out, "cacheRead": 0, "cacheWrite": 0, "totalTokens": inp + out,
                  "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "total": cost}},
        "stopReason": "stop", "timestamp": ms}}
h = 3_600_000
recs = [{"type": "session", "version": 3, "id": "usage-seed", "timestamp": iso(now), "cwd": "/usage-seed"},
        reply(1, now - 40 * 24 * h, "anthropic", "claude-x", 5, 5, 9.0),
        reply(2, now - h, "anthropic", "claude-x", 1000, 100, 1.0),
        reply(3, now - 2 * h, "opencode-go", "glm-5.2", 2000, 10, 0.25),
        reply(4, now - 3 * h, "openai-codex", "gpt-5.5", 300, 30, 0.0),
        {"type": "usage", "id": "seed5", "parentId": "seed4", "timestamp": iso(now - h), "kind": "cache_warm",
         "provider": "anthropic", "model": "claude-x",
         "usage": {"input": 0, "output": 0, "cacheRead": 50000, "cacheWrite": 0, "totalTokens": 50000, "cost": {"total": 0.5}}}]
open(sys.argv[1], "w").write("".join(json.dumps(r, separators=(",", ":")) + "\n" for r in recs))
PY
  # pi-permission-system's review log with two auto-review decisions, for
  # Settings › Safety's Recent reviews: an allow, and a defer the person denied.
  mkdir -p "$A/extensions/pi-permission-system/logs"
  python3 - "$A/extensions/pi-permission-system/logs/pi-permission-system-permission-review.jsonl" <<'PY'
import json, sys, time
def iso(s): return time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(s))
t = time.time() - 300
recs = [
    {"timestamp": iso(t), "event": "permission_request.waiting", "requestId": "r1", "surface": "bash", "command": "rm -rf build"},
    {"timestamp": iso(t + 4), "event": "auto_review.decision", "requestId": "r1", "outcome": "allow", "durationMs": 4000,
     "model": "claude-haiku-5-5", "provider": "opencode-go", "stage": "fast"},
    {"timestamp": iso(t + 4), "event": "permission_request.approved", "requestId": "r1",
     "decidedBy": {"kind": "authorizer", "name": "auto-review", "verdict": "allow", "reason": None}},
    {"timestamp": iso(t + 60), "event": "permission_request.waiting", "requestId": "r2", "surface": "bash", "command": "git push --force"},
    {"timestamp": iso(t + 61), "event": "auto_review.decision", "requestId": "r2", "outcome": "defer", "errorCategory": "provider-error"},
    {"timestamp": iso(t + 70), "event": "permission_request.denied", "requestId": "r2", "decidedBy": {"kind": "user", "via": "select"}},
]
open(sys.argv[1], "w").write("".join(json.dumps(r) + "\n" for r in recs))
PY
  echo '{"enabledModels":["other/glm-5.2","fake/echo-*"]}' > "$SCRATCH/home/.pi/agent/settings.json"
  # Subagent runs for GET /api/subagents: one live workflow with two steps and
  # an output log. POCKETPI_SUBAGENTS_DIR points the server at this root (the
  # real one is <tmpdir>/pi-subagents-*).
  SUB="$SCRATCH/subagents"
  mkdir -p "$SUB/async-subagent-runs/pp-test-live"
  python3 - "$SUB/async-subagent-runs/pp-test-live" <<'PY'
import json, sys, time
d = sys.argv[1]
now = int(time.time() * 1000)
status = {
    "runId": "pp-test-live", "toolCallId": "call_pp_test", "mode": "workflow",
    "state": "running", "active": True,
    "sessionId": "/pp-test-session.jsonl", "cwd": "/pp-test-project",
    "startedAt": now - 5000, "lastUpdate": now, "tokens": 1500, "cost": 0.02,
    "steps": [
        {"index": 0, "agent": "reviewer", "label": "task-1", "status": "completed",
         "active": False, "startedAt": now - 5000, "durationMs": 2000,
         "tokens": {"input": 900, "output": 300, "total": 1200}},
        {"index": 1, "agent": "worker", "label": "task-2", "status": "running",
         "active": True, "startedAt": now - 3000,
         "sessionFile": "/pp-test-child.jsonl",
         "recentTools": [{"tool": "read", "args": "src/main.rs"}],
         "recentOutput": ["working on it"],
         "tokens": {"input": 200, "output": 100, "total": 300}},
    ],
}
json.dump(status, open(f"{d}/status.json", "w"))
open(f"{d}/output-0.log", "w").write("hello from the child\n")
PY
  # A stand-in llama.cpp router, logged in the way pi's /login llama.cpp stores it.
  LLAMA_PORT=$((PORT + 2))
  export FAKE_LLAMA_STATE="$SCRATCH/llama.json"
  "$REPO/ios/fake-llama.py" "$LLAMA_PORT" & LLAMA=$!
  echo "{\"llama.cpp\":{\"type\":\"api_key\",\"env\":{\"LLAMA_BASE_URL\":\"http://127.0.0.1:$LLAMA_PORT\"}}}" > "$SCRATCH/home/.pi/agent/auth.json"
  # A throwaway APNs key, so device registration can be tested. Nothing in the
  # tests makes the server send a notification to Apple.
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 \
    -out "$SCRATCH/home/.config/pocketpi/apns/AuthKey_TEST000000.p8" 2>/dev/null
  HOME="$SCRATCH/home" XDG_CONFIG_HOME="$SCRATCH/home/.config" XDG_DATA_HOME="$SCRATCH/home/.local/share" \
    PI_CODING_AGENT_SESSION_DIR="$SCRATCH/sessions" POCKETPI_PI="$REPO/ios/fake-pi.py" \
    POCKETPI_SUBAGENTS_DIR="$SCRATCH/subagents" \
    POCKETPI_PORT="$PORT" "$REPO/target/release/pocketpi" >"$SCRATCH/server.log" 2>&1 &
  SERVER=$!
  for _ in $(seq 1 40); do
    curl -fs "http://127.0.0.1:$PORT/api/version" >/dev/null 2>&1 && break
    sleep 0.25
  done
  curl -fs "http://127.0.0.1:$PORT/api/version" >/dev/null || { cat "$SCRATCH/server.log"; exit 1; }
  ENVS=(-e "POCKETPI_TEST_URL=http://127.0.0.1:$PORT" -e "POCKETPI_TEST_CWD=$SCRATCH/home/project" -e "POCKETPI_TEST_PKG=$PKG")
fi

# As you rather than root, so nothing it writes into the checkout (.build)
# ends up owned by root. .build is kept between runs.
set +e
docker run --rm --network host "${ENVS[@]}" --user "$(id -u):$(id -g)" -e HOME=/tmp \
  -v "$REPO/ios/PocketPiKit:/src" -w /src "$SWIFT_IMAGE" swift test
status=$?
set -e
if [ $status -ne 0 ] && [ -n "$SERVER" ]; then
  echo "--- server log"; tail -50 "$SCRATCH/server.log"
fi
exit $status
