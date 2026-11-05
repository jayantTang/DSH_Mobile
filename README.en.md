# DSH Mobile

[中文](README.md) · **English**

A phone client for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) running on
your own computer: watch what your agent is doing, answer its questions, and keep a session going
while you are away from the desk.

The phone talks to your computer through a small relay. Nothing about your code or conversations is
stored on the relay — it forwards frames and keeps daily byte counters.

![DSH Mobile demo: register the computer, pair by scanning a QR code, then follow the session, files, git changes and commit history](docs/artifacts/demo/dsh-mobile-demo.gif)

## What you need

1. **DSH on a computer** (the desktop half of the product). Sessions live there; the phone is a
   remote control and a reader.
2. **The connector plugin**, which runs inside DSH:
   `dsh plugin --profile web add dsh-plugin-mobile-link`
3. **The app**, from TestFlight:
   <https://testflight.apple.com/join/tHKQsbCk>
   (TestFlight is the current distribution channel; builds expire after 90 days and need a manual
   update in the TestFlight app.)
4. **A relay address.** The default deployment accepts open enrollment; no invite code is
   required, and enrollment is rate-limited by source.

Keep the connector and the app on their latest versions: both follow the same protocol, and the
compatibility window across versions is limited.

## Register and pair

Register the computer first: open **移动端连接** at the bottom of the DSH sidebar, confirm the
prefilled relay address, and click **登记**. No invite code is needed and the connector
reconnects in place. Headless installs can run
`dsh-mobile-link enroll --relay wss://<relay>/dsh-link` instead. A CLI registration while DSH is
running needs one DSH restart.

Once registered, the panel shows the QR code and the pairing code (it stays the same until you click 重新生成). Scan it in the app
(**Scan QR code**); if the camera is unavailable, the same panel shows the code to type by hand.
The same code can be used again for another phone, a reinstall or a new device.

Once paired, the app lists that computer's sessions. It works the same way as the desktop client:
open a session to read its transcript, type to continue it, and answer whenever the agent asks for
approval or a choice.

## Privacy

- Conversations travel phone → relay → your computer, over TLS.
- The relay does not persist message content. It keeps registration state (accounts, computers,
  devices) and per-day byte counters (see [`relay-go/README.md`](relay-go/README.md)).
- The phone keeps a local cache in `Caches` (session list metadata, the tail of sessions you have
  opened, downloaded pictures). It is not backed up, expires after 30 days, and can be cleared in
  **Settings → Cache**. Conversation *content* is stored in the clear on the device — clear it if
  you hand the phone to someone else.
- Prefer to keep everything on your own hardware? The relay can be self-hosted; the repository
  includes the server, the systemd unit, and the Caddy snippet.

## Status

Early, and honest about it: the client is used daily by its author, and a handful of testers are on
TestFlight. The interface ships in Chinese and English; labels that point at the computer-side panel
(「移动端连接」, 「换一张」) are kept as-is.

## More

- [`docs/ONBOARDING.en.md`](docs/ONBOARDING.en.md) — install, pair, self-host a relay.
- [`docs/PRIVACY.en.md`](docs/PRIVACY.en.md) — what is stored where.
- [`docs/`](docs/) — protocol, architecture, pairing, images (mostly Chinese; the protocol
  reference is generated from real wire captures).
- [`docs/DSH-PROTOCOL.md`](docs/DSH-PROTOCOL.md) — the client/host wire, if you want to build your
  own client.
- [`CONTRIBUTING.md`](CONTRIBUTING.md) · [`SECURITY.md`](SECURITY.md) · [`CHANGELOG.md`](CHANGELOG.md)
