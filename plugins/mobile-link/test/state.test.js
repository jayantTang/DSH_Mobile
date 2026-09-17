/**
 * Identity resolution/persistence and the pairing helper.
 */

import assert from 'node:assert/strict'
import { mkdtemp, readFile, stat } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'

import { mintPairCode } from '../lib/pairing.js'
import { defaultEndpointFile, defaultStatePath, readState, resolveIdentity, writeState } from '../lib/state.js'

async function tempPath(name = 'agent.json') {
  return join(await mkdtemp(join(tmpdir(), 'mobile-link-state-')), name)
}

test('the default paths live under $DSH_HOME', () => {
  // DSH_HOME is what isolates the test suite from the real ~/.dsh; when it is
  // set, both paths must follow it rather than the home directory.
  const home = process.env.DSH_HOME || ''
  const relative = (path) => (home ? path.startsWith(home) : /\.dsh[/\\]/.test(path))
  assert.ok(relative(defaultStatePath()), `agent.json under ${home || '~/.dsh'}`)
  assert.ok(relative(defaultEndpointFile()), `endpoint.json under ${home || '~/.dsh'}`)
  assert.match(defaultStatePath(), /mobile-link[/\\]agent\.json$/)
  assert.match(defaultEndpointFile(), /desktop-shell[/\\]endpoint\.json$/)
})

test('writeState is atomic, 0600, and readable again', async () => {
  const path = await tempPath()
  await writeState(path, { agentId: 'agt_1', agentSecret: 'as_1', relayUrl: 'wss://relay' })
  assert.equal((await stat(path)).mode & 0o777, 0o600)
  assert.deepEqual(await readState(path), { agentId: 'agt_1', agentSecret: 'as_1', relayUrl: 'wss://relay' })
})

test('resolveIdentity persists a config-supplied identity to the state file', async () => {
  const path = await tempPath()
  const identity = await resolveIdentity({
    stateFile: path, agentId: 'agt_cfg', agentSecret: 'as_cfg', relayUrl: 'ws://relay.test',
  })
  assert.equal(identity.agentId, 'agt_cfg')
  assert.equal(identity.persisted, true)
  assert.equal((await stat(path)).mode & 0o777, 0o600)
  assert.deepEqual(await readState(path), {
    relayUrl: 'ws://relay.test', agentId: 'agt_cfg', agentSecret: 'as_cfg',
  })

  // A second call is a no-op: nothing stale to write.
  const again = await resolveIdentity({ stateFile: path })
  assert.equal(again.agentId, 'agt_cfg')
  assert.equal(again.persisted, undefined)
})

test('config and environment win over the file', async () => {
  const path = await tempPath()
  await writeState(path, { relayUrl: 'ws://old', agentId: 'agt_old', agentSecret: 'as_old' })
  const identity = await resolveIdentity({ stateFile: path, agentId: 'agt_new' })
  assert.equal(identity.agentId, 'agt_new')
  assert.equal(identity.agentSecret, 'as_old', 'an unspecified field still comes from the file')

  process.env.DSH_MOBILE_LINK_RELAY = 'ws://env'
  try {
    assert.equal((await resolveIdentity({ stateFile: path, agentId: 'agt_new' })).relayUrl, 'ws://env')
  } finally {
    delete process.env.DSH_MOBILE_LINK_RELAY
  }
})

test('resolveIdentity explains how to provision a missing identity', async () => {
  const path = await tempPath()
  await assert.rejects(
    () => resolveIdentity({ stateFile: path }),
    /not registered yet.*dsh-mobile-link enroll.*admin\.py agent-register/s,
  )
})

test('a read-only state file is reported but not fatal', async () => {
  const path = join(await mkdtemp(join(tmpdir(), 'mobile-link-ro-')), 'missing-dir', 'agent.json')
  // A path whose parent cannot be created (a file in the way) forces the write
  // to fail while the in-memory identity stays usable.
  const blocker = join(path, '..', '..')
  await writeState(join(blocker, 'blocker'), {})
  const identity = await resolveIdentity({
    stateFile: blocker, agentId: 'agt_x', agentSecret: 'as_x', relayUrl: 'ws://relay',
  })
  assert.equal(identity.agentId, 'agt_x')
  assert.equal(identity.persisted, false)
  assert.ok(identity.persistError)
})

test('mintPairCode posts to the prefixed relay and builds the dsh:// payload', async () => {
  const calls = []
  const fetchImpl = async (url, options) => {
    calls.push({ url, options })
    return {
      ok: true,
      status: 200,
      json: async () => ({ ok: true, code: '7F3K-9Q2M', expiresAt: 1790000000000, ttlMs: 600000 }),
    }
  }
  const minted = await mintPairCode({
    identity: { agentId: 'agt_1', agentSecret: 'as_1',
      relayUrl: 'wss://relay.example.com/dsh-link' },
    ttlMs: 600000,
    fetchImpl,
  })
  // The configured path prefix is kept, never replaced.
  assert.equal(calls[0].url, 'https://relay.example.com/dsh-link/pair/code')
  assert.equal(calls[0].options.headers.authorization, 'Bearer as_1')
  assert.deepEqual(JSON.parse(calls[0].options.body), { agentId: 'agt_1', ttlMs: 600000 })
  assert.equal(minted.code, '7F3K-9Q2M')
  assert.equal(minted.relayUrl, 'wss://relay.example.com/dsh-link')
  assert.equal(minted.qrPayload,
    'dsh://pair?relay=wss%3A%2F%2Frelay.example.com%2Fdsh-link&code=7F3K-9Q2M')
})

test('mintPairCode tolerates a trailing slash on the relay URL', async () => {
  const calls = []
  const fetchImpl = async (url, options) => {
    calls.push({ url, options })
    return { ok: true, status: 200, json: async () => ({ ok: true, code: 'AAAA-BBBB', expiresAt: 1 }) }
  }
  await mintPairCode({
    identity: { agentId: 'agt_1', agentSecret: 'as_1',
      relayUrl: 'wss://relay.example.com/dsh-link/' },
    fetchImpl,
  })
  assert.equal(calls[0].url, 'https://relay.example.com/dsh-link/pair/code')
})

test('mintPairCode surfaces a relay rejection', async () => {
  const fetchImpl = async () => ({
    ok: false, status: 401, json: async () => ({ ok: false, error: { code: 'auth/invalid-agent', message: 'nope' } }),
  })
  await assert.rejects(
    () => mintPairCode({
      identity: { agentId: 'agt_1', agentSecret: 'bad', relayUrl: 'wss://relay' }, fetchImpl,
    }),
    /nope/,
  )
})

test('readState tolerates a missing or broken file', async () => {
  assert.equal(await readState(join(tmpdir(), 'definitely-not-here', 'x.json')), undefined)
  const path = await tempPath()
  const { writeFile } = await import('node:fs/promises')
  await writeFile(path, '{not json')
  assert.equal(await readState(path), undefined)
  await writeFile(path, '[]')
  assert.equal(await readState(path), undefined)
  await writeFile(path, JSON.stringify({ agentId: 'agt_1' }))
  assert.deepEqual(JSON.parse(await readFile(path, 'utf8')), { agentId: 'agt_1' })
})
