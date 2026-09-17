#!/usr/bin/env node
// Everything a verb needs to know about this machine and this run: where the
// project is, which simulator is used, how to reach the live DSH, and how to
// build and install the app under test.
//
// Shared rather than repeated because the verbs are meant to be called one at a
// time — the agent decides which ones to run and in what order, and every verb
// has to agree on what "the current run" means.

import { execFileSync } from 'node:child_process'
import { existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

export const HERE = dirname(fileURLToPath(import.meta.url))
export const ROOT = resolve(HERE, '../..')
export const TEST_DIR = join(ROOT, 'test')
export const BUILD = join(TEST_DIR, '.build')
export const RUNS = join(TEST_DIR, 'runs')
export const PROJECT = join(ROOT, 'ios/DSHMobile')
export const DERIVED = join(PROJECT, '.build/sim')
export const BUNDLE_ID = 'com.jayanttang.dsh'
export const RUNNER_BUNDLE_ID = 'com.jayanttang.dsh.uitests.xctrunner'
/// The simulator every run drives, unless `SIM_ID` (or `--sim`) names another.
///
/// Discovered rather than written down: a UDID belongs to one machine, so a
/// hardcoded one makes every clone drive somebody else's simulator — and fail
/// on the machine that actually has it, the day it is erased and rebuilt.
export const DEFAULT_SIM = process.env.SIM_ID ?? discoverSimulator()

function discoverSimulator() {
  let devices = []
  try {
    const listed = JSON.parse(run('xcrun', ['simctl', 'list', 'devices', 'available', '--json'], { quiet: true }))
    devices = Object.values(listed.devices ?? {}).flat()
      .filter((device) => device.isAvailable !== false && /DSH-Test|iPhone|iPad/.test(device.name ?? ''))
  } catch {
    devices = []
  }
  const chosen = devices.find((device) => /DSH-Test/.test(device.name))
    ?? devices.find((device) => device.state === 'Booted')
    ?? devices[0]
  if (chosen?.udid) return chosen.udid
  throw new Error('找不到可用的 iOS 仿真器（xcrun simctl list devices available 为空）；用 SIM_ID=<udid> 指定一台')
}
export const DEFAULT_CASE = 'test/cases/fixed/01-全部独立页面逐屏核对.md'

export const log = (message) => console.log(`\x1b[1;36m>>>\x1b[0m ${message}`)
export const warn = (message) => console.error(`\x1b[1;31m!\x1b[0m ${message}`)

/// Runs a command and returns its stdout, or throws with the command in the
/// message — a bare ENOENT is useless when four tools are being orchestrated.
export function run(command, args, options = {}) {
  try {
    return execFileSync(command, args, { encoding: 'utf8', stdio: 'pipe', ...options })
  } catch (error) {
    if (options.quiet) throw error
    const detail = (error.stderr ?? '').toString().split('\n').slice(-3).join(' ').trim()
    throw new Error(`${command} ${args.slice(0, 3).join(' ')} 失败：${detail || error.message}`)
  }
}

// ---------------------------------------------------------------- arguments

const BOOLEAN_FLAGS = new Set(['no-build', 'plan-only', 'keep-going', 'scaffold', 'allow-lint-errors'])

/// `--x y`, `--flag`, and bare positionals. One parser for every verb so the
/// command line behaves the same whichever one is called.
export function parseArgs(argv = process.argv.slice(2)) {
  const flags = {}
  const positional = []
  for (let i = 0; i < argv.length; i += 1) {
    if (!argv[i].startsWith('--')) { positional.push(argv[i]); continue }
    const name = argv[i].slice(2)
    const next = argv[i + 1]
    if (BOOLEAN_FLAGS.has(name) || next === undefined || next.startsWith('--')) {
      flags[name] = true
      continue
    }
    flags[name] = argv[++i]
  }
  return { flags, positional }
}

/// A run id that reads as local wall-clock time.
///
/// `toISOString()` is UTC, which made every directory name eight hours off the
/// clock on the wall — the one thing a timestamp is for.
export function stamp(date = new Date()) {
  const pad = (value) => String(value).padStart(2, '0')
  return `${date.getFullYear()}${pad(date.getMonth() + 1)}${pad(date.getDate())}`
    + `-${pad(date.getHours())}${pad(date.getMinutes())}${pad(date.getSeconds())}`
}

/// The run the verbs act on: the newest one, or `--run <id>`.
export function resolveRun(flags = {}) {
  if (flags.run && flags.run !== true) return { runId: flags.run, runDir: join(RUNS, flags.run) }
  if (!existsSync(RUNS)) throw new Error('还没有任何运行记录，先执行一次 run')
  const ids = run('ls', ['-1', RUNS]).trim().split('\n').filter(Boolean).sort()
  if (!ids.length) throw new Error('还没有任何运行记录，先执行一次 run')
  const runId = ids.at(-1)
  return { runId, runDir: join(RUNS, runId) }
}

export function ensureRunDir(runId) {
  const runDir = join(RUNS, runId)
  const shots = join(runDir, 'shots')
  const detail = join(runDir, 'detail')
  for (const dir of [runDir, shots, detail, BUILD]) mkdirSync(dir, { recursive: true })
  return { runDir, shotsDir: shots, detailDir: detail }
}

// ---------------------------------------------------------------- pages

/// Pages the app can be launched straight into, and the arguments that do it.
/// Mirrors `test/screens.md`; `RootView.swift`'s `-DSHOpenScreen` switch is the
/// other half of this contract.
export const screens = {
  onboarding: { root: 'text:连接你电脑上的 DSH', args: () => [] },
  sessions: { root: 'id:session.list', args: () => [] },
  transcript: { root: 'id:chat.transcript', args: (session) => ['-DSHOpenSession', session] },
  // The file browser resolves its workspace from a session, and without one it
  // takes the first session in the list — which is the *user's* newest session,
  // not the one a case means to photograph. `-DSHOpenSession` makes it open the
  // named session's workspace instead; see `openFilesWhenTheListArrives`.
  files: { root: 'id:files.root', args: (session) => ['-DSHOpenScreen', 'files', '-DSHOpenSession', session] },
  settings: { root: 'id:settings.root', args: () => ['-DSHOpenScreen', 'settings'] },
  connections: { root: 'id:connection.scan', args: () => ['-DSHOpenScreen', 'connections'] },
  web: { root: 'text:插件界面不可用', args: () => ['-DSHOpenScreen', 'web'] },
  // A workspace file opened in the viewer the app chooses for its type. The
  // root is a line from the report fixture, so the check is "the page rendered"
  // rather than "the reader opened".
  report: { root: 'text:全部独立页面逐屏核对', args: () => [] },
  // What this device actually has: font families, and whether the system font
  // can draw a CJK glyph. Answers questions a screenshot cannot.
  diagnostics: { root: 'text:system font', args: () => ['-DSHOpenScreen', 'diagnostics'] },
}

// ---------------------------------------------------------------- host

/// The live DSH's endpoint, from `tools/host.mjs`.
export function host() {
  return JSON.parse(run('node', [join(HERE, 'host.mjs')], { quiet: true }))
}

/// The session with the most history, so the transcript page shows something
/// real rather than an empty conversation.
export async function pickSession(host) {
  const exchange = await fetch(`http://127.0.0.1:${host.port}/?token=${host.token}`, { redirect: 'manual' })
  const cookie = (exchange.headers.getSetCookie?.() ?? [])[0]?.split(';')[0]
  const response = await fetch(`http://127.0.0.1:${host.port}/api/session/list`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', cookie },
    body: JSON.stringify({ type: 'client-request', rpcId: 'pick', method: 'session/list',
                           payload: { args: { _request: {} } } }),
  })
  const body = await response.json()
  const items = (body.result?.value?.items ?? []).filter((item) => item.origin !== 'subagent' && !item.blank)
  items.sort((a, b) => ((b.projections ?? {}).asOfSeq ?? 0) - ((a.projections ?? {}).asOfSeq ?? 0))
  return items[0]?.sessionId ?? ''
}

// ---------------------------------------------------------------- build

export const appPath = join(DERIVED, 'Build/Products/Debug-iphonesimulator/DSHMobile.app')
export const runnerPath = join(DERIVED, 'Build/Products/Debug-iphonesimulator/DSHMobileUITests-Runner.app')

/// Builds the app and the one-file test engine, incrementally.
///
/// Two minutes on a cold derived data, about two seconds after a change to a
/// single Swift file — which is what makes per-case compilation of test code
/// affordable to avoid entirely.
///
/// "Incrementally" is decided by comparing the newest input against the product.
/// The first version skipped whenever a product existed, which silently tested
/// yesterday's binary after a source change: the run reported the old app's
/// behaviour as the new code's result.
export function build(simId, { force = false } = {}) {
  if (!force && existsSync(appPath) && existsSync(runnerPath)) {
    const product = newestMtime([appPath, runnerPath])
    if (product >= newestMtime(sourceRoots())) return { skipped: true }
  }
  const started = Date.now()
  run('xcodebuild', ['-project', join(PROJECT, 'DSHMobile.xcodeproj'), '-scheme', 'DSHMobile',
    '-configuration', 'Debug', '-destination', `platform=iOS Simulator,id=${simId}`,
    '-derivedDataPath', DERIVED, 'build-for-testing'], { quiet: true })
  return { skipped: false, seconds: (Date.now() - started) / 1000 }
}

/// Every directory whose contents the built product is made of.
function sourceRoots() {
  return [
    join(PROJECT, 'DSHMobile'),
    join(PROJECT, 'DSHKit', 'Sources'),
    join(PROJECT, 'DSHMobileUITests'),
    join(PROJECT, 'DSHMobile.xcodeproj'),
    join(PROJECT, 'DSHKit', 'Package.swift'),
  ]
}

/// The newest modification time in a tree.
///
/// Bundles are walked into rather than stamped: a bundle's own directory time
/// does not move when a file inside it is replaced, and the binary inside is
/// what carries the change.
function newestMtime(paths) {
  let newest = 0
  for (const path of paths) {
    let stats
    try { stats = statSync(path) } catch { continue }
    if (!stats.isDirectory()) {
      newest = Math.max(newest, stats.mtimeMs)
      continue
    }
    newest = Math.max(newest, newestMtime(readdirSync(path).map((name) => join(path, name))))
  }
  return newest
}

export function appVersion() {
  try {
    return run('/usr/libexec/PlistBuddy',
               ['-c', 'Print :CFBundleShortVersionString', join(appPath, 'Info.plist')],
               { quiet: true }).trim()
  } catch { return '?' }
}

export function appBuild() {
  try {
    return run('/usr/libexec/PlistBuddy',
               ['-c', 'Print :CFBundleVersion', join(appPath, 'Info.plist')],
               { quiet: true }).trim()
  } catch { return '?'; }
}

export function gitCommit() {
  try { return run('git', ['-C', ROOT, 'rev-parse', '--short', 'HEAD'], { quiet: true }).trim() }
  catch { return '?'; }
}

/// Everything a report needs to say what it was run against.
///
/// A test report that only names a commit cannot be reproduced: the same build
/// behaves differently on another iOS version or another device model. These are
/// the simulator's own facts, asked of `simctl` once per run, and they land in
/// `summary.json` so the report can print them without asking again.
export function environmentFacts(simId) {
  const facts = { simulator: null, ios: '?', model: '?', xcode: '?', host: 'macOS' }
  try {
    const listing = run('xcrun', ['simctl', 'list', 'devices', '--json'], { quiet: true })
    const devices = JSON.parse(listing).devices ?? {}
    for (const [runtime, entries] of Object.entries(devices)) {
      for (const device of entries ?? []) {
        if (device.udid !== simId) continue
        facts.simulator = device.name
        // `simctl` reports "26-3" for the OS and a dotted type identifier for the
        // model; a report should read "iOS 26.3 · iPhone 17 Pro".
        const version = (device.osVersion ?? runtime.split('.').pop() ?? '?').toString()
        facts.ios = version.replace(/^iOS[-.]?/, '').replace(/-/g, '.')
        facts.model = device.deviceTypeIdentifier
          ?.replace(/^com\.apple\.CoreSimulator\.SimDeviceType\./, '').replace(/-/g, ' ')
          ?? device.name
      }
    }
  } catch { /* keep the placeholders: an absent fact must not fail a run */ }
  try {
    facts.xcode = run('xcodebuild', ['-version'], { quiet: true }).split('\n')[0].replace('Xcode ', '').trim()
  } catch { /* same */ }
  try {
    facts.host = `${run('sw_vers', ['-productVersion'], { quiet: true }).trim()} macOS`
  } catch { /* same */ }
  return facts
}

// ---------------------------------------------------------------- simulator

export function bootSimulator(simId) {
  try { run('xcrun', ['simctl', 'bootstatus', simId, '-b'], { quiet: true }) } catch {
    run('xcrun', ['simctl', 'boot', simId], { quiet: true })
    run('xcrun', ['simctl', 'bootstatus', simId, '-b'], { quiet: true })
  }
  // Deterministic pixels: a fixed clock and full bars, so two runs of the same
  // case differ only where the app differs.
  try {
    run('xcrun', ['simctl', 'status_bar', simId, 'override', '--time', '9:41',
                  '--batteryLevel', '100', '--cellularBars', '4', '--wifiBars', '3'], { quiet: true })
  } catch { /* older runtimes */ }
  try { run('xcrun', ['simctl', 'ui', simId, 'appearance', 'light'], { quiet: true }) } catch { }
  try {
    // A connected hardware keyboard swallows `typeText`.
    run('defaults', ['write', `com.apple.iphonesimulator.${simId}`,
                     'ConnectHardwareKeyboard', '-bool', 'false'], { quiet: true })
  } catch { /* the key only exists after the Simulator UI has run once */ }
}

/// Installs the runner and stages the plan inside its container.
///
/// A UI test is a process inside the simulator: a path under /Users is invisible
/// to it, while its own container is readable from both sides. The container is
/// re-resolved on every call because `xcodebuild test` reinstalls the runner and
/// a reinstall can hand it a fresh container.
export function installRunner(simId) {
  run('xcrun', ['simctl', 'install', simId, runnerPath], { quiet: true })
}

export function runnerDocuments(simId) {
  return join(run('xcrun', ['simctl', 'get_app_container', simId, RUNNER_BUNDLE_ID, 'data'],
                  { quiet: true }).trim(), 'Documents')
}

export function stagePlan(simId, plan) {
  const documents = runnerDocuments(simId)
  mkdirSync(documents, { recursive: true })
  writeFileSync(join(documents, 'dsh-plan.json'), JSON.stringify(plan, null, 2))
  writeFileSync(join(documents, 'dsh-events.ndjson'), '')
  return documents
}

export function readEvents(simId) {
  try { return readFileSync(join(runnerDocuments(simId), 'dsh-events.ndjson'), 'utf8') }
  catch { return '' }
}
