#!/usr/bin/env node
// Deployment-level APNs check: send one real push through the relay's own
// `push-test` and require Apple to accept it. This is not part of CI: it needs
// the relay host, its APNs key, and a registered device.
//
//   DSH_APNS_DEVICE=dev_xxx node scripts/verify/check-apns.mjs
//
// The device id comes from `dsh-relay admin device-list`; it is intentionally
// not hard-coded because it changes when the phone is re-paired.

import { execFileSync } from 'node:child_process'
import { readFileSync, existsSync } from 'node:fs'
import { homedir } from 'node:os'

const envFile = '.env.local'
const env = existsSync(envFile) ? readFileSync(envFile, 'utf8') : ''
const read = (key) => process.env[key] ?? env.match(new RegExp(`^${key}\\s*=\\s*(\\S+)`, 'm'))?.[1] ?? ''
const host = read('DSH_OTA_HOST')
const device = process.env.DSH_APNS_DEVICE
const key = process.env.DSH_SSH_KEY ?? `${homedir()}/.ssh/id_ed25519`
if (!host || !device) {
  console.error('需要 DSH_OTA_HOST 与 DSH_APNS_DEVICE（中转设备 id）')
  process.exit(2)
}
const remote = [
  'set -a',
  '. /etc/dsh-relay/apns.env',
  'set +a',
  `/opt/dsh-relay-go/bin/dsh-relay admin --db /var/lib/dsh-relay/state.db push-test --device ${device} --kind attention --sid push-test`,
].join('; ')
const output = execFileSync('ssh', [
  '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes', '-i', key, `root@${host}`, remote,
], { encoding: 'utf8' })
const json = JSON.parse(output.slice(output.indexOf('{')))
if (!json.ok || json.status !== 200) {
  console.error(`FAIL APNs 未被接受：${output}`)
  process.exit(1)
}
console.log(`ok   APNs ${json.env} ${json.deviceId} status=${json.status} id=${json.apnsId}`)
