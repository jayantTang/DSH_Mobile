/**
 * The DLP wire vectors, shared by all three ends.
 *
 * `test/contract/dlp-vectors.json` is the single source of truth: the connector
 * (this file), the relay (`relay/tests/test_dlp.py`) and iOS
 * (`DSHKit/Tests/DSHKitTests/DLPContractTests.swift`) all read the *same* file.
 * The contract itself is `docs/relay-contract.json`.
 *
 * These assertions pin today's behaviour, drift included: a row whose `why`
 * names a `knownDrift` entry is recording a real disagreement, not blessing it.
 * `scripts/dev/check-contracts.mjs` (text-level) guards the wiring; this file
 * guards the behaviour.
 */

import assert from 'node:assert/strict'
import test from 'node:test'

import { readFileSync } from 'node:fs'

import {
  AGENT_CONTROL, AGENT_TO_DEVICE, DEVICE_TO_AGENT, RELAY_CONTROL, deviceFrameError, joinRelayPath,
  normalizeRelayUrl,
} from '../lib/dlp.js'

const REPO_ROOT = new URL('../../../', import.meta.url)
const readJson = (relative) => JSON.parse(readFileSync(new URL(relative, REPO_ROOT), 'utf8'))

const contract = readJson('docs/relay-contract.json')
const vectors = readJson('test/contract/dlp-vectors.json').vectors

const asSet = (values) => new Set(values)
const sorted = (values) => [...values].sort()

test('the frame vocabularies match docs/relay-contract.json', () => {
  assert.deepEqual(sorted(DEVICE_TO_AGENT), sorted(contract.deviceToAgent))
  assert.deepEqual(sorted(AGENT_TO_DEVICE), sorted(contract.agentToDevice))
  assert.deepEqual(sorted(RELAY_CONTROL), sorted(contract.relayControl))
  // agent 侧控制帧（`notify`）：agent→relay，**不跨到设备**。它单独一张表是有意的——
  // 加进 deviceToAgent/agentToDevice 会让 iOS 的 DLPContractTests 双向全等断言变红。
  assert.deepEqual(sorted(AGENT_CONTROL), sorted(contract.agentControl))
})

test('the connector default error code matches the contract', () => {
  // dlp.js:gatewayFailure falls back to this when the connector sends nothing.
  const source = readFileSync(new URL('../lib/dlp.js', import.meta.url), 'utf8')
  assert.ok(source.includes(`'${contract.defaultErrorCodes.connector}'`),
    `dlp.js 里找不到默认错误码 ${contract.defaultErrorCodes.connector}`)
})

test('every vector row is what this end actually does', () => {
  for (const vector of vectors) {
    // 帧的形状由向量决定：缺 id / 缺 method / 缺 endpoint 的那几行必须真的缺，
    // 否则测的是"合法帧"这一种情况，漂移行就白记了。
    const frame = { t: vector.t }
    if (vector.hasId) frame.id = 'stream_1'
    if (vector.t === 'req' && vector.js !== 'error: req: missing `method`') {
      frame.method = 'session/list'
    }
    if (vector.t === 'open' && vector.js !== 'error: open: missing `endpoint`') {
      frame.endpoint = '$events'
    }

    const error = deviceFrameError(frame)
    const expected = vector.js
    if (expected === 'ok') {
      assert.equal(error, undefined, `${vector.name}: deviceFrameError 应放行，实得 ${error}`)
      continue
    }
    assert.ok(expected.startsWith('error: '), `${vector.name}: 向量里的 js 期望写法不对`)
    assert.equal(error, expected.slice('error: '.length), `${vector.name}: 错误文案不符`)
  }
})

test('the id-carrying frame set matches the contract', () => {
  // Reachable only through deviceFrameError: a frame type that needs an `id`
  // must be reported as such when the id is missing.
  for (const kind of contract.idFrames) {
    const frame = { t: kind }
    if (kind === 'req') frame.method = 'session/list'
    if (kind === 'open') frame.endpoint = '$events'
    const error = deviceFrameError(frame)
    if (DEVICE_TO_AGENT.has(kind)) {
      assert.equal(error, `${kind}: missing \`id\``, `${kind} 应被判定为缺 id`)
    } else {
      // knownDrift validation-asymmetric: the connector never validates the
      // agent→device half, so these come back clean.
      assert.equal(error, undefined, `${kind} 落在 agent→device，本端不校验（记账中的漂移）`)
    }
  }
})

test('the shared vectors cover every drift the contract records', () => {
  const drifts = asSet(contract.knownDrift.map((entry) => entry.id))
  const recorded = new Set()
  for (const vector of vectors) {
    for (const drift of drifts) {
      if ((vector.why || '').includes(drift)) recorded.add(drift)
    }
  }
  assert.deepEqual(sorted(recorded), sorted(drifts), '每条 knownDrift 至少要有一条向量在记账')
})

test('the vectors include an unknown frame for forward compatibility', () => {
  const unknown = vectors.find((vector) => vector.direction === 'unknown')
  assert.ok(unknown, '向量里必须有一条未知帧')
  assert.equal(deviceFrameError({ t: unknown.t }), undefined, '未知帧必须放行')
})

// ── 基路径拼接：四份实现共享同一份向量 ──────────────────────────────────────

const basePathVectors = readJson('test/contract/relay-base-path-vectors.json').cases

/** 向量里的地址是 https 形态；连接器这一侧比的是 ws 形态（只换 scheme）。 */
const wsify = (url) => url.replace(/^https:/, 'wss:').replace(/^http:/, 'ws:')

test('joinRelayPath matches the shared base-path vectors', () => {
  const covered = basePathVectors.filter((item) => item.ends.includes('js'))
  assert.ok(covered.length > 0, '向量里没有任何一行标了 js')
  for (const item of covered) {
    // 空 base 是本端独有的能力（Swift 的 URL(string:"") 是 nil，测试台的 new URL('') 会抛）。
    const base = item.base === '' ? '' : normalizeRelayUrl(item.base).wsBase
    assert.equal(
      wsify(joinRelayPath(base, item.suffix)),
      wsify(item.url),
      `base=${item.base} suffix=${item.suffix}`,
    )
  }
})

test('the documented join drift is the connector\u2019s own difference', () => {
  const drifted = basePathVectors.filter((item) => item.knownDrift && item.ends.includes('js'))
  assert.ok(drifted.length > 0, '向量里应当有标了 knownDrift 的 js 行')
  for (const item of drifted) {
    // 漂移的另一侧就是这里：JS 补前导斜杠，Swift/测试台直接拼。
    const base = item.base === '' ? '' : normalizeRelayUrl(item.base).wsBase
    const joined = wsify(joinRelayPath(base, item.suffix))
    // 空 base 拼出来是相对路径（`/link/agent`），没有 host 可解析——直接用字符串比。
    const actualPath = item.base === '' ? joined : new URL(joined).pathname
    assert.equal(actualPath, item.path, `${item.base}+${item.suffix}: 本端路径变了`)
  }
})
