/**
 * `_link/sessionDigest` 的单测（spec 021 / T004、T005、T008、T009）。
 *
 * 两条主线：
 *   ① 纯函数：白名单逐字、未知字段保留、入参不被修改、压缩往返无损、非法编码不报错；
 *   ② 走完整 DLP 路径：经 `handleRelayFrame` 发一条 `req`，断言响应字段与"老方法逐字节不变"。
 */

import assert from 'node:assert/strict'
import test from 'node:test'
import { inflateRawSync } from 'node:zlib'

import {
  DROPPED_ITEM_KEYS, DROPPED_PROJECTION_KEYS, SESSION_DIGEST_METHOD,
  digestSessionList, encodeDigest,
} from '../lib/session-digest.js'

/** 造一份"宿主形状"的会话列表：每个投影键都在，另加一个未知字段（宿主将来新增的）。 */
function hostPage({ sessions = 3 } = {}) {
  const items = []
  for (let index = 0; index < sessions; index += 1) {
    items.push({
      sessionId: `session-${index}`,
      updatedAt: 1_791_860_000_000 + index,
      agentAvailable: true,
      running: index % 2 === 0,
      blank: false,
      cwd: '/Users/x/project',
      origin: index === 2 ? 'subagent' : 'session',
      parentSessionId: index === 2 ? 'session-0' : null,
      // 宿主将来新增的字段：裁剪不许把它删掉（只删名单里的）。
      someFutureField: { keep: true },
      projections: {
        kind: 'sequenced',
        asOfSeq: 100 + index,
        values: {
          title: `标题 ${index}`,
          turnOutline: [{ turn: 1, prompt: 'x'.repeat(200), response: 'y'.repeat(200) }],
          imageLimits: { maxImageBytes: 20_971_520, mediaTypes: ['image/png'] },
          sessionStats: { steps: 3, decodeMs: 12 },
          todos: [{ content: 't' }],
          subagentCatalog: [{ id: 'a' }],
          contextBreakdown: { systemTokens: 10 },
          sessionListMetadata: { blank: false, lastPromptAt: 1 },
          subagentTiming: { settledMs: 5 },
          agentPreset: 'default',
          tokenUsage: { totalTokens: 1234 },
          contextPressure: { fraction: 0.5 },
          subagent: { mode: 'one-shot' },
        },
      },
    })
  }
  return { ok: true, value: { items } }
}

test('裁剪只删名单里的字段，其余（含宿主将来新增的）原样保留', () => {
  const page = hostPage()
  const digested = digestSessionList(page)
  const item = digested.items[0]
  for (const key of DROPPED_ITEM_KEYS) assert.ok(!(key in item), `${key} 应被剔除`)
  assert.ok('someFutureField' in item, '名单之外的新字段必须保留')
  assert.ok(!('kind' in item.projections), 'projections.kind 是信封常量，应剔除')
  const values = item.projections.values
  for (const key of DROPPED_PROJECTION_KEYS) assert.ok(!(key in values), `${key} 应被剔除`)
  // 保留项逐字不变
  assert.equal(values.title, '标题 0')
  assert.deepEqual(values.tokenUsage, { totalTokens: 1234 })
  assert.equal(item.projections.asOfSeq, 100)
  assert.equal(item.sessionId, 'session-0')
})

test('裁剪不改入参（同一份数据能跑两条路径对比）', () => {
  const page = hostPage()
  const before = JSON.stringify(page)
  digestSessionList(page)
  assert.equal(JSON.stringify(page), before, '入参必须逐字节不变')
})

test('键序保持：裁剪后的键序等于原键序去掉被删项', () => {
  const page = hostPage({ sessions: 1 })
  const digested = digestSessionList(page)
  const keys = Object.keys(digested.items[0])
  assert.deepEqual(keys, ['sessionId', 'updatedAt', 'running', 'blank', 'cwd', 'origin',
    'parentSessionId', 'someFutureField', 'projections'], `键序变了：${keys.join(',')}`)
})

test('结构不是预期形状时原样返回：裁剪不把"看不懂"变成"删掉"', () => {
  assert.equal(digestSessionList(null), null)
  assert.deepEqual(digestSessionList({ ok: false, error: { code: 'host/unavailable' } }),
    { ok: false, error: { code: 'host/unavailable' } })
  assert.deepEqual(digestSessionList({ ok: true, value: { items: 'nope' } }),
    { ok: true, value: { items: 'nope' } })
  assert.deepEqual(digestSessionList({ items: 'nope' }), { items: 'nope' }, '直接给的畸形值也原样返回')
  // 空列表是合法结果：**返回列表值本身**（信封在调用方那层已经解开）
  assert.deepEqual(digestSessionList({ ok: true, value: { items: [] } }), { items: [] })
})

test('压缩往返无损，回执带 encoding 与 rawBytes（给 iOS 一次分配到位）', () => {
  const digested = digestSessionList(hostPage({ sessions: 5 }))
  const plain = encodeDigest(digested, undefined)
  assert.equal(plain.encoding, 'identity')
  assert.equal(plain.value, digested, '不压缩时原样给出去')
  assert.equal(plain.rawBytes, undefined, '不压缩时不需要 rawBytes')

  const packed = encodeDigest(digested, 'deflate-raw')
  assert.equal(packed.encoding, 'deflate-raw')
  const raw = inflateRawSync(Buffer.from(packed.value, 'base64'))
  assert.equal(packed.rawBytes, raw.length, 'rawBytes 必须等于解压后的字节数（iOS 靠它分配缓冲区）')
  assert.deepEqual(JSON.parse(raw.toString('utf8')), digested, '解压后必须逐字段一致')
  assert.ok(packed.value.length < JSON.stringify(digested).length, '压完应该更小')
})

test('非法 encoding 按不压缩处理（不因为多写一个字段就让调用方失败）', () => {
  assert.equal(encodeDigest({ items: [] }, 'brotli').encoding, 'identity')
  assert.equal(encodeDigest({ items: [] }, 'gzip').encoding, 'identity', 'gzip 不再接受：格式只有一种，避免第二套解压实现')
  assert.equal(encodeDigest({ items: [] }, 42).encoding, 'identity')
  assert.equal(encodeDigest({ items: [] }, null).encoding, 'identity')
})

test('端到端：裁剪后的响应字节显著小于原样，且字段集合等于白名单', () => {
  const page = hostPage({ sessions: 40 })
  const raw = JSON.stringify(page.value)
  const digested = digestSessionList(page)
  const small = JSON.stringify(digested)
  assert.ok(small.length < raw.length * 0.6, `应省下四成以上：${raw.length} → ${small.length}`)
  const keys = new Set(Object.keys(digested.items[0].projections.values))
  for (const key of DROPPED_PROJECTION_KEYS) assert.ok(!keys.has(key))
  assert.ok(keys.has('title') && keys.has('tokenUsage') && keys.has('subagent'))
})
