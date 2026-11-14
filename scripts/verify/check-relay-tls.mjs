#!/usr/bin/env node
// Deployment-level TLS check: the relay path must not be usable over plaintext.
// It does not test the app; it verifies the public edge (Caddy) does not serve
// the DLP endpoint over http. Run against the real relay, never in CI.

import { execFileSync } from 'node:child_process'
import { readFileSync, existsSync } from 'node:fs'

let base = process.env.DSH_RELAY_URL ?? ''
if (!base && existsSync('.env.local')) {
  const line = readFileSync('.env.local', 'utf8').match(/^DSH_RELAY_URL\s*=\s*(\S+)/m)
  base = line?.[1]?.replace(/\\\//g, '/') ?? ''
}
if (!base) {
  console.error('缺少 DSH_RELAY_URL')
  process.exit(2)
}
const plain = base.replace(/^wss:/, 'https:').replace(/^https:/, 'http:')
let status
try {
  const output = execFileSync('curl', ['-s', '-o', '/dev/null', '-w', '%{http_code}', '--max-time', '10', plain], {
    encoding: 'utf8',
  })
  status = Number(output.trim())
} catch (error) {
  console.error(`FAIL 明文请求未获得可判定的拒绝：${error.message}`)
  process.exit(1)
}
if (!Number.isFinite(status)) {
  console.error(`FAIL 无法判定明文响应：${plain}`)
  process.exit(1)
}
if (status === 101 || (status >= 200 && status < 300)) {
  console.error(`FAIL 明文可用：${plain} -> ${status}`)
  process.exit(1)
}
if (![301, 302, 307, 308].includes(status) && status < 400) {
  console.error(`FAIL 明文未被明确拒绝：${plain} -> ${status}`)
  process.exit(1)
}
console.log(`ok   ${plain} -> ${status}（未以明文提供 DLP）`)
