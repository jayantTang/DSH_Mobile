#!/usr/bin/env node
// SR-08.07 hard gate: no main-thread hang at or above the threshold in a set of
// HangTracer .ips reports copied from a physical device.
//
// Usage:
//   node test/performance/check-hangs.mjs [--dir /tmp/hang-ips] [--threshold 500]
//
// The reports are produced by iOS Hang Detection (Settings > Developer >
// Hang Detection) on a development-signed or TestFlight build. This script only
// reads the reports; it never touches the device.

import { existsSync, readFileSync, readdirSync } from 'node:fs'
import { join } from 'node:path'

const args = process.argv.slice(2)
const value = (name, fallback) => {
  const index = args.indexOf(name)
  return index >= 0 ? args[index + 1] : fallback
}
const directory = value('--dir', '/tmp/hang-ips')
const threshold = Number(value('--threshold', '500'))
const bundle = value('--bundle', 'com.jayanttang.dsh')

if (!existsSync(directory)) {
  console.error(`缺少卡顿报告目录：${directory}（先用 devicectl copy from 取回 HangTracer 报告）`)
  process.exit(2)
}

const reports = readdirSync(directory).filter((name) => name.endsWith('.ips')).sort()
const violations = []
let matched = 0
for (const name of reports) {
  const text = readFileSync(join(directory, name), 'utf8')
  const firstLine = text.split('\n', 1)[0]
  let header
  try {
    header = JSON.parse(firstLine)
  } catch {
    continue
  }
  const isOurs = header.bundleID === bundle
    || header.app_name === 'DSHMobile'
    || header.name === 'DSHMobile'
  if (!isOurs) continue
  const duration = Number(header.duration_ms)
  if (!Number.isFinite(duration)) continue
  matched += 1
  if (duration >= threshold) {
    violations.push({ name, duration, timestamp: header.timestamp })
  }
}

if (violations.length > 0) {
  console.error(`FAIL ${violations.length}/${matched} 份 ${bundle} 卡顿报告 ≥${threshold} ms`)
  for (const item of violations) {
    console.error(`  ${item.duration} ms  ${item.timestamp}  ${item.name}`)
  }
  process.exit(1)
}
console.log(`ok   ${matched} 份 ${bundle} 报告均 <${threshold} ms（阈值 ${threshold} ms）`)
