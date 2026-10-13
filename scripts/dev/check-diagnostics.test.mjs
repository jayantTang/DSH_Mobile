/**
 * `scripts/dev/check-diagnostics.mjs` 的离线单测（tasks.md T038）。
 *
 * 要钉住的性质：检查器**必须真的抓到**凭据与家目录，而不是"看起来在检查"——
 * 所以每条规则都配一个负例（故意注入），正例也要有（否则会把正常包判红）。
 */

import { test } from 'node:test'
import assert from 'node:assert/strict'

import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import {
  checkDiagnosticsPack, checkFindingsFile, parseArgs, parseContractKinds, redactHome, scanForLeaks,
} from './check-diagnostics.mjs'

/** 合成凭据：形状对（测得出规则），值不是真的（不违反宪法 V）。 */
const ANSWER_KEY = ['as', 'TESTONLY', '0'.repeat(24)].join('_')

test('parseArgs 默认与 --pack/--contract', () => {
  assert.deepEqual(parseArgs([]), { pack: undefined, contract: false, help: false })
  assert.equal(parseArgs(['--pack', '/tmp/p']).pack, '/tmp/p')
  assert.equal(parseArgs(['--contract']).contract, true)
})

test('parseArgs 对未知参数报错', () => {
  assert.throws(() => parseArgs(['--what']), /未知参数/)
})

// ── 脱敏：每条规则都要有负例（故意注入必须被抓到） ────────────────────────────

test('scanForLeaks 抓到每一类凭据与真实家目录', () => {
  const samples = [
    ['agent-secret', `relayUrl=wss://x ${ANSWER_KEY}`],
    ['bearer', `Authorization: Bearer ${'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9'}.abc`],
    ['launch-token', 'http://127.0.0.1:19387/?token=GyEW2yb1AEqGCbsK-WCuVCHRZMukXjX98sBCf2H8d8s'],
    ['auth-cookie', 'dsh-auth-x=deadbeefdeadbeef'],
    ['invite-code', 'DSH_MOBILE_LINK_INVITE=abcdefghijklmnop1234'],
    ['env-secret', 'CLIENT_SECRET=supersecretvalue'],
    ['foreign-home', `log at ${['', 'Users', 'someone'].join('/')}/Library/Logs/x.log`],
  ]
  for (const [rule, text] of samples) {
    const hits = scanForLeaks(text)
    assert.ok(hits.some((hit) => hit.rule === rule), `${rule} 没被抓到：${JSON.stringify(hits)}`)
  }
})

test('redactHome 把当前家目录换成 ~（两种形状都覆盖）', () => {
  // 拼出来而不是写字面量：任何 `/Users/<name>` 都会被 check:secrets 判成真实家目录。
  const home = ['', 'Users', 'tester'].join('/')
  assert.equal(redactHome(`读 ${home}/.dsh/mobile-link/agent.json`, home), '读 ~/.dsh/mobile-link/agent.json')
  assert.equal(redactHome(`file://${home}/x`, home), 'file://~/x')
  assert.equal(redactHome('别的路径不动 /opt/dsh-relay', home), '别的路径不动 /opt/dsh-relay')
})

test('正常文本不会被误报（否则检查器会被当成噪音忽略掉）', () => {
  const hits = scanForLeaks('device dev_testdevice0001 attached to agent agt_testagent00001')
  assert.deepEqual(hits, [], `不该报：${JSON.stringify(hits)}`)
})

test('checkDiagnosticsPack：注入一份带 secret 的包必须失败，干净包必须通过', () => {
  const dir = mkdtempSync(join(tmpdir(), 'dsh-pack-test-'))
  mkdirSync(join(dir, 'sources'), { recursive: true })
  for (const name of ['README.md', 'clock.json', 'coverage.json', 'missing.json']) {
    writeFileSync(join(dir, name), '{}\n')
  }
  writeFileSync(join(dir, 'timeline.jsonl'), '{"kind":"app.dial"}\n')
  writeFileSync(join(dir, 'sources', 'connector.jsonl'),
    '{"kind":"link.open","agentId":"agt_testagent00001"}\n')
  let result = checkDiagnosticsPack(dir)
  assert.equal(result.ok, true, `干净包不该被判红：${JSON.stringify(result)}`)
  assert.equal(result.files, 6)

  // 负例：有人顺手把 secret 写进包
  writeFileSync(join(dir, 'sources', 'connector.jsonl'),
    `{"kind":"link.start","secret":"${ANSWER_KEY}"}\n`)
  result = checkDiagnosticsPack(dir)
  assert.equal(result.ok, false, '带 secret 的包必须失败')
  assert.ok(result.hits.some((hit) => hit.rule === 'agent-secret'))
  assert.equal(result.hits[0].file, 'sources/connector.jsonl', '要指出在哪个文件')
})

test('checkDiagnosticsPack：缺结构文件要报出来', () => {
  const dir = mkdtempSync(join(tmpdir(), 'dsh-pack-test2-'))
  const result = checkDiagnosticsPack(dir)
  assert.equal(result.ok, false)
  assert.ok(result.issues.some((issue) => issue.includes('README.md')))
})

test('parseContractKinds 只取 §2/§3 表的第一列（§4 的行内片段不算 kind）', () => {
  const markdown = [
    '## 2. 既有 kind', '| `link.start` | `a` | 含义 |', '| `device.attach` | `b` | 含义 |',
    '## 3. 本次新增', '| `app.dial` | `phase` | 含义 |',
    '## 4. 中转日志行的解析契约', '| `device <id> (<name>) attached to agent <agentId>` | `relay.device-attach` | x |',
  ].join('\n')
  assert.deepEqual([...parseContractKinds(markdown)].sort(), ['app.dial', 'device.attach', 'link.start'])
})

// ── US9：findings.json 的核对（含"老包仍可读"） ──────────────────────────────

test('findings 结构不合法/缺证据要判红', () => {
  {
    const dir = mkdtempSync(join(tmpdir(), 'dsh-findings-1-'))
    writeFileSync(join(dir, 'findings.json'), JSON.stringify([
      { id: 'phone-slow', level: 'warn', summary: '手机侧处理用了 9455 ms，连接器侧只用 246 ms', evidence: [] },
      { id: '', level: 'fatal', summary: '短', evidence: [] },
    ]))
    const result = checkFindingsFile(dir)
    assert.equal(result.ok, false)
    assert.ok(result.problems.some((item) => /缺 id/.test(item)))
    assert.ok(result.problems.some((item) => /level 只能是/.test(item)))
    assert.ok(result.problems.some((item) => /没有 evidence/.test(item)))
  }
})

test('README 顶部漏列告警、或没有告警却不写「告警：无」，都要判红', () => {
  {
    const dir = mkdtempSync(join(tmpdir(), 'dsh-findings-2-'))
    writeFileSync(join(dir, 'findings.json'), JSON.stringify([
      { id: 'phone-slow', level: 'warn', summary: '手机侧处理用了 9455 ms，连接器侧只用 246 ms', evidence: ['attaches.jsonl#dev_1'] },
    ]))
    writeFileSync(join(dir, 'README.md'), '# 包\n\n没有列出那条告警\n')
    let result = checkFindingsFile(dir)
    assert.equal(result.ok, false)
    assert.ok(result.problems.some((item) => /README 没有列出/.test(item)))

    writeFileSync(join(dir, 'findings.json'), '[]')
    result = checkFindingsFile(dir)
    assert.equal(result.ok, false, '没有告警时 README 必须写「告警：无」')
    assert.ok(result.problems.some((item) => /告警：无/.test(item)))

    writeFileSync(join(dir, 'README.md'), '# 包\n\n**告警：无。**\n')
    assert.equal(checkFindingsFile(dir).ok, true)
  }
})

test('老包（没有 findings.json）仍算合格——包格式只增不改', () => {
  const dir = mkdtempSync(join(tmpdir(), 'dsh-findings-3-'))
  const result = checkFindingsFile(dir)
  assert.equal(result.ok, true)
  assert.match(result.skipped, /兼容/)
})
