#!/usr/bin/env node
// Physical-device performance driver with a stable temporary-session lifecycle.
//
//   node ios/DSHMobile/UITestHarness/run-physical-performance.mjs --device <UDID>
//
// Creates one scratch session, runs the send-echo performance test on the
// physical iPhone with that session, copies the DEBUG performance log back, and
// always deletes the session/workspace it created. It never names a real session.

import { spawnSync } from 'node:child_process'
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import { PROJECT, ROOT, host } from './context.mjs'
import { cleanupScratch, createScratchSession } from './scratch-session.mjs'

const args = process.argv.slice(2)
const arg = (name) => {
  const index = args.indexOf(name)
  return index >= 0 ? args[index + 1] : undefined
}
const device = arg('--device')
if (!device) {
  console.error('用法：run-physical-performance.mjs --device <UDID>')
  process.exit(2)
}
const team = process.env.DSH_TEAM_ID ?? (() => {
  const file = join(PROJECT, 'Signing.local.plist')
  if (!existsSync(file)) return undefined
  const text = readFileSync(file, 'utf8')
  return text.match(/teamID\s*=\s*([A-Z0-9]+)/)?.[1]
})()

const directory = mkdtempSync(join(tmpdir(), 'dsh-perf-session-'))
const live = host()
let sessionId
try {
  sessionId = await createScratchSession(live, directory)
  if (!sessionId) throw new Error('host did not return a scratch session id')
  console.log(`    临时会话 ${sessionId}（目录 ${directory}）`)

  const result = spawnSync('xcodebuild', [
    'test', '-scheme', 'DSHMobile',
    '-destination', `platform=iOS,id=${device}`,
    '-only-testing:DSHMobileUITests/PerformanceBaselineTests/testSendEcho',
    ...(team ? [`DEVELOPMENT_TEAM=${team}`] : []),
  ], {
    cwd: PROJECT,
    stdio: 'inherit',
    env: { ...process.env, TEST_RUNNER_DSH_TEMP_SESSION: sessionId },
  })
  if (result.status !== 0) throw new Error(`xcodebuild test failed: ${result.status}`)

  const copy = `/tmp/performance-device.log`
  rmSync(copy, { force: true })
  const copied = spawnSync('xcrun', [
    'devicectl', 'device', 'copy', 'from', '--device', device,
    '--domain-type', 'appDataContainer', '--domain-identifier', 'com.jayanttang.dsh',
    '--source', 'Documents/performance.log', '--destination', copy,
  ], { stdio: 'inherit' })
  if (copied.status === 0 && existsSync(copy)) {
    console.log(`\n样本：${copy}`)
    console.log(readFileSync(copy, 'utf8').split('\n').filter((line) => /send\.(echo|visible)/.test(line)).join('\n'))
  }
} finally {
  if (sessionId) {
    await cleanupScratch(live, directory, sessionId ? [sessionId] : []).catch((error) => console.error(`清理失败：${error.message}`))
  }
  rmSync(directory, { recursive: true, force: true })
}
