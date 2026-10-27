#!/usr/bin/env node
// 014 反馈通道的 owner 侧入口：本机包装两个服务的 admin CLI（DESIGN-20261015 M4 双目标）。
//
// 默认走 SSH 在服务器上跑（主机从 `.env.local` 的 DSH_OTA_HOST 取），`--local` 改跑本机
// 测试库（开发与自测用，不碰生产库）。目标按子命令分流：
//
//   - 信件类（list/show/template/reply/notify/delete）→ `/opt/dsh-mail`（信件服务）
//   - 用量与报告数据（report/report-data）→ `/opt/dsh-relay`（中转）的 ops-report
//     + `/opt/dsh-mail` 的 feedback-stats，**在本机合并**后渲染（两服务之间没有调用）。
//   - `notify` 在审批打印之前只读取一次中转的 account-list 打印覆盖（全库 / 本次点名 / 缺口）；
//     `--all` 在发送时再取一次作为名单，投递后断言投递数 == 名单数（M7 / P1-6）。mail 没有账号表。
//
//   node scripts/dev/feedback.mjs list [--status open|replied|all] [--limit 20] [--since 30]
//   node scripts/dev/feedback.mjs show --thread th_x
//   node scripts/dev/feedback.mjs template
//   node scripts/dev/feedback.mjs reply --thread th_x --body-file /tmp/reply.txt [--subject S]
//                                  [--format text|html] [--send] [--owner-approved "<owner 的原话>"]
//   node scripts/dev/feedback.mjs notify --body-file /tmp/notice.txt [--subject S]
//                                  [--format text|html] [--all] [--partial] [--yes] [--owner-approved "…"]
//   node scripts/dev/feedback.mjs delete --thread th_x [--yes]
//   node scripts/dev/feedback.mjs report [--days 30] [--date today|yesterday|YYYY-MM-DD]
//                                  [--full-day] [--out maintainers/reports]
//   node scripts/dev/feedback.mjs report --send --account acc_a [--account acc_b] [--subject S]
//   node scripts/dev/feedback.mjs report-data [--days 30]
//   node scripts/dev/feedback.mjs report --install-agent | --uninstall-agent
//
// **写操作默认预演**：reply 要 `--send`、notify/delete 要 `--yes` 才真正落库；`--dry-run`
// 强制预演。误发一条通知的代价比多点一次确认高（plan.md 11）。退出码与 admin.py 对齐：
// 0 成功 / 1 业务失败 / 2 用法错误。
//
// **发给其他用户的信必须先经 owner 批准**（owner 2026-10-13 要求，AGENTS.md 硬性约束第 9 条）：
// reply / notify / report --send 的收件人里只要有一个不是 owner 自己（`.env.local` 的
// `DSH_ACCOUNT_ID`），就必须带 `--owner-approved "<owner 的原话>"`，否则拒绝发送（退出码 2）。
// 预演（没有 --send/--yes，或带 `--dry-run`）不判；真发之前往
// `~/Library/Logs/dsh-feedback-approvals.log` 记一条 JSON 行（批准原话 + 收件人）。
//
// **发件存档**（owner 2026-10-15 要求）：真发给别人的信（审批门要拦的那类发送）落地之后，
// 自动向 owner 账号补一条存档通知——信件全文 + 发送对象 + 发送人（owner 手发还是系统代发），
// 不依赖人记得手动抄送。判定与审批门同一口径：需要批准的发送就是需要存档的发送，只发给
// owner 自己的不存档（他的收件箱里本来就有）。存档的收件人只有 owner，不再走审批门；它由
// `run()` 直接执行、不回头调 `main`，所以不会递归存档。存档失败只往 stderr 喊"需手动补档"、
// 不改退出码——信件已经发出，退非零会让上层重试、造成重发。
//
// `--format`（默认 text）原样透传给 admin.py：`html` 让手机用锁死的 HTML 容器渲染（日报）。
// `report --send` 把刚生成的 HTML 报告作为一条 HTML 通知投给 **账号**（019）：账号取
// `--account`，没给就取 `.env.local` 的 `DSH_ACCOUNT_ID`（定时任务走这条，参数里不再有
// 任何会随手机重配失效的 id）。**只发指定账号，不群发**：报告有三万多字节，不能当 ssh 的
// 参数元素传（命令行长度与引号都会出事），所以先 scp 到服务器 `/tmp/dsh-feedback-report-<文件名>`，
// 再 `feedback-notify --format html --body-file <远端路径> --account … --yes`，最后删掉远端
// 临时文件（失败也删）。

import { execFileSync } from 'node:child_process'
import { appendFileSync, existsSync, mkdirSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { basename, dirname, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

import { credentials, listBuilds, token } from './asc-client.mjs'
import { renderReport, updateHistory } from './feedback-report.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))
const ROOT = join(HERE, '..', '..')

/// 服务器侧固定路径（与 relay-go/deploy 的部署位置一致）。
const REMOTE = {
  argv: ['/opt/dsh-relay-go/bin/dsh-relay', 'admin'],
  db: '/var/lib/dsh-relay/state.db',
}
/// 信件服务的固定路径（DESIGN-20261015 M4：信件类命令改打这里；与中转同一台主机）。
const MAIL_REMOTE = {
  argv: ['/opt/dsh-mail/.venv/bin/python', '/opt/dsh-mail/admin.py'],
  db: '/var/lib/dsh-mail/mail.db',
}
const LOCAL_RELAY_BIN = join(ROOT, 'relay-go', 'bin', 'dsh-relay')
const LOCAL_MAIL_ADMIN = join(ROOT, 'mail', 'admin.py')
const LOCAL_PYTHON = join(ROOT, '.venv', 'bin', 'python')
const LOCAL_DB = join(ROOT, 'relay-go', '.local', 'state.db')
const LOCAL_MAIL_DB = join(ROOT, 'mail', '.local', 'mail.db')
const DEFAULT_OUT = join(ROOT, 'maintainers', 'reports')

/// 日报里的 GitHub 计数（仓库 star/fork、账号关注者）取自公开 API，只存数字。
/// 缓存落在报告目录（已 gitignore），6 小时内不重复请求：未认证配额 60 次/小时，
/// 补跑历史报告不能把配额打光。
const GITHUB_CACHE = join(DEFAULT_OUT, '.github-stats.json')
const GITHUB_TTL_MS = 6 * 3600_000
const GITHUB_BASE = 'https://api.github.com'

/// 日报里的发版日 = iOS 发了 TestFlight 的那一天（owner 2026-10-20 定）。真值在
/// App Store Connect，本机只缓存构建号与上传时间：6 小时内不重复请求，取不到时退回缓存，
/// 没有缓存就不标线——ASC 不通不能让日报生成失败。
const TESTFLIGHT_CACHE = join(DEFAULT_OUT, '.testflight-releases.json')
const TESTFLIGHT_TTL_MS = 6 * 3600_000

/// 子命令 → 服务：信件类打 mail，用量/报告数据打中转（拆分后的路由表）。
const MAIL_SUBS = new Set(['list', 'show', 'template', 'reply', 'notify', 'delete', 'rebind'])

const AGENT_LABEL = 'com.jayanttang.dsh-daily-report'
const AGENT_TEMPLATE = join(HERE, 'launchd', `${AGENT_LABEL}.plist`)
const AGENT_LOG = 'Library/Logs/dsh-daily-report.log'

const SUBCOMMANDS = new Set(['list', 'show', 'template', 'reply', 'notify', 'delete', 'rebind',
  'report', 'report-data'])
const NEEDS_THREAD = new Set(['show', 'reply', 'delete'])
const NEEDS_BODY = new Set(['reply', 'notify'])
/// 正文形态：`text` 由手机按 Markdown 渲染，`html` 走锁死的 HTML 容器（日报这类带图的）。
const FORMATS = new Set(['text', 'html'])
/// 管理清单的口径：`user` = 命中归属谓词（能进团队收件箱）、`test` = 命不中（测试机型与
/// 团队自己的提交，两者都永远进不了收件箱）、`all` = 全部。
const SCOPES = new Set(['user', 'test', 'all'])
/// 审批门（AGENTS.md 硬性约束第 9 条）：写给别人之前要 owner 的批准原话。
const OWNER_APPROVED = '--owner-approved'
const APPROVAL_LOG = 'Library/Logs/dsh-feedback-approvals.log'
/// 线程清单一次最多读多少条来判回信收件人（`feedback-list --limit` 没有服务端上限）。
const THREAD_LOOKUP_LIMIT = 500

const USAGE = `用法：
  feedback.mjs list [--status open|replied|all] [--scope user|test|all] [--limit 20] [--since DAYS]
  feedback.mjs show --thread th_x
  feedback.mjs template
  feedback.mjs reply --thread th_x (--body-file PATH | --body TEXT) [--subject S] [--format text|html] [--send]
                    [--owner-approved "owner 的原话"]
  feedback.mjs notify (--body-file PATH | --body TEXT) [--subject S] [--format text|html] [--account ACC]... [--all]
                    [--partial] [--yes] [--owner-approved "owner 的原话"]
  feedback.mjs delete --thread th_x [--yes]
  feedback.mjs rebind [--yes]         回滚旧包前把 teamAccountId 按归属谓词补齐（默认预演）
  feedback.mjs report [--days 30] [--date today|yesterday|YYYY-MM-DD] [--full-day] [--out DIR]
                    [--send [--account ACC]...] [--owner-approved "…"]
  feedback.mjs report [--install-agent | --uninstall-agent]
  feedback.mjs report [--date D | --full-day] --send [--account ACC]... [--subject S] [--days 30] [--out DIR]
  feedback.mjs report-data [--days 30]
  （加 --local 跑本机 relay-go/.local/state.db；写操作默认预演）
  （--date 指定报告覆盖哪一天：today = 今天 00:00 到此刻（默认口径），yesterday 或
    YYYY-MM-DD = 那一整天；日期一律由服务器按它自己的本地日算，不看本机时钟。
    --full-day 是 --date yesterday 的简写（00:00 的定时日报用），两个同时给是用法错误）
  （--format 默认 text；report --send 把 HTML 报告按 html 投给账号——收件人是账号不是设备，
    --account 不给时取 .env.local 的 DSH_ACCOUNT_ID；两者都没有是用法错误，不会群发。报告里的
    默认标题是「DSH Mobile 运营日报 YYYY-MM-DD」（日期取覆盖日），--subject 可覆盖）
  （收件人里有非 owner 账号（.env.local 的 DSH_ACCOUNT_ID）时必须给 --owner-approved "<owner 的原话>"，
    否则拒发（退出码 2）；只发给 owner 自己的（日报、自测）不需要。预演不判）
  （发给别人的信发送成功后，脚本自动向 owner 账号投一条「发件存档」通知：信件全文 +
    发送对象 + 覆盖记录 + 发送人。只发给 owner 自己的不存档；存档失败只警告需手动补档、不重发原件）
  （notify 在审批打印之前只读取一次中转账号清单，打印「全库 N，本次点名 M（缺 K：…）」；
    点名名单是全库的真子集且多于 1 个账号时默认拒发（退出码 2），确认有意只发这部分才加 --partial；
    --all 在发送时再取一次清单作为名单，投递数不等于名单数就退非零（1）并打印差额）
  （双目标：信件类命令打 /opt/dsh-mail，用量与报告数据打 /opt/dsh-relay-go 并与 mail 的
    feedback-stats 在本机合并；notify --all 先从中转展开成点名账号再投）
  （--scope 只对 list 有意义：user = 能进团队收件箱的用户来信、test = 测试机型与团队自己的
    提交（都永远进不了收件箱）、all = 全部；它要判"哪条算来信"，所以远端一定要有团队账号——
    这条命令会自动把 .env.local 的 DSH_ACCOUNT_ID 作为 --team-account 传给服务器）`

/// 用法错误（退出码 2）与业务失败（1）分开。
class UsageError extends Error {}

/// 没有 owner 的批准就写信。与用法错误同一个退出码（2），但只提示怎么补，不刷整屏用法。
class ApprovalError extends Error {
  constructor(message, { hint = true } = {}) {
    super(message)
    this.hint = hint
  }
}

/// 点名发送命中"全库的真子集"（M7 / P1-6）：默认拒发，要 `--partial` 显式声明意图。
/// 与用法错误同一个退出码（2），只打印缺口与放行条件，不刷整屏用法。
class PartialError extends Error {}

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

/// `--date` 的取值 → 服务器 `ops-report --as-of` 的锚点（`today` / `yesterday` / `YYYY-MM-DD`）。
///
/// `today` 落成 `now`：服务器按"当天 00:00 到此刻"给部分数据——一天还没过完，不存在"完整的今天"。
/// 要一整天就给 `yesterday` 或具体日期（服务器把 `YYYY-MM-DD` 锚到那天 23:59:59.999）。
/// 日期合法性在本机先判一次（`2026-02-30` 这种别等到服务器报错）；`day` 是 `YYYYMMDD`，
/// 老服务端不回 `today.day` 时用它给报告文件命名。
export function normalizeDate(value) {
  const text = String(value ?? '').trim()
  if (text === 'today') return { asOf: 'now', day: null }
  if (text === 'yesterday') return { asOf: 'yesterday', day: null }
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(text)
  if (!match) throw new UsageError(`--date 只能是 today / yesterday / YYYY-MM-DD，收到 ${value}`)
  const [, year, month, day] = match
  const at = new Date(Number(year), Number(month) - 1, Number(day))
  if (at.getFullYear() !== Number(year) || at.getMonth() !== Number(month) - 1
    || at.getDate() !== Number(day)) {
    throw new UsageError(`--date 不是有效日期：${text}`)
  }
  return { asOf: text, day: `${year}${month}${day}` }
}

export function parseArgs(argv) {
  const sub = argv[0]
  if (!sub) throw new UsageError('缺少子命令')
  if (!SUBCOMMANDS.has(sub)) throw new UsageError(`未知子命令 ${sub}`)
  const opts = { local: false, dryRun: false, send: false, yes: false, all: false, partial: false,
    accounts: [], days: 30, installAgent: false, uninstallAgent: false, fullDay: false }
  for (let i = 1; i < argv.length; i += 1) {
    const flag = argv[i]
    switch (flag) {
      case '--local': opts.local = true; break
      case '--dry-run': opts.dryRun = true; break
      case '--send': opts.send = true; break
      case '--yes': opts.yes = true; break
      case '--all': opts.all = true; break
      case '--partial': opts.partial = true; break
      case '--install-agent': opts.installAgent = true; break
      case '--uninstall-agent': opts.uninstallAgent = true; break
      case '--full-day': opts.fullDay = true; break
      case '--date': opts.date = need(argv, ++i, flag); break
      case '--thread': opts.thread = need(argv, ++i, flag); break
      case '--status': opts.status = need(argv, ++i, flag); break
      case '--scope':
        opts.scope = need(argv, ++i, flag)
        if (!SCOPES.has(opts.scope)) {
          throw new UsageError(`--scope 只能是 ${[...SCOPES].join(' / ')}，收到 ${opts.scope}`)
        }
        break
      case '--body': opts.body = need(argv, ++i, flag); break
      case '--body-file': opts.bodyFile = need(argv, ++i, flag); break
      case '--subject': opts.subject = need(argv, ++i, flag); break
      case '--format':
        opts.format = need(argv, ++i, flag)
        if (!FORMATS.has(opts.format)) throw new UsageError(`--format 只能是 text 或 html，收到 ${opts.format}`)
        break
      case '--out': opts.out = need(argv, ++i, flag); break
      case '--account': opts.accounts.push(need(argv, ++i, flag)); break
      case '--owner-approved': opts.ownerApproved = need(argv, ++i, flag); break
      case '--limit': opts.limit = number(argv, ++i, flag); break
      case '--since': opts.since = number(argv, ++i, flag); break
      case '--days': opts.days = number(argv, ++i, flag); break
      default: throw new UsageError(`未知参数 ${flag}`)
    }
  }
  if (NEEDS_THREAD.has(sub) && !opts.thread) throw new UsageError(`${sub} 需要 --thread`)
  if (NEEDS_BODY.has(sub) && !opts.body && !opts.bodyFile) throw new UsageError(`${sub} 需要 --body-file 或 --body`)
  // `--date` / `--full-day` 只对拉报告的 report 有意义；两个同时给说明口径没说清，直接报错，
  // 不搞"谁覆盖谁"的静默优先级。
  if (opts.date || opts.fullDay) {
    if (sub !== 'report') throw new UsageError(`${sub} 不支持 --date / --full-day（只有 report 有日期口径）`)
    if (opts.date && opts.fullDay) {
      throw new UsageError('--full-day 就是 --date yesterday，两个给一个就行')
    }
    const resolved = opts.fullDay ? { asOf: 'yesterday', day: null } : normalizeDate(opts.date)
    opts.asOf = resolved.asOf
    opts.dateDay = resolved.day
  }
  // `report --send` 的收件账号在 `main` 里定：`--account` 优先，否则取 `.env.local` 的
  // `DSH_ACCOUNT_ID`（定时任务用这条）。两者都没有时在那边报用法错误，绝不退化成群发。
  if (sub === 'report' && opts.send && opts.all) {
    throw new UsageError('report --send 按 --account 投递，不支持 --all')
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

/// 组装 `admin.py` 的参数（`--db` 与 `--team-account` 必须在子命令之前：argparse 只认顶层
/// 可选参数）。
///
/// `teamAccount` 必须**显式**传：`feedback.mjs` 走的是 `ssh <host> '…'`，远端是非交互 shell，
/// 拿不到 systemd 单元里的 `MAIL_TEAM_ACCOUNT`；而管理命令要靠它判"哪条线程算用户来信"
/// （评审 F2）。没有它就拼空值——宁可让 admin 报错，也不让它把空团队号当成"所有账号都是来信"。
export function adminArgs({ sub, opts, teamAccount = '' }, db) {
  const head = ['--db', db]
  const mailHead = [...head, ...(teamAccount ? ['--team-account', teamAccount] : [])]
  switch (sub) {
    case 'list':
      return [...mailHead, 'feedback-list', '--status', opts.status ?? 'open',
        '--limit', String(opts.limit ?? 50),
        ...(opts.since ? ['--since', String(opts.since)] : []),
        ...(opts.scope ? ['--scope', opts.scope] : [])]
    case 'show': return [...mailHead, 'feedback-show', '--thread', opts.thread]
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
        ...opts.accounts.flatMap((account) => ['--account', account]),
        ...(opts.all ? ['--all'] : []),
        ...(opts.yes && !opts.dryRun ? ['--yes'] : [])]
    }
    case 'delete':
      return [...head, 'feedback-delete', '--thread', opts.thread, ...(opts.yes && !opts.dryRun ? ['--yes'] : [])]
    // 回滚旧包前的一次性补列（M1 之后本列不再读写）；不带 --yes 时是 admin 的 dry-run。
    case 'rebind':
      return [...mailHead, 'feedback-rebind', ...(opts.yes && !opts.dryRun ? ['--yes'] : [])]
    // 桥用的两个只读清单（feedback.mjs 自己的子命令表里没有它们；buildInvocation
    // 直接构造 parsed 对象调用，不经过 parseArgs）。
    case 'account-list': return [...head, 'account-list']
    case 'device-list': return [...head, 'device-list', ...(opts.all ? ['--all'] : [])]
    // mail 侧给日报的反馈板块：--debug-device 是中转的调试设备 id（剔测试提交）。
    case 'feedback-stats': {
      return [...mailHead, 'feedback-stats', '--days', String(opts.days ?? 30),
        ...(opts.asOf ? ['--as-of', opts.asOf] : []),
        ...(opts.debugDevices ?? []).flatMap((id) => ['--debug-device', id])]
    }
    // `report` 拉的是 `ops-report`；`--as-of` 决定报告覆盖哪一天（`parseArgs` 已把
    // `--date` / `--full-day` 归一成 `opts.asOf`）：不给就是"当天到此刻"，`yesterday` 是
    // 刚过去的一整天（00:00 的自动日报要这个——按"今天"算的话新的一天刚开头，数字全是 0），
    // `YYYY-MM-DD` 是补跑历史。日期一律服务器按自己的本地日算，不看本机时钟。
    default: return [...head, 'ops-report', '--days', String(opts.days),
      ...(opts.asOf ? ['--as-of', opts.asOf] : [])]
  }
}

/// 得到要执行的 argv：SSH 远端命令或本机 python。
///
/// `service`：'relay'（用量/设备/账号/ops-report）或 'mail'（信件线程与通知）。
/// 两个服务在同一台主机上，SSH 目标相同，只有 python/admin/db 三个路径不同
/// （DESIGN-20261015 M4 的双目标）。
export function buildInvocation({ sub, opts }, { env = {}, exists = existsSync } = {},
  service = (MAIL_SUBS.has(sub) || sub === 'feedback-stats') ? 'mail' : 'relay') {
  const target = service === 'mail'
    ? (opts.local ? { argv: [exists(LOCAL_PYTHON) ? LOCAL_PYTHON : 'python3', LOCAL_MAIL_ADMIN],
      db: LOCAL_MAIL_DB } : MAIL_REMOTE)
    : (opts.local ? { argv: [exists(LOCAL_RELAY_BIN) ? LOCAL_RELAY_BIN : 'dsh-relay', 'admin'],
      db: LOCAL_DB } : REMOTE)
  const args = adminArgs({ sub, opts, teamAccount: ownerAccount(env) }, target.db)
  if (opts.local) {
    return { kind: 'local', argv: [...target.argv, ...args] }
  }
  const { target: sshTarget, port } = resolveSshTarget(env.DSH_OTA_HOST)
  const remote = [...target.argv, ...args].map(shellQuote).join(' ')
  const ssh = ['-q', '-o', 'BatchMode=yes', ...(port ? ['-p', port] : []), sshTarget, remote]
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

/// 报告文件名 = **覆盖日**的日期（`2026-10-12.html`），不是生成时刻的日期。
///
/// 自动日报在 00:00 跑、报的是刚过去的那一天：用生成时刻命名的话，10-13 00:02 生成的文件
/// 会叫 `2026-10-13.html`，而里面的数据全是 10-12 的——文件名、通知标题、手机上的报告日期
/// 三处都会指向错的那一天。`day` 是服务端给的本地日 `YYYYMMDD`；老服务端没这个字段时
/// （没有 `today.day`）退回按生成时刻命名。
export function reportPath({ outDir = DEFAULT_OUT, generatedAt, day = 0, now = Date.now() } = {}) {
  const raw = String(day ?? '')
  if (/^\d{8}$/.test(raw)) return join(outDir, `${raw.slice(0, 4)}-${raw.slice(4, 6)}-${raw.slice(6, 8)}.html`)
  const at = new Date(Number(generatedAt) || now)
  const pad = (value) => String(value).padStart(2, '0')
  return join(outDir, `${at.getFullYear()}-${pad(at.getMonth() + 1)}-${pad(at.getDate())}.html`)
}

/// 历史摘要文件：与报告同目录（maintainers/reports/ 已 gitignore），给 WoW 对照、
/// 告警连续天数与发版标注供数。只存聚合数字，不含任何用户文本。
const HISTORY_FILE = '.ops-history.json'

function loadHistory(outDir) {
  try {
    return JSON.parse(readFileSync(join(outDir, HISTORY_FILE), 'utf8'))
  } catch {
    return null
  }
}

function writeReport(raw, opts, io) {
  let data
  try {
    data = JSON.parse(raw)
  } catch {
    throw new Error(`ops-report 返回的不是 JSON：${String(raw).slice(0, 200)}`)
  }
  const outDir = opts.out ? resolve(ROOT, opts.out) : DEFAULT_OUT
  // 覆盖日以服务器回的 `today.day` 为准；老服务端没有这个字段时，用 `--date` 指定过的那天兜底
  // （不然文件名会落到生成时刻那天，正是「要 10-14 的报告却拿到 10-13」的来源）。
  const file = reportPath({ outDir, generatedAt: data?.generatedAt,
    day: data?.today?.day ?? opts.dateDay })
  const history = loadHistory(outDir)
  mkdirSync(dirname(file), { recursive: true })
  writeFileSync(file, renderReport(data, { history }), 'utf8')
  // 只有「已过完一整天」的报告才更新历史（updateHistory 自己判，半天数据返回 null）。
  const nextHistory = updateHistory(data, history)
  if (nextHistory) writeFileSync(join(outDir, HISTORY_FILE), JSON.stringify(nextHistory), 'utf8')
  io.out(file)
  return { code: data?.ok === false ? 1 : 0, file }
}

/// **审批门**（owner 2026-10-13 要求，AGENTS.md 硬性约束第 9 条）：写给别人的信，先拿 owner 的批准。
///
/// 判定只看"这次会不会真的落库"：预演（没有 --send/--yes，或带 `--dry-run`）一律不判，
/// 因为预演在服务器上只统计收件人、不写库。真发时：
/// - `notify`：收件账号由命令行给出，逐个与 owner 账号比；`--all` 直接算"有别人"。
/// - `report --send`：收件账号同上（日报默认就是 owner 自己，所以日常不受影响）。
/// - `reply`：收件人是线程提交者，argv 里看不出来，只能读一次线程清单来判（见下）。
///
/// 判定不出"收件人就是 owner"时一律按需要审批处理——宁可多要一次批准，不可少要。
///
/// 这是**流程约束**，不是防对抗的墙：门只在这条本机命令上（服务器侧的 `admin.py` 不校验，
/// 直接 ssh 调它就能绕过）。它的作用是让"没经 owner 同意就发信"这件事必须显式跨过一道门槛，
/// 并留下"谁批准了什么"的记录。

/// owner 自己的账号：与日报同一处口径，`.env.local` 的 `DSH_ACCOUNT_ID`。
export function ownerAccount(env) {
  return String(env?.DSH_ACCOUNT_ID ?? '').trim()
}

/// 这批收件账号里哪些不是 owner 自己。取不到 owner 账号（本机没配 `DSH_ACCOUNT_ID`）时，
/// 每个账号都算别人：证明不了是自己，就别放行。
export function foreignRecipients({ accounts = [], all = false } = {}, owner = '') {
  const mine = String(owner ?? '').trim()
  const foreign = accounts.filter((account) => !mine || account !== mine)
  return { all: Boolean(all), foreign }
}

/// 回信的收件人是线程提交者，要读一次线程清单才知道归属。
///
/// 用 `feedback-list`（只读）而不是 `feedback-show`：后者会把 `ownerReadAt` 推到最新一条
/// 用户留言，一个只为判定收件人的查询不该顺手改已读状态。读不到、或线程不在清单里，
/// 返回 false = 当作"发给别人"。
export function threadBelongsToOwner(parsed, { env = {}, exists = existsSync, run } = {}, owner = '') {
  const mine = String(owner ?? '').trim()
  if (!mine || typeof run !== 'function') return false
  try {
    const lookup = buildInvocation(
      { sub: 'list', opts: { local: parsed.opts.local, status: 'all', limit: THREAD_LOOKUP_LIMIT } },
      { env, exists })
    const rows = JSON.parse(run(lookup.argv))
    const row = (Array.isArray(rows) ? rows : []).find((each) => each?.threadId === parsed.opts.thread)
    return row?.source?.accountId === mine
  } catch {
    return false
  }
}

/// 这次发送需不需要 owner 审批；返回原因（字符串）或 null。
export function approvalGate(parsed, ctx = {}, owner = '') {
  const { sub, opts } = parsed
  if (opts.dryRun) return null
  if (sub === 'notify') {
    if (!opts.yes) return null
    if (opts.all) return 'notify --all 会发给库里全部账号（含其他用户）'
    const { foreign } = foreignRecipients({ accounts: opts.accounts }, owner)
    return foreign.length ? `notify 的收件人里有非 owner 账号：${foreign.join('、')}` : null
  }
  if (sub === 'report') {
    if (!opts.send) return null
    const { foreign } = foreignRecipients({ accounts: opts.accounts }, owner)
    return foreign.length ? `report --send 的收件人里有非 owner 账号：${foreign.join('、')}` : null
  }
  if (sub === 'reply') {
    if (!opts.send && !opts.yes) return null
    const who = `线程 ${opts.thread} 的提交者`
    // 已经拿到批准就不再读清单：判定只用来决定"要不要拦"，拦不拦已经定了。
    if (opts.ownerApproved) return `reply 发给${who}`
    if (threadBelongsToOwner(parsed, ctx, owner)) return null
    return `reply 的收件人是${who}（不是 owner 本人，或读不出归属）`
  }
  return null
}

/// 留痕文件：与日报日志同一个目录（`~/Library/Logs/`）。
export function approvalLogPath({ approvalLog } = {}) {
  return approvalLog ?? join(homedir(), 'Library', 'Logs', 'dsh-feedback-approvals.log')
}

/// 写在实际发送之前：记的是"owner 同意过这一次发送"，不是"发送成功"。
/// 留痕写不进去就不发——它的作用就是让"批准过什么"可查，丢了这个就退回无凭据发送。
function appendApprovalLog(parsed, approval, owner, deps = {}) {
  const { sub, opts } = parsed
  const record = {
    at: new Date().toISOString(),
    sub,
    thread: opts.thread ?? null,
    accounts: sub === 'notify' && opts.all ? ['--all'] : (opts.accounts ?? []),
    subject: opts.subject ?? null,
    bodyBytes: Buffer.byteLength(opts.bodyText ?? '', 'utf8'),
    ownerAccount: owner,
    approval,
  }
  const path = approvalLogPath(deps)
  try {
    mkdirSync(dirname(path), { recursive: true })
    appendFileSync(path, `${JSON.stringify(record)}\n`, 'utf8')
  } catch (error) {
    throw new ApprovalError(`审批留痕写不进去（${path}）：${error.message}`, { hint: false })
  }
}

/// 判定 + 放行：需要审批而没给 `--owner-approved` 就拒发；给了就留痕再继续。
/// 返回审批原因（null = 不需要审批）——它同时是「这次发送要不要发件存档」的判定输入。
function requireOwnerApproval(parsed, ctx, owner, io, deps) {
  const reason = approvalGate(parsed, ctx, owner)
  if (!reason) return null
  const approval = String(parsed.opts.ownerApproved ?? '').trim()
  if (!approval) throw new ApprovalError(reason)
  appendApprovalLog(parsed, approval, owner, deps)
  io.err(`（已批准）${reason}\nowner 的原话：${approval}`)
  return reason
}

// ── 发件存档（owner 2026-10-15 要求）：发给别人的信落地后自动抄送 owner 账号 ─────────

/// 存档正文里的「发送对象」一行。
export function archiveRecipients(parsed) {
  const { sub, opts } = parsed
  if (sub === 'reply') return `反馈线程 ${opts.thread} 的提交者`
  if (sub === 'notify') {
    if (opts.all) return '全部账号（--all 群发）'
    if (opts.expandedFromAll) return `全部账号（--all 群发，展开为 ${opts.accounts.length} 个）`
    return opts.accounts.join('、') || '（未点名）'
  }
  return opts.accounts.join('、')
}

/// 存档通知自己的标题。
export function archiveSubject(parsed, info = {}) {
  const { sub, opts } = parsed
  if (sub === 'reply') return `发件存档：回信 → 线程 ${opts.thread}`
  if (sub === 'notify') return `发件存档：通知${opts.subject ? `「${opts.subject}」` : ''}`
  return `发件存档：日报「${info.reportSubject ?? opts.subject ?? ''}」`
}

/// 原件结果 JSON（admin.py 的回包）里取 messageId / noticeId；取不到就不写这一行。
function resultId(raw) {
  try {
    const data = JSON.parse(String(raw))
    return data?.messageId ?? data?.noticeId ?? null
  } catch {
    return null
  }
}

/// 存档正文：头部元数据 + 信件全文。日报是 HTML 文件不是一段文本，塞进 text 通知只会
/// 得到一屏源码，所以那类存标识与落点（标题 + 本地文件），足够查证。
/// HTML 信件同理不能塞进 text（2026-10-15 owner 实测：存档成了源码乱码），html 原件
/// 按 html 存档：元数据横幅插在 `<body>` 之后，正文原样跟在后面渲染。
export function archiveBody(parsed, info = {}) {
  const { sub, opts } = parsed
  const sender = opts.ownerApproved
    ? `系统代发（owner 审批原话：${opts.ownerApproved}）`
    : 'owner 手动发送'
  const lines = [
    '【发件存档】（feedback.mjs 自动投递）',
    `发送对象：${archiveRecipients(parsed)}`,
  ]
  // 覆盖记录（M7 / P1-6）：群发漏掉的账号要留在 owner 的收件箱里，而不是只出现在终端。
  if (opts.coverage) lines.push(coverageArchiveLine(opts.coverage))
  lines.push(`发送人：${sender}`)
  const id = resultId(info.result)
  if (id) lines.push(`原件 ID：${id}`)
  lines.push(`存档时间：${new Date(info.now ?? Date.now()).toISOString()}`)
  if (sub === 'report') {
    lines.push(`信件全文：HTML 日报「${info.reportSubject ?? opts.subject ?? ''}」，`
      + `本地文件 ${info.reportFile ?? ''}；收件人收到的是同一条通知`)
    return lines.join('\n')
  }
  if (opts.format === 'html') {
    const banner = '<div style="margin:0 0 10px;padding:8px 12px;border:1px solid #e2e8f0;'
      + 'border-radius:10px;background:#f8fafc;color:#475569;font-size:12px;line-height:1.6;'
      + 'font-family:&quot;PingFang SC&quot;,&quot;Helvetica Neue&quot;,Arial,sans-serif">'
      + lines.map((line) => escapeArchiveHtml(line)).join('<br>') + '</div>'
    const body = String(opts.bodyText ?? '')
    const openBody = /<body[^>]*>/i.exec(body)
    return openBody
      ? body.slice(0, openBody.index + openBody[0].length) + banner
        + body.slice(openBody.index + openBody[0].length)
      : banner + body
  }
  lines.push('', '――― 信件全文 ―――', '', opts.bodyText ?? '')
  return lines.join('\n')
}

/// 存档横幅用的最小转义（内容是工具拼的元数据，但要进 HTML 就必须转义）。
function escapeArchiveHtml(text) {
  return String(text).replaceAll('&', '&amp;').replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;').replaceAll('"', '&quot;')
}

/// 发送成功后调用：向 owner 账号投一条存档通知。收件人只有 owner，不过审批门；
/// `run()` 直接执行、不回头调 `main`，不会递归。失败不改退出码（原件已发出，不能诱发重发）。
export function archiveSentLetter(parsed, owner, info, { env, exists, run, io }) {
  if (!owner) {
    io.err('发件存档跳过：取不到 owner 账号（.env.local 的 DSH_ACCOUNT_ID），请手动补档')
    return
  }
  const archiveOpts = {
    local: parsed.opts.local,
    accounts: [owner],
    all: false,
    yes: true,
    dryRun: false,
    format: parsed.opts.format === 'html' ? 'html' : 'text',
    subject: archiveSubject(parsed, info),
    bodyText: archiveBody(parsed, info),
    bodyFileArg: undefined,
  }
  try {
    const id = resultId(runLetterCommand({ sub: 'notify', opts: archiveOpts },
      { env, exists, run, io }))
    io.out(`（发件存档）已投给 owner 账号${id ? `：${id}` : ''}`)
  } catch (error) {
    io.err(`发件存档失败（信件已发出，需手动补档）：${failureText(error)}`)
  }
}

/// 报告通知的默认标题：日期取报告文件名（`2026-10-12.html` → `2026-10-12`）。
export function reportSubject(file) {
  return `DSH Mobile 运营日报 ${basename(file).replace(/\.html$/i, '')}`
}

// ── 双目标的桥（DESIGN-20261015 I-3/I-4：两服务之间不调用，人做桥） ─────────────

/// 中转的账号清单（`notify --all` 的展开源：mail 没有账号表，名单真值在中转）。
export function relayAccountsInvocation(parsed, { env, exists }) {
  return buildInvocation({ sub: 'account-list', opts: { local: parsed.opts.local } },
    { env, exists }, 'relay')
}

/// `account-list` 的回包 → 账号 id 列表（保序去重）。不是数组 = 读不出来（null）。
export function relayAccountIds(raw) {
  let rows
  try {
    rows = JSON.parse(String(raw ?? ''))
  } catch {
    return null
  }
  if (!Array.isArray(rows)) return null
  return [...new Set(rows.map((row) => String(row?.accountId ?? '').trim()).filter(Boolean))]
}

/// 取一次中转的账号清单（只读）。两个调用点——审批前的覆盖自检、`--all` 的发送名单——
/// 共用同一条 argv 与同一份解析，避免"名单"在两处各有各的理解。读不到回 null，连不上照抛。
export function fetchRelayAccounts(parsed, ctx) {
  return relayAccountIds(ctx.run(relayAccountsInvocation(parsed, ctx).argv))
}

/// 覆盖自检（M7 / P1-6）：全库是谁、这次点名谁、差谁。
///
/// 一个事实只在这里算一次：`total`（全库，读不到为 null）、`named`（本次点名，--all 时就是
/// 全库、读不到为 null）、`missing`（按全库顺序的缺口）、`subset`（点名名单是全库的**真**
/// 子集——点名发送要显式 `--partial` 才算声明了意图）。
export function coverageRecord(allAccounts, accounts) {
  const all = Array.isArray(allAccounts) ? [...new Set(allAccounts)] : null
  const named = accounts == null
    ? null
    : [...new Set(accounts.map((account) => String(account ?? '').trim()).filter(Boolean))]
  const missing = all && named ? all.filter((account) => !named.includes(account)) : null
  const subset = Boolean(all && named && missing.length && named.length
    && named.every((account) => all.includes(account)))
  return { total: all ? all.length : null, named: named ? named.length : null, missing, subset }
}

/// 缺口里的账号：最多列 8 个（超出的用 `…` 收束）——事故规模（6 个）能完整看到。
export function gapAccounts(ids, limit = 8) {
  const list = Array.isArray(ids) ? ids : []
  if (list.length <= limit) return list.join('、')
  return `${list.slice(0, limit).join('、')}…`
}

/// 审批之前那一行覆盖摘要：`全库 171，本次点名 165（缺 6：acc_a、acc_b）` / `（缺 0）`。
export function coverageSummary(coverage) {
  const named = coverage?.named == null ? '未知' : coverage.named
  if (!coverage || coverage.total == null) {
    return `全库未知，本次点名 ${named}（缺 ?：读不到账号清单，覆盖无法核对）`
  }
  const gap = coverage.missing.length
    ? `缺 ${coverage.missing.length}：${gapAccounts(coverage.missing)}`
    : '缺 0'
  return `全库 ${coverage.total}，本次点名 ${named}（${gap}）`
}

/// 发件存档里的覆盖行：`覆盖：全库 171，本次 165，未含 acc_a、acc_b×6`（缺口也留档）。
export function coverageArchiveLine(coverage) {
  const named = coverage?.named == null ? '未知' : coverage.named
  if (!coverage || coverage.total == null) {
    return `覆盖：全库未知，本次 ${named}，未含未知（读不到中转账号清单）`
  }
  const missing = coverage.missing ?? []
  const gap = missing.length ? `${gapAccounts(missing)}×${missing.length}` : '0'
  return `覆盖：全库 ${coverage.total}，本次 ${named}，未含 ${gap}`
}

/// mail 的 `feedback-notify` 回包里 `recipients` 就是这次真正写下的投递行数。
export function deliveredCount(raw) {
  try {
    const count = JSON.parse(String(raw ?? ''))?.recipients
    return Number.isInteger(count) ? count : null
  } catch {
    return null
  }
}

/// `--all` 的投递断言：返回 null（相等）或一句带差额的说明。读不出投递数也算不相等。
export function deliveryMismatch(raw, expected) {
  const delivered = deliveredCount(raw)
  if (delivered == null) return `清单 ${expected} 个账号，投递数读不出来，无法确认覆盖`
  if (delivered === expected) return null
  const delta = delivered - expected
  return `清单 ${expected} 个账号，实际投递 ${delivered} 个，差 ${delta > 0 ? '+' : ''}${delta} 个`
}

/// 中转的设备清单（`--all`：含已撤销，与 ops-report 的口径一致）。
export function relayDevicesInvocation(parsed, { env, exists }) {
  return buildInvocation({ sub: 'device-list', opts: { local: parsed.opts.local, all: true } },
    { env, exists }, 'relay')
}

/// 中转的调试设备 id（`DSH-` 前缀或测试台机型）——feedback-stats 剔测试提交用。
/// 规则与中转管理命令的调试设备判定同一条。
export function debugDeviceIds(rows) {
  return (Array.isArray(rows) ? rows : [])
    .filter((row) => String(row?.name ?? '').startsWith('DSH-')
      || ['Node', 'test-harness', 'simulator'].includes(String(row?.model ?? '')))
    .map((row) => row.deviceId)
    .filter(Boolean)
}

/// 合并两侧的日报数据：中转的 ops-report（用量/设备/留存/邀请码）+
/// mail 的 feedback-stats（反馈板块）。mail 的两块直接覆盖中转的——
/// 切换后中转那边的信件表不再进新数据，留着算也是旧的。
export function mergeReportData(relayReport, mailStats) {
  const merged = JSON.parse(JSON.stringify(relayReport))
  if (mailStats && mailStats.ok !== false && mailStats.feedback) {
    merged.feedback = mailStats.feedback
    if (mailStats.today && merged.today) {
      merged.today = { ...merged.today, feedback: mailStats.today }
    }
  }
  return merged
}

/// 跑一条**信件类**命令：只打 mail 服务。
export function runLetterCommand({ sub, opts }, { env, exists, run }) {
  return run(buildInvocation({ sub, opts }, { env, exists }, 'mail').argv)
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

/// 日报里的 GitHub 计数：仓库 star、fork，以及个人账号的关注者。
///
/// 三个数字只用于日报页面的一行统计，不列任何明细（owner 2026-10-19 要求）。
/// 仓库与账号从本机 git remote 推断，推断不出来时退回仓库默认值。
/// 取数失败一律返回 null：日报不能因为 GitHub 不通而生成失败。
export function gitHubSlug(root = ROOT) {
  try {
    const url = String(execFileSync('git', ['-C', root, 'config', '--get', 'remote.origin.url'],
      { encoding: 'utf8' })).trim()
    const match = url.match(/github\.com[:/]([^/]+)\/([^/]+?)(?:\.git)?$/)
    if (match) return { owner: match[1], repo: match[2], user: match[1] }
  } catch {
    // 没有 git 或没有 origin：用默认值
  }
  return { owner: 'jayantTang', repo: 'DSH_Mobile', user: 'jayantTang' }
}

/// 两个只读请求（仓库、用户），`curl` 负责超时；返回扁平数字，字段不全视为失败。
export function fetchGitHubStats({ slug = gitHubSlug(), timeoutMs = 6000, exec = execFileSync } = {}) {
  const get = (path) => JSON.parse(exec('curl', ['-sSf', '--max-time',
    String(Math.ceil(timeoutMs / 1000)), '-H', 'Accept: application/vnd.github+json',
    `${GITHUB_BASE}${path}`], { encoding: 'utf8' }))
  const repo = get(`/repos/${slug.owner}/${slug.repo}`)
  const user = get(`/users/${slug.user}`)
  const stats = {
    repo: `${slug.owner}/${slug.repo}`,
    stars: Number(repo?.stargazers_count),
    forks: Number(repo?.forks_count),
    followers: Number(user?.followers),
    fetchedAt: Date.now(),
  }
  if (!Number.isFinite(stats.stars) || !Number.isFinite(stats.forks)
    || !Number.isFinite(stats.followers)) throw new Error('GitHub 返回的字段不全')
  return stats
}

/// 缓存优先取数：6 小时内直接用缓存；过期就重新请求，失败时退回旧缓存（有过期数据
/// 也比没有强），再不行返回 null，页面那一行整块省略。
export function readGitHubStats({ cacheFile = GITHUB_CACHE, ttlMs = GITHUB_TTL_MS,
  now = Date.now(), fetchStats = fetchGitHubStats } = {}) {
  let cached = null
  try {
    cached = JSON.parse(readFileSync(cacheFile, 'utf8'))
  } catch {
    cached = null
  }
  const usable = cached && Number.isFinite(Number(cached.stars))
    && Number.isFinite(Number(cached.forks)) && Number.isFinite(Number(cached.followers))
  if (usable && now - Number(cached.fetchedAt) < ttlMs) return cached
  try {
    const fresh = fetchStats()
    mkdirSync(dirname(cacheFile), { recursive: true })
    writeFileSync(cacheFile, JSON.stringify(fresh), 'utf8')
    return fresh
  } catch {
    return usable ? cached : null
  }
}

/// 从 ASC 取最近的 TestFlight 构建（只读 GET，签名与请求见 asc-client.mjs）。
export function fetchTestFlightReleases({ env = {}, exec = execFileSync, limit = 60 } = {}) {
  const jwt = token(credentials({ ...process.env, ...env }))
  return listBuilds({ jwt, limit, exec })
    .map((row) => ({ build: String(row?.attributes?.version ?? ''),
      uploadedAt: String(row?.attributes?.uploadedDate ?? '') }))
    .filter((row) => row.build && row.uploadedAt)
}

/// 缓存优先取数，同一套口径照抄 GitHub 计数：过期就刷新，刷新失败退回旧缓存，
/// 再不行返回空数组（页面不标发版日，其余照常渲染）。
export function readTestFlightReleases({ cacheFile = TESTFLIGHT_CACHE, ttlMs = TESTFLIGHT_TTL_MS,
  env = {}, now = Date.now(), fetchReleases = fetchTestFlightReleases } = {}) {
  let cached = null
  try {
    cached = JSON.parse(readFileSync(cacheFile, 'utf8'))
  } catch {
    cached = null
  }
  const usable = Array.isArray(cached?.releases) ? cached.releases : null
  if (usable && now - Number(cached.fetchedAt) < ttlMs) return usable
  try {
    const releases = fetchReleases({ env })
    mkdirSync(dirname(cacheFile), { recursive: true })
    writeFileSync(cacheFile, JSON.stringify({ releases, fetchedAt: now }), 'utf8')
    return releases
  } catch {
    return usable ?? []
  }
}

/// 日报的合并取数：中转 ops-report + mail feedback-stats，本机合并（I-3）。
/// `feedback-stats` 的剔除口径要中转的调试设备 id（`DSH-` 前缀/测试台机型），
/// 所以一共三次只读调用：device-list（中转）→ ops-report（中转）→ feedback-stats（mail）。
/// GitHub 计数不进服务器：本机取，随合并结果一起渲染（`github` 为对象时用它，
/// 为 null 时不取，未给时按缓存/接口取）。
function fetchReportData(parsed, { env, exists, run, io, github, testflight }) {
  const { opts } = parsed
  const devices = JSON.parse(run(relayDevicesInvocation(parsed, { env, exists }).argv))
  const debugDevices = debugDeviceIds(devices)
  const relayReport = JSON.parse(run(buildInvocation(parsed, { env, exists }, 'relay').argv))
  const stats = buildInvocation({
    sub: 'feedback-stats',
    opts: { local: opts.local, days: opts.days, asOf: opts.asOf, debugDevices },
  }, { env, exists }, 'mail')
  const mailStats = JSON.parse(run(stats.argv))
  const merged = mergeReportData(relayReport, mailStats)
  const counts = github === null ? null : (github ?? readGitHubStats())
  if (counts) merged.github = counts
  const releases = testflight === null ? [] : (testflight ?? readTestFlightReleases({ env }))
  if (releases.length) merged.testflight = { releases }
  return merged
}

/// `report --send`：双侧取数合并 → 落盘 HTML → （scp → mail 的
/// `feedback-notify --format html` → 删远端）完整顺序。`--local` 时报告文件本机
/// 就能读到，不走 scp、也不需要清理。发给别人的日报（审批原因非空）在投递
/// 成功后自动发件存档。
function reportAndSend(parsed, { env, exists, run, io, owner, approvalReason, github, testflight }) {
  const { opts } = parsed
  const merged = fetchReportData(parsed, { env, exists, run, io, github, testflight })
  const { code, file } = writeReport(JSON.stringify(merged), opts, io)
  if (code !== 0) return code

  const remoteFile = remoteReportPath(file)
  const notifyOpts = {
    ...opts,
    // 报告一律按 HTML 投递；正文用文件（`--body-file`），不走 `--body`。
    format: 'html',
    bodyFileArg: opts.local ? file : remoteFile,
    bodyText: undefined,
    subject: opts.subject ?? reportSubject(file),
    yes: true,
  }
  const notify = buildInvocation({ sub: 'notify', opts: notifyOpts }, { env, exists }, 'mail')
  const scp = opts.local ? null : buildScpInvocation(file, remoteFile, { env })
  const remove = opts.local ? null : buildRemoteRemoveInvocation(remoteFile, { env })

  if (opts.dryRun) {
    io.out('（预演）报告已生成，以下命令没有执行，去掉 --dry-run 才真的投递：')
    if (scp) io.out(scp.join(' '))
    io.out(notify.argv.join(' '))
    if (remove) io.out(remove.join(' '))
    return 0
  }

  let notifyRaw = ''
  try {
    if (scp) run(scp)
    notifyRaw = runLetterCommand({ sub: 'notify', opts: notifyOpts }, { env, exists, run, io })
    io.out(notifyRaw.trimEnd())
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
  if (approvalReason) {
    archiveSentLetter(parsed, owner, { result: notifyRaw, reportFile: file,
      reportSubject: opts.subject ?? reportSubject(file) }, { env, exists, run, io })
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
  // 定时任务固定 `--send`：收件账号由脚本在运行时从 `.env.local` 的 DSH_ACCOUNT_ID 取
  // （019）。plist 里不再写任何 id —— 设备 id 每次重配都会变，写进去必然某天失效。
  const sendArgs = '\n    <string>--send</string>' 
  const rendered = template
    .replace('__SEND_ARGS__', sendArgs)
    .replaceAll('__NODE__', nodePath)
    .replaceAll('__REPO__', repoRoot)
    .replace(/(?<=<string>)~\//g, `${home}/`)
  if (rendered.includes('__')) throw new Error('plist 模板里还有未替换的占位符')
  return logPath ? rendered.replaceAll(join(home, AGENT_LOG), logPath) : rendered
}

function agentPath() {
  return join(homedir(), 'Library', 'LaunchAgents', `${AGENT_LABEL}.plist`)
}

function installAgent(io, opts = {}) {
  const path = agentPath()
  mkdirSync(dirname(path), { recursive: true })
  mkdirSync(join(homedir(), 'Library', 'Logs'), { recursive: true })
  const rendered = renderAgentPlist({})
  writeFileSync(path, rendered, { mode: 0o644 })
  const uid = process.getuid()
  try {
    execFileSync('launchctl', ['bootout', `gui/${uid}/${AGENT_LABEL}`], { stdio: 'ignore' })
  } catch { /* 还没装过：bootout 回非零是正常的 */ }
  execFileSync('launchctl', ['bootstrap', `gui/${uid}`, path])
  const where = '并把日报投给 .env.local 里 DSH_ACCOUNT_ID 指定的账号' 
  // 触发时刻从**装下去的 plist** 里读，不写死在提示里（改过模板后提示跟着变）。
  const at = (key) => new RegExp(`<key>${key}</key>\\s*<integer>(\\d+)</integer>`).exec(rendered)?.[1]
  const hour = at('Hour')
  const minute = at('Minute')
  const when = hour === undefined ? '按 plist 里的日程'
    : `每天 ${String(hour).padStart(2, '0')}:${String(minute ?? 0).padStart(2, '0')} 生成日报`
  io.out(`已装 LaunchAgent ${AGENT_LABEL}（${when}，${where}；日志 ~/${AGENT_LOG}）`)
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

/// 审批之前那一次**只读**的覆盖自检（M7 / P1-6）。
///
/// `--all` 的"本次点名"就是全库；点名发送就是命令行给的账号。读不到清单时覆盖记为未知
/// （不拦发送：这里只负责让缺口可见，投递本身仍由 mail 按名单写行）。
/// 除了覆盖记录，还把这份全库名单交给预演用——`mail` 拒收 `--all`（它没有账号表），
/// 预演要真的跑通就得展开成点名，而这次读取本来就已经发生。返回 `{ coverage, accounts }`。
function notifyCoverage(parsed, ctx, io) {
  const { opts } = parsed
  let all = null
  try {
    all = fetchRelayAccounts(parsed, ctx)
  } catch (error) {
    io.err(`（覆盖自检）读不到中转账号清单：${failureText(error)}`)
  }
  if (!all) {
    return { coverage: coverageRecord(null, opts.all ? null : opts.accounts), accounts: null }
  }
  return { coverage: coverageRecord(all, opts.all ? all : opts.accounts), accounts: all }
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
      return opts.installAgent ? installAgent(io, opts) : uninstallAgent(io)
    }
    if (NEEDS_BODY.has(sub)) opts.bodyText = readBody(opts)
    const env = deps.env ?? { ...localEnv(), ...process.env }
    const exists = deps.exists ?? existsSync
    const run = (command) => String((deps.runner ?? defaultRunner)(command))
    const owner = ownerAccount(env)
    // 一个派生布尔代替两处字面量比较：notify 的"审批前自检"与"审批后展开"是同一条链路的两段。
    const isNotify = sub === 'notify'
    if (sub === 'report' && opts.send) {
      // 收件账号：命令行优先，其次 `.env.local` 的 DSH_ACCOUNT_ID（定时任务的口径）。
      opts.accounts = opts.accounts.length ? opts.accounts : [env.DSH_ACCOUNT_ID].filter(Boolean)
      if (!opts.accounts.length) {
        throw new UsageError('report --send 需要 --account <accountId>（可重复），'
          + '或在 .env.local 里设 DSH_ACCOUNT_ID；本命令不会群发')
      }
      const approvalReason = requireOwnerApproval(parsed, { env, exists, run }, owner, io, deps)
      return reportAndSend(parsed, { env, exists, run, io, owner, approvalReason,
        github: deps.github, testflight: deps.testflight })
    }
    // 覆盖自检（M7 / P1-6）在**审批打印之前**只读地取一次中转账号清单：owner 批准时就要
    // 看到"全库多少、本次点名多少、缺谁"。读不到不算发送失败（这里只是核对），把覆盖标成
    // 未知；`--all` 的名单在发送时还会再取一次，那一次读不到才是致命的。
    let preflight = null
    if (isNotify) {
      preflight = notifyCoverage(parsed, { env, exists, run }, io)
      opts.coverage = preflight.coverage
      io.err(`（覆盖自检）${coverageSummary(opts.coverage)}`)
      // 点名发送命中全库的真子集（且不止一个账号）默认拒发：要 `--partial` 显式声明意图，
      // 不是按比例猜。"名单少了"最常见的成因就是复用了过期的账号清单。
      if (opts.coverage.subset && !opts.partial && opts.coverage.named > 1) {
        throw new PartialError(coverageSummary(opts.coverage))
      }
    }
    const approvalReason = requireOwnerApproval(parsed, { env, exists, run }, owner, io, deps)
    // `notify --all` 的展开：mail 没有账号表，名单真值在中转，--all 一律展开成逐个点名
    // （DESIGN-20261015 I-4）。真发在审批之后**再取一次**清单作为名单（M7：复用审批前那份
    // 会漏掉这期间新登记的账号）；预演复用审批前那次只读结果，不再多跑一次 ssh。
    if (isNotify && opts.all) {
      const sending = opts.yes && !opts.dryRun
      const listed = sending
        ? fetchRelayAccounts(parsed, { env, exists, run })
        : preflight?.accounts
      if (!listed) throw new Error('中转账号清单读不到，取不到 --all 的发送名单（预演也不会下传 --all）')
      opts.accounts = listed
      opts.all = false
      opts.expandedFromAll = true
      // 存档里的覆盖行按"发送时这份名单"记（它就是这次投递的分母）。
      opts.coverage = coverageRecord(listed, listed)
      if (!opts.accounts.length) {
        io.err('（展开 --all）中转一个账号都没有；没有发出任何东西')
        return 1
      }
      io.err(`（展开 --all）中转共 ${opts.accounts.length} 个账号，按点名投递`)
    }
    // report / report-data：双侧取数（中转 ops-report + mail feedback-stats）后合并。
    if (sub === 'report' || sub === 'report-data') {
      const merged = fetchReportData(parsed, { env, exists, run, io,
        github: deps.github, testflight: deps.testflight })
      if (sub === 'report-data') {
        io.out(JSON.stringify(merged))
        return 0
      }
      return writeReport(JSON.stringify(merged), opts, io).code
    }
    const invocation = buildInvocation(parsed, { env, exists })
    if (sub === 'reply' && ((!opts.send && !opts.yes) || opts.dryRun)) return previewReply(invocation, opts, io)
    const raw = runLetterCommand(parsed, { env, exists, run, io })
    io.out(raw.trimEnd())
    // `--all` 的投递断言（M7 / P1-6）：投递数必须等于发送时那份清单的账号数。不等就退非零
    // 并把差额打出来——漏发在 mail 库里看不出来，只能在这里对账。
    const shortfall = sub === 'notify' && opts.expandedFromAll && opts.yes && !opts.dryRun
      ? deliveryMismatch(raw, opts.accounts.length)
      : null
    // 发件存档：审批门要拦的那类发送（收件人里有别人）落地后，自动抄送 owner 账号。
    if (approvalReason) archiveSentLetter(parsed, owner, { result: raw }, { env, exists, run, io })
    if (shortfall) {
      io.err(`（覆盖断言未过）${shortfall}。信件已发出，不要直接重跑（会重发），先按名单核对`)
      return 1
    }
    if (sub === 'notify' && !opts.yes) io.err('（预演）没有 --yes：服务器只统计了收件人，没有落库')
    if (sub === 'delete' && !opts.yes) io.err('（预演）没有 --yes：还没有删除任何数据')
    if (sub === 'rebind' && !opts.yes) io.err('（预演）没有 --yes：没有写任何一列')
    return 0
  } catch (error) {
    if (error instanceof UsageError) {
      io.err(`用法错误：${error.message}`)
      io.err(USAGE)
      return 2
    }
    if (error instanceof ApprovalError) {
      io.err(`未获 owner 批准，没有发送：${error.message}`)
      if (error.hint) {
        io.err('先把正文全文与收件名单发给 owner，得到明确同意后再带上：')
        io.err(`  ${OWNER_APPROVED} "<owner 的原话>"`)
        io.err('（预演不加 --send/--yes 即可；留痕落在 ~/Library/Logs/dsh-feedback-approvals.log）')
      }
      return 2
    }
    if (error instanceof PartialError) {
      io.err(`点名发送默认拒发：${error.message}`)
      io.err('这次只发给全库的一部分账号。确认就是要这样发（不是漏了名单），再加 --partial 重跑')
      return 2
    }
    io.err(failureText(error))
    return 1
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exit(main(process.argv.slice(2)))
}
