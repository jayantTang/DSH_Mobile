#!/usr/bin/env node
// 014 反馈通道的 owner 侧入口：本机包装服务器的 `relay/admin.py`。
//
// 默认走 SSH 在服务器上跑（主机从 `.env.local` 的 DSH_OTA_HOST 取），`--local` 改跑本机
// 测试库 `relay/.local/state.db`（开发与自测用，不碰生产库）。
//
//   node scripts/dev/feedback.mjs list [--status open|replied|all] [--limit 20] [--since 30]
//   node scripts/dev/feedback.mjs show --thread th_x
//   node scripts/dev/feedback.mjs template
//   node scripts/dev/feedback.mjs reply --thread th_x --body-file /tmp/reply.txt [--subject S]
//                                  [--format text|html] [--send]
//   node scripts/dev/feedback.mjs notify --body-file /tmp/notice.txt [--subject S]
//                                  [--format text|html] [--all] [--yes]
//   node scripts/dev/feedback.mjs delete --thread th_x [--yes]
//   node scripts/dev/feedback.mjs report [--days 30] [--out maintainers/reports]
//   node scripts/dev/feedback.mjs report --send --device dvc_a [--device dvc_b] [--subject S]
//   node scripts/dev/feedback.mjs report-data [--days 30]
//   node scripts/dev/feedback.mjs report --install-agent | --uninstall-agent
//
// **写操作默认预演**：reply 要 `--send`、notify/delete 要 `--yes` 才真正落库；`--dry-run`
// 强制预演。误发一条通知的代价比多点一次确认高（plan.md 11）。退出码与 admin.py 对齐：
// 0 成功 / 1 业务失败 / 2 用法错误。
//
// `--format`（默认 text）原样透传给 admin.py：`html` 让手机用锁死的 HTML 容器渲染（日报）。
// `report --send` 把刚生成的 HTML 报告作为一条 HTML 通知投给 `--device` 指定的设备
// （**只发指定设备，不群发**）：报告有三万多字节，不能当 ssh 的参数元素传（命令行长度与
// 引号都会出事），所以先 scp 到服务器 `/tmp/dsh-feedback-report-<文件名>`，再
// `feedback-notify --format html --body-file <远端路径> --device … --yes`，最后删掉远端临时
// 文件（失败也删）。

import { execFileSync } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { basename, dirname, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

import { renderReport } from './feedback-report.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))
const ROOT = join(HERE, '..', '..')

/// 服务器侧固定路径（与 relay/deploy 的部署位置一致）。
const REMOTE = {
  python: '/opt/dsh-relay/.venv/bin/python',
  admin: '/opt/dsh-relay/admin.py',
  db: '/var/lib/dsh-relay/state.db',
}
const LOCAL_ADMIN = join(ROOT, 'relay', 'admin.py')
const LOCAL_PYTHON = join(ROOT, 'relay', '.venv', 'bin', 'python')
const LOCAL_DB = join(ROOT, 'relay', '.local', 'state.db')
const DEFAULT_OUT = join(ROOT, 'maintainers', 'reports')

const AGENT_LABEL = 'com.jayanttang.dsh-daily-report'
const AGENT_TEMPLATE = join(HERE, 'launchd', `${AGENT_LABEL}.plist`)
const AGENT_LOG = 'Library/Logs/dsh-daily-report.log'

const SUBCOMMANDS = new Set(['list', 'show', 'template', 'reply', 'notify', 'delete', 'report', 'report-data'])
const NEEDS_THREAD = new Set(['show', 'reply', 'delete'])
const NEEDS_BODY = new Set(['reply', 'notify'])
/// 正文形态：`text` 由手机按 Markdown 渲染，`html` 走锁死的 HTML 容器（日报这类带图的）。
const FORMATS = new Set(['text', 'html'])

const USAGE = `用法：
  feedback.mjs list [--status open|replied|all] [--limit 20] [--since DAYS]
  feedback.mjs show --thread th_x
  feedback.mjs template
  feedback.mjs reply --thread th_x (--body-file PATH | --body TEXT) [--subject S] [--format text|html] [--send]
  feedback.mjs notify (--body-file PATH | --body TEXT) [--subject S] [--format text|html] [--device ID]... [--all] [--yes]
  feedback.mjs delete --thread th_x [--yes]
  feedback.mjs report [--days 30] [--out DIR] [--install-agent | --uninstall-agent]
  feedback.mjs report --send --device ID [--device ID]... [--subject S] [--days 30] [--out DIR]
  feedback.mjs report-data [--days 30]
  （加 --local 跑本机 relay/.local/state.db；写操作默认预演）
  （--format 默认 text；report --send 把 HTML 报告按 html 投给 --device 指定的设备，报告里的
    默认标题是「DSH Mobile 运营日报 YYYY-MM-DD」，--subject 可覆盖；不带 --device 是用法错误）`

/// 用法错误（退出码 2）与业务失败（1）分开。
class UsageError extends Error {}

function localEnv() {
  const out = {}
  const path = join(ROOT, '.env.local')
  if (!existsSync(path)) return out
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    if (line.trimStart().startsWith('#')) continue
    const match = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/.exec(line)
    if (match) out[match[1]] = match[2].replace(/^(['"])(.*)\1$/, '$2')
  }
  return out
}

/// DSH_OTA_HOST 可能是裸主机、`user@host`、`host:port` 或 URL（照 watch-enrolls.mjs 的口径放宽）。
export function resolveSshTarget(raw) {
  const value = String(raw ?? '').trim()
  if (!value) throw new UsageError('.env.local 里没有 DSH_OTA_HOST（开发时可用 --local）')
  let host = value
  let port = ''
  let user = ''
  if (/^[a-z][a-z0-9+.-]*:\/\//i.test(value)) {
    const url = new URL(value)
    host = url.hostname
    port = url.port
    user = url.username
  } else {
    const at = value.lastIndexOf('@')
    if (at >= 0) { user = value.slice(0, at); host = value.slice(at + 1) }
    const colon = host.lastIndexOf(':')
    if (colon > 0 && /^\d+$/.test(host.slice(colon + 1))) { port = host.slice(colon + 1); host = host.slice(0, colon) }
  }
  if (!host) throw new UsageError(`DSH_OTA_HOST 解析不出主机名：${value}`)
  return { target: `${user || 'root'}@${host}`, port }
}

/// 远端命令是 ssh 的单个参数，必须自己按 POSIX 规则引号化（正文里会有空格与引号）。
function shellQuote(value) {
  const text = String(value)
  if (/^[A-Za-z0-9._:@/=+-]+$/.test(text)) return text
  return `'${text.replaceAll("'", `'\\''`)}'`
}

function need(argv, at, flag) {
  const value = argv[at]
  if (value === undefined || value.startsWith('--')) throw new UsageError(`${flag} 后面缺少值`)
  return value
}

function number(argv, at, flag) {
  const value = Number(need(argv, at, flag))
  if (!Number.isInteger(value) || value <= 0) throw new UsageError(`${flag} 需要一个正整数`)
  return value
}

export function parseArgs(argv) {
  const sub = argv[0]
  if (!sub) throw new UsageError('缺少子命令')
  if (!SUBCOMMANDS.has(sub)) throw new UsageError(`未知子命令 ${sub}`)
  const opts = { local: false, dryRun: false, send: false, yes: false, all: false, devices: [], days: 30,
    installAgent: false, uninstallAgent: false }
  for (let i = 1; i < argv.length; i += 1) {
    const flag = argv[i]
    switch (flag) {
      case '--local': opts.local = true; break
      case '--dry-run': opts.dryRun = true; break
      case '--send': opts.send = true; break
      case '--yes': opts.yes = true; break
      case '--all': opts.all = true; break
      case '--install-agent': opts.installAgent = true; break
      case '--uninstall-agent': opts.uninstallAgent = true; break
      case '--thread': opts.thread = need(argv, ++i, flag); break
      case '--status': opts.status = need(argv, ++i, flag); break
      case '--body': opts.body = need(argv, ++i, flag); break
      case '--body-file': opts.bodyFile = need(argv, ++i, flag); break
      case '--subject': opts.subject = need(argv, ++i, flag); break
      case '--format':
        opts.format = need(argv, ++i, flag)
        if (!FORMATS.has(opts.format)) throw new UsageError(`--format 只能是 text 或 html，收到 ${opts.format}`)
        break
      case '--out': opts.out = need(argv, ++i, flag); break
      case '--device': opts.devices.push(need(argv, ++i, flag)); break
      case '--limit': opts.limit = number(argv, ++i, flag); break
      case '--since': opts.since = number(argv, ++i, flag); break
      case '--days': opts.days = number(argv, ++i, flag); break
      default: throw new UsageError(`未知参数 ${flag}`)
    }
  }
  if (NEEDS_THREAD.has(sub) && !opts.thread) throw new UsageError(`${sub} 需要 --thread`)
  if (NEEDS_BODY.has(sub) && !opts.body && !opts.bodyFile) throw new UsageError(`${sub} 需要 --body-file 或 --body`)
  // `report --send` 只投给点名的设备：不给 --device 就是用法错误，绝不退化成群发（--all）。
  if (sub === 'report' && opts.send && !opts.devices.length) {
    throw new UsageError('report --send 需要 --device <id>（可重复）；本命令不会群发，群发请用 notify --all')
  }
  if (sub === 'report' && opts.send && opts.all) {
    throw new UsageError('report --send 只发 --device 指定的设备，不支持 --all')
  }
  return { sub, opts }
}

function readBody(opts) {
  if (!opts.bodyFile) return opts.body
  try {
    return readFileSync(opts.bodyFile, 'utf8')
  } catch {
    throw new UsageError(`读不到 --body-file ${opts.bodyFile}`)
  }
}

/// 组装 `admin.py` 的参数（`--db` 必须在子命令之前，argparse 只认顶层可选参数）。
export function adminArgs({ sub, opts }, db) {
  const head = ['--db', db]
  switch (sub) {
    case 'list':
      return [...head, 'feedback-list', '--status', opts.status ?? 'open', '--limit', String(opts.limit ?? 50),
        ...(opts.since ? ['--since', String(opts.since)] : [])]
    case 'show': return [...head, 'feedback-show', '--thread', opts.thread]
    case 'template': return [...head, 'feedback-reply', '--template']
    case 'reply':
      // `--subject` 是回信给线程起的标题（邮件那一行）；不传就沿用用户写的那句。
      // `--format` 只在用户显式给出时透传，不传就保持既有 argv（服务器默认 text）。
      return [...head, 'feedback-reply', '--thread', opts.thread, '--body', opts.bodyText,
        ...(opts.subject ? ['--subject', opts.subject] : []),
        ...(opts.format ? ['--format', opts.format] : [])]
    case 'notify': {
      // `bodyFileArg` 是"服务器上（或 --local 时本机上）已经存在的那份正文文件"，
      // 只有 `report --send` 会用到它；CLI 的 `--body-file` 一律读成本地正文再当 `--body` 传。
      const body = opts.bodyFileArg
        ? ['--body-file', opts.bodyFileArg]
        : ['--body', opts.bodyText]
      return [...head, 'feedback-notify', ...body,
        ...(opts.subject ? ['--subject', opts.subject] : []),
        ...(opts.format ? ['--format', opts.format] : []),
        ...opts.devices.flatMap((device) => ['--device', device]),
        ...(opts.all ? ['--all'] : []),
        ...(opts.yes && !opts.dryRun ? ['--yes'] : [])]
    }
    case 'delete':
      return [...head, 'feedback-delete', '--thread', opts.thread, ...(opts.yes && !opts.dryRun ? ['--yes'] : [])]
    default: return [...head, 'ops-report', '--days', String(opts.days)]
  }
}

/// 得到要执行的 argv：SSH 远端命令或本机 python。
export function buildInvocation({ sub, opts }, { env = {}, exists = existsSync } = {}) {
  const db = opts.local ? LOCAL_DB : REMOTE.db
  const args = adminArgs({ sub, opts }, db)
  if (opts.local) {
    const python = exists(LOCAL_PYTHON) ? LOCAL_PYTHON : 'python3'
    return { kind: 'local', argv: [python, LOCAL_ADMIN, ...args] }
  }
  const { target, port } = resolveSshTarget(env.DSH_OTA_HOST)
  const remote = [REMOTE.python, REMOTE.admin, ...args].map(shellQuote).join(' ')
  const ssh = ['-q', '-o', 'BatchMode=yes', ...(port ? ['-p', port] : []), target, remote]
  return { kind: 'ssh', argv: ['ssh', ...ssh], remote }
}

function defaultRunner(argv) {
  return execFileSync(argv[0], argv.slice(1), { encoding: 'utf8', maxBuffer: 8 * 1024 * 1024 })
}

/// 远端非零退出时把 admin.py 的 JSON 错误正文带出来（execFileSync 会把 stdout 留在 error 上）。
function failureText(error) {
  const parts = []
  if (error?.stdout) parts.push(String(error.stdout).trim())
  if (error?.stderr) parts.push(String(error.stderr).trim())
  if (!parts.length) parts.push(error?.message ?? String(error))
  return parts.join('\n')
}

function previewReply(invocation, opts, io) {
  io.out('（预演）以下命令没有执行，加 --send（或 --yes）才真正回信：')
  io.out(invocation.argv.join(' '))
  io.out('--- 正文 ---')
  io.out(opts.bodyText.replace(/\n$/, ''))
  return 0
}

export function reportPath({ outDir = DEFAULT_OUT, generatedAt, now = Date.now() } = {}) {
  const at = new Date(Number(generatedAt) || now)
  const pad = (value) => String(value).padStart(2, '0')
  return join(outDir, `${at.getFullYear()}-${pad(at.getMonth() + 1)}-${pad(at.getDate())}.html`)
}

function writeReport(raw, opts, io) {
  let data
  try {
    data = JSON.parse(raw)
  } catch {
    throw new Error(`ops-report 返回的不是 JSON：${String(raw).slice(0, 200)}`)
  }
  const file = reportPath({ outDir: opts.out ? resolve(ROOT, opts.out) : DEFAULT_OUT, generatedAt: data?.generatedAt })
  mkdirSync(dirname(file), { recursive: true })
  writeFileSync(file, renderReport(data), 'utf8')
  io.out(file)
  return { code: data?.ok === false ? 1 : 0, file }
}

/// 报告通知的默认标题：日期取报告文件名（`2026-10-12.html` → `2026-10-12`）。
export function reportSubject(file) {
  return `DSH Mobile 运营日报 ${basename(file).replace(/\.html$/i, '')}`
}

/// HTML 报告先落服务器上的临时路径：三万字节当 ssh 参数元素传会撞命令行长度与引号。
export function remoteReportPath(file) {
  return `/tmp/dsh-feedback-report-${basename(file)}`
}

/// 把本地报告 scp 到服务器；scp 的端口参数是大写 `-P`（与 ssh 的 `-p` 不同）。
export function buildScpInvocation(localFile, remoteFile, { env = {} } = {}) {
  const { target, port } = resolveSshTarget(env.DSH_OTA_HOST)
  return ['scp', '-q', '-o', 'BatchMode=yes', ...(port ? ['-P', port] : []),
    localFile, `${target}:${remoteFile}`]
}

/// 发完（或发失败）都要删掉远端临时文件。
export function buildRemoteRemoveInvocation(remoteFile, { env = {} } = {}) {
  const { target, port } = resolveSshTarget(env.DSH_OTA_HOST)
  return ['ssh', '-q', '-o', 'BatchMode=yes', ...(port ? ['-p', port] : []), target,
    `rm -f ${shellQuote(remoteFile)}`]
}

/// `report --send`：ops-report → 落盘 HTML → （scp → `feedback-notify --format html` → 删远端）
/// 完整顺序。`--local` 时报告文件本机就能读到，不走 scp、也不需要清理。
function reportAndSend(parsed, { env, exists, run, io }) {
  const { opts } = parsed
  const invocation = buildInvocation(parsed, { env, exists })
  const { code, file } = writeReport(run(invocation.argv), opts, io)
  if (code !== 0) return code

  const remoteFile = remoteReportPath(file)
  const notify = buildInvocation({
    sub: 'notify',
    opts: {
      ...opts,
      // 报告一律按 HTML 投递；正文用文件（`--body-file`），不走 `--body`。
      format: 'html',
      bodyFileArg: opts.local ? file : remoteFile,
      bodyText: undefined,
      subject: opts.subject ?? reportSubject(file),
      yes: true,
    },
  }, { env, exists })
  const scp = opts.local ? null : buildScpInvocation(file, remoteFile, { env })
  const remove = opts.local ? null : buildRemoteRemoveInvocation(remoteFile, { env })

  if (opts.dryRun) {
    io.out('（预演）报告已生成，以下命令没有执行，去掉 --dry-run 才真的投递：')
    if (scp) io.out(scp.join(' '))
    io.out(notify.argv.join(' '))
    if (remove) io.out(remove.join(' '))
    return 0
  }

  try {
    if (scp) run(scp)
    io.out(run(notify.argv).trimEnd())
  } finally {
    // 清理失败不能盖掉真正的失败原因，所以自己咽下、只提示。
    if (remove) {
      try {
        run(remove)
      } catch (error) {
        io.err(`远端临时文件没删掉：${remoteFile}\n${failureText(error)}`)
      }
    }
  }
  return 0
}

/// 模板里的 `__NODE__` / `__REPO__` 与 `~/` 由安装时展开（launchd 自己不展开 `~`）。
export function renderAgentPlist({
  nodePath = process.execPath,
  repoRoot = ROOT,
  logPath,
  template = readFileSync(AGENT_TEMPLATE, 'utf8'),
} = {}) {
  const home = homedir()
  const rendered = template
    .replaceAll('__NODE__', nodePath)
    .replaceAll('__REPO__', repoRoot)
    .replace(/(?<=<string>)~\//g, `${home}/`)
  if (rendered.includes('__')) throw new Error('plist 模板里还有未替换的占位符')
  return logPath ? rendered.replaceAll(join(home, AGENT_LOG), logPath) : rendered
}

function agentPath() {
  return join(homedir(), 'Library', 'LaunchAgents', `${AGENT_LABEL}.plist`)
}

function installAgent(io) {
  const path = agentPath()
  mkdirSync(dirname(path), { recursive: true })
  mkdirSync(join(homedir(), 'Library', 'Logs'), { recursive: true })
  writeFileSync(path, renderAgentPlist(), { mode: 0o644 })
  const uid = process.getuid()
  try {
    execFileSync('launchctl', ['bootout', `gui/${uid}/${AGENT_LABEL}`], { stdio: 'ignore' })
  } catch { /* 还没装过：bootout 回非零是正常的 */ }
  execFileSync('launchctl', ['bootstrap', `gui/${uid}`, path])
  io.out(`已装 LaunchAgent ${AGENT_LABEL}（每天 09:00 生成日报；日志 ~/${AGENT_LOG}）`)
  return 0
}

function uninstallAgent(io) {
  const uid = process.getuid()
  try {
    execFileSync('launchctl', ['bootout', `gui/${uid}/${AGENT_LABEL}`], { stdio: 'ignore' })
  } catch { /* 没装过 */ }
  if (existsSync(agentPath())) unlinkSync(agentPath())
  io.out(`已卸载 LaunchAgent ${AGENT_LABEL}`)
  return 0
}

/** 依赖全部经参数注入（runner/env/exists/out/err），测试才能断言"预演没执行写命令"。 */
export function main(argv, deps = {}) {
  const io = {
    out: deps.out ?? ((line) => console.log(line)),
    err: deps.err ?? ((line) => console.error(line)),
  }
  try {
    const parsed = parseArgs(argv)
    const { sub, opts } = parsed
    if (sub === 'report' && (opts.installAgent || opts.uninstallAgent)) {
      return opts.installAgent ? installAgent(io) : uninstallAgent(io)
    }
    if (NEEDS_BODY.has(sub)) opts.bodyText = readBody(opts)
    const env = deps.env ?? { ...localEnv(), ...process.env }
    const exists = deps.exists ?? existsSync
    const run = (command) => String((deps.runner ?? defaultRunner)(command))
    if (sub === 'report' && opts.send) return reportAndSend(parsed, { env, exists, run, io })
    const invocation = buildInvocation(parsed, { env, exists })
    if (sub === 'reply' && ((!opts.send && !opts.yes) || opts.dryRun)) return previewReply(invocation, opts, io)
    const raw = run(invocation.argv)
    if (sub === 'report') return writeReport(raw, opts, io).code
    io.out(raw.trimEnd())
    if (sub === 'notify' && !opts.yes) io.err('（预演）没有 --yes：服务器只统计了收件人，没有落库')
    if (sub === 'delete' && !opts.yes) io.err('（预演）没有 --yes：还没有删除任何数据')
    return 0
  } catch (error) {
    if (error instanceof UsageError) {
      io.err(`用法错误：${error.message}`)
      io.err(USAGE)
      return 2
    }
    io.err(failureText(error))
    return 1
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exit(main(process.argv.slice(2)))
}
