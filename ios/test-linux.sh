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
  echo '{"enabledModels":["other/glm-5.2","fake/echo-*"]}' > "$SCRATCH/home/.pi/agent/settings.json"
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
    POCKETPI_PORT="$PORT" "$REPO/target/release/pocketpi" >"$SCRATCH/server.log" 2>&1 &
  SERVER=$!
  for _ in $(seq 1 40); do
    curl -fs "http://127.0.0.1:$PORT/api/version" >/dev/null 2>&1 && break
    sleep 0.25
  done
  curl -fs "http://127.0.0.1:$PORT/api/version" >/dev/null || { cat "$SCRATCH/server.log"; exit 1; }
  ENVS=(-e "POCKETPI_TEST_URL=http://127.0.0.1:$PORT" -e "POCKETPI_TEST_CWD=$SCRATCH/home/project")
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
