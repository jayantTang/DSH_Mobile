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
3. **Register this computer from the panel.** Click **移动端连接** at the bottom of the DSH
   sidebar; the relay address is prefilled. Click **登记**. No invite code is required by default;
   the relay may rate-limit open enrollment by source and the connector shows the reason if it
   refuses. The connector derives the
   computer name automatically and reconnects in place after registration.
4. **Headless installs only:** use `dsh-mobile-link enroll --relay …` (add `--invite …` only if
   the deployment still requires one). The command writes the identity file; if the host is
   running, restart DSH so it reads the new identity. The panel path needs neither a terminal
   nor a restart.
5. **Pair the phone:** the same **移动端连接** panel shows a QR code containing both the relay address and the pairing code; scan it, so nothing has to be typed. The code is persistent and can be claimed again for another phone, a reinstall or
   a new device; click 重新生成 only when you want to replace it. Each paired device has a
   quiet **撤销** action; revoking one device leaves the pairing code and other devices unchanged.
   (With no GUI around,
   `node scripts/dev/show-pair-qr.mjs` prints the same code as an image.)
6. **Check the link:** the app's status chip turns green and the session list fills in.

## B · Run your own relay (20 minutes)

The relay is the Go implementation in `relay-go/`. Build and install it as described in
[`relay-go/deploy/README.md`](../relay-go/deploy/README.md) §3–§4, then:

```bash
# on your server (root, with Caddy already installed)
sudo systemctl enable --now dsh-relay-go

# optional: create an account and mint yourself an invite code (open enrollment needs neither)
/opt/dsh-relay-go/bin/dsh-relay admin --db /var/lib/dsh-relay/state.db \
  account-create --name "<you>"
/opt/dsh-relay-go/bin/dsh-relay admin --db /var/lib/dsh-relay/state.db \
  invite-mint --note "first computer" --relay wss://your.host/dsh-link
```

The Caddy route comes from [`relay-go/deploy/Caddyfile.snippet`](../relay-go/deploy/Caddyfile.snippet),
inserted with [`relay-go/deploy/caddy_splice.py`](../relay-go/deploy/caddy_splice.py).

Then enrol the connector against your own relay address instead of the shared one. Open enrollment is the default; if you keep invite codes, add `--invite` to the CLI. Details, including
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
