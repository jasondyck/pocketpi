#!/usr/bin/env bash
# Performance and resource benchmark: run once per wave to catch pocketpi
# getting slower or fatter. Builds release, starts a throwaway pocketpi on a
# free port (scratch HOME/XDG dirs, ios/fake-pi.py as pi, no model keys),
# generates synthetic history (pi session files and a ~20k-file git repo),
# load-tests the main endpoints, the SSE fan-out, a per-turn git snapshot and
# terminals, soaks, and writes bench-results/<date>-<sha>.json with a delta
# against the previous comparable run.
#
#   scripts/bench.sh                 # defaults: 2000 sessions, 8 s/endpoint, 60 s soak
#   scripts/bench.sh --quick         # under a minute: smaller data, short runs
#   scripts/bench.sh --sessions N --soak SECS --duration SECS --concurrency C
#   scripts/bench.sh --tool python|oha|hey   # load generator (default: oha, hey, else python)
#   scripts/bench.sh --no-build --keep       # reuse target/release; keep the scratch dir
#   scripts/bench.sh --bin PATH --out DIR    # bench another binary (implies --no-build); results elsewhere
#
# Never touches the real pocketpi (its port, home or sessions).
set -euo pipefail
cd "$(dirname "$0")/.."
REPO=$PWD

SESSIONS=2000 REPO_FILES=20000 DURATION=8 CONC=16 SOAK=60 SSE_CLIENTS=50 TURNS=5 TERMS=8
QUICK=0 BUILD=1 KEEP=0 TOOL=auto BIN="$REPO/target/release/pocketpi" OUT="$REPO/bench-results"
while [ $# -gt 0 ]; do
  case "$1" in
    --quick) QUICK=1 SESSIONS=500 REPO_FILES=5000 DURATION=2 CONC=8 SOAK=10 SSE_CLIENTS=20 TURNS=1 TERMS=2 ;;
    --sessions) SESSIONS=$2; shift ;;
    --repo-files) REPO_FILES=$2; shift ;;
    --soak) SOAK=$2; shift ;;
    --duration) DURATION=$2; shift ;;
    --concurrency) CONC=$2; shift ;;
    --tool) TOOL=$2; shift ;;
    --no-build) BUILD=0 ;;
    --keep) KEEP=1 ;;
    --bin) BIN=$(realpath "$2") BUILD=0; shift ;;
    --out) OUT=$(realpath -m "$2"); shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

# No real model is ever called: fake-pi needs no key, and none leaks to it.
for v in $(compgen -e); do
  case "$v" in *_API_KEY|*_AUTH_TOKEN|ANTHROPIC_*|OPENAI_*|OPENROUTER_*|DEEPSEEK_*|GEMINI_*|GOOGLE_API_*|POCKETPI_*|PI_*) unset "$v" ;; esac
done

if [ "$BUILD" = 1 ]; then
  echo "== cargo build --release"
  cargo build --release --quiet
fi
[ -x "$BIN" ] || { echo "no $BIN (drop --no-build)" >&2; exit 1; }

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/pocketpi-bench.XXXXXX")
SERVER=""
cleanup() {
  if [ -n "$SERVER" ]; then
    kill "$SERVER" 2>/dev/null || true
    # Give it a moment, then make sure (by PID only, never by pattern).
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$SERVER" 2>/dev/null || break; sleep 0.2; done
    kill -9 "$SERVER" 2>/dev/null || true
  fi
  if [ "$KEEP" = 1 ]; then echo "scratch kept: $SCRATCH"; else rm -rf "$SCRATCH"; fi
}
trap cleanup EXIT INT TERM

H="$SCRATCH/home"
mkdir -p "$H/.pi/agent" "$H/.config" "$H/.local/share" "$H/projects" "$SCRATCH/sessions" "$SCRATCH/subagents"
echo '{"enabledModels":["fake/echo-*"]}' > "$H/.pi/agent/settings.json"

echo "== synthetic data ($SESSIONS sessions, $REPO_FILES-file repo) in $SCRATCH"
t0=$(date +%s.%N)
python3 scripts/bench/gen.py repo "$H/projects/bigrepo" "$REPO_FILES" > "$SCRATCH/repo.json"
python3 scripts/bench/gen.py sessions "$SCRATCH/sessions" "$H/projects" "$SESSIONS" "$H/projects/bigrepo" > "$SCRATCH/sessions.json"
GEN_SECS=$(python3 -c "print(round($(date +%s.%N) - $t0, 1))")

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
echo "== starting scratch pocketpi on 127.0.0.1:$PORT"
t0=$(date +%s.%N)
HOME="$H" XDG_CONFIG_HOME="$H/.config" XDG_DATA_HOME="$H/.local/share" SHELL=/bin/sh \
  PI_CODING_AGENT_SESSION_DIR="$SCRATCH/sessions" POCKETPI_PI="$REPO/ios/fake-pi.py" \
  POCKETPI_SUBAGENTS_DIR="$SCRATCH/subagents" POCKETPI_PORT="$PORT" \
  "$BIN" >"$SCRATCH/server.log" 2>&1 &
SERVER=$!
for _ in $(seq 1 80); do
  curl -fs "http://127.0.0.1:$PORT/api/version" >/dev/null 2>&1 && break
  kill -0 "$SERVER" 2>/dev/null || break
  sleep 0.1
done
curl -fs "http://127.0.0.1:$PORT/api/version" >/dev/null || { echo "server did not start:"; cat "$SCRATCH/server.log"; exit 1; }
READY_MS=$(python3 -c "print(int(($(date +%s.%N) - $t0) * 1000))")

python3 scripts/bench/run.py \
  --port "$PORT" --pid "$SERVER" --scratch "$SCRATCH" --bin "$BIN" \
  --sessions-json "$SCRATCH/sessions.json" --repo "$H/projects/bigrepo" \
  --duration "$DURATION" --concurrency "$CONC" --soak "$SOAK" --sse-clients "$SSE_CLIENTS" \
  --turns "$TURNS" --terms "$TERMS" --tool "$TOOL" --quick "$QUICK" \
  --gen-secs "$GEN_SECS" --ready-ms "$READY_MS" --out-dir "$OUT"
