# Privacy

[中文](PRIVACY.md) · **English**

## In one line

Your conversations travel between your phone and your computer through a relay. The relay forwards
them and keeps no conversation history.

## The app

- The app talks to exactly one computer at a time, the one you paired.
- It stores the pairing secret in the iOS Keychain.
- It keeps a local cache in `Caches`: the session list (titles, times, usage numbers), the last
  200 records of sessions you have opened, and pictures you have viewed. That cache is not backed
  up, expires after 30 days, and can be cleared in **Settings → Cache**. Conversation *content* is
  stored in the clear on the device.
- Notifications are local; nothing is pushed through a third-party notification service.

## The relay

- **Authentication and forwarding only.** It sees metadata for each encrypted channel (which
  computer, which device, frame types) and, as the TLS endpoint, the frames it forwards.
- **No conversation history is kept.** What is stored is registration state: accounts, computers,
  devices, invite codes (hashed), and per-day byte counters. The byte counters exist so an operator
  can answer "how much did this device relay today".
- **The app reports its version and build** on connect, so a device list can show which build a phone
  is on. That is the only thing the phone volunteers about itself.

## Running it yourself

You can use someone else's relay together with an invite code from them, or run your own:
`relay/deploy/deploy.sh` is an idempotent installer, and the relay is a small Python service behind
Caddy. Self-hosting removes the third party entirely.

## Deleting data

- **On the phone:** Settings → Paired devices → revoke; or delete the app, which takes the token
  with it.
- **On the computer:** delete `~/.dsh/mobile-link/agent.json` to unregister this computer.
- **On the relay:** the operator (yourself, if self-hosted) uses `admin.py device-revoke` /
  `account-delete` / `purge`.

## Contact

Open an issue on the repository, or use the address in `SECURITY.md` for anything sensitive.
