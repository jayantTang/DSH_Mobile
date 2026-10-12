// 014 owner 侧运维脚本的用例：参数拼装、预演语义、退出码、日报渲染、LaunchAgent 模板。
//
// 为什么值得单测：这些命令会往生产库写回信与群发通知，"预演时到底有没有真的发出去"
// 只能靠断言 argv 来钉住——不能拿真服务器去试。

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

import { buildInvocation, main, renderAgentPlist, reportPath, resolveSshTarget } from './feedback.mjs'
import { escapeHtml, renderReport } from './feedback-report.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))
const ROOT = join(HERE, '..', '..')
const PLIST = join(HERE, 'launchd', 'com.jayanttang.dsh-daily-report.plist')

const HOST = 'relay.example.com'
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

function run(argv, { runner, env = { DSH_OTA_HOST: HOST } } = {}) {
  const out = []
  const err = []
  const code = main(argv, {
    runner: runner ?? (() => { throw new Error('runner 不该被调用') }),
    env,
    out: (line) => out.push(String(line)),
    err: (line) => err.push(String(line)),
  })
  return { code, out: out.join('\n'), err: err.join('\n') }
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
  const { code } = run(['reply', '--thread', 'th_x', '--body', '您好 & 谢谢', '--send'], { runner: fake.runner })
  assert.equal(code, 0)
  assert.equal(fake.calls.length, 1)
  const remote = fake.calls[0].at(-1)
  assert.match(remote, /feedback-reply --thread th_x --body /)
  assert.match(remote, /您好 & 谢谢/)
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
  run(['reply', '--thread', 'th_x', '--body', '正文', '--yes'], { runner: alias.runner })
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
  run(['notify', '--body', '维护通知', '--subject', 'S', '--all', '--yes'], { runner: notify.runner })
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
  assert.equal((html.match(/<svg /g) ?? []).length, 2, '只有每日出口与每日新增设备两张图')
  assert.ok(html.includes('每日出口流量') && html.includes('每日新增设备'))
  assert.ok(html.includes('今日出口流量') && html.includes('较昨日') && html.includes('近 7 日均值'))
  assert.ok(html.includes('3.0 MB'), '出口字节应换算成 MB')
  assert.ok(html.includes('今日账号') && html.includes('今日设备') && html.includes('今日反馈'))
  assert.ok(html.includes('账号排名') && html.includes('邀请码登记'))
  // 留存：外部账号口径、D1/D7 与分周队列、登记激活都要在页面上。
  assert.ok(html.includes('外部账号 · 活跃=当天有中转连接'))
  for (const label of ['今日活跃用户', '近 7 天活跃', '近 30 天活跃', '次日留存', '7 日留存', '登记激活']) {
    assert.ok(html.includes(label), `留存缺 ${label}`)
  }
  assert.ok(html.includes('62%') && html.includes('n=13'), '留存率要带队列人数')
  assert.ok(html.includes('2026-W40') && html.includes('60%'), '分周队列')
  // 今日版本分布：版本 / 设备 / 账号 三列。
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
  // 每一类清单只渲染前几条：设备 8、登记 6——正文长度因此不随库里的历史行数增长。
  assert.ok(html.includes('iPhone 7') && !html.includes('iPhone 39'), '设备清单只列前 8 台')
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

test('LaunchAgent 模板含 label、09:00 与日志路径', () => {
  const template = readFileSync(PLIST, 'utf8')
  assert.match(template, /<string>com\.jayanttang\.dsh-daily-report<\/string>/)
  assert.match(template, /<key>StartCalendarInterval<\/key>/)
  assert.match(template, /<key>Hour<\/key>\s*<integer>9<\/integer>/)
  assert.match(template, /<key>Minute<\/key>\s*<integer>0<\/integer>/)
  assert.ok((template.match(/dsh-daily-report\.log/g) ?? []).length >= 2, 'stdout/stderr 都要日志')
  assert.match(template, /--days<\/string>\s*<string>30<\/string>/)
  assert.match(template, /feedback\.mjs<\/string>/)
})

test('reply / notify 的 --format 透传；不传就不出现在 argv 里', () => {
  const reply = spy('{"ok":true}')
  run(['reply', '--thread', 'th_x', '--body', '正文', '--format', 'html', '--send'], { runner: reply.runner })
  assert.match(reply.calls[0].at(-1), /feedback-reply --thread th_x --body .*--format html/)

  const notify = spy('{"ok":true}')
  run(['notify', '--body', '维护通知', '--device', 'dvc_a', '--format', 'html', '--yes'],
    { runner: notify.runner })
  assert.match(notify.calls[0].at(-1), /feedback-notify --body .*--format html/)

  // 不传 --format 时保持既有 argv：服务器默认 text。
  const plain = spy('{"ok":true}')
  run(['notify', '--body', '维护通知', '--device', 'dvc_a', '--yes'], { runner: plain.runner })
  assert.ok(!plain.calls[0].at(-1).includes('--format'), '不传 --format 不得凭空加参数')

  const plainReply = spy('{"ok":true}')
  run(['reply', '--thread', 'th_x', '--body', '正文', '--send'], { runner: plainReply.runner })
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
    ['report', '--out', outDir, '--send', '--device', 'dvc_a', '--device', 'dvc_b'],
    { runner: fake.runner },
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
  assert.match(command, /--device dvc_a --device dvc_b/)
  assert.match(command, /--yes/)
  assert.ok(!command.includes('--all'), '直投指定设备，不得群发')
  assert.ok(!/--body /.test(command), '正文必须走 --body-file，不能塞进 ssh 参数')

  assert.equal(fake.calls[3][0], 'ssh')
  assert.equal(fake.calls[3].at(-1), `rm -f ${remote}`)
  assert.equal(out.split('\n')[0], local)
  assert.match(readFileSync(local, 'utf8'), /<svg /)
})

test('report --send 的 --subject 覆盖默认标题', () => {
  const outDir = mkdtempSync(join(tmpdir(), 'feedback-send-subject-'))
  const fake = spy(JSON.stringify(fixture()))
  const { code } = run(['report', '--out', outDir, '--send', '--device', 'dvc_a', '--subject', '周报'],
    { runner: fake.runner })
  assert.equal(code, 0)
  assert.match(fake.calls[2].at(-1), /--subject '周报'/)
})

test('report --send 不带 --device 退 2，不执行任何命令（也不群发）', () => {
  for (const argv of [['report', '--send'], ['report', '--send', '--all']]) {
    const fake = spy()
    const { code, err } = run(argv, { runner: fake.runner })
    assert.equal(code, 2, `${argv.join(' ')} 应该退 2`)
    assert.equal(fake.calls.length, 0)
    assert.match(err, /--device|--all/)
  }
})

test('report --send --dry-run 只生成报告并打印将执行的命令', () => {
  const outDir = mkdtempSync(join(tmpdir(), 'feedback-send-dry-'))
  const fake = spy(JSON.stringify(fixture()))
  const { code, out } = run(['report', '--out', outDir, '--send', '--device', 'dvc_a', '--dry-run'],
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
  const { code, err } = run(['report', '--out', outDir, '--send', '--device', 'dvc_a'], { runner })
  assert.equal(code, 1)
  assert.equal(calls.length, 4)
  assert.equal(calls[3].at(-1), 'rm -f /tmp/dsh-feedback-report-2026-10-12.html')
  assert.match(err, /notify 挂了/)
})

test('report --send --local 直接读本机报告文件，不 scp 也不清理', () => {
  const outDir = mkdtempSync(join(tmpdir(), 'feedback-send-local-'))
  const fake = spy(JSON.stringify(fixture()))
  const { code } = run(['report', '--out', outDir, '--send', '--device', 'dvc_a', '--local'],
    { runner: fake.runner })
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
  assert.ok(!plist.includes('--send'), '不给 --device 时定时任务只落盘，不发送')
})

test('renderAgentPlist 给了设备就带上 --send --device', () => {
  const plist = renderAgentPlist({ nodePath: '/opt/node/bin/node', repoRoot: '/srv/dsh',
    deviceIds: ['dev_test1', 'dev_test2'] })
  assert.ok(!plist.includes('__'), '不能留下占位符')
  assert.match(plist, /<string>--send<\/string>/)
  assert.match(plist, /<string>--device<\/string>\s*<string>dev_test1<\/string>/)
  assert.match(plist, /<string>--device<\/string>\s*<string>dev_test2<\/string>/)
})
