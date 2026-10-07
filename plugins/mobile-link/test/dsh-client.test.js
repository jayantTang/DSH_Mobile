/**
 * The two shapes one `POST /api/<method>` answer can arrive in.
 *
 * A result that carries bytes cannot be JSON, so a Host that supports them
 * answers `multipart/form-data`: a `metadata` part holds the envelope with
 * `null` standing where the bytes were, and one `bytes-N` part carries each of
 * them. A client that only reads JSON sees an unparsable body and reports
 * `gateway/bad-response` — which is how a Host generation that started doing
 * this broke every file read at once. Both shapes are pinned here.
 */

import assert from 'node:assert/strict'
import test from 'node:test'

import { DshClient } from '../lib/dsh-client.js'

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
