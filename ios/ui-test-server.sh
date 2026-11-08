#!/usr/bin/env bash
# A scratch pocketpi for the app's UI tests (the iOS workflow's app job, or a
# Mac): built from this checkout, ios/fake-pi.py as pi, a throwaway home with
# a few projects and chats so the screenshots show something real. Prints the
# address; the server keeps running in the background.
#
#   ios/ui-test-server.sh [port]      # default 3472
set -euo pipefail
cd "$(dirname "$0")/.."
REPO=$PWD
PORT=${1:-3472}
SCRATCH=${SCRATCH:-$(mktemp -d)}
URL="http://127.0.0.1:$PORT"

cargo build --release --quiet
mkdir -p "$SCRATCH/sessions"
mkdir -p "$SCRATCH/home/.pi/agent"
echo '{"enabledModels":["other/glm-5.2","fake/echo-*"]}' > "$SCRATCH/home/.pi/agent/settings.json"
for p in clipt natter canopy lantern-keep; do mkdir -p "$SCRATCH/home/projects/$p"; done
# A workflow that stops at an approval, for the Approvals screen.
mkdir -p "$SCRATCH/home/.config/pocketpi/workflows"
cat > "$SCRATCH/home/.config/pocketpi/workflows/clipt-review.json" <<JSON
{"id":"clipt-review","name":"clipt: PR check-in","project":"$SCRATCH/home/projects/clipt","worktree":false,"enabled":true,
 "triggers":[{"type":"manual"}],"inputs":[],"improve":"off",
 "stages":[{"id":"review","type":"shell","name":"Review","needs":[],"run":"echo reviewed"},
           {"id":"approve","type":"approval","name":"Post review on #92?","needs":["review"],
            "prompt":"Post this review on PR #92?\\n\\n**Verdict: changes requested**\\n\\n1. \`src/record.rs:88\` drops the last audio frame.\\n2. CHANGELOG has no line for the new flag."},
           {"id":"comment","type":"shell","name":"Comment","needs":["approve"],"run":"echo posted"}]}
JSON
# A PR workflow with an input and a finished run, for the Workflows screens.
cat > "$SCRATCH/home/.config/pocketpi/workflows/clipt-pr.json" <<JSON
{"id":"clipt-pr","name":"clipt: PR review + fix","description":"Review a PR's head; fix what the review asks for and push.",
 "project":"$SCRATCH/home/projects/clipt","worktree":false,"enabled":true,
 "triggers":[{"type":"manual"},{"type":"git","on":"pr"},{"type":"agent","when":"asked to review a PR"}],
 "inputs":[{"name":"pr","description":"PR number","required":true},{"name":"commit","required":false,"default":""}],
 "improve":"off",
 "stages":[{"id":"diff","type":"shell","name":"Fetch PR","needs":[],"run":"echo 'PR #{{input.pr}}: Sway tests'; echo 'Files changed: tests/sway.rs'"},
           {"id":"review","type":"shell","name":"Review PR","needs":["diff"],"run":"echo '**Verdict: pass**'; echo; echo 'No blocking issues.'"},
           {"id":"decide","type":"shell","name":"Fix needed?","needs":["review"],"run":"echo 'Review passed: nothing to fix.'; exit 79"},
           {"id":"fix","type":"shell","name":"Fix findings","needs":["decide"],"run":"true"}]}
JSON
# A run that keeps going, started from a natter chat (fake-pi's "deploy"),
# for the run line above the chat's composer.
cat > "$SCRATCH/home/.config/pocketpi/workflows/natter-deploy.json" <<JSON
{"id":"natter-deploy","name":"natter: deploy check","project":"$SCRATCH/home/projects/natter","worktree":false,"enabled":true,
 "triggers":[{"type":"manual"}],"inputs":[],"improve":"off",
 "stages":[{"id":"build","type":"shell","name":"Build","needs":[],"run":"echo built"},
           {"id":"smoke","type":"shell","name":"Smoke test","needs":["build"],"run":"sleep 1800"},
           {"id":"report","type":"shell","name":"Report","needs":["smoke"],"run":"echo ok"}]}
JSON
# A suggested improvement for it, for the Improvements screens.
mkdir -p "$SCRATCH/home/.config/pocketpi/workflows/.proposals"
python3 - "$SCRATCH/home/.config/pocketpi/workflows" <<'PY'
import json, sys
d = sys.argv[1]
w = json.load(open(f"{d}/clipt-pr.json"))
w["stages"][1]["run"] = "echo '**Verdict: pass**'; echo; echo 'No blocking issues. CHANGELOG checked.'"
json.dump({"created": 1794000000000, "run_id": "x", "model": "openai-codex/gpt-6.1-sol",
           "changes": [{"summary": "Check the CHANGELOG in every review",
                        "why": "Two of the last five PRs were missing a CHANGELOG line."}],
           "violations": ["changes a shell command"], "workflow": w},
          open(f"{d}/.proposals/clipt-pr.json", "w"))
PY
# A stand-in llama.cpp router (two models, one loaded), logged in the way
# pi's /login llama.cpp stores it, for the model sheet's Local section.
LLAMA_PORT=$((PORT + 2))
export FAKE_LLAMA_STATE="$SCRATCH/llama.json"
nohup "$REPO/ios/fake-llama.py" "$LLAMA_PORT" >/dev/null 2>&1 &
echo "{\"llama.cpp\":{\"type\":\"api_key\",\"env\":{\"LLAMA_BASE_URL\":\"http://127.0.0.1:$LLAMA_PORT\"}}}" > "$SCRATCH/home/.pi/agent/auth.json"
HOME="$SCRATCH/home" XDG_CONFIG_HOME="$SCRATCH/home/.config" XDG_DATA_HOME="$SCRATCH/home/.local/share" \
  PI_CODING_AGENT_SESSION_DIR="$SCRATCH/sessions" POCKETPI_PI="$REPO/ios/fake-pi.py" \
  POCKETPI_PORT="$PORT" nohup "$REPO/target/release/pocketpi" >"$SCRATCH/server.log" 2>&1 &
for _ in $(seq 1 40); do
  curl -fs "$URL/api/version" >/dev/null 2>&1 && break
  sleep 0.25
done
curl -fs "$URL/api/version" >/dev/null || { cat "$SCRATCH/server.log"; exit 1; }

post() { curl -fs -X POST -H 'X-Pocketpi: 1' -H 'Content-Type: application/json' "$URL$1" -d "$2"; }
P="$SCRATCH/home/projects"
post /api/projects/save "{\"path\":\"$P/clipt\"}" >/dev/null
post /api/projects/save "{\"path\":\"$P/natter\"}" >/dev/null
chat() {
  key=$(post /api/new "{\"cwd\":\"$1\"}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["key"])')
  post "/api/s/$key/cmd" "{\"type\":\"prompt\",\"message\":\"$2\"}" >/dev/null
  sleep 1
}
post /api/workflows/clipt-review/run '{}' >/dev/null
post /api/workflows/clipt-pr/run '{"inputs":{"pr":"96","commit":"75348bc"}}' >/dev/null
chat "$P/clipt" "Why does the region picker flicker on the second monitor?"
chat "$P/clipt" "Add a tool call to check the changelog"
post /api/workflows/natter-deploy/run '{}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["run_id"])' > "$SCRATCH/home/.fake-pi-run"
chat "$P/natter" "Check the SFU log with a tool, deploy, and summarize what changed since Monday"
chat "$P/canopy" "What does the Modbus poller do when a sensor times out?"
chat "$P/lantern-keep" "Plan the next puzzle room"
# A Chat-tab chat (plain conversation, in the server's chat folder).
CHAT_DIR=$(curl -fs "$URL/api/sessions?chat=1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["chat_dir"])')
chat "$CHAT_DIR" "What's a good way to keep sourdough starter over a long trip?"
# Archived chats to delete (two each: the light and dark passes delete one).
chat "$P/canopy" "Old note one"
chat "$P/canopy" "Old note two"
chat "$CHAT_DIR" "Old chat one"
chat "$CHAT_DIR" "Old chat two"
# The session files appear a moment after the prompt (slower on CI): keep
# looking until two are archived in each list.
old_paths() { curl -fs "$URL/api/sessions$1" | python3 -c 'import json,sys
for s in json.load(sys.stdin)["sessions"]:
    if s["title"].startswith("Old "): print(s["path"])'; }
for q in "" "chat=1&"; do
  for _ in $(seq 1 40); do
    old_paths "?$q" | while read -r f; do post /api/sessions/archive "{\"path\":\"$f\"}" >/dev/null; done
    [ "$(old_paths "?${q}archived=1" | wc -l)" -ge 2 ] && break
    sleep 0.5
  done
done
echo "$URL"
