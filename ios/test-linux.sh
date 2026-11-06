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
cleanup() {
  [ -n "$SERVER" ] && kill "$SERVER" 2>/dev/null || true
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

ENVS=()
if [ "${1:-}" != "--unit" ]; then
  cargo build --release --quiet
  mkdir -p "$SCRATCH/home/project" "$SCRATCH/sessions" "$SCRATCH/home/.config/pocketpi/apns"
  mkdir -p "$SCRATCH/home/.pi/agent"
  echo '{"enabledModels":["other/glm-5.2","fake/echo-*"]}' > "$SCRATCH/home/.pi/agent/settings.json"
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
