# dsh-plugin-mobile-link

[![DSH plugin](https://img.shields.io/badge/DSH-plugin-4D6BFE)](https://github.com/deepseek-ai/deepseek-harness)
[![listed in awesome-deepseek-harness](https://img.shields.io/badge/listed%20in-awesome--deepseek--harness-4D6BFE?logo=awesomelists&logoColor=white)](https://github.com/Dominic789654/awesome-deepseek-harness)
[![npm](https://img.shields.io/npm/v/dsh-plugin-mobile-link)](https://www.npmjs.com/package/dsh-plugin-mobile-link)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](../../LICENSE)

> 面向：使用者与实现者 · 状态：stable · 最近核对：2026-09-20

**The computer half of [DSH Mobile](https://github.com/jayantTang/DSH_Mobile): it
dials a relay over WSS, so the native iOS client reaches this DSH instance even
though the computer has no public IP.**

```
iPhone App ──WSS──▶ Relay（公网，只鉴权与转发）──WSS──▶ this plugin ──HTTP+WS──▶ 127.0.0.1:<port>
```

The connector always talks to the local DSH as `127.0.0.1:<port>`, so the host's
authority and its trust fence are unaffected: no `--trusted-host`, no rewritten
`Host`, no new listening port on this machine.

```
plugins/mobile-link/
├── package.json          # type: module, dsh.bundle.patch, bin: dsh-mobile-link
├── cordis.patch.yml      # bundle patch: the loader row + config reference
├── lib/
│   ├── index.js          # cordis plugin: starts the agent, registers 3 routes
│   ├── link.js           # the DLP agent transport: identity, socket, heartbeat, reconnect
│   ├── router.js         # frames ⇄ local DSH mux streams, per-device `$events`
│   ├── dlp.js            # DLP v1 frame codec (shared with the relay)
│   ├── files.js          # phone → computer file transfers (`_link/file*` methods)
│   ├── enroll.js         # invite-code redemption, writes ~/.dsh/mobile-link/agent.json
│   ├── routes.js         # GET /mobile-link/status, POST /pair-code, GET /qr
│   ├── qr.js             # dependency-free QR SVG
│   └── cli.js            # dsh-mobile-link: enroll / mint-pair-code
└── test/                 # node --test, 100+ tests (no DSH, no network)
```

## Install

```bash
dsh plugin --profile web add dsh-plugin-mobile-link
```

Then restart DSH (or reload the profile). From a checkout the same command takes
a path — the leading `./` matters, because DSH anchors a relative spec against
your current directory instead of resolving it inside the profile:

```bash
dsh plugin --profile web add ./plugins/mobile-link
```

## Use

1. Register this computer with a relay (once). Either redeem an invite code:

   ```bash
   dsh-mobile-link enroll --invite <邀请码> --relay wss://<你的站点>/dsh-link
   ```

   …or register it on the relay host with `relay/admin.py agent-register
   --write-config ~/.dsh/mobile-link/agent.json`.

2. Mint a pairing code, and show it as a QR the phone camera can read:

   ```bash
   dsh-mobile-link --mint-pair-code        # prints JSON: code + relay + agentId
   ```

   Or open `/mobile-link/qr` on the local DSH (behind DSH's own authentication).

3. Scan it in the iOS app. After that the phone reconnects on its own — nothing
   else has to be run by hand.

`GET /mobile-link/status` reports whether the link is up, which devices are
attached, and whether this computer is registered yet.

## Configuration

All optional; the defaults are what a stock deployment needs. Set them in the
plugin's config block (`cordis.patch.yml`), not by editing this file.

| Key | Default | Meaning |
| --- | --- | --- |
| `enabled` | `true` | `false` stops the outbound link without uninstalling |
| `relayUrl` | from `agent.json` | Relay base URL; a bare deployment dials `<relay>/link/agent` |
| `agentId` / `agentSecret` | from `agent.json` | Override the enrolled identity |
| `stateFile` | `~/.dsh/mobile-link/agent.json` | Where the identity lives |
| `dshUrl` | discovery | Explicit local DSH base URL |
| `endpointFile` | `$DSH_HOME/desktop-shell/endpoint.json` | DSH endpoint handoff file |
| `heartbeatMs` | `20000` | DLP ping interval |

Address resolution order: this config block, then `DSH_RELAY_URL` (or
`DSH_MOBILE_LINK_RELAY`), then the enrolled identity file, then the repository
placeholder `wss://relay.example.com/dsh-link` — the placeholder being the
"nothing configured yet" sentinel rather than a real address.

## Design notes

- **No required services.** `inject` is empty and the routes are attached through
  `ctx.inject([...])`, so a future DSH that renames or drops `webServer` /
  `connection` cannot make the tunnel fatal on boot.
- **Protocol-transparent.** Nothing outside `lib/` is imported and no DSH
  business API is touched: the connector forwards frames, it does not interpret
  sessions. The relay has the same property.
- **Disable** by removing the row from the profile's `cordis.patch.yml`, or by
  setting `enabled: false`.

## Test

```bash
cd plugins/mobile-link && npm test    # zero dependencies
```

The wire protocol is specified in
[`docs/RELAY-PROTOCOL.md`](https://github.com/jayantTang/DSH_Mobile/blob/main/docs/RELAY-PROTOCOL.md).

MIT.
