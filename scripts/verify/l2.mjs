/**
 * L2 Linux 容器渠道。
 *
 * 用途：在 Linux 里起同一套 web 宿主与插件，复核那些"和平台无关但值得再确认一遍"的结论；
 * 它与 CI（干净 Linux runner）同源，命令逐字相同。
 *
 * 两条硬前提（代价与理由见 `specs/006-verify-lanes/research.md` 决策 1）：
 *   1. **代码复制进卷**（`docker cp`），不许用共享挂载——共享挂载不转发 inotify，
 *      会让"文件监听"类结论得到假阴性（`selfcheck` 里的反向对照就是这条的证据）；
 *   2. **镜像拉得到**：本机直连 Docker Hub 超时，`doctor` 会检查镜像源是否配好。
 *
 * 纪律：容器名带 `dsh-lane-l2-` 前缀，跑完一律 `docker rm -f`；卷也删掉，不留痕。
 */

import { spawnSync } from 'node:child_process'
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import { REPO_ROOT } from './matrix.mjs'

const IMAGE = 'node:22-bookworm-slim'
/// relay 单测要 Python 3.12：单独一个镜像，省掉在 node 镜像里装 Python 的那些步骤。
const PYTHON_IMAGE = 'python:3.12-bookworm'
/// caddy 二进制只从官方镜像里取（容器里的 Debian 源不可靠，见 relayTests 里的注释）。
const CADDY_IMAGE = 'caddy:2'
const NAME_PREFIX = 'dsh-lane-l2-'
const VOLUME = 'dsh-lane-l2-data'

export const lane = {
  id: 'l2',
  title: 'Linux 容器',
  isolation: 'Linux guest 内的容器卷；代码复制进卷（docker cp / COPY），不用共享挂载',
  requiresCopyIn: true,
  doctor: doctorL2,
  scenarios: {
    selfcheck: { title: '起容器、复制进卷、卷内有事件而共享挂载没有', run: selfcheck },
    'plugin-install-hot': { title: '复核"新装插件是否需要重启宿主"（容器内）', run: pluginInstallHot },
    'relay-tests': {
      title: '中转单测在干净 Linux 里跑一遍（含真 Caddy 的端到端那半），命令同 CI',
      run: relayTests,
    },
  },
}

/** 自检：CLI 在不在、运行时起没起、镜像源配没配。只报告，不装东西。 */
export function doctorL2({ env = process.env } = {}) {
  const checks = []
  const docker = whichBinary('docker')
  checks.push({
    name: 'docker CLI 在',
    ok: Boolean(docker),
    detail: docker ?? 'PATH 上找不到 docker',
    fix: docker ? undefined : 'brew install colima docker',
  })
  const colima = whichBinary('colima')
  checks.push({
    name: 'colima 在',
    ok: Boolean(colima),
    detail: colima ?? 'PATH 上找不到 colima',
    fix: colima ? undefined : 'brew install colima',
  })
  const info = docker ? spawnSync(docker, ['info', '--format', '{{.ServerVersion}} {{.Architecture}}'], { encoding: 'utf8' }) : undefined
  checks.push({
    name: '容器运行时已启动',
    ok: Boolean(info && info.status === 0),
    detail: info?.stdout?.trim() || info?.stderr?.trim().split('\n')[0] || '未启动',
    fix: 'colima start（默认就是 vz + virtiofs）；起不来先看 colima 自己的输出',
  })
  // 镜像源以 dockerd 自报为准（`docker info`），不去猜配置文件在哪——
  // colima 启动时会重写自己的 colima.yaml，按文件判断会得到假结论。
  const mirrors = docker && info && info.status === 0 ? dockerMirrors(docker) : []
  checks.push({
    name: '镜像源已配置（本机直连 Docker Hub 超时）',
    ok: mirrors.length > 0,
    detail: mirrors[0] ?? 'dockerd 没配 registry-mirrors',
    fix: 'sh scripts/verify/l2-vm-setup.sh（补镜像源与 resolv.conf 后重启 docker；colima 启动会重写 daemon.json，所以每次启动后都要跑）',
  })
  const failed = checks.filter((check) => !check.ok)
  return {
    available: failed.length === 0,
    checks,
    blockedReason: failed.length > 0 ? failed.map((check) => check.name).join('、') : undefined,
    nextStep: failed.length > 0 ? failed.map((check) => check.fix).filter(Boolean).join('；') : undefined,
  }
}

/** 场景一：渠道自检——起容器、复制进卷、卷内有事件、共享挂载没有事件。 */
async function selfcheck({ outDir, log = () => {} }) {
  const observations = []
  const commands = []
  const hostProbe = mkdtempSync(join(tmpdir(), 'dsh-lane-l2-bind-'))
  const name = `${NAME_PREFIX}${process.pid}-${Date.now()}`
  let status = 'fail'
  let note
  try {
    record(commands, observations, ['docker', 'info', '--format', '{{.ServerVersion}} {{.Architecture}}'], outDir, 'docker-info.log')
    startContainer({ name, hostProbe })
    log(`L2: 容器已起 ${name}`)

    const version = exec(name, ['node', '--version'])
    observations.push({ step: 'node', fact: `卷内 node --version → ${version.stdout.trim()}（exit ${version.status}）` })
    if (version.status !== 0) throw new Error('容器内 node 不可用')

    copyRoundTrip({ name, hostProbe, observations })
    const watched = watchInsideVolume(name)
    observations.push({ step: 'volume-watch', fact: `卷内自身写入触发的事件：${watched || '(none)'}` })
    const bindEvents = await watchBindMount({ name, hostProbe })
    observations.push({ step: 'bind-control', fact: `共享挂载上由宿主写入触发的事件：${bindEvents || '(none)'}（预期 none）` })

    const volumeOk = Boolean(watched) && watched !== '(none)'
    const bindOk = !bindEvents || bindEvents === '(none)'
    status = volumeOk && bindOk ? 'pass' : 'fail'
    if (!volumeOk) note = '卷内 fs.watch 收不到事件：这台机器上"复制进卷"的前提不成立'
    else if (!bindOk) note = `共享挂载收到了宿主事件（${bindEvents}）：反向对照不成立，L2 的结论不可信`
  } catch (error) {
    status = 'fail'
    note = error.message
    observations.push({ step: 'error', fact: error.message })
  } finally {
    cleanup({ name, hostProbe })
    return {
      status,
      note,
      observations,
      commands,
      isolation: {
        dshHome: '(容器内 /root/.dsh)',
        realHomeUntouched: true,
        proof: '本场景只碰宿主临时目录与容器；跑完删容器、删卷、删临时目录',
      },
    }
  }
}

/** 场景二：容器里复核"新装插件是否需要重启宿主"（与 L1 同题）。 */
async function pluginInstallHot({ outDir, log = () => {} }) {
  const observations = []
  const commands = []
  const name = `${NAME_PREFIX}${process.pid}-${Date.now()}`
  let status = 'fail'
  let note
  try {
    prepareContainer({ name, commands, observations, log })
    // 记下宿主 pid：后面的"有没有重启"以**同一个 pid 是否还活着**为准。
    // 用 pgrep 匹配命令行是不可靠的——容器里 dsh 装在 /usr/local/bin，argv 与宿主机不一样。
    const boot = exec(name, ['sh', '-c', 'DSH_HOME=/root/.dsh nohup dsh --profile web --no-open --port 0 >/tmp/host.log 2>&1 & echo $! | tee /tmp/host.pid'])
    const hostPid = boot.stdout.trim()
    observations.push({ step: 'boot', fact: `宿主 pid=${hostPid}` })
    const baseline = await waitEndpointInContainer(name, 25_000)
    observations.push({ step: 'baseline', fact: `装之前 endpoint.json ${baseline ? '在（基准不干净）' : '不在'}` })
    if (baseline) throw new Error('基准不干净：新档案里不该已经有连接器')
    const outcome = await installAndObserve({ name, commands, observations, outDir })
    status = outcome.status
    note = outcome.note
    collectLogs(name, outDir, observations)
  } catch (error) {
    status = 'fail'
    note = error.message
    observations.push({ step: 'error', fact: error.message })
    collectLogs(name, outDir, observations)
  } finally {
    cleanup({ name })
    return {
      status,
      note,
      observations,
      commands,
      isolation: {
        dshHome: '(容器内 /root/.dsh：一次性容器，与宿主 ~/.dsh 无关)',
        realHomeUntouched: true,
        proof: '全程在容器里；跑完 docker rm -f 容器与卷，宿主只用到临时目录',
      },
    }
  }
}


/**
 * 场景：把 CI 的 relay 作业在本地容器里跑一遍——同一个镜像家族、同一条命令序列。
 *
 * 为什么值得一份：`test_caddy_runtime.py` 要一个**真的** Caddy 与真的 relay 进程，
 * 本机跑得过不代表干净 Linux 上也一样（依赖、locale、路径都会变）；CI 的判定就写在
 * `.github/workflows/ci.yml` 的 `relay` 作业里，这里逐条照抄，Caddy 缺失时那条用例会
 * **收集报错**（不是静默 skip），所以 `command -v caddy` 那一步不能省。
 */
async function relayTests({ outDir, log = () => {} }) {
  const observations = []
  const commands = []
  const name = `${NAME_PREFIX}${process.pid}-${Date.now()}`
  let status = 'fail'
  let note
  let blockedReason
  let nextStep
  const finish = () => {
    cleanup({ name })
    return {
      status,
      note,
      blockedReason,
      nextStep,
      observations,
      commands,
      isolation: {
        dshHome: '(容器内 /root/.dsh：一次性容器，与宿主 ~/.dsh 无关)',
        realHomeUntouched: true,
        proof: '全程在容器里；跑完 docker rm -f 容器与卷，宿主只用到临时目录',
      },
    }
  }
  const step = (argv, { timeoutMs = 900_000, note: label } = {}) => {
    const result = exec(name, argv, { timeoutMs })
    const text = `${result.stdout ?? ''}${result.stderr ?? ''}`
    const logPath = join(outDir, `container-${commands.length + 1}.log`)
    writeFileSync(logPath, `$ ${argv.join(' ')}\n${text}`)
    commands.push({ argv: ['docker', 'exec', name, ...argv], exitCode: result.status ?? -1,
      stdoutPath: logPath, note: label })
    return { code: result.status ?? -1, text, logPath }
  }
  try {
    const started = spawnSync('docker', ['run', '-d', '--name', name, '-v', `${VOLUME}:/data`, '-w', '/work',
      ...(process.arch === 'arm64' ? ['--platform', 'linux/arm64'] : []), PYTHON_IMAGE, 'sleep', 'infinity'],
      { encoding: 'utf8', timeout: 600_000 })
    if (started.status !== 0) throw new Error(`起容器失败：${tail(started.stderr || started.stdout, 400)}`)
    commands.push({ argv: ['docker', 'run', '-d', '--name', name, '-v', `${VOLUME}:/data`, PYTHON_IMAGE], exitCode: 0 })
    log(`L2: 容器已起 ${name}（${PYTHON_IMAGE}）`)
    observations.push({ step: 'container', fact: `${PYTHON_IMAGE}，代码稍后 docker cp 进 /work` })

    const pythonVersion = step(['python3', '--version'], { timeoutMs: 60_000, note: '容器内 Python 版本' })
    observations.push({ step: 'python', fact: `${pythonVersion.text.trim()}（exit ${pythonVersion.code}）` })

    // Caddy 不走 apt：容器里的 Debian 源在本机网络下会挂住（实测卡 16 分钟），
    // 而官方镜像拉得动。从镜像里把二进制抠出来放进测试容器，比装一个包可靠得多。
    // `command -v caddy && caddy version` 是硬要求：没有它，那五条端到端用例会静默变成 skip
    // （仓库自己的闸门 `DSH_REQUIRE_CADDY` 会在收集期直接报错，见下面 pytest 那条命令）。
    const caddyName = `${NAME_PREFIX}caddy-${process.pid}-${Date.now()}`
    const caddyHostPath = join(outDir, 'caddy-binary')
    try {
      const create = spawnSync('docker', ['create', '--name', caddyName, '--platform', 'linux/arm64', CADDY_IMAGE],
        { encoding: 'utf8', timeout: 900_000 })
      if (create.status !== 0) throw new Error(`拉/建 ${CADDY_IMAGE} 失败：${tail(create.stderr || create.stdout, 300)}`)
      commands.push({ argv: ['docker', 'create', '--name', caddyName, CADDY_IMAGE], exitCode: 0,
        note: '只为从镜像里取 caddy 二进制' })
      const extract = spawnSync('docker', ['cp', `${caddyName}:/usr/bin/caddy`, caddyHostPath],
        { encoding: 'utf8', timeout: 120_000 })
      if (extract.status !== 0) throw new Error(`从镜像取 caddy 失败：${tail(extract.stderr, 300)}`)
      const into = spawnSync('docker', ['cp', caddyHostPath, `${name}:/usr/local/bin/caddy`],
        { encoding: 'utf8', timeout: 120_000 })
      if (into.status !== 0) throw new Error(`把 caddy 放进容器失败：${tail(into.stderr, 300)}`)
      commands.push({ argv: ['docker', 'cp', `${CADDY_IMAGE}:/usr/bin/caddy`, `${name}:/usr/local/bin/caddy`],
        exitCode: 0, note: 'caddy 二进制进容器（不用 apt）' })
    } finally {
      spawnSync('docker', ['rm', '-f', caddyName], { encoding: 'utf8', timeout: 60_000 })
    }
    const caddyCheck = step(['sh', '-c', 'chmod 0755 /usr/local/bin/caddy && command -v caddy && caddy version'],
      { timeoutMs: 120_000, note: '确认 caddy 在 PATH 上' })
    observations.push({ step: 'caddy', fact: `caddy 就位：${caddyCheck.text.trim().split('\n')[0] || '(无输出)'}（exit ${caddyCheck.code}）` })
    if (caddyCheck.code !== 0) {
      status = 'blocked'
      blockedReason = `容器里没有可用的 caddy（exit ${caddyCheck.code}）：${tail(caddyCheck.text, 300)}`
      nextStep = '检查本机能否拉取 caddy 镜像；或在 CI 上跑（.github/workflows/ci.yml 的 relay 作业逐条相同）'
      return finish()
    }

    // 复制的不只是 `relay/`：`tests/test_dlp_contract.py` 要读仓库里的两份契约
    // （`docs/relay-contract.json` 与 `test/contract/dlp-vectors.json`），少一份就是收集期报错。
    const copied = []
    for (const [source, target] of [
      ['relay', '/work/relay'],
      ['docs', '/work/docs'],
      [join('test', 'contract'), join('/work/test', 'contract')],
    ]) {
      const result = spawnSync('docker', ['exec', name, 'mkdir', '-p', target],
        { encoding: 'utf8', timeout: 60_000 })
      if (result.status !== 0) throw new Error(`容器内建目录失败：${target}`)
      const copy = spawnSync('docker', ['cp', join(REPO_ROOT, source) + '/.', `${name}:${target}`],
        { encoding: 'utf8', timeout: 600_000 })
      if (copy.status !== 0) throw new Error(`docker cp ${source} 失败：${tail(copy.stderr, 300)}`)
      copied.push(source)
    }
    commands.push({ argv: ['docker', 'cp', '<仓库>/relay,docs,test/contract', `${name}:/work`],
      exitCode: 0, note: '代码与测试要读的契约复制进卷（不用共享挂载）' })

    const install = step(['pip', 'install', '--quiet', '-r', '/work/relay/requirements-dev.txt'],
      { note: '装 relay 依赖（requirements-dev.txt，照 CI）' })
    if (install.code !== 0) throw new Error(`pip 装依赖失败（exit ${install.code}）`)

    // `DSH_REQUIRE_CADDY=1` 是仓库自己的硬闸门：没有 caddy 时那五条用例会静默变成 skip，
    // 绿色的运行等于什么都没说。`-rs` 把每次跳过连同原因打进日志，供人事后核对。
    const pytest = step(['sh', '-c',
      'mkdir -p /root/.dsh && cd /work/relay && DSH_REQUIRE_CADDY=1 python -m pytest -q -rs'],
      { timeoutMs: 1_800_000, note: '中转单测（含真 Caddy 的端到端那半，缺 caddy 即报错）' })
    const summary = pytest.text.trim().split('\n').filter(Boolean).at(-1) ?? '(没有输出)'
    observations.push({ step: 'pytest', fact: `${summary}（exit ${pytest.code}）`, evidence: `container-${commands.length}.log` })
    const skipped = Number(/(\d+) skipped/.exec(pytest.text)?.[1] ?? 0)
    if (skipped > 0) observations.push({ step: 'skip', fact: `有 ${skipped} 条 skip：逐条确认不是环境缺失导致的静默退化` })
    status = pytest.code === 0 ? 'pass' : 'fail'
    if (pytest.code !== 0) note = `pytest 退出码 ${pytest.code}：${summary}`
  } catch (error) {
    status = 'fail'
    note = error.message
    observations.push({ step: 'error', fact: error.message })
  } finally {
    if (status !== 'blocked') cleanup({ name })
  }
  return finish()
}

/** 起容器 → 装 DSH 与 pnpm → 把仓库子集复制进卷。 */
function prepareContainer({ name, commands, observations, log }) {
  startContainer({ name })
  commands.push({ argv: ['docker', 'run', '-d', '--name', name, '-v', `${VOLUME}:/data`, IMAGE, 'sleep', 'infinity'], exitCode: 0 })
  log(`L2: 容器已起 ${name}`)
  const npm = exec(name, ['sh', '-c', 'mkdir -p /work && npm i -g --silent @deepseek-ai/dsh pnpm'], { timeoutMs: 600_000 })
  commands.push({ argv: ['docker', 'exec', name, 'npm', 'i', '-g', '@deepseek-ai/dsh', 'pnpm'], exitCode: npm.status ?? -1, note: '容器内装 DSH 与 pnpm' })
  if (npm.status !== 0) throw new Error(`容器内装 DSH 失败：${tail(`${npm.stdout}${npm.stderr}`, 400)}`)
  copyRepoIn(name)
  commands.push({ argv: ['docker', 'cp', '<仓库>/plugins,scripts,package.json', `${name}:/work`], exitCode: 0, note: '代码复制进卷（不用共享挂载）' })
  observations.push({ step: 'setup', fact: '容器内已装 DSH 与 pnpm，仓库子集已复制进 /work' })
}

/** 装插件 → 不重启 → 看连接器有没有自己挂上、宿主进程有没有退出。 */
async function installAndObserve({ name, commands, observations, outDir }) {
  const install = exec(name, ['sh', '-c', 'cd /work && dsh plugin --profile web add /work/plugins/mobile-link'], { timeoutMs: 600_000 })
  commands.push({ argv: ['docker', 'exec', name, 'dsh', 'plugin', '--profile', 'web', 'add', '/work/plugins/mobile-link'], exitCode: install.status ?? -1, note: '官方安装路径' })
  writeFileSync(join(outDir, 'container-install.log'), `$ dsh plugin add /work/plugins/mobile-link\n${install.stdout ?? ''}${install.stderr ?? ''}`)
  observations.push({ step: 'install', fact: `dsh plugin add 退出码 ${install.status}`, evidence: 'container-install.log' })
  if (install.status !== 0) {
    observations.push({ step: 'install-head', fact: head(`${install.stdout}${install.stderr}`, 500) })
    throw new Error(`容器内安装失败（exit ${install.status}），完整输出见 container-install.log`)
  }
  const mounted = await waitEndpointInContainer(name, 90_000)
  const aliveProbe = exec(name, ['sh', '-c', 'kill -0 $(cat /tmp/host.pid) 2>/dev/null && echo alive || echo gone'])
  commands.push({ argv: ['docker', 'exec', name, 'sh', '-c', 'kill -0 $(cat /tmp/host.pid)'], exitCode: aliveProbe.status ?? -1, note: '宿主 pid 是否还活着（活着=没重启）' })
  const hostAlive = aliveProbe.stdout.trim()
  observations.push({ step: 'after-install', fact: `不重启的情况下：连接器${mounted ? '自己挂上了' : '仍未挂上'}；宿主进程（pid 未变）${hostAlive === 'alive' ? '仍在' : '已退出'}` })
  const status = mounted && hostAlive === 'alive' ? 'pass' : 'fail'
  let note
  if (!mounted) note = '装完 90 秒内没有挂上：这条路径在 Linux 上需要重启宿主'
  else if (hostAlive !== 'alive') note = '宿主进程退出过，等于重启过，不能算"不用重启"'
  return { status, note }
}

// —— 小工具 ——

function startContainer({ name, hostProbe }) {
  const args = ['run', '-d', '--name', name, '-v', `${VOLUME}:/data`, '-w', '/work']
  if (hostProbe) args.push('-v', `${hostProbe}:/bind`)
  if (process.arch === 'arm64') args.push('--platform', 'linux/arm64')
  args.push(IMAGE, 'sleep', 'infinity')
  const result = spawnSync('docker', args, { encoding: 'utf8', timeout: 600_000 })
  if (result.status !== 0) throw new Error(`起容器失败：${tail(result.stderr || result.stdout, 400)}`)
}

function exec(name, argv, { timeoutMs = 120_000 } = {}) {
  return spawnSync('docker', ['exec', name, ...argv], { encoding: 'utf8', timeout: timeoutMs })
}

function copyRepoIn(name) {
  const result = spawnSync('docker', ['exec', name, 'mkdir', '-p', '/work/plugins', '/work/scripts'], { encoding: 'utf8' })
  if (result.status !== 0) throw new Error('容器内建目录失败')
  // 目录要写 `src/.`（复制内容）——`docker cp src ctr:/dest` 在 dest 已存在时会把 src 整个
  // 塞进 dest，于是路径变成 /work/plugins/plugins/...，后面按 /work/plugins/mobile-link 找就找不到。
  for (const [source, target] of [
    [join(REPO_ROOT, 'plugins') + '/.', '/work/plugins'],
    [join(REPO_ROOT, 'scripts') + '/.', '/work/scripts'],
    [join(REPO_ROOT, 'package.json'), '/work/package.json'],
  ]) {
    const copied = spawnSync('docker', ['cp', source, `${name}:${target}`], { encoding: 'utf8', timeout: 600_000 })
    if (copied.status !== 0) throw new Error(`docker cp ${source} 失败：${tail(copied.stderr, 300)}`)
  }
}

/** 复制进 / 复制出，逐字节比对——证明"复制进卷"这条路真的可用。 */
function copyRoundTrip({ name, hostProbe, observations }) {
  const file = join(hostProbe, 'roundtrip.txt')
  writeFileSync(file, 'hello-from-host\n')
  const into = spawnSync('docker', ['cp', file, `${name}:/data/roundtrip.txt`], { encoding: 'utf8' })
  const out = spawnSync('docker', ['cp', `${name}:/data/roundtrip.txt`, join(hostProbe, 'roundtrip.out')], { encoding: 'utf8' })
  const same = into.status === 0 && out.status === 0
    && readFileSync(file, 'utf8') === readFileSync(join(hostProbe, 'roundtrip.out'), 'utf8')
  observations.push({ step: 'copy', fact: `docker cp 进/出并逐字节比对：${same ? '一致' : '不一致'}` })
  if (!same) throw new Error('docker cp 往返比对不一致')
}

/** 卷内自写自看：证明容器卷上 fs.watch 是有效的。 */
function watchInsideVolume(name) {
  const script = "import fs from 'node:fs';const ev=[];fs.watch('/data',(e,f)=>ev.push(e));"
    + "setTimeout(()=>fs.writeFileSync('/data/probe','hi'),300);"
    + "setTimeout(()=>{process.stdout.write(ev.join(',')||'(none)')},2500);"
  const result = exec(name, ['node', '--input-type=module', '-e', script], { timeoutMs: 30_000 })
  return result.stdout.trim()
}

/** 反向对照：共享挂载上由**宿主**写文件，容器内 watcher 不该看到（inotify 不转发）。 */
async function watchBindMount({ name, hostProbe }) {
  const script = "import fs from 'node:fs';const ev=[];fs.watch('/bind',(e,f)=>ev.push(e));"
    + "setTimeout(()=>fs.writeFileSync('/tmp/bind-watch.log',ev.join(',')||'(none)'),4000);"
    + "setTimeout(()=>process.exit(0),4300);"
  spawnSync('docker', ['exec', '-d', name, 'node', '--input-type=module', '-e', script], { encoding: 'utf8' })
  await new Promise((resolve) => setTimeout(resolve, 1200))
  writeFileSync(join(hostProbe, 'from-host.txt'), 'written-on-the-host\n')
  await new Promise((resolve) => setTimeout(resolve, 3500))
  return exec(name, ['cat', '/tmp/bind-watch.log']).stdout.trim()
}

async function waitEndpointInContainer(name, timeoutMs) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const result = exec(name, ['sh', '-c', 'test -s /root/.dsh/mobile-link/endpoint.json && cat /root/.dsh/mobile-link/endpoint.json'])
    if (result.status === 0 && result.stdout.includes('"port"')) return result.stdout
    await new Promise((resolve) => setTimeout(resolve, 1000))
  }
  return undefined
}

function collectLogs(name, outDir, observations) {
  for (const [source, target] of [['/tmp/host.log', 'container-host.log'], ['/root/.dsh/mobile-link/endpoint.json', 'container-endpoint.json']]) {
    const result = spawnSync('docker', ['cp', `${name}:${source}`, join(outDir, target)], { encoding: 'utf8' })
    if (result.status === 0) observations.push({ step: 'log', fact: `已取回 ${source}`, evidence: target })
  }
}

function cleanup({ name, hostProbe }) {
  spawnSync('docker', ['rm', '-f', name], { encoding: 'utf8', timeout: 60_000 })
  spawnSync('docker', ['volume', 'rm', '-f', VOLUME], { encoding: 'utf8', timeout: 30_000 })
  if (hostProbe && existsSync(hostProbe)) rmSync(hostProbe, { recursive: true, force: true })
}

function record(commands, observations, argv, outDir, fileName) {
  const result = spawnSync(argv[0], argv.slice(1), { encoding: 'utf8', timeout: 60_000 })
  const logPath = join(outDir, fileName)
  writeFileSync(logPath, `$ ${argv.join(' ')}\n${result.stdout ?? ''}${result.stderr ?? ''}`)
  commands.push({ argv, exitCode: result.status ?? -1, stdoutPath: logPath })
  observations.push({ step: 'command', fact: `${argv.join(' ')} → exit ${result.status ?? -1}：${tail(result.stdout ?? '', 120)}` })
}

function head(text, limit) {
  const value = String(text ?? '').trim()
  return value.length > limit ? `${value.slice(0, limit)}…` : value
}

function tail(text, limit) {
  const value = String(text ?? '').trim()
  return value.length > limit ? value.slice(-limit) : value
}

/** dockerd 自报的镜像源；环境变量可额外指定一个（用于没有改 daemon 的场合）。 */
function dockerMirrors(docker) {
  const result = spawnSync(docker, ['info', '--format', '{{json .RegistryConfig.Mirrors}}'], { encoding: 'utf8', timeout: 30_000 })
  if (result.status !== 0) return []
  try {
    const parsed = JSON.parse(result.stdout.trim() || '[]')
    return Array.isArray(parsed) ? parsed.filter(Boolean) : []
  } catch {
    return []
  }
}

function whichBinary(name) {
  const result = spawnSync('which', [name], { encoding: 'utf8' })
  return result.status === 0 ? result.stdout.trim() : undefined
}
