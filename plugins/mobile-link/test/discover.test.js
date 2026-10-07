/**
 * 端点发现：候选顺序、降级与"谁最接近成功"的分类。
 *
 * 旧的"读外壳交接文件 / 读外壳日志"两级已随自研外壳一起删除（本特性 FR-009），
 * 所以这里既要断言新顺序，也要断言旧来源**不再出现**。
 */
import assert from 'node:assert/strict'
import test from 'node:test'

import { discoverCandidates, discoverEndpoint } from '../lib/dsh-client.js'

const sources = (list) => list.map((item) => item.source)

test('explicit config always comes first', () => {
  const list = discoverCandidates({
    explicitUrl: 'http://127.0.0.1:5555/?token=abc',
    hostService: () => 'http://127.0.0.1:6666/?token=def',
    env: { DSH_WEB_URL: 'http://127.0.0.1:7777' },
  })
  assert.equal(list[0].source, 'config')
  assert.equal(list[0].port, 5555)
  assert.equal(list[0].token, 'abc')
  assert.equal(list[1].source, 'host-service')
})

test('the in-process resolver beats the environment variable', () => {
  const list = discoverCandidates({
    hostService: () => 'http://127.0.0.1:19387/?token=hosttok',
    env: { DSH_WEB_URL: 'http://127.0.0.1:52430' },
  })
  assert.deepEqual(sources(list), ['host-service', 'DSH_WEB_URL', 'default'])
  assert.equal(list[0].port, 19387)
  assert.equal(list[0].token, 'hosttok')
})

test('a resolver that throws is skipped, not fatal', () => {
  const list = discoverCandidates({
    hostService: () => { throw new Error('no ctx') },
    env: {},
  })
  assert.deepEqual(sources(list), ['default'])
})

test('a resolver returning a non-string is skipped', () => {
  const list = discoverCandidates({ hostService: () => undefined, env: {} })
  assert.deepEqual(sources(list), ['default'])
})

test('DSH_WEB_URL is used when there is no resolver, and forces loopback', () => {
  const list = discoverCandidates({ env: { DSH_WEB_URL: 'http://192.168.1.9:52430' } })
  assert.equal(list[0].source, 'DSH_WEB_URL')
  assert.equal(list[0].base, 'http://127.0.0.1:52430')
})

test('with nothing at all the default port is the last resort', () => {
  const list = discoverCandidates({ env: {} })
  assert.deepEqual(sources(list), ['default'])
  assert.equal(list[0].port, 54499)
  assert.equal(list[0].token, '')
})

test('the removed shell sources never appear again', () => {
  const list = discoverCandidates({ env: { DSH_WEB_URL: 'http://127.0.0.1:1' } })
  for (const candidate of list) {
    assert.doesNotMatch(String(candidate.source), /endpoint\.json|dsh-shell\.log/)
  }
})

test('discoverEndpoint stays as the first-candidate helper', async () => {
  const first = await discoverEndpoint({ env: { DSH_WEB_URL: 'http://127.0.0.1:4321' } })
  assert.equal(first.source, 'DSH_WEB_URL')
  assert.equal(first.port, 4321)
})
