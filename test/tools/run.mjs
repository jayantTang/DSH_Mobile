#!/usr/bin/env node
// Runs one case and files its evidence.
//
//   node test/tools/run.mjs test/cases/fixed/01-全部独立页面逐屏核对.md
//
// One of four verbs the tester drives; see `dsh.mjs`. This one turns a case
// into a plan, lets the UI engine execute it, then brings the screenshots back
// out of the result bundle, checks the pixels arithmetic can check, annotates
// every picture, and leaves the machine-readable outcome in `summary.json` for
// `report.mjs` to render.
//
// Two decisions carry the speed:
//   * the engine is one compiled test file, so editing a case costs no build;
//   * screenshots are taken by the engine, because an app driven by XCUITest
//     does not appear on the simulator's own display.

import { spawn, spawnSync } from 'node:child_process'
import { copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

import { buildPlan, caseMeta } from './case.mjs'
import { claimedRelayLink, pairDevice, revokeDevice } from './relaypair.mjs'
import {
  BUILD, BUNDLE_ID, DEFAULT_CASE, DEFAULT_SIM, DERIVED, HERE, PROJECT, ROOT, TEST_DIR,
  appBuild, appVersion, bootSimulator, build, ensureRunDir, environmentFacts, gitCommit, host,
  installRunner, log, parseArgs, pickSession, readEvents, run, screens, stagePlan, stamp, warn,
} from './context.mjs'

/// 把 App 内探针（`-DSHViewportProbe`，DEBUG-only）的日志取回来，并对
/// "会话区有没有真的变白"下一条机器判定。
///
/// 为什么值得进测试台：用户报的是**概率性**的空白，一张两张截图证不了它不在，
/// 而录像又要人一帧帧看。探针在 App 里每 0.5 秒把转写区画一遍、数墨迹占比，
/// 于是"这一轮有没有白过"变成一个可以复核的数字。用例没带探针参数时静默跳过。
function analyzeProbe({ simId, detailDir, verdicts, log }) {
  try {
    probeVerdicts({ simId, detailDir, verdicts, log })
  } catch (error) {
    warn(`探针分析失败（不影响本轮的其它判定）：${error.message.split('\n')[0]}`)
  }
}

function probeVerdicts({ simId, detailDir, verdicts, log }) {
  let container = ''
  try {
    container = run('xcrun', ['simctl', 'get_app_container', simId, BUNDLE_ID, 'data'],
                     { quiet: true }).trim()
  } catch {
    return
  }
  const documents = join(container, 'Documents')
  const source = join(documents, 'probe.log')
  if (!existsSync(source)) return

  copyFileSync(source, join(detailDir, 'probe.log'))
  const snapshots = readdirSync(documents).filter((item) => /^probe-.*\.png$/.test(item))
  for (const name of snapshots) {
    copyFileSync(join(documents, name), join(detailDir, name))
  }
  // 取走就删：容器不一定会被下一次安装重置，留着会让下一轮把旧日志当成自己的。
  rmSync(source, { force: true })
  for (const name of snapshots) rmSync(join(documents, name), { force: true })

  const samples = []
  const content = []
  // 读**取回来的副本**：容器里那份已经删掉了，留着会让下一轮把旧日志当成自己的。
  for (const line of readFileSync(join(detailDir, 'probe.log'), 'utf8').split('\n')) {
    const at = Number(line.split(' ')[0])
    if (!Number.isFinite(at)) continue
    const ink = /(?:^| )ink=([\d.]+)/.exec(line)
    if (ink) samples.push({ at, ink: Number(ink[1]) })
    const value = /(?:^| )content=([\d.]+)/.exec(line)
    if (value) content.push(Number(value[1]))
  }
  if (!samples.length) return

  // 相邻 0.7 秒内的空白算一段：偶发的一两帧抖动不算，用户看到的是"白了一片"。
  const episodes = []
  for (const sample of samples.filter((item) => item.ink < 0.12)) {
    const last = episodes[episodes.length - 1]
    if (last && sample.at - last.to <= 0.7) last.to = sample.at
    else episodes.push({ from: sample.at, to: sample.at })
  }
  // 单帧不算：页面切换、回前台的第一帧都会让采样区短暂为空，而用户看到的"跳白"
  // 是持续好几秒的那种（2026-09-20 复现时是 12.5–13.0s、27.3–41.7s）。
  // 0.5 秒（够 2 个采样点）以上才算一段，否则判定会被过渡帧刷成假阳性。
  const meaningful = episodes.filter((item) => item.to - item.from >= 0.5)
  const describe = meaningful.map((item) => `${item.from.toFixed(1)}s–${item.to.toFixed(1)}s`).join('、')
  const ignored = episodes.length - meaningful.length
  verdicts.push({
    seq: -3, id: 'probe.blank', kind: 'probe',
    status: meaningful.length ? 'fail' : 'pass',
    detail: meaningful.length
      ? `会话区白过 ${meaningful.length} 段（${describe}）；现场图见 detail/probe-*-blank*.png`
      : `探针 ${samples.length} 个采样点里会话区墨迹最低 ${Math.min(...samples.map((s) => s.ink)).toFixed(3)}，没有变白`
        + (ignored ? `（另有 ${ignored} 段单帧过渡空白，不计）` : ''),
  })
  // 启动那几拍的内容高度是 1pt（会话还没折进来），不参与统计。
  const grown = content.filter((value) => value > 500)
  if (grown.length) {
    const sorted = [...grown].sort((a, b) => a - b)
    const median = sorted[Math.floor(sorted.length / 2)]
    const worst = sorted[sorted.length - 1]
    verdicts.push({
      seq: -4, id: 'probe.estimate', kind: 'probe', status: 'pass',
      detail: `转写内容高度中位 ${median.toFixed(0)}pt、最大 ${worst.toFixed(0)}pt`
        + (median > 0 && worst > median * 4
            ? `（最大是中位的 ${(worst / median).toFixed(1)} 倍：滚动几何在估算与实测之间来回跳）`
            : '（稳定）'),
    })
  }
  void log
}

/// Brings the evidence out of the result bundle and files it under the names the
/// case asked for.
function exportScreenshots({ resultBundle, shotsDir, manifest }) {
  const target = join(shotsDir, '..', 'detail', 'attachments')
  rmSync(target, { recursive: true, force: true })
  try {
    run('xcrun', ['xcresulttool', 'export', 'attachments', '--path', resultBundle,
                  '--output-path', target], { quiet: true })
  } catch (error) {
    warn(`截图导出失败：${error.message.split('\n')[0]}`)
    return
  }

  let listed = []
  try {
    listed = JSON.parse(readFileSync(join(target, 'manifest.json'), 'utf8'))
  } catch {
    warn('导出里没有 manifest.json，无法把截图对回步骤')
    return
  }

  const tidy = (value) => (value ?? '').replace(/_\d+_[0-9A-F-]{8,}\.png$/i, '').trim()
  // Keyed by "seq~name": the step's sequence is unique within a run, while a
  // name is not (a case may ask for "settings" on two different steps). XCTest
  // appends its own suffix to an attachment name, so the label is a prefix.
  const byRequest = new Map(manifest.filter((entry) => entry.placeholder)
    .map((entry) => [`${entry.seq}~${entry.name}`, entry]))

  for (const group of listed) {
    for (const attachment of group.attachments ?? []) {
      const parts = (attachment.suggestedHumanReadableName ?? '').split('~')
      if (parts[0] !== 'shot') continue
      const [, step, name, note] = parts
      let entry = byRequest.get(`${step}~${name}`)
      if (!entry) {
        // A request whose verdict was overwritten by a passing repeat no longer
        // has an entry; the export itself becomes the source.
        entry = { index: manifest.length + 1, step, name, seq: null, screen: '', do: '',
                  title: '', note: tidy(note), file: null, region: 'body',
                  appearance: 'light', checks: [], verdict: null }
        manifest.push(entry)
        byRequest.set(`${step}~${name}`, entry)
      }
      if (entry.file) continue
      const file = `${String(entry.index).padStart(2, '0')}-${step}-${name}.png`
      writeFileSync(join(shotsDir, file), readFileSync(join(target, attachment.exportedFileName)))
      entry.file = file
      entry.note = tidy(note) || entry.note
    }
  }

  // Filed in step order, so the folder reads in the order a person reviews it.
  manifest.sort((a, b) => Number(a.seq ?? 0) - Number(b.seq ?? 0))
  let next = 0
  for (const entry of manifest) {
    delete entry.placeholder
    if (!entry.file) continue
    next += 1
    const wanted = `${String(next).padStart(2, '0')}-${entry.step}-${entry.name}.png`
    if (wanted !== entry.file && existsSync(join(shotsDir, entry.file))) {
      rmSync(join(shotsDir, wanted), { force: true })
      writeFileSync(join(shotsDir, wanted), readFileSync(join(shotsDir, entry.file)))
      rmSync(join(shotsDir, entry.file), { force: true })
    }
    entry.file = wanted
    entry.index = next
  }
  rmSync(target, { recursive: true, force: true })
}

/// Signs in to the host the way the app does, for the calls a run has to make
/// outside the app: creating its scratch session, and cleaning up after.
async function hostSession(live) {
  const exchange = await fetch(`http://127.0.0.1:${live.port}/?token=${live.token}`, { redirect: 'manual' })
  const cookie = (exchange.headers.getSetCookie?.() ?? [])[0]?.split(';')[0]
  const call = async (method, args) => {
    const response = await fetch(`http://127.0.0.1:${live.port}/api/${method}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', cookie },
      body: JSON.stringify({ type: 'client-request', rpcId: `run${Date.now()}`,
                             method, payload: { args } }),
    })
    const body = await response.json()
    if (!body.result?.ok) throw new Error(`${method}: ${JSON.stringify(body.result?.error)}`)
    return body.result.value
  }
  return { call }
}

/// Creates the session a case works on, in its own directory.
async function createScratchSession(live, directory) {
  const { call } = await hostSession(live)
  const created = await call('session/create', { request: { cwd: directory, agentPreset: 'standard' } })
  return created?.sessionId ?? null
}

/// Deletes every session whose working directory is the scratch one, plus the
/// workspace registration the app made for it.
///
/// Both the raw and the canonical spelling of the directory are matched: the
/// host canonicalizes a path when it registers a workspace (a `/tmp` scratch
/// directory is stored as `/private/tmp`), so a cleanup that only knew the path
/// it was handed silently left behind exactly what the case created. The
/// registration matters for the same reason — the desktop sidebar shows every
/// workspace, so a leftover one is an empty group the user has to delete.
async function cleanupScratch(live, directory) {
  const { call } = await hostSession(live)
  const canonical = canonicalPath(directory)
  const wanted = new Set([directory, canonical])
  let ids = []
  try {
    const list = await call('session/list', { _request: {} })
    ids = (list.items ?? []).filter((item) => wanted.has(item.cwd ?? '')).map((item) => item.sessionId)
  } catch { /* fall through: nothing to delete if the list cannot be read */ }

  const projcache = join(homedir(), '.dsh', 'storages', 'session_projcache', 'sessions')
  for (const id of ids) {
    // Best effort: this host ignores the un-archive flag, so the id may stay in
    // the archived set as a pointer to nothing. The files are what matter.
    await call('workspace/archiveSession', { request: { sessionId: id, archived: false } }).catch(() => {})
    for (const dir of readdirSync(join(homedir(), '.dsh', 'sessions'))) {
      rmSync(join(homedir(), '.dsh', 'sessions', dir, id), { recursive: true, force: true })
    }
    rmSync(join(projcache, `${id}.json`), { force: true })
  }
  console.log(`    清理了 ${ids.length} 个临时会话`)
  await deleteWorkspacesAt(call, canonical)
}

/// Removes every workspace registration covering one directory.
///
/// Used both after a run (a case that creates a session in an unregistered
/// directory makes the app register it) and to take back a workspace the runner
/// registered itself.
async function deleteWorkspacesAt(call, path) {
  let deleted = 0
  for (const id of workspacesAt(path)) {
    await call('workspace/delete', { request: { workspaceId: id } })
      .then(() => { deleted += 1 })
      .catch(() => {})
  }
  if (deleted) console.log(`    清理了 ${deleted} 个临时工作区登记`)
}

/// The workspace registrations covering one directory.
///
/// Read from the registry's own file rather than the Remote API: the workspace
/// inventory is only served on a stream endpoint, and a cleanup that has to
/// open a mux connection is not worth the ceremony — this file is the same one
/// the projcache deletions above already touch.
function workspacesAt(path) {
  const file = join(homedir(), '.dsh', 'storages', 'workspace.json')
  try {
    const doc = JSON.parse(readFileSync(file, 'utf8'))
    return Object.entries(doc.tables?.workspaces ?? {})
      .filter(([, record]) => record.path === path)
      .map(([id]) => id)
  } catch {
    return []
  }
}

/// A directory path as the host would store it.
function canonicalPath(path) {
  try { return realpathSync(path) } catch { return path }
}

/// Runs a case, optionally over the relay channel, and always cleans up.
///
/// The pairing is deliberately owned here rather than by the app: a pairing code
/// is one-time, so whoever claims it is the only party that learns the device
/// id — and a device nobody can name is a device nobody can revoke. Letting the
/// app claim left a `DSH-Test` row on the relay after every simulator run; the
/// runner now pairs before the run and revokes in a `finally`, so the user's
/// device list only ever holds their real phones.
///
/// The `finally` only covers *this* run. A run killed mid-flight (Ctrl-C, a
/// crash, the machine sleeping) can still strand its own row, and a pairing made
/// outside the runner strands its own the same way — so every relay run first
/// sweeps what a previous one left behind (scripts/dev/relay-devices.mjs).
/// Nobody cleans the device list by hand, and the sweep's own throwaway pairing
/// revokes itself.
export async function execute(flags = {}, positional = []) {
  const wantsRelay = process.env.DSH_CONNECT === 'relay'
  if (!wantsRelay) return runCase(flags, positional, null)

  log('清扫上一轮遗留的调试配对设备')
  const swept = spawnSync('node', [join(ROOT, 'scripts', 'dev', 'relay-devices.mjs'), 'sweep'], { encoding: 'utf8' })
  if (swept.status === 0) {
    for (const line of swept.stdout.trim().split('\n')) console.log(`    ${line}`)
  } else {
    // Never fatal: a sweep that cannot run must not stop the case, and its own
    // failure mode (nothing swept) is the status quo this replaces.
    warn(`清扫没跑成：${(swept.stderr || swept.stdout || '').trim().split('\n').slice(-1)[0]}`)
  }

  log('配对仿真器设备（跑完撤销）')
  const pairing = await pairDevice()
  console.log(`    device=${pairing.deviceId} name=DSH-Test（${pairing.agentName}）`)
  try {
    return await runCase(flags, positional, pairing)
  } finally {
    try {
      await revokeDevice(pairing)
      console.log(`    已撤销配对设备 ${pairing.deviceId}`)
    } catch (error) {
      // Loud, because the whole point is not to leave one behind: if this fails
      // the row stays visible in the user's device list until they revoke it.
      warn(`配对设备 ${pairing.deviceId} 撤销失败：${error.message}`)
      // Second net, by name rather than by token: whatever made the token
      // unusable (it has happened once, with a 401 on a token the relay itself
      // issued ten minutes earlier), the row is addressable by its `DSH-` name.
      const swept = spawnSync('node', [join(ROOT, 'scripts', 'dev', 'relay-devices.mjs'), 'sweep'], { encoding: 'utf8' })
      const output = `${swept.stdout || ''}${swept.stderr || ''}`.trim().split('\n').slice(-2).join('；')
      if (swept.status === 0) warn(`已改用按名字清扫：${output}`)
      else warn(`按名字清扫也没跑成：${output}——请在手机上撤销这一行`)
    }
  }
}

async function runCase(flags, positional, pairing) {
  const casePath = positional[0] ?? join(ROOT, DEFAULT_CASE)
  if (!existsSync(casePath)) throw new Error(`找不到用例文件 ${casePath}`)
  const simId = flags.sim ?? DEFAULT_SIM
  const runId = flags.run && flags.run !== true ? flags.run : stamp()
  const { runDir, shotsDir, detailDir } = ensureRunDir(runId)
  // The record of one execution, not a pile: an earlier run's pictures under a
  // name this run also uses are indistinguishable from this run's.
  for (const dir of [shotsDir, join(runDir, 'annotated'), detailDir]) rmSync(dir, { recursive: true, force: true })
  ensureRunDir(runId)

  log('读取本机 DSH 端点')
  const live = host()
  console.log(`    port=${live.port} (${live.source})`)

  log('挑选只读会话')
  let sessionId = await pickSession(live)
  let pickedSession = sessionId
  console.log(`    session=${sessionId || '（无，转写页会跳过）'}`)

  // A case that archives or creates sessions says so in its front matter; it
  // then works on a session made for the run, deleted afterwards. Real history
  // is never the subject of an experiment.
  const meta0 = caseMeta(readFileSync(casePath, 'utf8'))
  const scratch = typeof meta0['临时目录'] === 'string' ? meta0['临时目录'].trim() : ''
  // A case that verifies what happens to an archived session should not also
  // have to perform the archiving: the swipe is its own case. This lets the
  // runner set the state up instead.
  const preArchive = (meta0['预置归档'] ?? '').trim() === '是'
  // A case about starting a session inside an *existing* workspace needs one to
  // exist, and it must not be one of the user's: the runner registers a scratch
  // directory and takes the registration back afterwards.
  const scratchWorkspace = typeof meta0['临时工作区'] === 'string' ? meta0['临时工作区'].trim() : ''
  let scratchSession = null
  if (scratch) {
    mkdirSync(scratch, { recursive: true })
    scratchSession = await createScratchSession(live, scratch)
    sessionId = scratchSession ?? sessionId
    console.log(`    临时会话 ${sessionId}（目录 ${scratch}）`)
    if (preArchive && sessionId) {
      const { call } = await hostSession(live)
      await call('workspace/archiveSession', { request: { sessionId } })
      console.log('    已按用例要求预置为归档状态')
    }
  }
  // A case can name the session it needs, instead of taking the runner's pick.
  //
  // The pick is "the session with the most history", which is a *size*: it
  // cannot find a session in a particular state — one holding a pending
  // question, say — and such a state is exactly what some cases are about.
  // Anything the runner itself created (a scratch session) yields to an
  // explicit name.
  const named = typeof meta0['会话'] === 'string' ? meta0['会话'].trim() : ''
  if (named) {
    sessionId = named
    pickedSession = named
    console.log(`    用例指定的会话 ${named}`)
  }
  if (scratchWorkspace) {
    mkdirSync(scratchWorkspace, { recursive: true })
    const { call } = await hostSession(live)
    const value = await call('workspace/create', { request: { path: scratchWorkspace } })
    console.log(`    临时工作区 ${value?.workspace?.workspaceId ?? '?'}`
                + `（${value?.workspace?.path ?? scratchWorkspace}，新建 ${value?.created === true}）`)
  }

  if (!flags['no-build']) {
    log('编译 App 与用例引擎（增量）')
    const result = build(simId)
    console.log(result.skipped ? '    产物已是最新' : `    编译完成 ${result.seconds.toFixed(1)}s`)
  }

  log('生成执行计划')
  const caseText = readFileSync(casePath, 'utf8')
  // Instructions live beside the case, same stem: the case stays prose, the
  // steps file stays mechanical, and step N of one lines up with step N of the
  // other.
  const stepsPath = casePath.replace(/\.md$/, '.steps')
  if (!existsSync(stepsPath)) {
    throw new Error(`${casePath} 缺少同名的指令文件 ${stepsPath.split('/').pop()}`)
  }
  // `DSH_CONNECT=relay` runs the case over the product's own channel instead of
  // the DEBUG direct link. Some surfaces only exist there — the paired-device
  // list is rendered from a relay carrier and cannot appear on a direct one — so
  // a case that checks them has to be run this way. The credential was paired at
  // the top of `execute`; the link carries it so the app does not have to trade
  // the one-time code itself (that is what made the device unrevokable).
  const connectUrl = pairing ? claimedRelayLink(pairing) : live.url
  const plan = buildPlan({ casePath, caseText, stepsText: readFileSync(stepsPath, 'utf8'),
                           runId, bundleId: 'com.jayanttang.dsh', sessionId,
                           pickedSession, connectUrl, screens })
  // A screen may carry its own anchor (a report names its own title); otherwise
  // the page table decides.
  for (const screen of plan.screens) screen.root ||= screens[screen.id]?.root ?? ''
  writeFileSync(join(BUILD, 'plan.json'), JSON.stringify(plan, null, 2))
  writeFileSync(join(detailDir, 'plan.json'), JSON.stringify(plan, null, 2))
  const stepCount = plan.screens.reduce((total, screen) => total + screen.steps.length, 0)
  console.log(`    ${plan.screens.length} 个页面 / ${stepCount} 个步骤`)
  if (flags['plan-only']) {
    console.log(JSON.stringify(plan, null, 2))
    return { runId, runDir, plan, planOnly: true }
  }

  log('准备仿真器')
  bootSimulator(simId)
  installRunner(simId)
  stagePlan(simId, plan)

  log('执行用例')
  const resultBundle = join(detailDir, 'result.xcresult')
  rmSync(resultBundle, { recursive: true, force: true })
  const manifest = []
  const verdicts = []
  const stepWishes = {}
  /// Steps already announced in this run, so a repeat of the test replaces its
  /// own announcement instead of appending another copy.
  const announced = new Set()
  let currentScreen = ''

  /// The app is a separate process: it can crash, or a stray gesture can send it
  /// to the background, and either makes the following assertions fail for a
  /// reason that has nothing to do with what the case is checking.
  const checkAppState = (name, state) => {
    if (!state || state === 'runningForeground') return
    verdicts.push({ seq: -2, id: `app.${name}`, kind: 'app', status: 'fail',
                    detail: `App 不在前台（${state}），这一屏的判定不可信` })
    warn(`App 不在前台（${state}）—— 这一屏的判定不可信`)
  }

  const drain = () => {
    const lines = readEvents(simId).split('\n')
    for (const line of lines.slice(0, -1)) {
      if (!line.trim()) continue
      let event
      try { event = JSON.parse(line) } catch { continue }

      if (event.event === 'screen') { currentScreen = event.id; continue }

      if (event.event === 'verdict' && event.kind === 'screen'
          && event.status !== 'pass' && event.id
          && !manifest.some((entry) => entry.step === event.id && entry.name === 'screen-failed')) {
        // Registered before the dedupe below, which may drop this verdict when a
        // repeat of the test succeeds: a picture of what went wrong is worth
        // keeping either way.
        manifest.push({ index: manifest.length + 1, step: event.id, name: 'screen-failed',
                        seq: event.seq, screen: currentScreen, do: 'screen',
                        title: `未到达的页面：${currentScreen}`, note: event.detail,
                        file: null, region: 'body', appearance: 'light', checks: [],
                        verdict: 'fail', placeholder: true })
      }

      if (event.event === 'step') {
        stepWishes[event.id] = { screen: currentScreen, title: event.title,
                                 checks: event.checks ?? [], verdict: null }
        // A repeat of the test announces the same step again; only the last
        // announcement describes the run being reported.
        const key = `${event.seq}~${event.id}`
        if (announced.has(key)) {
          for (let at = manifest.length - 1; at >= 0; at -= 1) {
            if (String(manifest[at].seq) === String(event.seq) && manifest[at].step === event.id) {
              manifest.splice(at, 1)
            }
          }
        }
        announced.add(key)
        for (const shot of event.shots ?? []) {
          manifest.push({ index: manifest.length + 1, step: event.id, name: shot.name,
                          seq: String(event.seq), screen: currentScreen, do: event.do,
                          title: event.title, note: shot.note, file: null,
                          region: 'body', appearance: 'light',
                          checks: event.checks ?? [], verdict: null, placeholder: true,
                          expect: event.expect ?? [] })
        }
      }

      if (event.event === 'verdict') {
        const previous = verdicts.findIndex((item) => item.seq === event.seq && item.id === event.id)
        if (previous >= 0) verdicts.splice(previous, 1)
        verdicts.push(event)
        if (stepWishes[event.id]) stepWishes[event.id].verdict = event.status
        if (event.kind === 'screen') checkAppState(currentScreen, event.app)
        const mark = { pass: '\x1b[32m✓\x1b[0m', fail: '\x1b[31m✗\x1b[0m',
                       blocked: '\x1b[33m–\x1b[0m' }[event.status] ?? '·'
        console.log(`    ${mark} ${event.id || event.seq}  ${event.detail}`)
      }
    }
  }

  const child = spawn('xcodebuild', ['-project', join(PROJECT, 'DSHMobile.xcodeproj'),
    '-scheme', 'DSHMobile', '-configuration', 'Debug',
    '-destination', `platform=iOS Simulator,id=${simId}`, '-derivedDataPath', DERIVED,
    '-resultBundlePath', resultBundle, 'test-without-building',
    '-only-testing:DSHMobileUITests/Engine'],
    { env: { ...process.env, DSH_RUN: runId }, stdio: ['ignore', 'inherit', 'inherit'] })
  const startedAt = new Date()
  const tailer = setInterval(drain, 150)
  const exitCode = await new Promise((done) => child.on('close', done))
  const seconds = (new Date() - startedAt) / 1000
  clearInterval(tailer)
  drain()
  writeFileSync(join(detailDir, 'events.ndjson'), readEvents(simId))

  analyzeProbe({ simId, detailDir, verdicts, log })

  exportScreenshots({ resultBundle, shotsDir, manifest })
  for (const entry of manifest) {
    if (entry.verdict) continue
    const verdict = [...verdicts].reverse().find((item) => item.seq === entry.seq)
    entry.verdict = verdict?.status ?? stepWishes[entry.step]?.verdict ?? null
  }

  const checks = [...new Set(manifest.flatMap((entry) => entry.checks))]
  let pixel = { ok: true, results: [] }
  if (checks.length) {
    log(`像素核对：${checks.join(', ')}`)
    try {
      pixel = JSON.parse(run('node', [join(HERE, 'verify.mjs'),
        '--shots', shotsDir, '--manifest', JSON.stringify(manifest), '--checks', checks.join(','),
        '--theme', join(PROJECT, 'DSHMobile/Design/DSHTheme.swift')], { quiet: true }))
      writeFileSync(join(detailDir, 'verify.json'), JSON.stringify(pixel, null, 2))
      for (const item of pixel.results) {
        const mark = item.ok ? '\x1b[32m✓\x1b[0m' : '\x1b[31m✗\x1b[0m'
        console.log(`    ${mark} ${item.file} ${item.check}：${item.detail}`)
        const entry = manifest.find((candidate) => candidate.file === item.file)
        if (entry && !item.ok) (entry.findings ??= []).push(item)
      }
    } catch (error) {
      warn(`像素核对失败：${error.message}`)
    }
  }

  const tidy = (value) => (value ?? '').replace(/_\d+_[0-9A-F-]{8,}\.png$/i, '').trim()
  for (const entry of manifest) { entry.title = tidy(entry.title); entry.note = tidy(entry.note) }

  log('标注截图')
  try {
    const annotatedDir = join(runDir, 'annotated')
    mkdirSync(annotatedDir, { recursive: true })
    run(join(TEST_DIR, '.venv/bin/python'), [join(HERE, 'annotate.py'), '--shots', shotsDir,
      '--out', annotatedDir, '--manifest', JSON.stringify(manifest),
      '--meta', JSON.stringify({ run: runId, case: plan.case, title: plan.caseTitle,
                                 commit: gitCommit(), appVersion: appVersion() })],
      { quiet: true })
    console.log(`    ${readdirSync(annotatedDir).length} 张`)
  } catch (error) {
    warn(`标注失败（原图仍在 shots/）：${error.message}`)
  }

  const meta = caseMeta(caseText)
  // The case's own definition of done. Without it a reader can only guess which
  // verdicts would have been acceptable, and the tester is free to grade on a
  // curve — which is exactly what the contract exists to stop.
  const criteria = String(meta['通过判据'] ?? '').split(/[／|;]/).map((part) => part.trim()).filter(Boolean)
  const verdict = verdicts.some((item) => item.status === 'fail')
    ? 'FAIL'
    : verdicts.length === 0 || exitCode !== 0 ? 'ERROR' : 'PASS'
  const summary = {
    run: runId,
    case: plan.case,
    caseTitle: plan.caseTitle,
    caseVersion: plan.caseVersion,
    caseFile: casePath.startsWith(ROOT) ? casePath.slice(ROOT.length + 1) : casePath,
    at: startedAt.toISOString(),
    durationSeconds: Math.round(seconds * 10) / 10,
    engineVerdict: verdict,
    pixelOk: pixel.ok,
    xcodeExit: exitCode,
    host: { port: live.port, source: live.source },
    simulator: simId,
    environment: environmentFacts(simId),
    appVersion: appVersion(),
    appBuild: appBuild(),
    gitCommit: gitCommit(),
    criteria,
    verdicts,
    screenshots: manifest,
    meta,
  }
  if (scratch || scratchWorkspace) {
    // Put anything the run archived back, then remove every session that lives
    // in the scratch directory — including ones the run created through the app
    // — and the workspace registration it made for that directory.
    const directory = scratch || scratchWorkspace
    await cleanupScratch(live, directory)
    console.log('    临时会话与工作区已清理')
  }
  writeFileSync(join(runDir, 'summary.json'), JSON.stringify(summary, null, 2))
  const failing = verdicts.filter((item) => item.status !== 'pass').length
  log(`结果写入 test/runs/${runId}/（引擎判定 ${verdict}${failing ? `，${failing} 项未通过` : ''}）`)
  return { runId, runDir, plan, summary }
}

// Called directly, as well as through `dsh.mjs run`.
if (import.meta.url === `file://${process.argv[1]}`) {
  const { flags, positional } = parseArgs()
  execute(flags, positional).catch((error) => { warn(error.message); process.exit(2) })
}
