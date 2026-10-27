# After installing: how to use it

[中文](ONBOARDING.md) · **English**

Two ways to get the phone talking to your computer. Pick one before you start —
they differ only in who runs the relay.

## What you need first

1. **DSH running on your computer** (the desktop half of the product).
2. **The connector plugin**, installed into that DSH:
   `dsh plugin --profile web add dsh-plugin-mobile-link`
3. **The app on your phone**, from TestFlight:
   <https://testflight.apple.com/join/tHKQsbCk>

## A · Use the existing relay (5 minutes)

1. **Install the app** from the TestFlight link above.
2. **Install the connector** on your computer (step 2 above), then keep DSH running.
3. **Enrol this computer with an invite code.** Claim one from
   [issue #1](https://github.com/jayantTang/DSH_Mobile/issues/1) — one code enrols one computer,
   and the connector prints the enrolment command when it starts without an identity.
4. **Restart DSH** so the connector picks up its new identity. After that it reconnects by itself.
5. **Pair the phone:** click **移动端连接** at the bottom of the sidebar in DSH and scan the QR
   code it shows; the relay address and the pairing code are both inside that code, so nothing has
   to be typed. The code is persistent and can be claimed again for another phone, a reinstall or
   a new device; click 重新生成 only when you want to revoke it. (With no GUI around,
   `node scripts/dev/show-pair-qr.mjs` prints the same code as an image.)
6. **Check the link:** the app's status chip turns green and the session list fills in.

## B · Run your own relay (20 minutes)

The relay is the Go implementation in `relay-go/`. Build and install it as described in
[`relay-go/deploy/README.md`](../relay-go/deploy/README.md) §3–§4, then:

```bash
# on your server (root, with Caddy already installed)
sudo systemctl enable --now dsh-relay-go

# create an account and mint yourself an invite code
/opt/dsh-relay-go/bin/dsh-relay admin --db /var/lib/dsh-relay/state.db \
  account-create --name "<you>"
/opt/dsh-relay-go/bin/dsh-relay admin --db /var/lib/dsh-relay/state.db \
  invite-mint --note "first computer" --relay wss://your.host/dsh-link
```

The Caddy route comes from [`relay-go/deploy/Caddyfile.snippet`](../relay-go/deploy/Caddyfile.snippet),
inserted with [`relay-go/deploy/caddy_splice.py`](../relay-go/deploy/caddy_splice.py).

Then enrol the connector against your own relay address instead of the shared one. Details, including
the systemd sandbox and the operating limits, are in [`relay-go/README.md`](../relay-go/README.md).

## What you can do once paired

- Read any session's transcript, including tool calls and their output.
- Answer whenever the agent asks for approval or a choice — the phone is often faster than walking
  back to the desk.
- Keep a session going: type, send pictures, stop a run.
- Browse the session's workspace files and its git changes.
- Get a notification when a run finishes or when something needs you.

## When it will not connect

Check in this order:

1. Is DSH still running on the computer, with the connector loaded?
2. Does the phone have network access, and can it reach the relay?
3. Is the pairing still valid? Revoke and pair again if the device was revoked on the computer.
4. Self-hosted relay: is Caddy up, and does the path in `DSH_RELAY_BASE_PATH` match the client's
   relay address?

## Uninstall / change relay

```bash
# switching relays: drop the old identity, then enrol again
rm ~/.dsh/mobile-link/agent.json

# removing the connector
dsh plugin --profile web remove dsh-plugin-mobile-link
```

On the phone, revoke this phone in **Settings → Paired devices**, or just delete the app.
