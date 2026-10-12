# Privacy

[中文](PRIVACY.md) · **English**

## In one line

Your conversations travel between your phone and your computer through a relay. The relay forwards
them and keeps no conversation history. The one thing the app sends on its own initiative is a
feedback message, and only when you press send (see *Feedback and notices*).

## The app

- The app talks to exactly one computer at a time, the one you paired.
- It stores the pairing secret in the iOS Keychain, and the pickup key for feedback replies next to
  it.
- It keeps a local cache in `Caches`: the session list (titles, times, usage numbers), the last
  200 records of sessions you have opened, pictures you have viewed, and a mirror of your feedback
  threads. That cache is not backed up, expires after 30 days, and can be cleared in
  **Settings → Cache**; clearing it keeps the Keychain pickup key.
- Nothing leaves the phone unless you send it: a feedback message is uploaded only when you press
  send, on the screen that shows exactly what will be sent.
- Notifications are local; nothing is pushed through a third-party notification service.

## The relay

- **Authentication and forwarding only.** It sees metadata for each encrypted channel (which
  computer, which device, frame types) and, as the TLS endpoint, the frames it forwards.
- **No conversation history is kept.** What is stored is registration state: accounts, computers,
  devices, invite codes (hashed), and per-day byte counters. The byte counters exist so an operator
  can answer "how much did this device relay today". The only message bodies ever stored are the
  feedback you submit and our replies to it (see below).
- **The app reports its version and build** on connect, so a device list can show which build a phone
  is on. That is the only thing the phone volunteers about itself.

## Feedback and notices

- A message is submitted only when you press send in the app: your text, plus the app version, device
  model and iOS version the app attaches. The compose screen shows all of it before you send, and you
  can walk away.
- The text is stored in the database of **the relay you are using** (your own, if self-hosted), so we
  can read it and reply. It is not published, not used for analytics, and not shared with any SDK.
- Conversation content, transcripts and files are never uploaded.
- After the first submission the phone holds a random *pickup key* in the system Keychain, which is
  what fetches our replies and notices. Deleting the app leaves the key behind, so reinstalling shows
  the same records again.
- Retention: feedback and replies are not deleted automatically. To have them removed, ask the relay
  operator (yourself, if self-hosted) as described under *Deleting data*.

## Running it yourself

You can use someone else's relay together with an invite code from them, or run your own:
`relay/deploy/deploy.sh` is an idempotent installer, and the relay is a small Python service behind
Caddy. Self-hosting removes the third party entirely.

## Deleting data

- **On the phone:** Settings → Paired devices → revoke; or delete the app, which takes the token
  with it. The feedback pickup key lives in the Keychain and survives an app reinstall (that is what
  makes replies readable again after reinstalling); *Settings → Cache* clears the local mirror of
  feedback records and keeps the key. There is no separate in-app way to delete that key — it goes
  away when the device is erased.
- **On the computer:** delete `~/.dsh/mobile-link/agent.json` to unregister this computer.
- **On the relay:** the operator (yourself, if self-hosted) uses `admin.py device-revoke` /
  `account-delete` / `purge`, and deletes feedback threads on request.

## Contact

Open an issue on the repository, or use the address in `SECURITY.md` for anything sensitive.
