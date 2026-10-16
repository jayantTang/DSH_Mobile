// 014 owner 侧运维脚本的用例：参数拼装、预演语义、退出码、日报渲染、LaunchAgent 模板。
//
// 为什么值得单测：这些命令会往生产库写回信与群发通知，"预演时到底有没有真的发出去"
// 只能靠断言 argv 来钉住——不能拿真服务器去试。

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

import { buildInvocation, debugDeviceIds, foreignRecipients, main, mergeReportData,
  renderAgentPlist, reportPath, resolveSshTarget } from './feedback.mjs'
import { escapeHtml, humanModel, renderReport, updateHistory } from './feedback-report.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))
const ROOT = join(HERE, '..', '..')
const PLIST = join(HERE, 'launchd', 'com.jayanttang.dsh-daily-report.plist')

const HOST = 'relay.example.com'
/// owner 自己的账号（`.env.local` 的 DSH_ACCOUNT_ID）：默认 env 里带上它，才是本机的真实形状。
const OWNER = 'acc_owner'
/// 写给别人的信必须带这句——审批门（AGENTS.md 硬性约束第 9 条）。
const APPROVED = ['--owner-approved', '同意，发吧']
/// 生成时间取本机时区的 2026-10-12 09:00，文件名才不随 UTC 偏移变化。
const GENERATED_AT = new Date(2026, 9, 12, 9, 0, 0).getTime()

const THREAD = '<script>alert(1)</script> 正文'

function fixture() {
  return {
    ok: true,
    generatedAt: GENERATED_AT,
    days: 30,
    today: {
      day: 20261012, dayStartAt: GENERATED_AT - 9 * 3600_000,
      usage: { egressBytes: 2 * 1024 * 1024, connections: 9, devices: 2, accounts: 2,
        firstSeenAt: GENERATED_AT - 5 * 3600_000, lastSeenAt: GENERATED_AT,
        builds: [{ build: '1.0 20261012.1056', devices: 2, accounts: 2 },
          { build: '1.0 20260924.1925', devices: 1, accounts: 1 }] },
      topAccounts: [{ accountId: 'acc_a', name: 'jayant', egressBytes: 2 * 1024 * 1024,
        connections: 9, devices: 2 }],
      devices: { new: 1, active: 2, revoked: 0, live: 3,
        list: [{ deviceId: 'dvc_a', name: 'iPhone 17 Pro', model: 'iPhone 17 Pro',
          appVersion: '1.2.3', accountId: 'acc_a', accountName: 'jayant',
          egressBytes: 2 * 1024 * 1024, connections: 9,
          firstSeenAt: GENERATED_AT - 5 * 3600_000, lastSeenAt: GENERATED_AT,
          lastBuild: '1.0 20261012.1056', revoked: false }] },
      feedback: { new: 1, open: 1, replied: 0, threads: [
        { threadId: 'th_a', createdAt: GENERATED_AT - 3600_000, status: 'open',
          subject: '新建会话转圈', ownerUnread: 1,
          source: { kind: 'device', deviceModel: 'iPhone 17 Pro', appVersion: '1.2.3' },
          excerpt: THREAD }] },
      invites: { used: 1, enrollments: [
        { usedAt: GENERATED_AT - 1800_000, inviteNote: '试用 <A>', accountId: 'acc_b',
          accountName: 'Sam', agentId: 'agt_b', agentName: 'Sam 的 MacBook', devices: 0 }] },
    },
    feedback: {
      new: 4, open: 2, replied: 2, medianFirstReplyHours: 6.5, test: 3,
      threads: [
        { threadId: 'th_a', createdAt: GENERATED_AT - 3600_000, status: 'open',
          source: { kind: 'device', deviceModel: 'iPhone 17 Pro', appVersion: '1.2.3' }, excerpt: THREAD },
        { threadId: 'th_b', createdAt: GENERATED_AT - 7200_000, status: 'replied',
          source: { kind: 'anonymous' }, excerpt: '匿名用户' },
      ],
    },
    devices: {
      paired: 12, active7d: 5, activeWindow: 6, newInWindow: 3, revoked: 1,
      newPerDay: [{ day: '2026-10-11', count: 2 }, { day: '2026-10-12', count: 1 }],
      list: [{ deviceId: 'dvc_a', name: 'DSH-Test', model: 'iPhone 17 Pro', appVersion: '1.2.3',
        createdAt: GENERATED_AT, lastSeenAt: GENERATED_AT, revoked: 0,
        push: { registered: true } }],
    },
    usage: {
      perDay: [{ day: '2026-10-11', egressBytes: 1024 * 1024, connections: 3, devices: 1, accounts: 1 },
        { day: '2026-10-12', egressBytes: 2 * 1024 * 1024, connections: 9, devices: 2, accounts: 2 }],
      topAccounts: [{ accountId: 'acc_a', name: 'jayant', egressBytes: 3 * 1024 * 1024,
        connections: 12, lastSeenAt: GENERATED_AT, lastBuild: '1.0 20261012.1056' }],
      totals: { egressBytes: 3 * 1024 * 1024, connections: 12 },
      averagePerDay: 1024 * 1024, peakDay: { day: '2026-10-12', egressBytes: 2 * 1024 * 1024 },
      activeDays: 2, activeAccounts: 2, activeAccounts7d: 2,
    },
    retention: {
      scope: 'external',
      users: { dau: 3, wau: 7, mau: 11, stickiness: 0.636, external: 21 },
      d1: { rate: 0.615, cohort: 13, active: 8 },
      d7: { rate: 0.4, cohort: 10, active: 4 },
      activation: { rate: 0.75, cohort: 8, active: 6 },
      weeks: [{ week: '2026-W40', size: 5, active: 3, rate: 0.6 },
        { week: '2026-W41', size: 4, active: 1, rate: 0.25 }],
    },
    invites: {
      minted: 30, used: 21, remaining: 9, test: 0,
      enrollments: [{ usedAt: GENERATED_AT, inviteNote: '试用 <A>', accountId: 'acc_a', accountName: 'jayant',
        agentId: 'agt_a', agentName: 'MacBook', devices: 1, lastSeenAt: GENERATED_AT }],
    },
  }
}

/// 假 runner：记录被调用过的 argv，并回一条像 admin.py 的 JSON。
function spy(reply = '{"ok":true}') {
  const calls = []
  return { calls, runner: (argv) => { calls.push(argv); return reply } }
}

/// 00:02 自动日报的那一份：生成时刻是 10-13 00:05，`today` 板块覆盖的是已经过完的 10-12
/// （服务端按 `--as-of yesterday` 给的 `today.day` / `dayStartAt` / `asOf`）。
function completedDayFixture() {
  const data = fixture()
  const dayStartAt = new Date(2026, 9, 12, 0, 0, 0).getTime()
  data.generatedAt = new Date(2026, 9, 13, 0, 5, 0).getTime()
  data.asOf = dayStartAt + 86_400_000 - 1
  data.today = { ...data.today, day: 20261012, dayStartAt }
  return data
}

function run(argv, { runner, approvalLog, env = { DSH_OTA_HOST: HOST, DSH_ACCOUNT_ID: OWNER } } = {}) {
  const out = []
  const err = []
  // 默认把留痕写进临时目录：用例绝不能碰真实 `~/Library/Logs`（宪法第 III 条）。
  const code = main(argv, {
    runner: runner ?? (() => { throw new Error('runner 不该被调用') }),
    env,
    approvalLog: approvalLog ?? approvalLogFile(),
    out: (line) => out.push(String(line)),
    err: (line) => err.push(String(line)),
  })
  return { code, out: out.join('\n'), err: err.join('\n') }
}

/// 审批留痕文件放临时目录：断言"批准过什么"记下来了，不往真实 `~/Library/Logs` 写。
function approvalLogFile() {
  return join(mkdtempSync(join(tmpdir(), 'feedback-approval-')), 'approvals.log')
}

function bodyFile(content = '您好：\n\n已收到反馈。\n\nDSH Mobile 团队\n2026-10-12\n') {
  const path = join(mkdtempSync(join(tmpdir(), 'feedback-test-')), 'body.txt')
  writeFileSync(path, content, 'utf8')
  return path
}

test('DSH_OTA_HOST 支持裸主机、user@host、URL 与端口', () => {
  assert.deepEqual(resolveSshTarget(HOST), { target: `root@${HOST}`, port: '' })
  assert.deepEqual(resolveSshTarget(`deploy@${HOST}`), { target: `deploy@${HOST}`, port: '' })
  assert.deepEqual(resolveSshTarget(`https://${HOST}/`), { target: `root@${HOST}`, port: '' })
  assert.deepEqual(resolveSshTarget(`https://ops@${HOST}:2222/x`), { target: `ops@${HOST}`, port: '2222' })
  assert.deepEqual(resolveSshTarget(`${HOST}:2222`), { target: `root@${HOST}`, port: '2222' })
  assert.throws(() => resolveSshTarget(''))
})

test('默认经 ssh 跑服务器上的 admin.py（信件类打 mail）', () => {
  const fake = spy('{"threads":[]}')
  const { code, out } = run(['list', '--status', 'open', '--limit', '20'], { runner: fake.runner })
  assert.equal(code, 0)
  const [command, ...rest] = fake.calls[0]
  assert.equal(command, 'ssh')
  assert.deepEqual(rest.slice(0, 2), ['-q', '-o'])
  assert.equal(rest[2], 'BatchMode=yes')
  assert.equal(rest.at(-2), `root@${HOST}`)
  assert.match(rest.at(-1), /^\/opt\/dsh-mail\/\.venv\/bin\/python \/opt\/dsh-mail\/admin\.py /)
  assert.match(rest.at(-1), /--db \/var\/lib\/dsh-mail\/mail\.db feedback-list --status open --limit 20/)
  assert.equal(out, '{"threads":[]}')
})

test('--local 跑本机 admin.py 与本机测试库，不碰 ssh', () => {
  const fake = spy('{"ok":true}')
  const { code } = run(['list', '--local'], { runner: fake.runner })
  assert.equal(code, 0)
  const argv = fake.calls[0]
  assert.notEqual(argv[0], 'ssh')
  assert.equal(argv[1], join(ROOT, 'mail', 'admin.py'))
  assert.ok(argv.includes(join(ROOT, 'mail', '.local', 'mail.db')), argv.join(' '))
})

test('reply 默认预演：runner 一次都不调用，正文原样打出来', () => {
  const fake = spy()
  const path = bodyFile()
  const { code, out } = run(['reply', '--thread', 'th_x', '--body-file', path], { runner: fake.runner })
  assert.equal(code, 0)
  assert.equal(fake.calls.length, 0)
  assert.match(out, /预演/)
  assert.match(out, /--send/)
  assert.match(out, /DSH Mobile 团队/)
})

test('reply --send 才真的执行，正文作远端参数传过去', () => {
  const fake = spy('{"ok":true,"threadId":"th_x","messageId":"fm_1"}')
  const log = approvalLogFile()
  const { code } = run(['reply', '--thread', 'th_x', '--body', '您好 & 谢谢', '--send', ...APPROVED],
    { runner: fake.runner, approvalLog: log })
  assert.equal(code, 0)
  assert.equal(fake.calls.length, 2, '给了批准就直发（不重读线程清单），发完自动存档')
  const remote = fake.calls[0].at(-1)
  assert.match(remote, /feedback-reply --thread th_x --body /)
  assert.match(remote, /您好 & 谢谢/)
  assert.equal(JSON.parse(readFileSync(log, 'utf8')).approval, '同意，发吧')
})

test('--dry-run 压过 --send/--yes，一次写都不发', () => {
  const reply = spy()
  const { code } = run(['reply', '--thread', 'th_x', '--body', '正文', '--send', '--dry-run'],
    { runner: reply.runner })
  assert.equal(code, 0)
  assert.equal(reply.calls.length, 0)

  const notify = spy('{"ok":true,"dryRun":true}')
  run(['notify', '--body', '正文', '--yes', '--dry-run'], { runner: notify.runner })
  assert.ok(!notify.calls[0].at(-1).includes('--yes'))

  // reply 也接受 --yes 这种写法（命令契约把两个开关并列写过）；真发后跟着一条存档。
  const alias = spy('{"ok":true}')
  run(['reply', '--thread', 'th_x', '--body', '正文', '--yes', ...APPROVED], { runner: alias.runner })
  assert.equal(alias.calls.length, 2, '发信一次 + 发件存档一次')
  assert.match(alias.calls[1].at(-1), /feedback-notify --body /)
})

test('notify 默认预演：服务器只统计收件人，argv 里没有 --yes', () => {
  const fake = spy('{"ok":true,"dryRun":true,"recipients":3}')
  const { code, out, err } = run(['notify', '--body', '维护通知'], { runner: fake.runner })
  assert.equal(code, 0)
  assert.equal(fake.calls.length, 1)
  assert.ok(!fake.calls[0].at(-1).includes('--yes'), '预演不得带 --yes')
  assert.match(out, /dryRun/)
  assert.match(err, /没有 --yes/)
})

test('notify --yes 才落库；delete 同理', () => {
  // notify --all：审批后先从中转展开账号（account-list 是第一条），再打 mail 的 notify。
  const calls = []
  const runner = (argv) => {
    calls.push(argv)
    const remote = argv.at(-1)
    if (/account-list/.test(remote)) return JSON.stringify([{ accountId: 'acc_b' }, { accountId: 'acc_c' }])
    if (/feedback-notify/.test(remote)) return '{"ok":true,"noticeId":"nt_a","recipients":2}'
    return '{"ok":true}'
  }
  const { code, err } = run(['notify', '--body', '维护通知', '--subject', 'S', '--all', '--yes', ...APPROVED],
    { runner, approvalLog: approvalLogFile() })
  assert.equal(code, 0)
  assert.match(err, /展开 --all）中转共 2 个账号/)
  const notifyRemote = calls[1].at(-1)
  assert.match(notifyRemote, /\/opt\/dsh-mail\/admin\.py [^\n]*feedback-notify --body /)
  assert.match(notifyRemote, /--subject S/)
  assert.match(notifyRemote, /--account acc_b --account acc_c/)
  assert.ok(!notifyRemote.includes('--all'), '--all 已展开成点名，不再下传')
  assert.match(notifyRemote, /--yes/)

  const del = spy('{"ok":true,"deleted":2}')
  const delCode = run(['delete', '--thread', 'th_x', '--yes'], { runner: del.runner })
  assert.equal(delCode.code, 0)
  assert.match(del.calls[0].at(-1), /feedback-delete --thread th_x --yes/)

  const preview = spy('{"deleted":2}')
  run(['delete', '--thread', 'th_x'], { runner: preview.runner })
  assert.ok(!preview.calls[0].at(-1).includes('--yes'))
})

test('notify --format html 的发件存档也按 html 投递（横幅 + 原件正文渲染，不是源码）', () => {
  const html = '<!DOCTYPE html><html><head><title>x</title></head><body><p>海报正文</p></body></html>'
  const fake = spy('{"ok":true,"noticeId":"nt_h"}')
  const { code } = run(['notify', '--body', html, '--subject', '专题', '--format', 'html',
    '--account', 'acc_b', '--yes', ...APPROVED], { runner: fake.runner, approvalLog: approvalLogFile() })
  assert.equal(code, 0)
  assert.equal(fake.calls.length, 2, '发信一次 + 发件存档一次')
  const archive = fake.calls[1].at(-1)
  assert.match(archive, /feedback-notify --body /)
  assert.match(archive, /--format html/, '存档跟随原件格式，否则 owner 收到一屏源码')
  assert.match(archive, /【发件存档】/)
  assert.match(archive, /发送对象：acc_b/)
  assert.match(archive, /<body><div style=/, '元数据横幅插在 body 之后')
  assert.match(archive, /<p>海报正文<\/p>/, '原件正文原样保留')
  assert.match(archive, /发件存档：通知「专题」/)
})

test('report / report-data 走双侧取数：中转 ops-report + mail feedback-stats', () => {
  const fake = spy(JSON.stringify(fixture()))
  const out = run(['report-data', '--days', '7'], { runner: fake.runner })
  assert.equal(out.code, 0)
  assert.equal(fake.calls.length, 3, 'device-list（中转）→ ops-report（中转）→ feedback-stats（mail）')
  assert.match(fake.calls[0].at(-1), /device-list --all/)
  assert.match(fake.calls[1].at(-1), /ops-report --days 7/)
  assert.match(fake.calls[2].at(-1), /\/opt\/dsh-mail\/admin\.py [^\n]*feedback-stats --days 7/)
  const merged = JSON.parse(out.out)
  assert.equal(merged.ok, true)
  assert.ok(merged.feedback, '合并后的报告仍带反馈板块')
})

test('report 把 JSON 渲染成 HTML 并打印落盘路径', () => {
  const outDir = mkdtempSync(join(tmpdir(), 'feedback-report-'))
  const fake = spy(JSON.stringify(fixture()))
  const { code, out } = run(['report', '--days', '30', '--out', outDir], { runner: fake.runner })
  assert.equal(code, 0)
  assert.equal(out, reportPath({ outDir, generatedAt: GENERATED_AT }))
  assert.match(readFileSync(out, 'utf8'), /<svg /)
})

test('report 默认落 maintainers/reports/YYYY-MM-DD.html', () => {
  assert.equal(reportPath({ generatedAt: GENERATED_AT }),
    join(ROOT, 'maintainers', 'reports', '2026-10-12.html'))
})

test('用法错误一律退出码 2（且不调用 runner）', () => {
  const body = bodyFile()
  const cases = [
    [],
    ['rm'],
    ['show'],
    ['show', '--thread'],
    ['reply', '--thread', 'th_x'],
    ['reply', '--body-file', body],
    ['reply', '--thread', 'th_x', '--body-file', '/tmp/feedback-does-not-exist.txt'],
    ['notify'],
    ['delete'],
    ['list', '--limit', 'abc'],
    ['list', '--limit'],
    ['list', '--nope'],
  ]
  for (const argv of cases) {
    const fake = spy()
    const { code, err } = run(argv, { runner: fake.runner })
    assert.equal(code, 2, `${argv.join(' ')} 应该退 2`)
    assert.equal(fake.calls.length, 0, `${argv.join(' ')} 不该执行任何命令`)
    assert.match(err, /用法错误|用法：/)
  }
})

test('缺 DSH_OTA_HOST 时退 2，并提示可以 --local', () => {
  const fake = spy()
  const { code, err } = run(['list'], { runner: fake.runner, env: {} })
  assert.equal(code, 2)
  assert.match(err, /DSH_OTA_HOST/)
  assert.equal(fake.calls.length, 0)
})

test('buildInvocation 的远端命令按 POSIX 引号化', () => {
  const invocation = buildInvocation(
    { sub: 'reply', opts: { thread: 'th_x', bodyText: "it's a test" } },
    { env: { DSH_OTA_HOST: HOST } },
  )
  assert.match(invocation.remote, /'it'\\''s a test'/)
})

test('日报分「今日」与「最近 30 天」两段，正文被转义', () => {
  const html = renderReport(fixture())
  // 两段：概览 + 趋势与留存。页面只有两张图（每日活跃用户、每日出口流量）。
  assert.ok(html.includes('<span class="tag ">今日</span>概览'), '今日板块')
  assert.ok(html.includes('<span class="tag range">最近 30 天</span>趋势与留存'), '30 天板块')
  assert.equal((html.match(/<svg /g) ?? []).length, 2, '只有每日活跃用户与每日出口流量两张图')
  assert.ok(html.includes('每日活跃用户') && html.includes('每日出口流量'))
  // 头牌是账号口径的活跃用户（owner 2026-10-17 定的口径），活跃手机降为状态行里的一个数。
  assert.ok(html.includes('今日活跃用户（电脑账号）') && html.includes('较昨日'))
  assert.ok(html.includes('活跃手机 2 台'), '状态行里给出同一天的设备行口径')
  assert.ok(!html.includes('今日活跃手机'), '头牌不再写活跃手机')
  assert.ok(html.includes('今日出口流量') && html.includes('较昨日 ↑ 100.0%'))
  assert.ok(html.includes('3.0 MB'), '出口字节应换算成 MB')
  // 近 7 天表：活跃用户与新增手机各一列。
  assert.ok(html.includes('活跃用户') && html.includes('新增手机'))
  // 留存：外部账号（页面写「电脑」）口径、D1/D7 与登记激活都要在页面上。
  assert.ok(html.includes('外部电脑 · 活跃=当天有中转连接'))
  for (const label of ['登记激活', '次日留存', '7 日留存']) {
    assert.ok(html.includes(label), `留存缺 ${label}`)
  }
  assert.ok(html.includes('62%') && html.includes('n=13'), '留存率要带队列人数')
  assert.ok(html.includes('已剔除测试提交 3 条'))
  // 2026-10-17 精简掉的那几块不再出现：版本分布、邀请码登记清单、分周队列表。
  for (const gone of ['今日版本分布', '邀请码登记', '2026-W40', '今日电脑']) {
    assert.ok(!html.includes(gone), `已精简的块不该再渲染：${gone}`)
  }
  assert.ok(!html.includes('<script>'), '正文里的 script 必须被转义')
  assert.ok(html.includes('&lt;script&gt;'))
})

test('手机上不写死宽表：长清单有上限', () => {
  const many = fixture()
  many.devices.list = Array.from({ length: 40 }, (_, i) => ({
    deviceId: `dvc_${i}`, name: `iPhone ${i}`, model: 'iPhone 17 Pro', appVersion: '1.2.3',
    createdAt: GENERATED_AT, lastSeenAt: GENERATED_AT, revoked: 0, push: { registered: true } }))
  many.usage.perDay = Array.from({ length: 30 }, (_, i) => ({
    day: 20260901 + i, egressBytes: 1024 * 1024, connections: 3, devices: 1, accounts: 1 }))
  const html = renderReport(many)
  // 清单只渲染前 6 台：正文长度因此不随库里的历史行数增长。
  assert.ok(html.includes('iPhone 5') && !html.includes('iPhone 39'), '手机清单只列前 6 台')
  assert.ok(html.includes('最近在线前 6 台'), '清单要说明只列了前几条')
  // 近 7 天表只留最近 7 行，不是整个 30 天窗口。
  assert.ok(html.includes('2026-09-30') && !html.includes('2026-09-01'), '表只列最近 7 天')
})

test('空数据也能渲染出可看的整页', () => {
  const html = renderReport({ ok: true, generatedAt: GENERATED_AT, days: 30 })
  assert.match(html, /<span class="tag ">今日<\/span>概览/)
  assert.match(html, /今日活跃用户（电脑账号）/)
  assert.match(html, /窗口内没有数据/)
  assert.match(html, /窗口内没有反馈/)
  assert.match(html, /窗口内没有用量记录/)
  assert.ok(!html.includes('NaN') && !html.includes('undefined'), '缺字段不能漏成 NaN/undefined')
})

test('escapeHtml 覆盖五个字符', () => {
  assert.equal(escapeHtml(`<a href="x" & 'y'>`), '&lt;a href=&quot;x&quot; &amp; &#39;y&#39;&gt;')
  assert.equal(escapeHtml(null), '')
})

test('「关注」板块把待办提到整页最上面，阈值越线才报警', () => {
  const html = renderReport(fixture())
  // fixture 的形状：2 条待回复、邀请码剩 9（≤10）——两条 warn 必须在关注区里。
  const focus = html.indexOf('要处理的事')
  assert.ok(focus > -1 && focus < html.indexOf('今日</span>概览'), '关注区在今日板块之前')
  assert.match(html, /反馈待回复 2 条，最早一条已等 1\.0 h/)
  assert.match(html, /邀请码只剩 9 张（21\/30 已用）/)
  assert.match(html, /2 件待办/)
  // d7 = 40% 不越线、推送全注册、没有背离：这三件不该出现。
  assert.ok(!html.includes('7 日留存 40%（n=10）低于'), '没越线的指标不报警')
  assert.ok(!html.includes('没注册推送'), '推送全注册不报警')
  // 没事的时候给一句明确的"没事"，不是一片空白。
  const quiet = fixture()
  quiet.feedback.open = 0
  quiet.invites.remaining = 20
  quiet.devices.newPerDay = [{ day: '2026-10-11', count: 30 }] // 达成目标，不报缺口
  quiet.usage.perDay = [{ day: '2026-10-11', egressBytes: 2 * 1024 * 1024, connections: 9, devices: 2 },
    { day: '2026-10-12', egressBytes: 2 * 1024 * 1024, connections: 9, devices: 2 }]
  assert.match(renderReport(quiet), /没有待回复反馈，余量与指标都在常态区间内/)
})

test('「关注」区只留要 owner 动作的待办，自动观察不再堆上去', () => {
  // fixture 的形状：2 条待回复、邀请码剩 9（≤10）——两条 warn 必须在关注区里。
  const html = renderReport(fixture())
  assert.match(html, /2 件待办/)
  // 2026-10-17 删掉的 info 级自动观察（周目标缺口、版本分裂、单日波动、背离）都不再出现。
  for (const gone of ['本周新增手机', '个 App 版本同时在用', '偏离超过', '核对重连逻辑']) {
    assert.ok(!html.includes(gone), `自动观察不该再出现在关注区：${gone}`)
  }
  assert.ok(!html.includes('<span class="chip up">提示</span>'), '关注区不再有 info 级提示条目')
})

test('推送注册率只算近 7 天活跃的手机（owner 2026-10-17 定）', () => {
  // 6 台未注册推送、但一个月没上线：废弃设备不进分母，不报警。
  const quiet = fixture()
  quiet.devices.list = Array.from({ length: 6 }, (_, i) => ({
    deviceId: `dvc_old_${i}`, name: 'iPhone', model: 'iPhone 17', appVersion: '1.2.3',
    createdAt: GENERATED_AT - 40 * 86_400_000, lastSeenAt: GENERATED_AT - 30 * 86_400_000,
    revoked: 0, push: { registered: false } }))
  assert.ok(!renderReport(quiet).includes('没注册推送'), '废弃设备不进分母')

  // 近 7 天活跃的 6 台里 4 台没注册：报警，文案写明分母是「近 7 天活跃」。
  const loud = fixture()
  loud.devices.list = Array.from({ length: 6 }, (_, i) => ({
    deviceId: `dvc_${i}`, name: 'iPhone', model: 'iPhone 17', appVersion: '1.2.3',
    createdAt: GENERATED_AT, lastSeenAt: GENERATED_AT - i * 3_600_000,
    revoked: 0, push: { registered: i < 2 } }))
  assert.match(renderReport(loud), /近 7 天活跃的 6 台手机里 4 台没注册推送（67%）/)
})

test('待回复反馈超过 24h SLA 时文案升级', () => {
  const data = fixture()
  data.feedback.threads[0].createdAt = GENERATED_AT - 30 * 3_600_000
  assert.match(renderReport(data), /最早一条已等 30\.0 h，超过 24h 响应 SLA/)
})

test('同一条待办连续挂三天，文案升级为「已连续 N 天未处理」', () => {
  const data = fixture()
  const dayStartAt = data.today.dayStartAt
  const history = { days: {}, alerts: { 'invites-low': { lastStart: dayStartAt - 86_400_000, count: 2 } } }
  const html = renderReport(data, { history })
  assert.match(html, /邀请码只剩 9 张（21\/30 已用），该补铸一批（已连续 3 天未处理）/)
  // 同一天重复渲染不重复计数。
  const sameDay = renderReport(data, { history:
    { days: {}, alerts: { 'invites-low': { lastStart: dayStartAt, count: 4 } } } })
  assert.match(sameDay, /已连续 4 天未处理/)
})

test('活跃用户有上周同期对照；留存漏斗不再写目标与上周小字', () => {
  const data = fixture()
  data.usage.perDay = Array.from({ length: 9 }, (_, i) => ({
    day: 20261004 + i, egressBytes: 1024 * 1024 * (i + 1), connections: 3,
    devices: i + 1, accounts: i + 1 }))
  data.today.usage.accounts = 9
  const html = renderReport(data)
  assert.match(html, /较上周同期 [↑→]/, '窗口满 8 天就有 WoW chip')  // 漏斗只留率与队列人数（小字删了），目标/WoW 这类对照线不再占位。
  assert.ok(!html.includes('目标 30%') && !html.includes('上周 50%'), '漏斗不再写目标与上周')
  assert.ok(!html.includes('上周同日'), '没有历史文件时也不写上周同日')
})

test('发版日在流量图上标注（构建号第一次出现在历史快照里的那天）', () => {
  const data = fixture()
  data.usage.perDay = [
    { day: 20261010, egressBytes: 1024 * 1024, connections: 3, devices: 1 },
    { day: 20261011, egressBytes: 2 * 1024 * 1024, connections: 4, devices: 2 },
    { day: 20261012, egressBytes: 3 * 1024 * 1024, connections: 9, devices: 2 }]
  const history = { days: {
    '20261010': { day: 20261010, dayStartAt: 1, builds: ['20261010.0900'] },
    '20261011': { day: 20261011, dayStartAt: 2, builds: ['20261011.1447'] },
  }, alerts: {} }
  const html = renderReport(data, { history })
  assert.ok(html.includes('>发版</text>'), '新版首次出现的那天有标注')
  assert.ok(!renderReport(data).includes('>发版</text>'), '没有历史文件就不标')
})

test('updateHistory 只记过完的一整天，并累计告警连续天数', () => {
  // 半天数据不记：午间手动跑的报告不该污染 WoW 对照。
  assert.equal(updateHistory(fixture()), null)

  const completed = completedDayFixture()
  const first = updateHistory(completed)
  assert.ok(first, '过完的一天要记')
  const snap = first.days['20261012']
  assert.equal(snap.dau, 3)
  assert.equal(snap.devicesActive, 2)
  assert.deepEqual(snap.builds, ['20261012.1056', '20260924.1925'])
  assert.equal(first.alerts['invites-low'].count, 1, '告警第一次出现 streak=1')

  // 次日同一告警还在：streak +1。生成时刻也要跟着往后推一天，否则这天还没"过完"。
  const nextDay = completedDayFixture()
  nextDay.today.day = 20261013
  nextDay.today.dayStartAt += 86_400_000
  nextDay.generatedAt += 86_400_000
  nextDay.feedback = { new: 0, open: 0, replied: 0, threads: [] } // 这条告警次日消失了
  const second = updateHistory(nextDay, first)
  assert.equal(second.alerts['invites-low'].count, 2)
  assert.equal(second.alerts['invites-low'].lastStart, nextDay.today.dayStartAt)
  // 不再出现的告警从账上清掉（下次再出现 streak 从 1 重算）。
  assert.ok(!('feedback-open' in second.alerts), '消失的告警不保留连续天数')
})

test('report --full-day 落盘时把当天摘要写进 .ops-history.json', () => {
  const outDir = mkdtempSync(join(tmpdir(), 'feedback-history-'))
  const full = spy(JSON.stringify(completedDayFixture()))
  const { code } = run(['report', '--out', outDir, '--full-day'], { runner: full.runner })
  assert.equal(code, 0)
  const history = JSON.parse(readFileSync(join(outDir, '.ops-history.json'), 'utf8'))
  assert.ok(history.days['20261012'], '过完的那一天要记账')
  assert.equal(history.days['20261012'].dau, 3)
  assert.equal(history.alerts['invites-low'].count, 1)

  // 半天数据（不带 --full-day 的当天报告）不写历史，免得污染 WoW 对照。
  const outDir2 = mkdtempSync(join(tmpdir(), 'feedback-history-partial-'))
  run(['report', '--out', outDir2], { runner: spy(JSON.stringify(fixture())).runner })
  assert.ok(!existsSync(join(outDir2, '.ops-history.json')), '部分数据不记账')
})

test('机型代码转人话，查不到的原样保留', () => {
  assert.equal(humanModel('iPhone15,4'), 'iPhone 15')
  assert.equal(humanModel('iPhone11,8'), 'iPhone XR')
  assert.equal(humanModel('iPhone18,3'), 'iPhone 17')
  assert.equal(humanModel('iPhone99,9'), 'iPhone99,9', '新型号别乱猜')
  assert.equal(humanModel('iPhone 17 Pro'), 'iPhone 17 Pro', '已经是人话的原样通过')
  const data = fixture()
  data.devices.list[0].model = 'iPhone15,4'
  assert.ok(renderReport(data).includes('iPhone 15'))
})

test('日报不再渲染邀请码登记清单（登记只在关注区作为余量提醒出现）', () => {
  const html = renderReport(fixture())
  assert.ok(!html.includes('邀请码登记'), '窗口登记清单已删')
  assert.ok(!html.includes('Sam 的 MacBook'), '登记明细不再上页面')
  assert.match(html, /邀请码只剩 9 张（21\/30 已用）/, '余量提醒仍在关注区')
})

test('活跃时段接近一整天时写「全天有连接」', () => {
  const data = completedDayFixture()
  const dayEnd = data.today.dayStartAt + 86_400_000 - 1
  data.today.usage.firstSeenAt = data.today.dayStartAt + 60_000
  data.today.usage.lastSeenAt = dayEnd
  assert.match(renderReport(data), /全天有连接/)
  assert.ok(!renderReport(data).includes('活跃时段 00:01–23:59'), '不再写占地方的整点跨度')
})

test('LaunchAgent 模板每天 00:02 跑、带 --full-day 与日志路径', () => {
  const template = readFileSync(PLIST, 'utf8')
  assert.match(template, /<string>com\.jayanttang\.dsh-daily-report<\/string>/)
  assert.match(template, /<key>StartCalendarInterval<\/key>/)
  // owner 2026-10-12：改成晚上 12 点、发刚过去的一整天。00:02 不是整点——中转每 30 秒
  // 才把用量冲一次盘，整点跑会少最后一小段（理由写在模板注释里）。
  assert.match(template, /<key>Hour<\/key>\s*<integer>0<\/integer>/)
  assert.match(template, /<key>Minute<\/key>\s*<integer>2<\/integer>/)
  assert.ok((template.match(/dsh-daily-report\.log/g) ?? []).length >= 2, 'stdout/stderr 都要日志')
  assert.match(template, /--days<\/string>\s*<string>30<\/string>/)
  assert.match(template, /--full-day<\/string>/, '定时任务报的是刚过去的一整天')
  assert.match(template, /feedback\.mjs<\/string>/)
})

test('report --full-day 让 ops-report 锚到刚过去的一整天', () => {
  const outDir = mkdtempSync(join(tmpdir(), 'feedback-fullday-'))
  const full = spy(JSON.stringify(fixture()))
  const { code } = run(['report', '--out', outDir, '--full-day'], { runner: full.runner })
  assert.equal(code, 0)
  assert.match(full.calls[1].at(-1), /ops-report --days 30 --as-of yesterday/)
  assert.match(full.calls[2].at(-1), /feedback-stats --days 30 --as-of yesterday/)

  const plain = spy(JSON.stringify(fixture()))
  run(['report', '--out', outDir], { runner: plain.runner })
  assert.ok(!plain.calls[1].at(-1).includes('--as-of'), '不给 --full-day 就是当天到此刻')
})

test('report --date 把报告锚到指定那一天（今天 = 到现在）', () => {
  const outDir = mkdtempSync(join(tmpdir(), 'feedback-date-'))
  const fixed = spy(JSON.stringify(fixture()))
  const { code } = run(['report', '--out', outDir, '--date', '2026-10-09'], { runner: fixed.runner })
  assert.equal(code, 0)
  assert.match(fixed.calls[1].at(-1), /ops-report --days 30 --as-of 2026-10-09/,
    '给具体日期就报那一整天')

  const today = spy(JSON.stringify(fixture()))
  run(['report', '--out', outDir, '--date', 'today'], { runner: today.runner })
  assert.match(today.calls[1].at(-1), /ops-report --days 30 --as-of now/,
    '今天还没过完，就是当天 00:00 到此刻')

  const yesterday = spy(JSON.stringify(fixture()))
  run(['report', '--out', outDir, '--date', 'yesterday'], { runner: yesterday.runner })
  assert.match(yesterday.calls[1].at(-1), /--as-of yesterday/)
})

test('--date 与 --full-day 的冲突、非法日期与错子命令都判用法错误（退出码 2）', () => {
  const both = run(['report', '--date', '2026-10-09', '--full-day'], { runner: spy().runner })
  assert.equal(both.code, 2, '等价的两种写法同时给要报错，不能静默选一个')
  assert.match(both.err, /--full-day 就是 --date yesterday/)

  for (const bad of ['2026-02-30', '2026-10-9', 'last-week']) {
    const { code, err } = run(['report', '--date', bad], { runner: spy().runner })
    assert.equal(code, 2, `${bad} 该判用法错误`)
    assert.match(err, /--date/)
  }

  const wrongSub = run(['list', '--date', 'today'], { runner: spy().runner })
  assert.equal(wrongSub.code, 2, '日期口径只有 report 有')
})

test('服务端不回覆盖日时，文件名用 --date 指定的那天兜底', () => {
  const outDir = mkdtempSync(join(tmpdir(), 'feedback-dateday-'))
  const data = fixture()
  delete data.today.day
  const { code, out } = run(['report', '--out', outDir, '--date', '2026-10-09'],
    { runner: spy(JSON.stringify(data)).runner })
  assert.equal(code, 0)
  assert.ok(out.trim().endsWith('2026-10-09.html'), `文件名该是覆盖日，实际 ${out}`)
})

test('reportPath 按覆盖日命名：00:02 生成的那份叫前一天', () => {
  const nextDay = new Date(2026, 9, 13, 0, 2, 0).getTime()
  assert.equal(basename(reportPath({ outDir: '/tmp', day: 20261012, generatedAt: nextDay })),
    '2026-10-12.html')
  assert.equal(basename(reportPath({ outDir: '/tmp', generatedAt: nextDay })), '2026-10-13.html',
    '老服务端没有 today.day 时退回按生成时刻命名')
})

test('覆盖整天的日报按覆盖日写日期、标题与「全天」标签', () => {
  const completed = completedDayFixture()
  // 跨零点的连接会被中转记在前一天的行上（lastSeenAt 落在覆盖日之后）：夹回 23:59。
  const dayEnd = completed.today.dayStartAt + 86_400_000
  completed.today.usage.firstSeenAt = completed.today.dayStartAt + 5 * 3600_000
  completed.today.usage.lastSeenAt = dayEnd + 13_000
  completed.today.devices.list[0].lastSeenAt = dayEnd + 13_000
  const html = renderReport(completed)
  assert.ok(html.includes('<title>DSH Mobile 运营日报 · 2026-10-12</title>'), '标题是覆盖日')
  assert.ok(html.includes('2026-10-12 周一'), '周几也要按覆盖日算')
  assert.ok(html.includes('<span class="tag ">全天</span>概览'), '过完的那一天叫「整天」')
  assert.ok(html.includes('10-12 自然日 00:00–23:59（已过完）'))
  assert.ok(html.includes('全天活跃用户（电脑账号）') && html.includes('较前一日'))
  assert.ok(html.includes('全天出口流量'), '成本口径跟着覆盖日的叫法')
  assert.ok(html.includes('本地日窗口（含 10-12）'))
  assert.ok(html.includes('活跃用户 = 当天有中转连接的电脑'))
  assert.ok(html.includes('活跃时段 05:00–23:59'), '跨零点的时间要夹到 23:59')
  assert.ok(!/23:59–00:00/.test(html), '不能出现回到 00:00 的时段')
  assert.ok(!html.includes('较昨日'), '10-13 生成的页面上不能把 10-12 写成"今日"')
})

test('reply / notify 的 --format 透传；不传就不出现在 argv 里', () => {
  const reply = spy('{"ok":true}')
  run(['reply', '--thread', 'th_x', '--body', '正文', '--format', 'html', '--send', ...APPROVED], { runner: reply.runner })
  assert.match(reply.calls[0].at(-1), /feedback-reply --thread th_x --body .*--format html/)

  const notify = spy('{"ok":true}')
  run(['notify', '--body', '维护通知', '--account', 'acc_a', '--format', 'html', '--yes', ...APPROVED],
    { runner: notify.runner })
  assert.match(notify.calls[0].at(-1), /feedback-notify --body .*--format html/)

  // 不传 --format 时保持既有 argv：服务器默认 text。
  const plain = spy('{"ok":true}')
  run(['notify', '--body', '维护通知', '--account', 'acc_a', '--yes', ...APPROVED], { runner: plain.runner })
  assert.ok(!plain.calls[0].at(-1).includes('--format'), '不传 --format 不得凭空加参数')

  const plainReply = spy('{"ok":true}')
  run(['reply', '--thread', 'th_x', '--body', '正文', '--send', ...APPROVED], { runner: plainReply.runner })
  assert.ok(!plainReply.calls[0].at(-1).includes('--format'), '不传 --format 不得凭空加参数')

  const bad = spy()
  const { code, err } = run(['notify', '--body', '维护通知', '--format', 'markdown'], { runner: bad.runner })
  assert.equal(code, 2)
  assert.equal(bad.calls.length, 0)
  assert.match(err, /--format/)
})

test('report --send：先 scp，再按 html 通知，最后删远端临时文件', () => {
  const outDir = mkdtempSync(join(tmpdir(), 'feedback-send-'))
  const fake = spy(JSON.stringify(fixture()))
  const { code, out } = run(
    ['report', '--out', outDir, '--send', '--account', 'acc_a', '--account', 'acc_b', ...APPROVED],
    { runner: fake.runner, approvalLog: approvalLogFile() },
  )
  assert.equal(code, 0)
  const local = join(outDir, '2026-10-12.html')
  const remote = '/tmp/dsh-feedback-report-2026-10-12.html'
  assert.equal(fake.calls.length, 7,
    `应当是 device-list → ops-report → feedback-stats → scp → notify → 清理 → 存档：${fake.calls.length} 次调用`)
  assert.match(fake.calls[0].at(-1), /device-list --all/)
  assert.match(fake.calls[1].at(-1), /ops-report --days 30/)
  assert.match(fake.calls[2].at(-1), /feedback-stats --days 30/)

  const scp = fake.calls[3]
  assert.equal(scp[0], 'scp')
  assert.equal(scp.at(-2), local)
  assert.equal(scp.at(-1), `root@${HOST}:${remote}`)

  const command = fake.calls[4].at(-1)
  assert.equal(fake.calls[4][0], 'ssh')
  assert.match(command, /\/opt\/dsh-mail\/admin\.py/)
  assert.match(command, new RegExp(`feedback-notify --body-file ${remote} `))
  assert.match(command, /--format html/)
  assert.match(command, /--subject 'DSH Mobile 运营日报 2026-10-12'/)
  assert.match(command, /--account acc_a --account acc_b/)
  assert.match(command, /--yes/)
  assert.ok(!command.includes('--all'), '直投指定账号，不得群发')
  assert.ok(!/--body /.test(command), '正文必须走 --body-file，不能塞进 ssh 参数')

  assert.equal(fake.calls[5][0], 'ssh')
  assert.equal(fake.calls[5].at(-1), `rm -f ${remote}`)
  // 收件人里有别人（acc_a、acc_b）：投递成功后自动给 owner 存档（text，记标识与落点）。
  const archive = fake.calls[6].at(-1)
  assert.equal(fake.calls[6][0], 'ssh')
  assert.match(archive, /feedback-notify --body /)
  assert.match(archive, new RegExp(`--account ${OWNER}`))
  assert.match(archive, /发件存档：日报「DSH Mobile 运营日报 2026-10-12」/)
  assert.match(archive, /发送对象：acc_a、acc_b/)
  assert.match(archive, /HTML 日报/)
  assert.equal(out.split('\n')[0], local)
  assert.match(readFileSync(local, 'utf8'), /<svg /)
})

test('report --send 的 --subject 覆盖默认标题', () => {
  const outDir = mkdtempSync(join(tmpdir(), 'feedback-send-subject-'))
  const fake = spy(JSON.stringify(fixture()))
  const { code } = run(['report', '--out', outDir, '--send', '--account', 'acc_a', '--subject', '周报', ...APPROVED],
    { runner: fake.runner, approvalLog: approvalLogFile() })
  assert.equal(code, 0)
  assert.match(fake.calls[4].at(-1), /--subject '周报'/)
})

test('report --send 收件账号：--account 优先，其次 .env.local 的 DSH_ACCOUNT_ID', () => {
  // 没给 --account 时取 DSH_ACCOUNT_ID（定时任务的 plist 里不再有任何 id）。
  const outDir = mkdtempSync(join(tmpdir(), 'feedback-send-env-'))
  const fake = spy(JSON.stringify(fixture()))
  const { code } = run(['report', '--out', outDir, '--send'],
    { runner: fake.runner, env: { DSH_OTA_HOST: HOST, DSH_ACCOUNT_ID: 'acc_env' } })
  assert.equal(code, 0)
  assert.match(fake.calls[4].at(-1), /--account acc_env/)

  // 命令行给了就压过 .env.local（换账号试发时不必改本机真值）；换成别人的账号就要审批。
  const explicit = spy(JSON.stringify(fixture()))
  const other = mkdtempSync(join(tmpdir(), 'feedback-send-env2-'))
  run(['report', '--out', other, '--send', '--account', 'acc_cli', ...APPROVED],
    { runner: explicit.runner, approvalLog: approvalLogFile(),
      env: { DSH_OTA_HOST: HOST, DSH_ACCOUNT_ID: 'acc_env' } })
  assert.match(explicit.calls[4].at(-1), /--account acc_cli/)
  assert.ok(!explicit.calls[4].at(-1).includes('acc_env'))
})

test('report --send 一个账号都取不到时退 2，不执行任何命令（也不群发）', () => {
  for (const argv of [['report', '--send'], ['report', '--send', '--all']]) {
    const fake = spy()
    // env 里没有 DSH_ACCOUNT_ID：连"发给谁"都取不到
    const { code, err } = run(argv, { runner: fake.runner, env: { DSH_OTA_HOST: HOST } })
    assert.equal(code, 2, `${argv.join(' ')} 应该退 2`)
    assert.equal(fake.calls.length, 0)
    assert.match(err, /--account|--all|DSH_ACCOUNT_ID/)
  }
})

test('report --send --dry-run 只生成报告并打印将执行的命令', () => {
  const outDir = mkdtempSync(join(tmpdir(), 'feedback-send-dry-'))
  const fake = spy(JSON.stringify(fixture()))
  const { code, out } = run(['report', '--out', outDir, '--send', '--account', 'acc_a', '--dry-run'],
    { runner: fake.runner })
  assert.equal(code, 0)
  assert.equal(fake.calls.length, 3, '预演只跑三次只读取数（清单 ×2 + 报告数据）')
  assert.match(fake.calls[0].at(-1), /device-list/)
  assert.match(fake.calls[1].at(-1), /ops-report/)
  assert.match(fake.calls[2].at(-1), /feedback-stats/)
  assert.match(out, /预演/)
  assert.match(out, /scp /)
  assert.match(out, /feedback-notify --body-file \/tmp\/dsh-feedback-report-2026-10-12\.html/)
  assert.match(out, /rm -f \/tmp\/dsh-feedback-report-2026-10-12\.html/)
})

test('notify 失败时远端临时文件仍然被删掉，退出码 1', () => {
  const outDir = mkdtempSync(join(tmpdir(), 'feedback-send-fail-'))
  const calls = []
  const runner = (argv) => {
    calls.push(argv)
    if (/feedback-notify/.test(String(argv.at(-1)))) throw new Error('notify 挂了')
    return JSON.stringify(fixture())
  }
  const { code, err } = run(['report', '--out', outDir, '--send', '--account', 'acc_a', ...APPROVED],
    { runner, approvalLog: approvalLogFile() })
  assert.equal(code, 1)
  assert.equal(calls.length, 6, 'device-list → ops-report → feedback-stats → scp → notify(挂) → rm')
  assert.equal(calls[5].at(-1), 'rm -f /tmp/dsh-feedback-report-2026-10-12.html')
  assert.match(err, /notify 挂了/)
})

test('report --send --local 直接读本机报告文件，不 scp 也不清理', () => {
  const outDir = mkdtempSync(join(tmpdir(), 'feedback-send-local-'))
  const fake = spy(JSON.stringify(fixture()))
  const { code } = run(['report', '--out', outDir, '--send', '--account', 'acc_a', '--local', ...APPROVED],
    { runner: fake.runner, approvalLog: approvalLogFile() })
  assert.equal(code, 0)
  assert.equal(fake.calls.length, 5, 'device-list → ops-report → feedback-stats → notify → 发件存档')
  assert.ok(fake.calls.every((argv) => argv[0] !== 'scp' && argv[0] !== 'ssh'))
  const notify = fake.calls[3]
  assert.ok(notify.includes(join(outDir, '2026-10-12.html')), notify.join(' '))
  assert.ok(notify.includes('--format') && notify.includes('html'))
  assert.ok(notify.includes('--yes'))
  assert.ok(!notify.at(-1).includes('rm -f'))
  // 存档同样走本机 admin.py，收件人只有 owner。
  const archive = fake.calls[4]
  assert.ok(archive.includes(join(ROOT, 'mail', 'admin.py')), archive.join(' '))
  assert.ok(archive.includes('--account'), archive.join(' '))
  assert.match(archive.join(' '), /发件存档：日报/)
})

test('renderAgentPlist 把占位符换成绝对路径', () => {
  const plist = renderAgentPlist({ nodePath: '/opt/node/bin/node', repoRoot: '/srv/dsh' })
  assert.ok(!plist.includes('__'), '不能留下占位符')
  assert.match(plist, /<string>\/opt\/node\/bin\/node<\/string>/)
  assert.match(plist, /<string>\/srv\/dsh\/scripts\/dev\/feedback\.mjs<\/string>/)
  assert.match(plist, /<key>WorkingDirectory<\/key>\s*<string>\/srv\/dsh<\/string>/)
  assert.ok(!plist.includes('<string>~/'), 'launchd 不展开 ~，安装时必须绝对化')
  // 019：定时任务固定带 --send，收件账号运行时从 .env.local 取；plist 里不留任何 id。
  assert.match(plist, /<string>--send<\/string>/)
  assert.ok(!plist.includes('--device'), '设备维度已删：plist 里不该再有 --device')
  assert.ok(!/dev_|acc_/.test(plist), 'plist 里不该写任何设备或账号 id')
})

// ── 审批门（AGENTS.md 硬性约束第 9 条）：写给别人的信先要 owner 的批准 ────────────────

test('foreignRecipients：没配 DSH_ACCOUNT_ID 时每个账号都算别人', () => {
  assert.deepEqual(foreignRecipients({ accounts: ['a', 'b'] }, 'a'), { all: false, foreign: ['b'] })
  assert.deepEqual(foreignRecipients({ accounts: ['a'] }, ''), { all: false, foreign: ['a'] })
  assert.deepEqual(foreignRecipients({ accounts: [OWNER] }, OWNER), { all: false, foreign: [] })
  assert.deepEqual(foreignRecipients({ accounts: [], all: true }, OWNER), { all: true, foreign: [] })
})

test('审批门：写给别人的信没给 --owner-approved 就退 2，一次写都不发', () => {
  // notify 点名别人的账号
  const notify = spy('{"ok":true,"noticeId":"nt_a"}')
  const notified = run(['notify', '--body', '维护通知', '--account', 'acc_b', '--yes'],
    { runner: notify.runner, approvalLog: approvalLogFile() })
  assert.equal(notified.code, 2)
  assert.equal(notify.calls.length, 0, '拒发时一条命令都不执行')
  assert.match(notified.err, /未获 owner 批准/)
  assert.match(notified.err, /--owner-approved/)
  assert.match(notified.err, /acc_b/)

  // notify --all：本机看不到账号名单，一律要批准
  const everyone = spy('{"ok":true,"noticeId":"nt_b"}')
  const all = run(['notify', '--body', '全体通知', '--all', '--yes'],
    { runner: everyone.runner, approvalLog: approvalLogFile() })
  assert.equal(all.code, 2)
  assert.equal(everyone.calls.length, 0)
  assert.match(all.err, /--all/)

  // reply：只允许读一次线程清单，读出来不是 owner 的就不回信
  const reply = spy(JSON.stringify([{ threadId: 'th_x', source: { accountId: 'acc_b' } }]))
  const replied = run(['reply', '--thread', 'th_x', '--body', '正文', '--send'],
    { runner: reply.runner, approvalLog: approvalLogFile() })
  assert.equal(replied.code, 2)
  assert.equal(reply.calls.length, 1, '只读清单，不回信')
  assert.match(reply.calls[0].at(-1), /feedback-list/)
  assert.match(replied.err, /th_x/)

  // reply：清单读不出来（不是 JSON）也算"发给别人"
  const garbled = spy('ssh 挂了')
  const undecided = run(['reply', '--thread', 'th_x', '--body', '正文', '--send'],
    { runner: garbled.runner, approvalLog: approvalLogFile() })
  assert.equal(undecided.code, 2)
  assert.equal(garbled.calls.filter((argv) => /feedback-reply/.test(argv.at(-1))).length, 0)

  // report --send 点名别人的账号：连只读的 ops-report 都不跑
  const report = spy(JSON.stringify(fixture()))
  const outDir = mkdtempSync(join(tmpdir(), 'feedback-gate-report-'))
  const sent = run(['report', '--out', outDir, '--send', '--account', 'acc_b'],
    { runner: report.runner, approvalLog: approvalLogFile() })
  assert.equal(sent.code, 2)
  assert.equal(report.calls.length, 0)

  // --owner-approved 后面没值 = 用法错误
  const missing = run(['notify', '--body', '通知', '--account', 'acc_b', '--yes', '--owner-approved'],
    { runner: spy().runner, approvalLog: approvalLogFile() })
  assert.equal(missing.code, 2)
})

test('审批门：只发给 owner 自己、或回复自己的线程，不需要批准', () => {
  const log = approvalLogFile()
  const notify = spy('{"ok":true,"noticeId":"nt_a"}')
  const mine = run(['notify', '--body', '给自己', '--account', OWNER, '--yes'],
    { runner: notify.runner, approvalLog: log })
  assert.equal(mine.code, 0)
  assert.match(notify.calls[0].at(-1), new RegExp(`--account ${OWNER}`))

  // 日报的默认收件账号就是 DSH_ACCOUNT_ID（定时任务的口径）→ 不加审批也照发
  const outDir = mkdtempSync(join(tmpdir(), 'feedback-gate-daily-'))
  const daily = spy(JSON.stringify(fixture()))
  const sent = run(['report', '--out', outDir, '--send'], { runner: daily.runner, approvalLog: log })
  assert.equal(sent.code, 0)
  assert.ok(daily.calls.some((argv) => /feedback-notify/.test(argv.at(-1))), '日报必须真的投出去')

  // 回信：清单说这条线程就是 owner 自己的
  const ownThread = spy(JSON.stringify([{ threadId: 'th_mine', source: { accountId: OWNER } }]))
  const replied = run(['reply', '--thread', 'th_mine', '--body', '正文', '--send'],
    { runner: ownThread.runner, approvalLog: log })
  assert.equal(replied.code, 0)
  assert.equal(ownThread.calls.length, 2, '先读清单判归属，再回信')
  assert.match(ownThread.calls[0].at(-1), /feedback-list --status all --limit 500/)
  assert.match(ownThread.calls[1].at(-1), /feedback-reply --thread th_mine/)

  assert.ok(!existsSync(log), '全程没走审批，不该留下任何"批准"记录')
})

test('审批门：预演不判——没有 --send/--yes 或带 --dry-run 都能跑', () => {
  const notify = spy('{"ok":true,"dryRun":true,"recipients":3}')
  const preview = run(['notify', '--body', '通知', '--all'],
    { runner: notify.runner, approvalLog: approvalLogFile() })
  assert.equal(preview.code, 0)
  assert.ok(!notify.calls[0].at(-1).includes('--yes'))

  const dry = spy('{"ok":true,"dryRun":true}')
  assert.equal(run(['notify', '--body', '通知', '--all', '--yes', '--dry-run'],
    { runner: dry.runner, approvalLog: approvalLogFile() }).code, 0)

  const reply = spy()
  assert.equal(run(['reply', '--thread', 'th_x', '--body', '正文'],
    { runner: reply.runner, approvalLog: approvalLogFile() }).code, 0)
  assert.equal(reply.calls.length, 0, '回信预演不读清单')
})

test('审批门：批准过的发送留一条 JSON 痕（原话 + 收件人）', () => {
  const log = approvalLogFile()
  const notify = spy('{"ok":true,"noticeId":"nt_a"}')
  const { code, err } = run(['notify', '--body', '维护通知', '--subject', 'S', '--account', 'acc_b', '--yes', ...APPROVED],
    { runner: notify.runner, approvalLog: log })
  assert.equal(code, 0)
  assert.match(notify.calls[0].at(-1), /--yes/)
  const record = JSON.parse(readFileSync(log, 'utf8'))
  assert.equal(record.sub, 'notify')
  assert.deepEqual(record.accounts, ['acc_b'])
  assert.equal(record.subject, 'S')
  assert.equal(record.approval, '同意，发吧')
  assert.equal(record.ownerAccount, OWNER)
  assert.ok(record.bodyBytes > 0, '正文长度要记下来')
  assert.match(err, /已批准/)

  // 群发那条记成 --all，不留空数组
  const log2 = approvalLogFile()
  run(['notify', '--body', '全体通知', '--all', '--yes', ...APPROVED],
    { runner: spy('{"ok":true,"noticeId":"nt_b"}').runner, approvalLog: log2 })
  assert.deepEqual(JSON.parse(readFileSync(log2, 'utf8')).accounts, ['--all'])

  // 回信那条记线程 id
  const log3 = approvalLogFile()
  run(['reply', '--thread', 'th_x', '--body', '正文', '--send', ...APPROVED],
    { runner: spy('{"ok":true}').runner, approvalLog: log3 })
  assert.equal(JSON.parse(readFileSync(log3, 'utf8')).thread, 'th_x')
})

test('审批门：留痕写不进去就不发（不留无凭据的发送）', () => {
  const blocker = join(mkdtempSync(join(tmpdir(), 'feedback-approval-')), 'a-file')
  writeFileSync(blocker, 'x')
  const fake = spy('{"ok":true,"noticeId":"nt_a"}')
  const { code, err } = run(['notify', '--body', '通知', '--account', 'acc_b', '--yes', ...APPROVED],
    { runner: fake.runner, approvalLog: join(blocker, 'nested', 'approvals.log') })
  assert.equal(code, 2)
  assert.equal(fake.calls.length, 0)
  assert.match(err, /留痕/)
})

// ── 发件存档（owner 2026-10-15 要求）：发给别人的信落地后自动抄送 owner 账号 ─────────

test('发件存档：notify 发给别人的信，存档含全文、发送对象、发送人与 noticeId', () => {
  const fake = spy('{"ok":true,"noticeId":"nt_9"}')
  const { code, out } = run(
    ['notify', '--body', '维护通知正文', '--subject', '维护', '--account', 'acc_b', '--yes', ...APPROVED],
    { runner: fake.runner, approvalLog: approvalLogFile() })
  assert.equal(code, 0)
  assert.equal(fake.calls.length, 2, '一次发信 + 一次存档')
  const archive = fake.calls[1].at(-1)
  assert.match(archive, new RegExp(`--account ${OWNER} `))
  assert.match(archive, /--yes/)
  assert.ok(!archive.includes('acc_b --yes') || archive.includes(`--account ${OWNER}`))
  assert.match(archive, /发件存档：通知「维护」/)
  assert.match(archive, /发送对象：acc_b/)
  assert.match(archive, /系统代发（owner 审批原话：同意，发吧）/)
  assert.match(archive, /原件 ID：nt_9/)
  assert.match(archive, /维护通知正文/)
  assert.match(out, /（发件存档）已投给 owner 账号：nt_9/)
})

test('发件存档：群发 --all 展开后也存档，发送对象写"全部账号（展开为 N 个）"', () => {
  const calls = []
  const runner = (argv) => {
    calls.push(argv)
    const remote = String(argv.at(-1))
    if (/account-list/.test(remote)) return JSON.stringify([{ accountId: 'acc_b' }, { accountId: 'acc_c' }])
    if (/feedback-notify/.test(remote)) return '{"ok":true,"noticeId":"nt_10"}'
    return '{"ok":true}'
  }
  const { code } = run(['notify', '--body', '公告', '--all', '--yes', ...APPROVED],
    { runner, approvalLog: approvalLogFile() })
  assert.equal(code, 0)
  assert.equal(calls.length, 3, 'account-list（中转展开）→ notify（mail）→ 存档（mail）')
  assert.match(calls[1].at(-1), /--account acc_b --account acc_c/)
  assert.match(calls[2].at(-1), /发送对象：全部账号（--all 群发，展开为 2 个）/)
})

test('发件存档：只发给 owner 自己的不存档（自己的收件箱里本来就有）', () => {
  const fake = spy('{"ok":true,"noticeId":"nt_11"}')
  const { code } = run(['notify', '--body', '给自己', '--account', OWNER, '--yes'],
    { runner: fake.runner, approvalLog: approvalLogFile() })
  assert.equal(code, 0)
  assert.equal(fake.calls.length, 1, '不抄送自己')

  // 回复 owner 自己的线程同样不存档。
  const ownThread = spy(JSON.stringify([{ threadId: 'th_mine', source: { accountId: OWNER } }]))
  run(['reply', '--thread', 'th_mine', '--body', '正文', '--send'],
    { runner: ownThread.runner, approvalLog: approvalLogFile() })
  assert.equal(ownThread.calls.length, 2, '读清单判归属 + 回信，没有第三条存档')
})

test('发件存档：存档失败不改退出码（原件已发出，退非零会让上层重发），stderr 喊补档', () => {
  const calls = []
  const runner = (argv) => {
    calls.push(argv)
    if (calls.length === 2) throw new Error('存档挂了')   // 2 = 存档那次
    return '{"ok":true,"noticeId":"nt_12"}'
  }
  const { code, err } = run(['notify', '--body', '通知', '--account', 'acc_b', '--yes', ...APPROVED],
    { runner, approvalLog: approvalLogFile() })
  assert.equal(code, 0, '原件已发出，不得退非零诱发重发')
  assert.equal(calls.length, 2)
  assert.match(err, /发件存档失败（信件已发出，需手动补档）/)
})

test('发件存档：预演与拒发都不存档', () => {
  const dry = spy('{"ok":true,"dryRun":true}')
  run(['notify', '--body', '通知', '--all', '--yes', '--dry-run'],
    { runner: dry.runner, approvalLog: approvalLogFile() })
  assert.equal(dry.calls.length, 1, '预演只有服务器那次统计')

  const refused = spy('{"ok":true}')
  run(['notify', '--body', '通知', '--account', 'acc_b', '--yes'],
    { runner: refused.runner, approvalLog: approvalLogFile() })
  assert.equal(refused.calls.length, 0, '没批准连原件都没发，更没有存档')
})


// ── 双目标（DESIGN-20261015 M4）：合并、调试设备规则与 --all 展开的边界 ─────────

test('mergeReportData：mail 的反馈两块覆盖中转的，其余板块原样保留', () => {
  const relayReport = {
    ok: true, generatedAt: 1, days: 30,
    today: { day: 20261015, usage: { egressBytes: 5 }, feedback: { new: 9, threads: ['旧数据'] } },
    feedback: { new: 9, open: 9, threads: ['旧数据'] },
    usage: { perDay: [{ day: '2026-10-14' }] },
    devices: { paired: 3 },
  }
  const mailStats = {
    ok: true, generatedAt: 2, asOf: 3, days: 30,
    feedback: { new: 1, open: 1, replied: 0, threads: ['新数据'] },
    today: { new: 1, open: 1, replied: 0, threads: ['新数据'] },
  }
  const merged = mergeReportData(relayReport, mailStats)
  assert.deepEqual(merged.feedback.threads, ['新数据'])
  assert.deepEqual(merged.today.feedback.threads, ['新数据'])
  assert.deepEqual(merged.usage, relayReport.usage, '中转的板块不动')
  assert.deepEqual(merged.today.usage, relayReport.today.usage)
  // 原 report 不被修改。
  assert.deepEqual(relayReport.feedback.threads, ['旧数据'])
  // mail 侧失败（ok:false）时保留中转的计算，日报照常出。
  const fallback = mergeReportData(relayReport, { ok: false })
  assert.deepEqual(fallback.feedback.threads, ['旧数据'])
})

test('debugDeviceIds：DSH- 前缀与测试台机型，规则与中转 _is_debug_device 同一条', () => {
  const rows = [
    { deviceId: 'dev_1', name: 'DSH-Test', model: 'iPhone17,1' },
    { deviceId: 'dev_2', name: 'iPhone', model: 'Node' },
    { deviceId: 'dev_3', name: 'iPhone', model: 'test-harness' },
    { deviceId: 'dev_4', name: 'iPhone', model: 'simulator' },
    { deviceId: 'dev_5', name: '我的 iPhone', model: 'iPhone15,4' },
  ]
  assert.deepEqual(debugDeviceIds(rows), ['dev_1', 'dev_2', 'dev_3', 'dev_4'])
  assert.deepEqual(debugDeviceIds('not-an-array'), [])
})

test('--all 展开的中转一个账号都没有：退 1，一条写命令都不发', () => {
  const calls = []
  const runner = (argv) => {
    calls.push(argv)
    if (/account-list/.test(String(argv.at(-1)))) return '[]'
    return '{"ok":true}'
  }
  const { code, err } = run(['notify', '--body', '公告', '--all', '--yes', ...APPROVED],
    { runner, approvalLog: approvalLogFile() })
  assert.equal(code, 1)
  assert.equal(calls.length, 1, '只读了 account-list，没发任何东西')
  assert.match(err, /中转一个账号都没有/)
})

test('--all 不带 --yes：仍是预演，不展开、不下发', () => {
  const fake = spy('{"ok":true,"dryRun":true,"recipients":3}')
  const { code, err } = run(['notify', '--body', '公告', '--all'], { runner: fake.runner })
  assert.equal(code, 0)
  assert.equal(fake.calls.length, 1, '预演不读账号清单')
  assert.match(err, /没有 --yes/)
})


// ── 过渡期回退：服务器还没部署 mail 时，信件命令与日报走中转旧路径 ─────────────

test('过渡期：mail 未部署时信件命令回退中转，提示一次', () => {
  const calls = []
  const runner = (argv) => {
    calls.push(argv)
    const remote = String(argv.at(-1))
    if (/opt\/dsh-mail/.test(remote)) {
      const error = new Error('ssh failed')
      error.stderr = '/opt/dsh-mail/admin.py: No such file or directory'
      throw error
    }
    if (/feedback-list/.test(remote)) return '[{"threadId":"th_a"}]'
    return '{"ok":true}'
  }
  const { code, out, err } = run(['list', '--status', 'open'], { runner })
  assert.equal(code, 0)
  assert.equal(calls.length, 2, '先试 mail，失败后走中转')
  assert.match(String(calls[0].at(-1)), /opt\/dsh-mail/)
  assert.match(String(calls[1].at(-1)), /opt\/dsh-relay/)
  assert.match(out, /th_a/)
  assert.match(err, /（回退）服务器上还没有 mail 服务/)
})

test('过渡期：mail 未部署时日报照常出（反馈板块用中转的旧计算）', () => {
  const outDir = mkdtempSync(join(tmpdir(), 'feedback-fallback-'))
  const calls = []
  const runner = (argv) => {
    calls.push(argv)
    const remote = String(argv.at(-1))
    if (/feedback-stats/.test(remote)) {
      const error = new Error('ssh failed')
      error.stderr = '/opt/dsh-mail/admin.py: No such file or directory'
      throw error
    }
    if (/feedback-notify/.test(remote)) return '{"ok":true,"noticeId":"nt_f"}'
    return JSON.stringify(fixture())
  }
  const { code, err } = run(['report', '--out', outDir, '--send', '--account', OWNER],
    { runner, approvalLog: approvalLogFile() })
  assert.equal(code, 0, '定时日报在切换前不许挂')
  assert.match(err, /（回退）服务器上还没有 mail 服务/)
  const html = readFileSync(join(outDir, '2026-10-12.html'), 'utf8')
  assert.ok(html.includes('&lt;script&gt;'), '反馈板块用的还是中转那份数据（且照样转义）')
})

test('过渡期回退只认目标缺失：线程不存在等真错误不回退', () => {
  const calls = []
  const runner = (argv) => {
    calls.push(argv)
    const remote = String(argv.at(-1))
    if (/opt\/dsh-mail/.test(remote)) {
      const error = new Error('ssh failed')
      error.stdout = '{"ok": false, "error": "thread not found"}'
      throw error
    }
    return '{"ok":true}'
  }
  const { code } = run(['show', '--thread', 'th_nope'], { runner })
  assert.equal(code, 1, '真错误原样透传，不许拿中转再试一遍把错误搅浑')
  assert.equal(calls.length, 1, '没有第二次调用')
})
