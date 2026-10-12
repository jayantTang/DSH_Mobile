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
    feedback: {
      new: 4, open: 2, replied: 2, medianFirstReplyHours: 6.5,
      threads: [
        { threadId: 'th_a', createdAt: GENERATED_AT - 3600_000, status: 'open',
          source: { kind: 'device', deviceModel: 'iPhone 17 Pro', appVersion: '1.2.3' }, excerpt: THREAD },
        { threadId: 'th_b', createdAt: GENERATED_AT - 7200_000, status: 'replied',
          source: { kind: 'anonymous' }, excerpt: '匿名用户' },
      ],
    },
    devices: {
      paired: 12, active7d: 5, revoked: 1,
      newPerDay: [{ day: '2026-10-11', count: 2 }, { day: '2026-10-12', count: 1 }],
      list: [{ deviceId: 'dvc_a', name: 'DSH-Test', model: 'iPhone 17 Pro', appVersion: '1.2.3',
        createdAt: GENERATED_AT, lastSeenAt: GENERATED_AT, revoked: 0 }],
    },
    usage: {
      perDay: [{ day: '2026-10-11', egressBytes: 1024 * 1024, connections: 3, devices: 1 },
        { day: '2026-10-12', egressBytes: 2 * 1024 * 1024, connections: 9, devices: 2 }],
      topAccounts: [{ accountId: 'acc_a', name: 'jayant', egressBytes: 3 * 1024 * 1024 }],
      totals: { egressBytes: 3 * 1024 * 1024, connections: 12 },
    },
    invites: {
      minted: 30, used: 21, remaining: 9,
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

test('日报含三张内联 SVG 与四个板块标题，正文被转义', () => {
  const html = renderReport(fixture())
  assert.ok((html.match(/<svg /g) ?? []).length >= 3)
  for (const title of ['反馈', '设备', '流量', '邀请码']) {
    assert.ok(html.includes(`<h2>${title}</h2>`), `缺板块 ${title}`)
  }
  assert.ok(html.includes('每日出口字节') && html.includes('每日新增设备') && html.includes('反馈状态占比'))
  assert.ok(html.includes('3.0 MB'), '出口字节应换算成 MB')
  assert.ok(!html.includes('<script>'), '正文里的 script 必须被转义')
  assert.ok(html.includes('&lt;script&gt;'))
  assert.ok(html.includes('&lt;A&gt;'), '邀请码备注同样要转义')
})

test('空数据也能渲染出可看的整页', () => {
  const html = renderReport({ ok: true, generatedAt: GENERATED_AT, days: 30 })
  assert.match(html, /<h2>图表<\/h2>/)
  assert.match(html, /窗口内没有数据/)
  assert.match(html, /窗口内没有反馈/)
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

test('renderAgentPlist 把占位符换成绝对路径', () => {
  const plist = renderAgentPlist({ nodePath: '/opt/node/bin/node', repoRoot: '/srv/dsh' })
  assert.ok(!plist.includes('__'), '不能留下占位符')
  assert.match(plist, /<string>\/opt\/node\/bin\/node<\/string>/)
  assert.match(plist, /<string>\/srv\/dsh\/scripts\/dev\/feedback\.mjs<\/string>/)
  assert.match(plist, /<key>WorkingDirectory<\/key>\s*<string>\/srv\/dsh<\/string>/)
  assert.ok(!plist.includes('<string>~/'), 'launchd 不展开 ~，安装时必须绝对化')
})
