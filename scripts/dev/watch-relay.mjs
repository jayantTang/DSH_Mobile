#!/usr/bin/env node
/**
 * Watches the relay for "somebody started using it" and prints one line per change.
 *
 * Publishing invite codes means the first question is "did anyone take one?" —
 * and the relay can answer it exactly, without guessing from GitHub stars or
 * clone counts:
 *
 *   * a redeemed invite shows up as a new **agent** (a new computer enrolled);
 *   * a phone connecting shows up as a **device**;
 *   * egress bytes show whether that person is actually using it.
 *
 * It only reads `/stats`, so it never touches the relay's own state. Run it on
 * the Mac that has SSH access to the relay host:
 *
 *   node scripts/dev/watch-relay.mjs                  # every 5 minutes, forever
 *   node scripts/dev/watch-relay.mjs --every 60       # every minute
 *   node scripts/dev/watch-relay.mjs --once           # one sample, for a cron job
 *
 * The host comes from `.env.local` (`DSH_OTA_HOST`), the same place the deploy
 * scripts read it — the repository never carries a real address.
 */

import { execFileSync } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const ROOT = join(HERE, '..', '..')

function hostFromEnvLocal() {
  const path = join(ROOT, '.env.local')
  if (!existsSync(path)) throw new Error(`${path} 不存在：先 cp .env.example .env.local 并填 DSH_OTA_HOST`)
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    const match = /^\s*DSH_OTA_HOST\s*=\s*(.+?)\s*$/.exec(line)
    if (match) {
      const value = match[1].replace(/^['"]|['"]$/g, '')
      return value.includes('@') ? value.split('@').pop().split('/')[0] : value.split('/')[0]
    }
  }
  throw new Error('DSH_OTA_HOST 没写在 .env.local 里')
}

/// One sample of the relay's own accounting, read over SSH (the relay listens on
/// loopback only, so there is no other way in — which is the point).
function sample(host) {
  const raw = execFileSync('ssh', [
    '-q', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10',
    `root@${host}`, 'curl -s --max-time 10 http://127.0.0.1:8787/stats',
  ], { encoding: 'utf8', timeout: 30_000 })
  const stats = JSON.parse(raw)
  const devices = stats.traffic?.devices ?? []
  return {
    agents: stats.load?.agents ?? 0,
    devices: stats.load?.devices ?? 0,
    totalMB: (stats.traffic?.totalEgressBytes ?? 0) / 1048576,
    deviceNames: devices.map((device) => device.name || device.deviceId),
  }
}

const argv = process.argv.slice(2)
const everyIndex = argv.indexOf('--every')
const everySeconds = everyIndex >= 0 ? Number(argv[everyIndex + 1]) : 300
const once = argv.includes('--once')

const host = hostFromEnvLocal()
const stamp = () => new Date().toLocaleString('zh-CN', { hour12: false })

let previous = null
let failed = 0

function poll() {
  let current
  try {
    current = sample(host)
    failed = 0
  } catch (error) {
    failed += 1
    // One failed sample is noise (an ssh hiccup); a run of them is worth saying.
    if (failed === 1 || failed % 10 === 0) {
      console.log(`${stamp()}  ✗ 读不到 /stats（第 ${failed} 次）：${String(error.message).split('\n')[0]}`)
    }
    return
  }

  if (previous === null) {
    console.log(`${stamp()}  · 基线：agent ${current.agents} 台电脑 · 设备 ${current.devices} 台 · `
      + `累计出口 ${current.totalMB.toFixed(2)} MB`)
  } else {
    const newAgents = current.agents - previous.agents
    const newDevices = current.devices - previous.devices
    const grew = current.totalMB - previous.totalMB
    if (newAgents > 0) {
      console.log(`${stamp()}  ★ 有人用邀请码登记了一台电脑！（agent ${previous.agents} → ${current.agents}）`)
    }
    if (newDevices > 0) {
      console.log(`${stamp()}  ★ 有手机连上了：${current.deviceNames.join('、')}`
        + `（设备 ${previous.devices} → ${current.devices}）`)
    }
    if (newAgents < 0 || newDevices < 0) {
      console.log(`${stamp()}  · 断开：agent ${previous.agents} → ${current.agents}，`
        + `设备 ${previous.devices} → ${current.devices}`)
    }
    // Report traffic every sample: a quiet relay is information too, and it is
    // what tells an operator whether the pipe is actually being used.
    if (grew > 0.01 || newAgents !== 0 || newDevices !== 0) {
      console.log(`${stamp()}    本次新增出口 ${grew.toFixed(2)} MB，累计 ${current.totalMB.toFixed(2)} MB`
        + `（agent ${current.agents} · 设备 ${current.devices}）`)
    }
  }
  previous = current
}

poll()
if (!once) {
  setInterval(poll, Math.max(15, everySeconds) * 1000)
  console.log(`每 ${Math.max(15, everySeconds)} 秒采样一次 ${host}:/stats，Ctrl-C 结束`)
}
