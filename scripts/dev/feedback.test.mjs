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

import { buildInvocation, foreignRecipients, main, renderAgentPlist, reportPath,
  resolveSshTarget } from './feedback.mjs'
import { escapeHtml, renderReport } from './feedback-report.mjs'

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
      usage: { egressBytes: 2 * 1024 * 1024, connections: 9, devices: 2,
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
      perDay: [{ day: '2026-10-11', egressBytes: 1024 * 1024, connections: 3, devices: 1 },
        { day: '2026-10-12', egressBytes: 2 * 1024 * 1024, connections: 9, devices: 2 }],
      topAccounts: [{ accountId: 'acc_a', name: 'jayant', egressBytes: 3 * 1024 * 1024,
        connections: 12, lastSeenAt: GENERATED_AT, lastBuild: '1.0 20261012.1056' }],
      totals: { egressBytes: 3 * 1024 * 1024, connections: 12 },
      averagePerDay: 1024 * 1024, peakDay: { day: '2026-10-12', egressBytes: 2 * 1024 * 1024 },
      activeDays: 2,
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

test('默认经 ssh 跑服务器上的 admin.py', () => {
  const fake = spy('{"threads":[]}')
  const { code, out } = run(['list', '--status', 'open', '--limit', '20'], { runner: fake.runner })
  assert.equal(code, 0)
  const [command, ...rest] = fake.calls[0]
  assert.equal(command, 'ssh')
  assert.deepEqual(rest.slice(0, 2), ['-q', '-o'])
  assert.equal(rest[2], 'BatchMode=yes')
  assert.equal(rest.at(-2), `root@${HOST}`)
  assert.match(rest.at(-1), /^\/opt\/dsh-relay\/\.venv\/bin\/python \/opt\/dsh-relay\/admin\.py /)
  assert.match(rest.at(-1), /--db \/var\/lib\/dsh-relay\/state\.db feedback-list --status open --limit 20/)
  assert.equal(out, '{"threads":[]}')
})

test('--local 跑本机 admin.py 与本机测试库，不碰 ssh', () => {
  const fake = spy('{"ok":true}')
  const { code } = run(['list', '--local'], { runner: fake.runner })
  assert.equal(code, 0)
  const argv = fake.calls[0]
  assert.notEqual(argv[0], 'ssh')
  assert.equal(argv[1], join(ROOT, 'relay', 'admin.py'))
  assert.ok(argv.includes(join(ROOT, 'relay', '.local', 'state.db')), argv.join(' '))
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
  const fake = spy('{"ok":true,"threadId":"th_x"}')
  const log = approvalLogFile()
  const { code } = run(['reply', '--thread', 'th_x', '--body', '您好 & 谢谢', '--send', ...APPROVED],
    { runner: fake.runner, approvalLog: log })
  assert.equal(code, 0)
  assert.equal(fake.calls.length, 1, '给了批准就直发，不再多读一次线程清单')
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

  // reply 也接受 --yes 这种写法（命令契约把两个开关并列写过）。
  const alias = spy('{"ok":true}')
  run(['reply', '--thread', 'th_x', '--body', '正文', '--yes', ...APPROVED], { runner: alias.runner })
  assert.equal(alias.calls.length, 1)
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
  const notify = spy('{"ok":true,"noticeId":"nt_a"}')
  run(['notify', '--body', '维护通知', '--subject', 'S', '--all', '--yes', ...APPROVED], { runner: notify.runner })
  const remote = notify.calls[0].at(-1)
  assert.match(remote, /feedback-notify --body /)
  assert.match(remote, /--subject S/)
  assert.match(remote, /--all/)
  assert.match(remote, /--yes/)

  const del = spy('{"ok":true,"deleted":2}')
  const { code } = run(['delete', '--thread', 'th_x', '--yes'], { runner: del.runner })
  assert.equal(code, 0)
  assert.match(del.calls[0].at(-1), /feedback-delete --thread th_x --yes/)

  const preview = spy('{"deleted":2}')
  run(['delete', '--thread', 'th_x'], { runner: preview.runner })
  assert.ok(!preview.calls[0].at(-1).includes('--yes'))
})

test('report / report-data 走 ops-report，天数透传', () => {
  const fake = spy('{"ok":true}')
  run(['report-data', '--days', '7', '--local'], { runner: fake.runner })
  assert.match(fake.calls[0].join(' '), /ops-report --days 7/)
  const out = run(['report-data', '--days', '90'], { runner: fake.runner })
  assert.equal(out.out, '{"ok":true}')
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
  // 两段的板块标题与图：今日有对比条，30 天有两张折线/柱状图。
  assert.ok(html.includes('<span class="tag ">今日</span>概览'), '今日板块')
  assert.ok(html.includes('<span class="tag range">最近 30 天</span>趋势与明细'), '30 天板块')
  assert.equal((html.match(/<svg /g) ?? []).length, 2, '只有每日出口与每日新增手机两张图')
  assert.ok(html.includes('每日出口流量') && html.includes('每日新增手机'))
  assert.ok(html.includes('今日出口流量') && html.includes('较昨日') && html.includes('近 7 日均值'))
  assert.ok(html.includes('3.0 MB'), '出口字节应换算成 MB')
  assert.ok(html.includes('今日电脑') && html.includes('今日手机') && html.includes('今日反馈'))
  assert.ok(html.includes('电脑排名') && html.includes('邀请码登记'))
  // 留存：外部账号（页面写「电脑」）口径、D1/D7 与分周队列、登记激活都要在页面上。
  assert.ok(html.includes('外部电脑 · 活跃=当天有中转连接'))
  for (const label of ['今日活跃电脑', '近 7 天活跃', '近 30 天活跃', '次日留存', '7 日留存', '登记激活']) {
    assert.ok(html.includes(label), `留存缺 ${label}`)
  }
  assert.ok(html.includes('62%') && html.includes('n=13'), '留存率要带队列人数')
  assert.ok(html.includes('2026-W40') && html.includes('60%'), '分周队列')
  // 今日版本分布：版本 / 手机 / 电脑 三列。
  assert.ok(html.includes('今日版本分布') && html.includes('20261012.1056'))
  assert.ok(html.includes('已剔除测试提交 3 条'))
  assert.ok(!html.includes('<script>'), '正文里的 script 必须被转义')
  assert.ok(html.includes('&lt;script&gt;'))
  assert.ok(html.includes('&lt;A&gt;'), '邀请码备注同样要转义')
})

test('手机上不写死宽表：长清单有上限，且提示"前几条"', () => {
  const many = fixture()
  many.devices.list = Array.from({ length: 40 }, (_, i) => ({
    deviceId: `dvc_${i}`, name: `iPhone ${i}`, model: 'iPhone 17 Pro', appVersion: '1.2.3',
    createdAt: GENERATED_AT, lastSeenAt: GENERATED_AT, revoked: 0, push: { registered: true } }))
  many.invites.enrollments = Array.from({ length: 40 }, (_, i) => ({
    usedAt: GENERATED_AT, inviteNote: '试用', accountId: `acc_${i}`, accountName: `用户 ${i}`,
    agentId: `agt_${i}`, agentName: 'MacBook', devices: 1 }))
  const html = renderReport(many)
  // 每一类清单只渲染前几条：手机 8、登记 6——正文长度因此不随库里的历史行数增长。
  assert.ok(html.includes('iPhone 7') && !html.includes('iPhone 39'), '手机清单只列前 8 台')
  assert.ok(html.includes('最近在线前 8 台'), '清单要说明只列了前几条')
  assert.ok(html.includes('用户 5') && !html.includes('用户 39'), '登记清单只列前 6 条')
  assert.ok(html.includes('最近 6 条'), '登记清单同理')
})

test('空数据也能渲染出可看的整页', () => {
  const html = renderReport({ ok: true, generatedAt: GENERATED_AT, days: 30 })
  assert.match(html, /<span class="tag ">今日<\/span>概览/)
  assert.match(html, /今天还没有中转流量/)
  assert.match(html, /窗口内没有数据/)
  assert.match(html, /今天没有新反馈/)
  assert.match(html, /还没有人用邀请码登记/)
  assert.ok(!html.includes('NaN') && !html.includes('undefined'), '缺字段不能漏成 NaN/undefined')
})

test('escapeHtml 覆盖五个字符', () => {
  assert.equal(escapeHtml(`<a href="x" & 'y'>`), '&lt;a href=&quot;x&quot; &amp; &#39;y&#39;&gt;')
  assert.equal(escapeHtml(null), '')
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
  assert.match(full.calls[0].at(-1), /ops-report --days 30 --as-of yesterday/)

  const plain = spy(JSON.stringify(fixture()))
  run(['report', '--out', outDir], { runner: plain.runner })
  assert.ok(!plain.calls[0].at(-1).includes('--as-of'), '不给 --full-day 就是当天到此刻')
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
  assert.ok(html.includes('全天出口流量') && html.includes('较前一日'))
  assert.ok(html.includes('本地日窗口（含 10-12）'))
  assert.ok(html.includes('本报告覆盖 2026-10-12 一整个服务器本地自然日'))
  assert.ok(html.includes('活跃时段 05:00–23:59'), '跨零点的时间要夹到 23:59')
  assert.ok(!/23:59–00:00/.test(html), '不能出现回到 00:00 的时段')
  assert.ok(!html.includes('今日出口流量') && !html.includes('较昨日'),
    '10-13 生成的页面上不能把 10-12 写成"今日"')
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
  assert.equal(fake.calls.length, 4, `应当是 ops-report → scp → notify → 清理：${fake.calls.length} 次调用`)
  assert.match(fake.calls[0].at(-1), /ops-report --days 30/)

  const scp = fake.calls[1]
  assert.equal(scp[0], 'scp')
  assert.equal(scp.at(-2), local)
  assert.equal(scp.at(-1), `root@${HOST}:${remote}`)

  const command = fake.calls[2].at(-1)
  assert.equal(fake.calls[2][0], 'ssh')
  assert.match(command, new RegExp(`feedback-notify --body-file ${remote} `))
  assert.match(command, /--format html/)
  assert.match(command, /--subject 'DSH Mobile 运营日报 2026-10-12'/)
  assert.match(command, /--account acc_a --account acc_b/)
  assert.match(command, /--yes/)
  assert.ok(!command.includes('--all'), '直投指定账号，不得群发')
  assert.ok(!/--body /.test(command), '正文必须走 --body-file，不能塞进 ssh 参数')

  assert.equal(fake.calls[3][0], 'ssh')
  assert.equal(fake.calls[3].at(-1), `rm -f ${remote}`)
  assert.equal(out.split('\n')[0], local)
  assert.match(readFileSync(local, 'utf8'), /<svg /)
})

test('report --send 的 --subject 覆盖默认标题', () => {
  const outDir = mkdtempSync(join(tmpdir(), 'feedback-send-subject-'))
  const fake = spy(JSON.stringify(fixture()))
  const { code } = run(['report', '--out', outDir, '--send', '--account', 'acc_a', '--subject', '周报', ...APPROVED],
    { runner: fake.runner, approvalLog: approvalLogFile() })
  assert.equal(code, 0)
  assert.match(fake.calls[2].at(-1), /--subject '周报'/)
})

test('report --send 收件账号：--account 优先，其次 .env.local 的 DSH_ACCOUNT_ID', () => {
  // 没给 --account 时取 DSH_ACCOUNT_ID（定时任务的 plist 里不再有任何 id）。
  const outDir = mkdtempSync(join(tmpdir(), 'feedback-send-env-'))
  const fake = spy(JSON.stringify(fixture()))
  const { code } = run(['report', '--out', outDir, '--send'],
    { runner: fake.runner, env: { DSH_OTA_HOST: HOST, DSH_ACCOUNT_ID: 'acc_env' } })
  assert.equal(code, 0)
  assert.match(fake.calls[2].at(-1), /--account acc_env/)

  // 命令行给了就压过 .env.local（换账号试发时不必改本机真值）；换成别人的账号就要审批。
  const explicit = spy(JSON.stringify(fixture()))
  const other = mkdtempSync(join(tmpdir(), 'feedback-send-env2-'))
  run(['report', '--out', other, '--send', '--account', 'acc_cli', ...APPROVED],
    { runner: explicit.runner, approvalLog: approvalLogFile(),
      env: { DSH_OTA_HOST: HOST, DSH_ACCOUNT_ID: 'acc_env' } })
  assert.match(explicit.calls[2].at(-1), /--account acc_cli/)
  assert.ok(!explicit.calls[2].at(-1).includes('acc_env'))
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
  assert.equal(fake.calls.length, 1, '预演只跑只读的 ops-report')
  assert.match(fake.calls[0].at(-1), /ops-report/)
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
    if (calls.length === 3) throw new Error('notify 挂了')   // 3 = notify（1 ops-report / 2 scp）
    return JSON.stringify(fixture())
  }
  const { code, err } = run(['report', '--out', outDir, '--send', '--account', 'acc_a', ...APPROVED],
    { runner, approvalLog: approvalLogFile() })
  assert.equal(code, 1)
  assert.equal(calls.length, 4)
  assert.equal(calls[3].at(-1), 'rm -f /tmp/dsh-feedback-report-2026-10-12.html')
  assert.match(err, /notify 挂了/)
})

test('report --send --local 直接读本机报告文件，不 scp 也不清理', () => {
  const outDir = mkdtempSync(join(tmpdir(), 'feedback-send-local-'))
  const fake = spy(JSON.stringify(fixture()))
  const { code } = run(['report', '--out', outDir, '--send', '--account', 'acc_a', '--local', ...APPROVED],
    { runner: fake.runner, approvalLog: approvalLogFile() })
  assert.equal(code, 0)
  assert.equal(fake.calls.length, 2)
  assert.ok(fake.calls.every((argv) => argv[0] !== 'scp' && argv[0] !== 'ssh'))
  const notify = fake.calls[1]
  assert.ok(notify.includes(join(outDir, '2026-10-12.html')), notify.join(' '))
  assert.ok(notify.includes('--format') && notify.includes('html'))
  assert.ok(notify.includes('--yes'))
  assert.ok(!notify.at(-1).includes('rm -f'))
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
