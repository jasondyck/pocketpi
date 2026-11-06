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
for p in clipt natter canopy lantern-keep; do mkdir -p "$SCRATCH/home/projects/$p"; done
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
chat "$P/clipt" "Why does the region picker flicker on the second monitor?"
chat "$P/clipt" "Add a tool call to check the changelog"
chat "$P/natter" "Summarize what changed in the SFU since Monday"
chat "$P/canopy" "What does the Modbus poller do when a sensor times out?"
chat "$P/lantern-keep" "Plan the next puzzle room"
echo "$URL"
