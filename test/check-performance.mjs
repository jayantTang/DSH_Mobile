#!/usr/bin/env node
// Hard gate for the physical performance log copied from the device.
// Usage: node test/check-performance.mjs [--file /tmp/performance-device.log]

import { existsSync, readFileSync } from 'node:fs'

const args = process.argv.slice(2)
const index = args.indexOf('--file')
const file = index >= 0 ? args[index + 1] : '/tmp/performance-device.log'
if (!existsSync(file)) {
  console.error(`缺少性能样本：${file}（先跑真机基线并拷回）`)
  process.exit(2)
}
const thresholds = JSON.parse(readFileSync('test/performance-thresholds.json', 'utf8'))
const samples = new Map()
for (const line of readFileSync(file, 'utf8').split('\n')) {
  const match = line.match(/^(\S+)\s+(\d+)$/)
  if (!match) continue
  if (!samples.has(match[1])) samples.set(match[1], [])
  samples.get(match[1]).push(Number(match[2]))
}
const percentile = (values, p) => {
  const sorted = [...values].sort((a, b) => a - b)
  const k = (sorted.length - 1) * p / 100
  const floor = Math.floor(k)
  const ceil = Math.ceil(k)
  return floor === ceil ? sorted[floor] : sorted[floor] * (ceil - k) + sorted[ceil] * (k - floor)
}
let failed = 0
for (const [name, rule] of Object.entries(thresholds)) {
  const values = samples.get(name) ?? []
  if (values.length < rule.minSamples) {
    console.error(`FAIL ${name}: ${values.length} 个样本，至少需要 ${rule.minSamples}`)
    failed += 1
    continue
  }
  // 只取最近 minSamples 次，避免历史热噪声把当前基线拖宽。
  const recent = values.slice(-rule.minSamples)
  const p95 = Math.round(percentile(recent, 95))
  if (p95 > rule.p95Ms) {
    console.error(`FAIL ${name}: p95 ${p95} ms > ${rule.p95Ms} ms`)
    failed += 1
  } else {
    console.log(`ok   ${name}: ${values.length} 样本（最近 ${recent.length}），p95 ${p95} ms ≤ ${rule.p95Ms} ms`)
  }
}
process.exit(failed ? 1 : 0)
