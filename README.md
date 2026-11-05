# pocketpi

A small, phone-first web UI for the [pi coding agent](https://github.com/earendil-works/pi).

- Rust (axum) server, one `pi --mode rpc` child process per open chat
- Streams pi's events to the browser over SSE; the page sends pi RPC commands back
- Chats are pi's own session files, so terminal and web chats are the same list
- **Spaces**: chats grouped by project folder (auto-discovered from session folders, pin/rename/hide in `~/.config/pocketpi/spaces.json`)
- Model + thinking switcher, context ring, cost, compaction, steering while pi works, stop, image attachments, slash commands, extension dialogs
- Vanilla JS/CSS embedded in the binary; Geist fonts (OFL, see `web/GEIST-OFL.txt`)

## Run

```sh
cargo build --release
POCKETPI_PORT=3457 ./target/release/pocketpi
```

| Env | Default | Meaning |
|---|---|---|
| `POCKETPI_PORT` | `3457` | Listens on 127.0.0.1 only |
| `POCKETPI_PI` | `pi` | pi binary |
| `POCKETPI_ALLOWED_USERS` | unset | Comma-separated Tailscale logins allowed through Tailscale Serve |
| `PI_CODING_AGENT_DIR`, `PI_CODING_AGENT_SESSION_DIR` | pi defaults | Passed through to pi; also where sessions are listed from |

## Access model

Loopback only. Remote access is meant to go through `tailscale serve` (tailnet only, never Funnel):
requests must come from loopback and carry `Tailscale-User-Login` (or a localhost Host header),
Funnel requests are refused, and every POST needs `X-Pocketpi: 1` so other sites can't drive it.
Anyone allowed in can run pi, which has shell access as your user. Treat it like SSH.

## Icons

`scripts/icons.sh` renders `web/icon.svg` to the PNG icons (needs `rsvg-convert`).
