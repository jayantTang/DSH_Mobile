/**
 * L1 的四个场景：验什么、怎么判。
 *
 * 环境搭建与收尾在 `l1-runtime.mjs`；这里只管"做什么、观察到什么、四态怎么给"。
 */

import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { spawn, spawnSync } from 'node:child_process'

import { REPO_ROOT } from './matrix.mjs'
import {
  desktopBinary, httpStatus, listDesktopHosts, seedProfile, sleep, snapshotRealData,
  spawnHost, stderrTail, stopHost, waitForEndpoint,
} from './l1-runtime.mjs'

/**
 * 场景：Go 中转的单测在本机跑一遍。
 *
 * 为什么它在 L1：`relay-go` 的权威口径是 `make test`（用例自带 `t.TempDir()` 临时库），
 * 本场景额外要证明的只有"跑它们没动真实数据"这一条。构建环境（CGO、缓存目录）由
 * `relay-go/Makefile` 固定，这里不另设变量，避免与 `relay-go/README.md` 的口径分叉。
 */
export async function relayGoTests({ outDir, log = () => {} }) {
  const before = snapshotRealData()
  const observations = []
  const commands = []
  const argv = ['make', 'test']
  let status = 'fail'
  let note

  try {
    const result = spawnSync('make', ['test'], {
      cwd: join(REPO_ROOT, 'relay-go'), encoding: 'utf8', timeout: 900_000, maxBuffer: 64 * 1024 * 1024,
    })
    const logPath = join(outDir, 'relay-go-test.log')
    writeFileSync(logPath, `$ cd relay-go && make test\n${result.stdout ?? ''}${result.stderr ?? ''}`)
    commands.push({ argv, exitCode: result.status ?? -1, stdoutPath: logPath, note: 'Go 中转单测' })
    const summary = (result.stdout ?? '').trim().split('\n')
      .filter((line) => /^(ok|FAIL|---)/.test(line)).slice(-6).join(' / ') || '(没有输出)'
    observations.push({ step: 'go test', fact: `${summary}（exit ${result.status}）`, evidence: 'relay-go-test.log' })
    if (result.status === 0) status = 'pass'
    else note = `make test 退出码 ${result.status}：${summary}`
  } catch (error) {
    note = error.message
    observations.push({ step: 'error', fact: error.message })
  }

  const after = snapshotRealData()
  const untouched = before.digest === after.digest
  observations.push({ step: 'isolation', fact: untouched ? '真实 agent.json 未变' : '真实 agent.json 变了' })
  log(`L1: relay-go 单测 ${status}`)
  return {
    status,
    note,
    observations,
    commands,
    isolation: {
      dshHome: '(go test 只用 t.TempDir()，不碰任何真实档案)',
      realHomeUntouched: untouched,
      proof: `跑前 ${before.digest} / 跑后 ${after.digest}（sha256 + mtime）`,
    },
  }
}

/**
 * 场景：信件服务（mail）的单测在本机跑一遍。
 *
 * 为什么它在 L1：与中转同一条理由（见 lanes.json 的理由列）——mail 的权威口径就是
 * `pytest`，用例全部用 `tmp_path` 建库、不碰真实 `mail.db`；本场景额外证明的只有
 * "跑它们没动真实数据"这一条。`DSH_REQUIRE_CADDY=1` 是仓库自己的硬闸门：
 * 缺 caddy 时 `test_split_runtime.py`（真两服务 + 真 Caddy 的切换演练）会**收集报错**，
 * 而不是静默变成 skip 让绿色变得没有意义。
 */
export async function mailTests({ outDir, log = () => {} }) {
  const before = snapshotRealData()
  const observations = []
  const commands = []
  const venvPython = join(REPO_ROOT, '.venv', 'bin', 'python')
  const python = existsSync(venvPython) ? venvPython : 'python3'
  const argv = [python, '-m', 'pytest', '-q', '-rs']
  let status = 'fail'
  let note

  try {
    const result = spawnSync(python, ['-m', 'pytest', '-q', '-rs'], {
      cwd: join(REPO_ROOT, 'mail'), encoding: 'utf8', timeout: 900_000, maxBuffer: 32 * 1024 * 1024,
      env: { ...process.env, DSH_REQUIRE_CADDY: '1' },
    })
    const logPath = join(outDir, 'mail-pytest.log')
    writeFileSync(logPath, `$ cd mail && DSH_REQUIRE_CADDY=1 ${argv.join(' ')}\n${result.stdout ?? ''}${result.stderr ?? ''}`)
    commands.push({ argv: ['sh', '-c', 'cd mail && DSH_REQUIRE_CADDY=1 ' + argv.join(' ')], exitCode: result.status ?? -1,
      stdoutPath: logPath, note: '信件服务单测（含真 Caddy 的切换演练）' })
    const summary = (result.stdout ?? '').trim().split('\n').filter(Boolean).at(-1) ?? '(没有输出)'
    observations.push({ step: 'pytest', fact: `${summary}（exit ${result.status}）`, evidence: 'mail-pytest.log' })
    const skipped = Number(/(\d+) skipped/.exec(result.stdout ?? '')?.[1] ?? 0)
    if (skipped > 0) {
      observations.push({ step: 'skip', fact: `有 ${skipped} 条 skip：逐条确认不是"Caddy 缺失导致的静默退化"` })
    }
    if (result.status === 0) status = 'pass'
    else note = `pytest 退出码 ${result.status}：${summary}`
  } catch (error) {
    note = error.message
    observations.push({ step: 'error', fact: error.message })
  }

  const after = snapshotRealData()
  const untouched = before.digest === after.digest
  observations.push({ step: 'isolation', fact: untouched ? '真实 agent.json 未变' : '真实 agent.json 变了' })
  log(`L1: mail 单测 ${status}`)
  return {
    status,
    note,
    observations,
    commands,
    isolation: {
      dshHome: '(pytest 只用 tmp_path，不碰任何真实档案)',
      realHomeUntouched: untouched,
      proof: `跑前 ${before.digest} / 跑后 ${after.digest}（sha256 + mtime）`,
    },
  }
}

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
 * 场景：iOS App 逐屏——折叠形态词 / 占位行四态 / 首帧无整块铺开（仿真器经中转）。
 *
 * 为什么需要它：`ios-app × l1 = required` 早就在矩阵里，但 l1 没有"跑 App 逐屏用例"
 * 这个场景，于是 App 侧改动只能拿别的场景（链路握手 / 信件）的旧证据去顶——
 * 2026-10-27/28 两次评审踩的都是这个坑（`check:lanes` 按 lane+status+新鲜度匹配，
 * 不按 scenario 匹配，所以错配的证据它拦不住；见 scripts/verify/README.md）。
 *
 * 覆盖边界（写清，防止被当成"App 改动全保"）：只覆盖**逐屏看得出对错**的那一档——
 * 占位行四态、形态词（`empty/unknown/running/folded` 等）与首帧有没有整块铺开。
 * **不覆盖** D1/D2/D3 的抖动统计：那需要在真实长会话上按 25 s 取探针序列，
 * 本场景的一条用例给不了（详见设计 §12.14 与本文件顶部说明）。
 *
 * 四态怎么给：
 * - 前置缺（没有 xcrun / 没有已启动的仿真器 / 用例文件不在 / 中转设备表读不到）→ `blocked`；
 * - 构建失败、用例引擎不 PASS、像素未过、截图不足、探针缺项 → `fail`；
 * - 全部达标 → `pass`。
 *
 * 用例文件默认 `test/cases/current/131-过程区占位行四态与重试.md`（`test/cases/*` 被 gitignore，
 * 所以"找不到"是常态而不是缺陷）；可用环境变量 `FOLD_L1_CASE` 指向一份等价用例。
 */
export async function iosTranscriptFold({ outDir, root = REPO_ROOT, log = () => {}, env = process.env }) {
  const before = snapshotRealData()
  const observations = []
  const commands = []
  const CASE = String(env.FOLD_L1_CASE ?? 'test/cases/current/131-过程区占位行四态与重试.md').trim()
  let status = 'fail'
  let note
  let blockedReason
  let nextStep

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
    // 0) 前置：缺任何一项都是 blocked（不是 fail——"跑不起来"与"结论为否"必须分开）。
    // 三条探路命令也走 `run()`：证据包的 `commands` 不得为空（blocked 时尤其重要，
    // 它是"跑不起来"的现场）。
    const xcrun = run(['xcrun', '--version'], '.', { note: 'xcrun 可用性', timeoutMs: 60_000 })
    const booted = run(['xcrun', 'simctl', 'list', 'devices', 'booted'], '.',
                       { note: '已启动的仿真器', timeoutMs: 60_000 })
    const devicesList = run(['node', 'scripts/dev/relay-devices.mjs', 'list'], '.',
                            { note: '中转设备表（只读）', timeoutMs: 60_000 })
    const missing = []
    if (xcrun.result.status !== 0) missing.push('xcrun（Xcode 命令行工具）不可用')
    if (booted.result.status !== 0 || !/Booted/.test(booted.text)) missing.push('没有已启动的仿真器')
    if (!existsSync(join(root, CASE))) missing.push(`用例文件 ${CASE} 不在本机`)
    if (devicesList.result.status !== 0) missing.push('读不到中转设备表（`node scripts/dev/relay-devices.mjs list`）')
    observations.push({
      step: 'preconditions',
      fact: missing.length
        ? `前置缺 ${missing.length} 项：${missing.join('；')}`
        : `前置齐备（仿真器已启动、用例 ${CASE} 在本机、中转设备表可读）`,
    })
    if (missing.length) {
      status = 'blocked'
      blockedReason = `App 逐屏用例跑不起来：${missing.join('；')}`
      nextStep = '先 `xcrun simctl boot DSH-Test`（或 `open -a Simulator`）并完成一次中转配对；'
        + '用例文件不在本机时把它复制到 test/cases/current/，或用 FOLD_L1_CASE 指向等价用例'
      note = blockedReason
      throw Object.assign(new Error(blockedReason), { blocked: true })
    }

    // 1) 构建：改动要能进 App 产物。
    const build = run(['xcodebuild', '-scheme', 'DSHMobile',
                       '-destination', 'platform=iOS Simulator,name=DSH-Test', 'build'],
                      'ios/DSHMobile', { note: 'BUILD SUCCEEDED' })
    const buildOk = build.result.status === 0 && /BUILD SUCCEEDED/.test(build.text)
    observations.push({
      step: 'build',
      fact: buildOk ? '仿真器构建成功（BUILD SUCCEEDED）' : '仿真器构建失败',
      evidence: build.logPath.slice(outDir.length + 1),
    })
    if (!buildOk) throw new Error('构建失败')

    // 2) 经产品通道（中转）跑用例。
    const caseRun = run(['./test/run.sh', 'run', CASE], '.',
                        { env: { DSH_CONNECT: 'relay' }, note: `DSH_CONNECT=relay；用例 ${CASE}` })
    const runMatch = caseRun.text.match(/结果写入\s+test\/runs\/([0-9A-Za-z-]+)\//)
    if (!runMatch) {
      const envBroken = /No booted device|xcrun: error|配对|pair\b/i.test(caseRun.text)
      if (envBroken) {
        status = 'blocked'
        blockedReason = '用例跑不起来：运行器报环境问题（无已启动设备 / xcrun 出错 / 配对失败）'
        nextStep = '先 `xcrun simctl boot DSH-Test` 并重跑配对；详见本次 test_run_sh*.log'
        note = blockedReason
        throw Object.assign(new Error(blockedReason), { blocked: true })
      }
      throw new Error('用例没跑出运行号（test/run.sh 输出里没有「结果写入 test/runs/<stamp>/」）')
    }
    const runId = runMatch[1]
    const runDir = join(root, 'test', 'runs', runId)
    observations.push({
      step: 'simulator-case',
      fact: `用例 ${CASE} 跑出运行 ${runId}`,
      evidence: `test/runs/${runId}/report.html`,
    })

    // 3) summary：引擎 PASS + 像素过 + 截图 ≥5。
    const summaryPath = join(runDir, 'summary.json')
    if (!existsSync(summaryPath)) throw new Error(`运行 ${runId} 缺 summary.json`)
    const summary = JSON.parse(readFileSync(summaryPath, 'utf8'))
    const shots = (summary.screenshots ?? []).length
    const summaryOk = summary.engineVerdict === 'PASS' && summary.pixelOk === true && shots >= 5
    observations.push({
      step: 'summary',
      fact: `引擎 ${summary.engineVerdict}、像素 ${summary.pixelOk ? '通过' : '未过'}、${shots} 张截图`
        + (summary.judgementNote ? `（${summary.judgementNote}）` : ''),
      evidence: `test/runs/${runId}/summary.json`,
    })
    if (!summaryOk) {
      throw new Error(`summary 不达标（engine=${summary.engineVerdict} pixel=${summary.pixelOk} shots=${shots}，要求 PASS/true/≥5）`)
    }

    // 4) 探针：整块铺开、形态词、重试终态三条。
    const probePath = join(runDir, 'detail', 'probe.log')
    if (!existsSync(probePath)) throw new Error(`运行 ${runId} 没有 detail/probe.log（跑完了却没有探针本身就是问题）`)
    const probe = readFileSync(probePath, 'utf8')
    const unfolded = probe.split('\n').filter((line) => /(?:^| )anomaly\.unfolded(?: |$)/.test(line))
    const shapeUnknown = /(?:^| )fold\.shape\b[^\n]* shape=unknown(?: |$)/.test(probe)
    const shapeFolded = /(?:^| )fold\.shape\b[^\n]* shape=folded(?: |$)/.test(probe)
    const terminals = probe.split('\n')
      .filter((line) => /(?:^| )process\.unknown\.retry(?: |$)/.test(line))
      .map((line) => (/(?:^| )state=([^ ]*)/.exec(line) ?? [])[1] ?? '')
      .filter((state) => ['unresolved', 'failed:read', 'failed:hole', 'failed:timeout'].includes(state))
    const probeOk = unfolded.length === 0 && shapeUnknown && shapeFolded && terminals.length > 0
    const copy = join(outDir, 'probe.log')
    writeFileSync(copy, probe)
    observations.push({
      step: 'probe',
      fact: `anomaly.unfolded ${unfolded.length} 条；shape=unknown ${shapeUnknown ? '有' : '缺'}；`
        + `shape=folded ${shapeFolded ? '有' : '缺'}；process.unknown.retry 终态 ${terminals.length} 条`,
      evidence: 'probe.log',
    })
    if (!probeOk) {
      throw new Error('探针不达标（要求：无 anomaly.unfolded、出现 shape=unknown 与 shape=folded、'
        + 'process.unknown.retry 有非 resolving 终态）')
    }

    status = 'pass'
    note = 'App 逐屏：占位行四态、形态词与首帧无整块铺开均达标（仿真器经中转）'
  } catch (error) {
    if (error.blocked) {
      // blocked 已在上面的分支里写好 reason/nextStep。
    } else {
      status = 'fail'
      note = error.message
      observations.push({ step: 'error', fact: error.message })
    }
  }

  const after = snapshotRealData()
  const untouched = before.digest === after.digest
  return {
    status,
    note,
    blockedReason,
    nextStep,
    observations,
    commands,
    isolation: {
      dshHome: '真实 ~/.dsh（本场景只读：打开的是夹具会话，不写真实会话数据）',
      realHomeUntouched: untouched,
      proof: `跑前 ${before.digest} / 跑后 ${after.digest}（agent.json 的 sha256 + mtime）；`
        + '运行器配对的 DSH-Runner 调试设备跑完自行撤销；证据包 = verdict.json + xcodebuild/test_run_sh 日志 + test/runs/<stamp>/report.html',
    },
  }
}

/**
 * 场景：iOS 协议层——relay socket 的生命周期（断开/替换时必须 cancel）。
 *
 * 为什么需要它：`LinkCarrier` 断开时只把 socket 置 nil、不 cancel，丢引用的
 * `URLSessionWebSocketTask` 会继续活着（并继续回 Pong），中转那边同一 deviceId 就攒出
 * 多条僵尸链路（2026-10-12 线上一个 deviceId 14 条，分析见
 * `maintainers/20261012-连接器断续分析.md`）。这条改动是协议层的，权威口径在
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
    // 钉住的语义是"那两条 lifecycle 用例必须全过"，不是"套件总数恒为 2"：
    // 后续若给同一套件加用例，断言不该因此变红（2026-10-27 实测：套件已 4 条）。
    const ran = /Test run with (\d+) tests/.exec(pinned.text)
    const pinnedOk = pinned.result.status === 0 && Boolean(ran)
      && Number(ran[1]) >= 2 && !/✘/.test(pinned.text)
    observations.push({
      step: 'pinned-tests',
      fact: pinnedOk
        ? `LinkCarrierSocketLifecycleTests 通过（${ran ? ran[1] : '?'} 条，至少 2 条，无失败）`
        : '钉住修复的单测未通过',
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

/**
 * 场景：三侧诊断（spec 020 / tasks.md T024）。
 *
 * 判什么：**在真实宿主里**（不是单测桩里）隔离起一个 DSH，确认新增的诊断设施真的活着：
 *   1. 连接器在孤立 DSH_HOME 下写出 `mobile-link/link-events.jsonl`，权限 0600；
 *   2. 写进去的 kind **全部**在 `EVENT_KINDS` 词表内（写入侧自检在真实宿主里也成立）；
 *   3. 文件大小在上限内，且 `journal` 的 `.1` 滚动口径不产生第三份文件；
 *   4. 真实 `~/.dsh/mobile-link/agent.json` 未被改动（宪法 III）。
 *
 * 为什么 L1 只能验到这些：隔离宿主没有身份文件（身份在 `$DSH_HOME/mobile-link/agent.json`，
 * 不在 profile 里），于是连接器**不会**去连真中转——这既是安全性质（L1 不会把用户的手机挤下线），
 * 也意味着"App→连接器推送"那一段只能在慢闸用仿真器经中转验（见 quickstart 的 S1/S2）。
 */
export async function linkDiagnostics({ outDir, log = () => {} }) {
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
    const journal = await inspectDiagnosticsJournal({ dshHome, outDir, log })
    observations.push(...journal.observations)
    status = probe.ok && journal.ok ? 'pass' : 'fail'
    note = probe.note ?? journal.note
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

/** 等隔离宿主的连接器写出流水，然后逐条核对（词表、权限、上限）。 */
async function inspectDiagnosticsJournal({ dshHome, outDir, log, timeoutMs = 30_000 }) {
  const { EVENT_KINDS, DEFAULT_MAX_BYTES } = await import('../../plugins/mobile-link/lib/journal.js')
  const directory = join(dshHome, 'mobile-link')
  const path = join(directory, 'link-events.jsonl')
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline && !existsSync(path)) await sleep(500)
  if (!existsSync(path)) {
    return { ok: false, note: `${timeoutMs}ms 内连接器没写出 ${path}`, observations: [
      { step: 'journal', fact: `没等到流水文件：${path}` },
    ] }
  }
  const text = readFileSync(path, 'utf8')
  const copy = join(outDir, 'link-events.jsonl')
  writeFileSync(copy, text)
  const lines = text.split('\n').filter(Boolean)
  const events = []
  const badLines = []
  for (const line of lines) {
    try {
      events.push(JSON.parse(line))
    } catch {
      badLines.push(line)
    }
  }
  const kinds = [...new Set(events.map((event) => event.kind))]
  const unknown = kinds.filter((kind) => !EVENT_KINDS.includes(kind))
  const mode = (statSync(path).mode & 0o777).toString(8)
  const size = statSync(path).size
  const observations = [
    { step: 'journal', fact: `流水已写出：${lines.length} 条事件，${size} 字节，权限 0${mode}`, evidence: 'link-events.jsonl' },
    { step: 'journal', fact: `事件种类：${kinds.join(', ') || '（空）'}` },
  ]
  const problems = []
  if (badLines.length > 0) problems.push(`${badLines.length} 行不是合法 JSON`)
  if (unknown.length > 0) problems.push(`出现词表外的 kind：${unknown.join(', ')}`)
  if (mode !== '600') problems.push(`权限应为 0600，实际 0${mode}`)
  if (size > DEFAULT_MAX_BYTES) problems.push(`单文件超过上限：${size} > ${DEFAULT_MAX_BYTES}`)
  if (events.length === 0) problems.push('一条事件都没有')
  if (existsSync(`${path}.2`)) problems.push('出现了第三份流水文件（滚动口径只该保两代）')
  log(`L1: 诊断流水核完（${events.length} 条，问题 ${problems.length} 处）`)
  return {
    ok: problems.length === 0,
    note: problems.join('；') || undefined,
    observations: [...observations, ...problems.map((problem) => ({ step: 'journal', fact: `不合格：${problem}` }))],
  }
}

/**
 * 场景：DSHKit 协议层单测（`swift test`）。
 *
 * 覆盖 `protocol` 这个被测对象里 DSHKit 的纯函数与契约向量。跳过 `LiveIntegrationTests`：
 * 那条用例吃本机真实会话，选到迁移被拒的会话会红，属于已知环境噪声，不是协议回归；
 * 其余测试必须全绿。`DSH_HOME` 指到临时目录，并在跑前/跑后对照真实 agent.json。
 */
export async function protocolTests({ outDir, log = () => {} }) {
  const before = snapshotRealData()
  const root = mkdtempSync(join(tmpdir(), 'dsh-lane-l1-protocol-'))
  const home = join(root, 'home')
  const dshHome = join(home, '.dsh')
  mkdirSync(dshHome, { recursive: true })
  const observations = []
  const commands = []
  let status = 'fail'
  let note
  let blockedReason
  let nextStep

  const argv = ['swift', 'test', '--skip', 'LiveIntegrationTests']
  try {
    const version = spawnSync('swift', ['--version'], { encoding: 'utf8', timeout: 60_000 })
    commands.push({ argv: ['swift', '--version'], exitCode: version.status ?? -1 })
    if (version.status !== 0) {
      status = 'blocked'
      blockedReason = 'swift 不可用，跑不了 DSHKit 协议层单测'
      nextStep = '安装 Xcode 命令行工具并确认 `swift --version` 可用'
      throw Object.assign(new Error(blockedReason), { blocked: true })
    }

    const started = Date.now()
    const result = spawnSync(argv[0], argv.slice(1), {
      cwd: join(REPO_ROOT, 'ios/DSHMobile/DSHKit'),
      encoding: 'utf8',
      timeout: 15 * 60 * 1000,
      maxBuffer: 32 * 1024 * 1024,
      env: { ...process.env, DSH_HOME: dshHome },
    })
    const logPath = join(outDir, 'protocol-swift-test.log')
    writeFileSync(logPath, `$ cd ios/DSHMobile/DSHKit && ${argv.join(' ')}\n${result.stdout ?? ''}${result.stderr ?? ''}`)
    commands.push({ argv, cwd: 'ios/DSHMobile/DSHKit', exitCode: result.status ?? -1, stdoutPath: logPath,
      note: 'DSHKit swift test（跳过 LiveIntegrationTests）' })
    const summary = (result.stdout ?? '').trim().split('\n').filter(Boolean).at(-1) ?? '(没有输出)'
    observations.push({
      step: 'swift-test',
      fact: `${summary}（exit ${result.status}，${((Date.now() - started) / 1000).toFixed(1)}s）`,
      evidence: 'protocol-swift-test.log',
    })
    if (result.status === 0) status = 'pass'
    else note = `swift test 退出码 ${result.status}：${summary}`
  } catch (error) {
    if (!error.blocked) {
      note = error.message
      observations.push({ step: 'error', fact: error.message })
    }
  }

  const after = snapshotRealData()
  const untouched = before.digest === after.digest
  observations.push({ step: 'isolation', fact: untouched ? '真实 agent.json 未变' : '真实 agent.json 变了' })
  rmSync(root, { recursive: true, force: true })
  log(`L1: DSHKit 协议层单测 ${status}`)
  return {
    status,
    note,
    blockedReason,
    nextStep,
    observations,
    commands,
    isolation: {
      dshHome: `(临时 DSH_HOME: ${dshHome})`,
      realHomeUntouched: untouched,
      proof: `跑前 ${before.digest} / 跑后 ${after.digest}（sha256 + mtime）`,
    },
  }
}

/**
 * 场景：iOS App 单元测试（`DSHMobileTests`，不启动主界面、不截图）。
 *
 * 覆盖 `ios-unit` 这个被测对象；入口与矩阵理由里的 `npm run test:app-unit` 一致。
 * 只跑单测，不替代 `ios-app` 的逐屏核对；`DSH_HOME` 指到临时目录并对照真实 agent.json。
 */
export async function iosUnitTests({ outDir, log = () => {} }) {
  const before = snapshotRealData()
  const root = mkdtempSync(join(tmpdir(), 'dsh-lane-l1-ios-unit-'))
  const home = join(root, 'home')
  const dshHome = join(home, '.dsh')
  mkdirSync(dshHome, { recursive: true })
  const observations = []
  const commands = []
  let status = 'fail'
  let note
  let blockedReason
  let nextStep

  const argv = ['bash', 'scripts/dev/verify-app-unit.sh']
  try {
    const xcrun = spawnSync('xcrun', ['--version'], { encoding: 'utf8', timeout: 60_000 })
    commands.push({ argv: ['xcrun', '--version'], exitCode: xcrun.status ?? -1 })
    if (xcrun.status !== 0) {
      status = 'blocked'
      blockedReason = 'xcrun 不可用，跑不了 iOS App 单元测试'
      nextStep = '安装 Xcode 命令行工具，并准备一台可用的 iPhone 模拟器'
      throw Object.assign(new Error(blockedReason), { blocked: true })
    }

    const started = Date.now()
    const result = spawnSync(argv[0], argv.slice(1), {
      cwd: REPO_ROOT,
      encoding: 'utf8',
      timeout: 20 * 60 * 1000,
      maxBuffer: 32 * 1024 * 1024,
      env: { ...process.env, DSH_HOME: dshHome },
    })
    const logPath = join(outDir, 'ios-unit-tests.log')
    writeFileSync(logPath, `$ ${argv.join(' ')}\n${result.stdout ?? ''}${result.stderr ?? ''}`)
    commands.push({ argv, cwd: '.', exitCode: result.status ?? -1, stdoutPath: logPath,
      note: 'DSHMobileTests（-only-testing，不跑 UI）' })
    const lines = (result.stdout ?? '').trim().split('\n').filter(Boolean)
    const summary = lines.at(-1) ?? '(没有输出)'
    observations.push({
      step: 'xcodebuild-test',
      fact: `exit ${result.status}，${((Date.now() - started) / 1000).toFixed(1)}s；末行：${summary.slice(0, 240)}`,
      evidence: 'ios-unit-tests.log',
    })
    if (result.status === 0) status = 'pass'
    else note = `verify-app-unit.sh 退出码 ${result.status}：${summary}`
  } catch (error) {
    if (!error.blocked) {
      note = error.message
      observations.push({ step: 'error', fact: error.message })
    }
  }

  const after = snapshotRealData()
  const untouched = before.digest === after.digest
  observations.push({ step: 'isolation', fact: untouched ? '真实 agent.json 未变' : '真实 agent.json 变了' })
  rmSync(root, { recursive: true, force: true })
  log(`L1: iOS App 单元测试 ${status}`)
  return {
    status,
    note,
    blockedReason,
    nextStep,
    observations,
    commands,
    isolation: {
      dshHome: `(临时 DSH_HOME: ${dshHome})`,
      realHomeUntouched: untouched,
      proof: `跑前 ${before.digest} / 跑后 ${after.digest}（sha256 + mtime）`,
    },
  }
}
