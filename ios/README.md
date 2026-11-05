# pocketpi for iOS

A native SwiftUI client for the same pocketpi server the web UI uses. It talks
to the existing HTTP API and event stream with no server changes: Tailscale
Serve supplies the caller's login, and the app sends `X-Pocketpi: 1` on POSTs
like the web page does.

Why native: things a Home Screen web app can't do. The keyboard follows the
finger when you swipe down (`.scrollDismissesKeyboard(.interactively)`), and
notifications come through APNs.

## Notifications

The server sends every notification it already sends by web push (approvals,
finished/failed runs, long replies nobody watched) to registered iOS devices
too (`src/apns.rs`). It needs the APNs key from developer.apple.com in
`~/.config/pocketpi/apns/AuthKey_<KEYID>.p8` (0600); without it APNs is off and
`/api/apns/register` answers 503. The app asks for permission when it first
reaches the chat list and registers its token on every launch (sandbox for
debug builds, production for TestFlight; the server retries the other service
on BadDeviceToken). Tapping a chat notification opens that chat.

Check the key against Apple without a phone:
`cargo test apns_credentials -- --ignored --nocapture` (expects BadDeviceToken).

## Layout

| Path | What |
|---|---|
| `PocketPiKit/` | SwiftPM package with everything except views: `JSONValue`, models, `PocketPiClient` (HTTP + SSE), `Transcript` (pi events → chat, a port of `web/app.js`'s `onEvent`), `ChatSession` (connect, reconnect, snapshot, send, steer, stop, dialogs), `MarkdownBlock`. Builds and tests on Linux. |
| `PocketPi/` | The SwiftUI app. `project.yml` is the XcodeGen spec; the `.xcodeproj` is generated, never committed. |
| `fake-pi.py` | Stands in for `pi --mode rpc` (echo replies, a tool call, an extension dialog, abort) so the client is tested against a real pocketpi with no model. |
| `test-linux.sh` | Builds pocketpi, starts a scratch instance with fake-pi, runs the Kit's tests in the `swift:6.4` container. |

## Test on Linux

```sh
ios/test-linux.sh          # unit + integration (needs docker, cargo, python3)
ios/test-linux.sh --unit   # unit only
```

The SwiftUI views can't be compiled on Linux; they need Xcode on macOS (a Mac,
the manual `iOS` GitHub workflow, or Xcode Cloud via `PocketPi/ci_scripts`).

## Build on a Mac

```sh
brew install xcodegen
cd ios/PocketPi && xcodegen generate && open PocketPi.xcodeproj
```

Team `57YB5MQBTL`, bundle id `ca.caldron.pocketpi`, iOS 18+. For the
simulator, run a local pocketpi and connect to `http://127.0.0.1:3457`
(loopback with a localhost Host passes pocketpi's guard).

## Not done yet

- Workflows and runs (list, DAG, approve, cancel)
- Tapping a run notification opens the app but not the run (no runs screen yet)
- Model picker, slash-command completion, suggested replies
- Folding finished tool steps into a summary line, like the web's `collapseTurns`
