/**
 * 生命周期流水（`lib/journal.js`）。
 *
 * 这份设施的价值全在"事后还能读到"，所以三条性质要钉住：
 *   1. 内存环是**定长**的（长跑不涨内存），被挤掉的条数要如实报出来；
 *   2. 落盘是**一行一条 JSON**、超限滚动一次，读回来能逐条解析；
 *   3. **任何写失败都不许抛**——它是诊断设施，不能把链路带崩。
 */

import assert from 'node:assert/strict'
import { readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import test from 'node:test'

import {
  LinkJournal, EVENT_KINDS, DEFAULT_LIMIT, DEFAULT_MAX_BYTES, MAX_EVENT_BYTES, defaultJournalPath,
} from '../lib/journal.js'
import { withTempHome } from './helpers/tmp-home.js'

/** 读回 JSONL，逐行解析（顺便证明每一行都是合法 JSON）。 */
function readLines(path) {
  return readFileSync(path, 'utf8')
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line))
}

test('the ring is bounded and reports what it dropped', () => {
  const journal = new LinkJournal({ limit: 3, now: () => 1000 })
  for (const deviceId of ['dev_1', 'dev_2', 'dev_3', 'dev_4', 'dev_5']) {
    journal.record('device.attach', { deviceId })
  }
  assert.equal(journal.entries().length, 3)
  assert.equal(journal.recorded, 5)
  assert.equal(journal.dropped, 2)
  assert.deepEqual(journal.recent(2).map((entry) => entry.deviceId), ['dev_4', 'dev_5'])
  assert.equal(journal.path, null, '没有给路径时不该碰磁盘')
})

test('entries carry both a readable time and an integer one', () => {
  const journal = new LinkJournal({ now: () => 1791825010506 })
  const entry = journal.record('link.close', { reason: 'relay closed the socket (1006 )', from: 'connected' })
  assert.equal(entry.kind, 'link.close')
  assert.equal(entry.ms, 1791825010506)
  assert.equal(entry.at, new Date(1791825010506).toISOString())
  assert.equal(entry.reason, 'relay closed the socket (1006 )')
  assert.equal(entry.from, 'connected')
})

test('record() ignores undefined detail but keeps false and zero', () => {
  const journal = new LinkJournal({ now: () => 1 })
  const entry = journal.record('link.open', { attempt: 0, relay: undefined, retry: false })
  assert.equal(entry.attempt, 0)
  assert.equal(entry.retry, false)
  assert.ok(!('relay' in entry), 'undefined 的字段不该在载荷里变成一个 null')
})

test('the JSONL file gets one parseable line per event', async () => {
  await withTempHome(async (home) => {
    const path = join(home, 'mobile-link', 'link-events.jsonl')
    const journal = new LinkJournal({ path, now: () => 42 })
    journal.record('link.start', { relay: 'wss://relay.test/dsh-link' })
    journal.record('link.open', { agentId: 'agt_1' })
    const lines = readLines(path)
    assert.equal(lines.length, 2)
    assert.equal(lines[0].kind, 'link.start')
    assert.equal(lines[1].kind, 'link.open')
    assert.equal(lines[1].agentId, 'agt_1')
    // 目录是它自己建的（身份文件旁边那个 mobile-link 目录）
    assert.equal(journal.fileErrors, 0)
  })
})

test('the file rotates once its size cap is reached, keeping the older half', async () => {
  await withTempHome(async (home) => {
    const path = join(home, 'link-events.jsonl')
    const journal = new LinkJournal({ path, maxBytes: 1024, now: () => 7 })
    for (let index = 0; index < 40; index += 1) {
      journal.record('device.attach', { deviceId: `dev_${index}`, pad: 'x'.repeat(50) })
    }
    assert.equal(journal.fileErrors, 0)
    // 现文件被滚走了：`<path>.1` 里是滚之前那一批，现文件里是滚之后的。
    const archived = readLines(`${path}.1`)
    const current = readLines(path)
    assert.ok(archived.length > 0, '滚走的那一份应该有内容')
    assert.ok(current.length > 0, '滚动之后还在继续写')
    assert.ok(archived.length + current.length <= 40)
    // 现文件不超过上限（最后一条可能略微超出，但绝不该是"上限的几倍"）
    assert.ok(readFileSync(path, 'utf8').length < 2048)
  })
})

test('an already-oversized file is rotated before the next append, not grown further', async () => {
  await withTempHome(async (home) => {
    // 这条盯的是"跨实例/跨重启还会不会涨"：插件热更或 DSH 重启会新建一个 LinkJournal，
    // 而磁盘上那份可能是上一代留下的（甚至被手工塞大过）。`_bytes` 是首次写入时才 stat
    // 出来的，所以这里必须靠"先落一个大文件、再新建实例写一条"来验，不能只靠单实例滚动。
    const path = join(home, 'link-events.jsonl')
    const oversized = `${JSON.stringify({ at: 'x', ms: 1, kind: 'pad', pad: 'y'.repeat(4096) })}\n`
    writeFileSync(path, oversized.repeat(80))  // ~330 KiB > 256 KiB 上限
    const before = readFileSync(path, 'utf8').length
    assert.ok(before > 256 * 1024, `前提没成立：只有 ${before} 字节`)

    const journal = new LinkJournal({ path, now: () => 9 })
    journal.record('link.start', { attempt: 0 })
    assert.equal(journal.fileErrors, 0)
    // 新写的那条不该再追加到超限文件后面：它被滚成 `.1`，现文件从这一条重新开始。
    assert.equal(readLines(path).length, 1)
    assert.equal(readLines(path)[0].kind, 'link.start')
    assert.ok(readFileSync(path, 'utf8').length < 1024, '滚过之后现文件应当很小')
    assert.ok(readFileSync(`${path}.1`, 'utf8').length > 256 * 1024, '超限的那份被滚走，不再长')
  })
})

test('a broken path is reported once and never thrown', async () => {
  await withTempHome(async (home) => {
    // 父路径是一个**文件**，所以 mkdir 必然失败——写坏了也不能抛。
    const blocker = join(home, 'not-a-dir')
    writeFileSync(blocker, 'x')
    const messages = []
    const journal = new LinkJournal({
      path: join(blocker, 'link-events.jsonl'),
      logger: { debug: (message) => messages.push(message) },
      now: () => 1,
    })
    assert.doesNotThrow(() => journal.record('link.start', {}))
    assert.doesNotThrow(() => journal.record('link.close', {}))
    assert.equal(journal.fileErrors, 1, '第一次失败之后就停手，不刷屏')
    assert.equal(messages.length, 1)
    assert.match(messages[0], /link journal disabled/)
    // 内存那份照旧可用：落盘坏了不影响现场读
    assert.equal(journal.recent(5).length, 2)
  })
})

test('the default path sits next to the identity file under DSH_HOME', async () => {
  await withTempHome(async (home) => {
    const previous = process.env.DSH_HOME
    process.env.DSH_HOME = home
    try {
      assert.equal(defaultJournalPath(), join(home, 'mobile-link', 'link-events.jsonl'))
    } finally {
      process.env.DSH_HOME = previous
    }
  })
})

// ── 事件目录与单条上限（spec 020 / tasks.md T004-T005） ──────────────────────

test('EVENT_KINDS 无重复，且每条都能真的写进流水', () => {
  assert.equal(new Set(EVENT_KINDS).size, EVENT_KINDS.length, '词表里有重复项')
  const journal = new LinkJournal({ now: () => 1 })
  for (const kind of EVENT_KINDS) journal.record(kind, {})
  assert.equal(journal.entries().length, EVENT_KINDS.length)
  assert.deepEqual(journal.entries().map((entry) => entry.kind), [...EVENT_KINDS])
})

test('超大条目先截断（留 truncated 标记），截不动才丢并自报一条', () => {
  const journal = new LinkJournal({ now: () => 1 })
  // 1) 一个长字符串：截短到上限内，保住了这一条，且读者能看出不完整。
  const truncated = journal.record('device.detach', { deviceId: 'dev_1', reason: 'x'.repeat(8000) })
  assert.equal(truncated.kind, 'device.detach')
  assert.equal(truncated.truncated, true)
  assert.ok(truncated.reason.length <= 201, `截断后仍太长：${truncated.reason.length}`)
  assert.ok(JSON.stringify(truncated).length <= MAX_EVENT_BYTES)

  // 2) 截短也救不回来（字段太多）：丢掉它，但留一条 journal.error，且**不抛**。
  const huge = {}
  for (let index = 0; index < 400; index += 1) huge[`field${index}`] = 'v'.repeat(20)
  const replaced = journal.record('device.summary', huge)
  assert.equal(replaced.kind, 'journal.error')
  assert.equal(replaced.originalKind, 'device.summary', '自报那条要说明丢的是哪种事件')
  assert.ok(replaced.bytes > MAX_EVENT_BYTES)
  for (const entry of journal.entries()) {
    assert.ok(JSON.stringify(entry).length <= MAX_EVENT_BYTES, '环里不该留下超限条目')
  }
})

test('未知 kind 照写不误（老读者必须忽略，写入者不得因未知而丢事件）', () => {
  const journal = new LinkJournal({ now: () => 1 })
  const entry = journal.record('future.thing', { hello: 'world' })
  assert.equal(entry.kind, 'future.thing')
  assert.equal(entry.hello, 'world')
})

// ── US5：上限的常量口径（改了这里就等于改了对外承诺） ─────────────────────────

test('默认上限口径固定：单文件 256 KiB、滚动保两代、单条 2 KiB', () => {
  assert.equal(DEFAULT_MAX_BYTES, 256 * 1024, '连接器流水单文件上限')
  assert.equal(MAX_EVENT_BYTES, 2048, '单条事件上限')
  assert.equal(DEFAULT_LIMIT, 200, '内存环容量')
})

test('写失败只报一次，之后不再尝试（不刷屏、不拖慢链路）', async () => {
  await withTempHome(async (home) => {
    const blocker = join(home, 'blocker')
    writeFileSync(blocker, 'x')
    const journal = new LinkJournal({ path: join(blocker, 'sub', 'x.jsonl'), logger: { debug() {} } })
    for (let index = 0; index < 5; index += 1) journal.record('link.start', {})
    assert.equal(journal.fileErrors, 1, '只报一次')
    assert.equal(journal.recorded, 5, '内存那份照旧可用')
  })
})
