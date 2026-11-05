#!/bin/sh
# Install the release build and restart pocketpi once no chat is streaming
# or workflow run is active (a restart kills running pi processes). Checks every 15s.
set -e
cd "$(dirname "$0")/.."
calm=0
while [ $calm -lt 2 ]; do
  # /api/busy covers streaming chats and active workflow runs; older builds
  # without it fall back to the session list.
  b=$(curl -sf http://127.0.0.1:3457/api/busy || echo none)
  case "$b" in
    *'"busy":false'*) idle=1 ;;
    none) n=$(curl -s http://127.0.0.1:3457/api/sessions | grep -o '"streaming":true' | wc -l); [ "$n" = 0 ] && idle=1 || idle=0 ;;
    *) idle=0 ;;
  esac
  if [ "$idle" = 1 ]; then calm=$((calm + 1)); else calm=0; fi
  [ $calm -lt 2 ] && sleep 15
done
install -m755 target/release/pocketpi ~/.local/bin/pocketpi
systemctl --user restart pocketpi
echo "deployed $(git log --oneline -1) at $(date +%H:%M:%S)"
