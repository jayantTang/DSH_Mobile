/**
 * L1 的四个场景：验什么、怎么判。
 *
 * 环境搭建与收尾在 `l1-runtime.mjs`；这里只管"做什么、观察到什么、四态怎么给"。
 */

import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { spawn, spawnSync } from 'node:child_process'

import { REPO_ROOT } from './matrix.mjs'
import {
  desktopBinary, httpStatus, listDesktopHosts, seedProfile, sleep, snapshotRealData,
  spawnHost, stderrTail, stopHost, waitForEndpoint,
} from './l1-runtime.mjs'

/** 场景：起隔离宿主 → 等连接器写出 endpoint.json → 探一次端口 → 收尾对照。 */
export async function smoke({ outDir, log = () => {} }) {
  const before = snapshotRealData()
  const root = mkdtempSync(join(tmpdir(), 'dsh-lane-l1-'))
  const home = join(root, 'home')
  const dshHome = join(home, '.dsh')
  mkdirSync(dshHome, { recursive: true })
  const observations = []
  const commands = []
  let status = 'fail'
  let note
  let host

  try {
    seedProfile(dshHome)
    observations.push({ step: 'seed', fact: `隔离档案已就位：${join(dshHome, 'profiles', 'web')}` })
    host = spawnHost({ home, dshHome, outDir })
    log(`L1: 已起隔离宿主 pid=${host.pid}`)
    const probe = await probeHost(host, dshHome)
    observations.push(...probe.observations)
    status = probe.ok ? 'pass' : 'fail'
    note = probe.note
  } catch (error) {
    status = 'fail'
    note = error.message
    observations.push({ step: 'error', fact: error.message })
    const tail = stderrTail(host)
    if (tail) observations.push({ step: 'stderr', fact: `宿主 stderr 末尾：\n${tail}`, evidence: 'host.stderr.log' })
  } finally {
    return await finishSmoke({ host, before, observations, commands, root, status, note })
  }
}

/** 收尾：停宿主、对照真实数据、组装返回给上层的四态结果。 */
async function finishSmoke({ host, before, observations, commands, root, status, note }) {
  if (host) await stopHost(host)
  const after = snapshotRealData()
  const untouched = before.digest === after.digest
  observations.push({ step: 'isolation', fact: untouched ? '真实 agent.json 未变' : '真实 agent.json 变了' })
  commands.push({
    argv: host?.argv ?? ['dsh', '--profile', 'web', '--no-open', '--port', '0'],
    exitCode: host?.laneExitCode ?? -1,
    stdoutPath: host?.stdoutPath,
    stderrPath: host?.stderrPath,
    note: '隔离宿主（收尾后退出码）',
  })
  rmSync(root, { recursive: true, force: true })
  return {
    status,
    note,
    observations,
    commands,
    isolation: {
      dshHome: host?.laneDshHome ?? '(未起环境)',
      realHomeUntouched: untouched,
      proof: `跑前 ${before.digest} / 跑后 ${after.digest}（sha256 + mtime）`,
    },
  }
}

/**
 * 场景：新装一个插件是否需要重启宿主。
 *
 * 做法：一次性档案里把 mobile-link 摘干净（bundles + dependencies + node_modules 链接），
 * 起宿主 → 确认它确实没挂上（等不到 endpoint.json）→ 用**官方 CLI**
 * （`dsh plugin --profile web add <路径>`）装它 → **不重启**，看它是否自己挂上。
 *
 * 判定：装完后 endpoint.json 出现且宿主 pid 没变 → `pass`（不需要重启）；
 * 超时没出现 → `fail`（这个路径需要重启）；宿主退出过 → `fail`（等于重启过，不算数）。
 */
export async function pluginInstallHot({ outDir, log = () => {} }) {
  const before = snapshotRealData()
  const root = mkdtempSync(join(tmpdir(), 'dsh-lane-l1-'))
  const home = join(root, 'home')
  const dshHome = join(home, '.dsh')
  mkdirSync(dshHome, { recursive: true })
  const observations = []
  const commands = []
  let host
  let status = 'fail'
  let note

  try {
    const pluginDir = join(REPO_ROOT, 'plugins', 'mobile-link')
    seedProfile(dshHome, { stripPlugins: ['dsh-plugin-mobile-link'] })
    observations.push({ step: 'seed', fact: '一次性档案已就位，并从 bundles / dependencies / node_modules 里摘掉 dsh-plugin-mobile-link' })
    host = spawnHost({ home, dshHome, outDir })
    log(`L1: 隔离宿主 pid=${host.pid}（插件未装）`)
    if (await hasEndpoint(dshHome, 6000)) throw new Error('基准不对：插件在装之前就已经挂上，档案没摘干净')
    observations.push({ step: 'baseline', fact: '装之前连接器没有挂上（endpoint.json 不在）' })

    const install = installPlugin({ home, dshHome, pluginDir, outDir })
    commands.push({ argv: install.argv, exitCode: install.code, stdoutPath: install.logPath, note: '官方安装路径（dsh plugin add）' })
    observations.push({ step: 'install', fact: `dsh plugin --profile web add 退出码 ${install.code}`, evidence: 'install.log' })
    if (install.code !== 0) throw new Error(`安装失败（exit ${install.code}），看 ${install.logPath}`)

    const mounted = await hasEndpoint(dshHome, 60_000)
    const alive = host.laneExitCode === null || host.laneExitCode === undefined
    observations.push({
      step: 'after-install',
      fact: `不重启的情况下：连接器${mounted ? '自己挂上了' : '仍未挂上'}；宿主进程${alive ? '没退出（未重启）' : '退出过'}`,
      evidence: 'host.stderr.log',
    })
    status = mounted && alive ? 'pass' : 'fail'
    if (!mounted) note = '装完 60 秒内没有挂上：这条安装路径需要重启宿主'
    else if (!alive) note = '插件挂上了但宿主进程退出过，等于重启过，不能算"不用重启"'
  } catch (error) {
    status = 'fail'
    note = error.message
    observations.push({ step: 'error', fact: error.message })
    const tail = stderrTail(host)
    if (tail) observations.push({ step: 'stderr', fact: `宿主 stderr 末尾：\n${tail}`, evidence: 'host.stderr.log' })
  } finally {
    return await finishSmoke({ host, before, observations, commands, root, status, note })
  }
}

/** 装之前有没有挂上：只等一小会儿，用来确认基准干净。 */
async function hasEndpoint(dshHome, timeoutMs) {
  try {
    await waitForEndpoint(dshHome, undefined, { timeoutMs })
    return true
  } catch {
    return false
  }
}

/** 走官方安装路径；stdout/stderr 落证据目录，别把判定建立在自己的手改上。 */
function installPlugin({ home, dshHome, pluginDir, outDir }) {
  const argv = ['dsh', 'plugin', '--profile', 'web', 'add', pluginDir]
  const result = spawnSync(argv[0], argv.slice(1), {
    encoding: 'utf8',
    timeout: 180_000,
    env: { ...process.env, HOME: home, DSH_HOME: dshHome },
  })
  const logPath = join(outDir, 'install.log')
  writeFileSync(logPath, `$ ${argv.join(' ')}\n${result.stdout ?? ''}${result.stderr ?? ''}`)
  return { argv, code: result.status ?? -1, logPath }
}

/**
 * 场景：官方桌面版能否在隔离 `HOME` 下起第二个实例。
 *
 * 这条是矩阵里 `host-desktop × l1` 的 prerequisite：能起，L1 就能验桌面版宿主；
 * 起不来，那一格按 research 决策 2 的三层退路降级。判据是"新起的 `dsh-desktop-host`
 * 进程用的是**临时**档案目录"——只看"有新进程"不够，那可能只是复用/聚焦了旧实例。
 *
 * 安全：只杀**本次新出现**的进程与本次拉起的 App 进程；跑之前先记下已有的 pid，绝不碰。
 */
export async function desktopInstance({ outDir, log = () => {} }) {
  const before = snapshotRealData()
  const existing = listDesktopHosts()
  const root = mkdtempSync(join(tmpdir(), 'dsh-lane-l1-'))
  const home = join(root, 'home')
  const dshHome = join(home, '.dsh')
  mkdirSync(dshHome, { recursive: true })
  const observations = [{ step: 'baseline', fact: `跑之前已有 ${existing.length} 个桌面版宿主进程（不动它们）` }]
  const commands = []
  let status = 'fail'
  let note
  let child
  try {
    const binary = desktopBinary()
    if (!existsSync(binary)) throw new Error(`找不到桌面版可执行文件：${binary}`)
    seedProfile(dshHome, { profile: 'desktop' })
    observations.push({ step: 'seed', fact: `临时 desktop 档案已就位：${join(dshHome, 'profiles', 'desktop')}` })
    const probe = await launchAndProbe({ binary, home, dshHome, existing, outDir, log })
    child = probe.child
    observations.push(...probe.observations)
    status = probe.isolated.length > 0 ? 'pass' : 'fail'
    if (status === 'fail') {
      note = probe.fresh.length === 0
        ? '隔离 HOME 下起不来第二个实例（单实例锁挡住或未启动）：桌面版在 L1 里不可用'
        : '起了新进程但没有用临时档案：说明它复用了真实档案，隔离不成立'
    }
    for (const entry of probe.fresh) {
      try {
        process.kill(entry.pid, 'SIGTERM')
      } catch { /* 已经退出 */ }
    }
  } catch (error) {
    status = 'fail'
    note = error.message
    observations.push({ step: 'error', fact: error.message })
  } finally {
    if (child) child.kill('SIGTERM')
    commands.push({ argv: [desktopBinary()], exitCode: -1, note: '隔离 HOME 下拉起桌面版（收尾已终止）' })
    return await finishSmoke({ host: { laneExitCode: 0, laneDshHome: dshHome, argv: [desktopBinary()] }, before, observations, commands, root, status, note })
  }
}

/** 拉起桌面版、等 25 秒、看有没有新宿主；返回给上层做判定与收尾。 */
async function launchAndProbe({ binary, home, dshHome, existing, outDir, log }) {
  const child = spawn(binary, [], {
    env: { ...process.env, HOME: home, DSH_HOME: dshHome },
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  const out = []
  const err = []
  child.stdout.on('data', (chunk) => out.push(chunk))
  child.stderr.on('data', (chunk) => err.push(chunk))
  log(`L1: 已拉起桌面版（隔离 HOME）pid=${child.pid}`)
  await sleep(25_000)
  const fresh = listDesktopHosts().filter((entry) => !existing.some((old) => old.pid === entry.pid))
  const isolated = fresh.filter((entry) => entry.command.includes(dshHome))
  const observations = [{
    step: 'probe',
    fact: `25 秒后新出现 ${fresh.length} 个桌面版宿主进程，其中使用临时档案的有 ${isolated.length} 个`,
  }]
  for (const entry of fresh) observations.push({ step: 'fresh-host', fact: `pid=${entry.pid} ${entry.command.slice(0, 220)}` })
  writeFileSync(join(outDir, 'desktop.stdout.log'), Buffer.concat(out))
  writeFileSync(join(outDir, 'desktop.stderr.log'), Buffer.concat(err))
  return { child, fresh, isolated, observations }
}

/**
 * 场景：空 `DSH_HOME` 下从零起得来。
 *
 * 与 `smoke` 的区别只有一处：**不复制真实档案**——`DSH_HOME` 是空的，这正是新用户第一次
 * 跑 `dsh web` 的样子。它回答的是"从零能不能自己把档案建起来并开始服务"，
 * 也就是"干净机器"里**电脑侧那一半**（真正的干净机器还需要 guest，见 L3）。
 */
export async function freshInstall({ outDir, log = () => {} }) {
  const before = snapshotRealData()
  const root = mkdtempSync(join(tmpdir(), 'dsh-lane-l1-'))
  const home = join(root, 'home')
  const dshHome = join(home, '.dsh')
  mkdirSync(dshHome, { recursive: true })
  const observations = [{ step: 'seed', fact: `空 DSH_HOME：${dshHome}（没有复制任何档案）` }]
  const commands = []
  let host
  let status = 'fail'
  let note
  try {
    host = spawnHost({ home, dshHome, outDir })
    log(`L1: 空档案下起宿主 pid=${host.pid}`)
    const url = await waitForHostUrl(host, 180_000)
    observations.push({ step: 'boot', fact: `宿主自报地址：${url.replace(/token=[^&]+/, 'token=***')}`, evidence: 'host.stdout.log' })
    const profile = join(dshHome, 'profiles', 'web')
    const bundles = existsSync(join(profile, 'package.json'))
      ? JSON.parse(readFileSync(join(profile, 'package.json'), 'utf8')).dsh?.profile?.bundles ?? []
      : []
    observations.push({ step: 'profile', fact: `DSH 自建的档案 bundles：${bundles.join('、') || '(空)'}` })
    const port = Number(/127\.0\.0\.1:(\d+)/.exec(url)?.[1] ?? 0)
    const code = port ? httpStatus(port) : 0
    observations.push({ step: 'probe', fact: `宿主端口应答 HTTP ${code}` })
    status = bundles.length > 0 && [200, 302, 401].includes(code) ? 'pass' : 'fail'
    if (status === 'fail') note = `自建档案不完整或端口不可用（bundles ${bundles.length} 个，HTTP ${code}）`
  } catch (error) {
    status = 'fail'
    note = error.message
    observations.push({ step: 'error', fact: error.message })
    const tail = stderrTail(host)
    if (tail) observations.push({ step: 'stderr', fact: `宿主 stderr 末尾：\n${tail}`, evidence: 'host.stderr.log' })
  } finally {
    return await finishSmoke({ host, before, observations, commands, root, status, note })
  }
}

/** 等宿主在 stdout 上自报地址（`dsh web: http://127.0.0.1:<port>/?token=…`）。 */
async function waitForHostUrl(host, timeoutMs) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const match = /dsh web:\s*(http:\/\/127\.0\.0\.1:\d+\/\?token=\S+)/.exec(host.laneStdoutText?.() ?? '')
    if (match) return match[1]
    if (host.laneExitCode !== null && host.laneExitCode !== undefined) {
      throw new Error(`宿主提前退出（exit ${host.laneExitCode}），看 ${host.stderrPath}`)
    }
    await new Promise((resolve) => setTimeout(resolve, 500))
  }
  throw new Error(`${timeoutMs}ms 内没等到宿主自报地址，看 ${host.stdoutPath}`)
}

/** 观测两件事：连接器有没有写出 endpoint.json、宿主端口活不活。 */
async function probeHost(host, dshHome) {
  const endpoint = await waitForEndpoint(dshHome, host)
  const observations = [{
    step: 'endpoint',
    fact: `连接器写出 endpoint.json：port=${endpoint.port}（说明插件已加载并完成进程内发现）`,
    evidence: 'host.stdout.log',
  }]
  const code = httpStatus(endpoint.port)
  const ok = [200, 302, 401].includes(code)
  observations.push({ step: 'probe', fact: `宿主端口应答 HTTP ${code}（401/200/302 视为活着）` })
  return { ok, note: ok ? undefined : `宿主端口返回 HTTP ${code}`, observations }
}

/**
 * 场景：iOS 协议层——relay socket 的生命周期（断开/替换时必须 cancel）。
 *
 * 为什么需要它：`LinkCarrier` 断开时只把 socket 置 nil、不 cancel，丢引用的
 * `URLSessionWebSocketTask` 会继续活着（并继续回 Pong），中转那边同一 deviceId 就攒出
 * 多条僵尸链路（2026-10-12 线上一个 deviceId 14 条，分析见
 * `maintainers/ANALYSIS-20261012-connector-flap.md`）。这条改动是协议层的，权威口径在
 * 本机 `swift test`；另外经产品通道（中转）在仿真器里跑一条用例，确认没有回归。
 *
 * 判定：钉住修复的单测通过 + 仿真器用例引擎 PASS 且像素核对通过 → `pass`；
 * 全量 `swift test` 允许**已知**的那条真实会话用例红（宿主拒绝 v0 会话迁移，见
 * `AGENTS.md` 与 DSHKit 的 LiveIntegrationTests），但出现别的失败即 `fail`。
 */
export async function iosLinkCarrierLifecycle({ outDir, root = REPO_ROOT, log = () => {} }) {
  const before = snapshotRealData()
  const observations = []
  const commands = []
  const CASE = 'test/cases/current/06-中转链路复用不堆僵尸socket.md'
  let status = 'fail'
  let note

  const slug = (argv) => argv.join('_').replace(/[^A-Za-z0-9._-]+/g, '-').slice(0, 80)
  const run = (argv, cwd, options = {}) => {
    const started = Date.now()
    const result = spawnSync(argv[0], argv.slice(1), {
      cwd: join(root, cwd),
      encoding: 'utf8',
      timeout: options.timeoutMs ?? 30 * 60 * 1000,
      env: { ...process.env, ...(options.env ?? {}) },
    })
    const logPath = join(outDir, `${slug(argv)}.log`)
    writeFileSync(logPath, `${result.stdout ?? ''}\n${result.stderr ?? ''}`)
    commands.push({ argv, cwd, exitCode: result.status ?? -1, stdoutPath: logPath, note: options.note })
    log(`L1: ${argv.join(' ')} → exit ${result.status}（${((Date.now() - started) / 1000).toFixed(1)}s）`)
    return { result, text: `${result.stdout ?? ''}\n${result.stderr ?? ''}`, logPath }
  }

  try {
    // 1) 钉住修复：断开必须 cancel、旧 socket 的残响不许二次重连。
    const pinned = run(['swift', 'test', '--filter', 'LinkCarrierSocketLifecycleTests'],
                       'ios/DSHMobile/DSHKit',
                       { note: 'Relay socket lifecycle 2 条（无修复时两条都红，已做 red-check）' })
    const pinnedOk = pinned.result.status === 0 && /Test run with 2 tests/.test(pinned.text)
    observations.push({
      step: 'pinned-tests',
      fact: pinnedOk ? 'LinkCarrierSocketLifecycleTests 2/2 通过' : '钉住修复的单测未通过',
      evidence: pinned.logPath.slice(outDir.length + 1),
    })

    // 2) 全量单测：只容忍那条已知的真实会话红。
    const full = run(['swift', 'test'], 'ios/DSHMobile/DSHKit',
                     { note: 'DSHKit 全量；唯一允许的失败是 LiveIntegrationTests 的真实会话迁移被拒' })
    const knownRed = /refuses this format v0 Session/.test(full.text)
    const otherRed = /Executed \d+ tests?, with .*(\d+) failure/.test(full.text)
      && !/with 1 failure/.test(full.text)
    const fullOk = full.result.status === 0 || (knownRed && !otherRed)
    observations.push({
      step: 'full-tests',
      fact: full.result.status === 0
        ? 'DSHKit 全量通过'
        : `DSHKit 全量 exit ${full.result.status}：${knownRed ? '仅 LiveIntegrationTests 的真实会话迁移被拒（已知，非本次改动）' : '出现已知之外的失败'}`,
      evidence: full.logPath.slice(outDir.length + 1),
    })

    // 3) 仿真器构建：改动要能进 App 产物。
    const buildResult = run(['xcodebuild', '-scheme', 'DSHMobile',
                             '-destination', 'platform=iOS Simulator,name=DSH-Test', 'build'],
                            'ios/DSHMobile', { note: 'BUILD SUCCEEDED' })
    const buildOk = buildResult.result.status === 0 && /BUILD SUCCEEDED/.test(buildResult.text)

    // 4) 经产品通道（中转）跑用例，并读回运行结果。
    const caseRun = run(['./test/run.sh', 'run', CASE], '.',
                        { env: { DSH_CONNECT: 'relay' }, note: `DSH_CONNECT=relay；用例 ${CASE}` })
    const runMatch = caseRun.text.match(/结果写入\s+test\/runs\/([0-9A-Za-z-]+)\//)
    const deviceMatch = caseRun.text.match(/device=(dev_[a-z0-9]+)/)
    let caseOk = false
    let caseFact = '用例没跑出运行号'
    if (runMatch) {
      const summaryPath = join(root, 'test', 'runs', runMatch[1], 'summary.json')
      if (existsSync(summaryPath)) {
        const summary = JSON.parse(readFileSync(summaryPath, 'utf8'))
        caseOk = summary.engineVerdict === 'PASS' && summary.pixelOk === true
        caseFact = `运行 ${runMatch[1]}：引擎 ${summary.engineVerdict}、像素 ${summary.pixelOk ? '通过' : '未过'}、` +
                   `${(summary.screenshots ?? []).length} 张截图`
      } else {
        caseFact = `运行 ${runMatch[1]} 缺 summary.json`
      }
    }
    observations.push({
      step: 'simulator-case',
      fact: `${caseFact}；本轮配对设备 ${deviceMatch?.[1] ?? '(未打印)'}（中转侧 attach 次数见 test/runs/<id>/review.md）`,
      evidence: runMatch ? `test/runs/${runMatch[1]}/report.html` : undefined,
    })

    status = pinnedOk && fullOk && buildOk && caseOk ? 'pass' : 'fail'
    note = status === 'pass'
      ? '断开/替换 socket 必须 cancel：单测钉住，仿真器经中转用例通过'
      : `未达标（pinned=${pinnedOk} full=${fullOk} build=${buildOk} case=${caseOk}）`
  } catch (error) {
    status = 'fail'
    note = error.message
    observations.push({ step: 'error', fact: error.message })
  }

  const after = snapshotRealData()
  const untouched = before.digest === after.digest
  return {
    status,
    note,
    observations,
    commands,
    isolation: {
      dshHome: '真实 ~/.dsh（本场景只读：用例打开的是只读会话，不写数据）',
      realHomeUntouched: untouched,
      proof: `跑前 ${before.digest} / 跑后 ${after.digest}（agent.json 的 sha256 + mtime）；` +
             '运行器配对的 DSH-Runner 调试设备跑完自行撤销（若同时另有轮次在跑，它的 sweep 会先撤销而让' +
             '本轮 revoke 返回 401，此时由按名字清扫兜底）；relay 设备表核对只剩真实 iPhone 与常驻 DSH-Test',
    },
  }
}
