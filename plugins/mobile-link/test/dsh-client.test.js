/**
 * 两种答案形状（JSON / multipart 二进制），以及**候选顺序上的认证行为**。
 *
 * 前者是既有契约：带字节的结果不可能是 JSON，支持字节的宿主改回
 * `multipart/form-data`；只读 JSON 的客户端会报 `gateway/bad-response`。
 * 后者是本特性新增：发现层按顺序给候选，"认证成功"的那个才算命中。
 */

import assert from 'node:assert/strict'
import test from 'node:test'

import { DshClient, DshUnavailable } from '../lib/dsh-client.js'

/** A client whose transport, endpoint and cookie are all already settled. */
function clientWith(fetchImpl) {
  const instance = new DshClient({ fetchImpl, logger: { debug() {}, warn() {} } })
  instance.endpoint = {
    base: 'http://127.0.0.1:9', wsBase: 'ws://127.0.0.1:9', port: 9, token: '',
  }
  instance.cookie = 'dsh-auth-test=v1'
  return instance
}

test('a JSON answer comes back exactly as before', async () => {
  const instance = clientWith(async () => Response.json({
    type: 'server-response',
    rpcId: 'r1',
    result: { ok: true, value: { bytes: 3, version: 'v' } },
  }))

  const result = await instance.rpc('workspaceFiles/stat', {})
  assert.deepEqual(result, { ok: true, value: { bytes: 3, version: 'v' } })
})

test('a binary answer is decoded into the same envelope shape', async () => {
  const form = new FormData()
  form.set('bytes-0', new Blob([new Uint8Array([1, 2, 3, 4])]))
  form.set('metadata', JSON.stringify({
    type: 'server-response',
    rpcId: 'r2',
    result: { ok: true, value: { offset: 7, data: null, eof: false, bytes: 9 } },
    attachments: [{ path: ['data'], codec: 'bytes', part: 'bytes-0' }],
  }))
  const instance = clientWith(async () => new Response(form))

  const result = await instance.rpc('workspaceFiles/readBytes', {})
  assert.equal(result.ok, true, '二进制答案被当成失败了')
  assert.equal(result.value.offset, 7)
  assert.equal(result.value.bytes, 9)
  assert.equal(result.value.eof, false)
  assert.ok(result.value.data instanceof Uint8Array, 'data 不是字节')
  assert.deepEqual(Array.from(result.value.data), [1, 2, 3, 4])
})

test('a binary answer whose part is missing is a bad response, not a crash', async () => {
  const form = new FormData()
  form.set('metadata', JSON.stringify({
    type: 'server-response',
    rpcId: 'r3',
    result: { ok: true, value: { data: null } },
    attachments: [{ path: ['data'], codec: 'bytes', part: 'bytes-0' }],
  }))
  const instance = clientWith(async () => new Response(form))

  const result = await instance.rpc('workspaceFiles/readBytes', {})
  assert.equal(result.ok, false)
  assert.equal(result.error.code, 'gateway/bad-response')
})

/** 只对带正确令牌的 URL 发 cookie；其余一律 401。 */
function authBy(fetchImpl) {
  return async (url, init) => {
    const parsed = new URL(typeof url === 'string' ? url : url.url)
    if (parsed.searchParams.get('token') !== 'good') return new Response('', { status: 401 })
    return new Response('', {
      status: 303,
      headers: { 'set-cookie': 'dsh-auth-test=v1; Path=/; HttpOnly' },
    })
  }
}

test('refresh takes the first candidate that actually authenticates', async () => {
  const client = new DshClient({
    logger: { debug() {}, warn() {} },
    env: {},
    hostService: () => 'http://127.0.0.1:19387/?token=good',
    fetchImpl: authBy(),
  })
  const endpoint = await client.refresh()
  assert.equal(endpoint.source, 'host-service')
  assert.equal(endpoint.port, 19387)
  assert.match(client.cookie, /dsh-auth-test/)
  assert.equal(client.errorKind, undefined)
})

test('refresh falls back to the older source when the new one cannot authenticate', async () => {
  const client = new DshClient({
    logger: { debug() {}, warn() {} },
    env: { DSH_WEB_URL: 'http://127.0.0.1:52430/?token=good' },
    hostService: () => 'http://127.0.0.1:19387/?token=bad',
    fetchImpl: authBy(),
  })
  const endpoint = await client.refresh()
  assert.equal(endpoint.source, 'DSH_WEB_URL', '第 2 级认证失败后必须继续用第 3 级')
  assert.match(client.cookie, /dsh-auth-test/)
})

test('a wrong explicit config does not wedge discovery: later candidates are still tried', async () => {
  const client = new DshClient({
    logger: { debug() {}, warn() {} },
    env: {},
    explicitUrl: 'http://127.0.0.1:9/?token=bad',
    hostService: () => 'http://127.0.0.1:19387/?token=good',
    fetchImpl: authBy(),
  })
  const endpoint = await client.refresh()
  assert.equal(endpoint.source, 'host-service')
})

test('when every candidate fails the error kind names the one that got furthest', async () => {
  const client = new DshClient({
    logger: { debug() {}, warn() {} },
    env: {},
    hostService: () => 'http://127.0.0.1:19387/?token=bad',
    fetchImpl: authBy(),
  })
  await assert.rejects(() => client.refresh(), DshUnavailable)
  assert.equal(client.errorKind, 'host-service')
  assert.equal(client.cookie, '')
})

test('with no token anywhere the failure is "unreachable", not a service name', async () => {
  const client = new DshClient({
    logger: { debug() {}, warn() {} },
    env: {},
    fetchImpl: authBy(),
  })
  await assert.rejects(() => client.refresh(), DshUnavailable)
  assert.equal(client.errorKind, 'unreachable')
})

test('the resolver can be wired after construction (that is how ctx.inject arrives)', async () => {
  const client = new DshClient({ logger: { debug() {}, warn() {} }, env: {}, fetchImpl: authBy() })
  assert.equal(client.hostService, undefined)
  client.setHostService(() => 'http://127.0.0.1:19387/?token=good')
  const endpoint = await client.refresh()
  assert.equal(endpoint.source, 'host-service')
})

test('outside a host (no resolver) the older sources still work exactly as before', async () => {
  // 进程外运行（独立命令行）拿不到宿主内注入：第 1、3、4 级必须照旧可用。
  const client = new DshClient({
    logger: { debug() {}, warn() {} },
    env: { DSH_WEB_URL: 'http://127.0.0.1:52430/?token=good' },
    fetchImpl: authBy(),
  })
  assert.equal(client.hostService, undefined)
  const endpoint = await client.refresh()
  assert.equal(endpoint.source, 'DSH_WEB_URL')
  assert.equal(endpoint.port, 52430)
})
