# DSH Mobile

[中文](README.md) · **English**

A phone client for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) running on
your own computer: watch what your agent is doing, answer its questions, and keep a session going
while you are away from the desk.

The phone talks to your computer through a small relay. Nothing about your code or conversations is
stored on the relay — it forwards frames and keeps daily byte counters.

## What you need

1. **DSH on a computer** (the desktop half of the product). Sessions live there; the phone is a
   remote control and a reader.
2. **The connector plugin**, which runs inside DSH:
   `dsh plugin --profile web add dsh-plugin-mobile-link`
3. **The app**, from TestFlight:
   <https://testflight.apple.com/join/tHKQsbCk>
   (The App Store release is in review. TestFlight builds expire after 90 days and need a manual
   update in the TestFlight app.)
4. **An invite code.** The relay is invite-only while it is in early use. Codes are handed out in
   [issue #1](https://github.com/jayantTang/DSH_Mobile/issues/1) — one code enrolls one computer,
   and the issue is written in Chinese today.

## Pairing

On the computer, open `/mobile-link/qr` in DSH (or the mobile-connection page) to show a QR code,
then scan it in the app: **Scan QR code**. If you would rather type it, the same screen shows a
pairing code.

Once paired, the app lists that computer's sessions. It works the same way as the desktop client:
open a session to read its transcript, type to continue it, and answer whenever the agent asks for
approval or a choice.

## Privacy

- Conversations travel phone → relay → your computer, over TLS.
- The relay does not persist message content. It keeps device rows, invite state, and per-day byte
  counters (see [`relay/README.md`](relay/README.md)).
- The phone keeps a local cache in `Caches` (session list metadata, the tail of sessions you have
  opened, downloaded pictures). It is not backed up, expires after 30 days, and can be cleared in
  **Settings → Cache**. Conversation *content* is stored in the clear on the device — clear it if
  you hand the phone to someone else.
- Prefer to keep everything on your own hardware? The relay can be self-hosted; the repository
  includes the server, the systemd unit, and the Caddy snippet.

## Status

Early, and honest about it: the client is used daily by its author, a handful of testers are on
TestFlight, and the app's interface is being translated — the main paths (connect, session list,
transcript, settings) are in English, while longer screens are still Chinese.

## More

- [`docs/`](docs/) — protocol, architecture, pairing, images (Chinese; the protocol reference is
  generated from the real wire captures).
- [`docs/DSH-PROTOCOL.md`](docs/DSH-PROTOCOL.md) — the client/host wire, if you want to build your
  own client.
- [`CONTRIBUTING.md`](CONTRIBUTING.md) · [`SECURITY.md`](SECURITY.md) · [`CHANGELOG.md`](CHANGELOG.md)
