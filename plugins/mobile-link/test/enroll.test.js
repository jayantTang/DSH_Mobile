/**
 * Enrollment: invite code -> durable identity.
 *
 * The failure modes here are the ones that matter in the field — a wrong code,
 * an already-used code, an unreachable relay — and the invariant that a failed
 * enrollment must leave the machine exactly as it was.
 */

import assert from 'node:assert/strict'
import { mkdtemp, readFile, stat } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'

import { enrollAgent, enrollPlan, inviteFrom } from '../lib/enroll.js'
import { enrollEndpoint } from '../lib/dlp.js'
import { INVITE_ENV, MissingIdentity, readState, resolveIdentity } from '../lib/state.js'

const RELAY = 'wss://relay.test/dsh-link'

function statePath() {
  return mkdtemp(join(tmpdir(), 'mobile-link-enroll-')).then((dir) => join(dir, 'agent.json'))
}

/** A stub relay that answers like the real `/agents/enroll`. */
function relayStub({ status = 200, body } = {}) {
  const calls = []
  const fetchImpl = async (url, init) => {
    calls.push({ url, init })
    return {
      ok: status >= 200 && status < 300,
      status,
      json: async () => body,
    }
  }
  return { fetchImpl, calls }
}

const OK = { ok: true, agentId: 'agt_enrolled', agentSecret: 'as_secret', agentName: 'Sam Mac', accountId: 'acc_1' }

test('enroll writes the identity with mode 0600', async () => {
  const path = await statePath()
  const { fetchImpl, calls } = relayStub({ body: OK })

  const settled = await enrollAgent({
    relayUrl: RELAY, inviteCode: 'ABCD-EFGH-JKMN-PQRS', name: 'Sam Mac',
    stateFile: path, fetchImpl,
  })

  assert.equal(settled.agentId, 'agt_enrolled')
  assert.equal(settled.stateFile, path)
  assert.equal((await stat(path)).mode & 0o777, 0o600)
  assert.deepEqual(await readState(path), {
    relayUrl: RELAY, agentId: 'agt_enrolled', agentSecret: 'as_secret', agentName: 'Sam Mac',
  })

  // The call goes to the enroll endpoint under the relay's path prefix and
  // carries only the invite code and a name — never an existing secret.
  assert.equal(calls.length, 1)
  assert.equal(calls[0].url, 'https://relay.test/dsh-link/agents/enroll')
  assert.equal(calls[0].init.method, 'POST')
  assert.deepEqual(JSON.parse(calls[0].init.body), {
    inviteCode: 'ABCD-EFGH-JKMN-PQRS', name: 'Sam Mac',
  })
})

test('the resolved identity is usable by the link straight afterwards', async () => {
  const path = await statePath()
  const { fetchImpl } = relayStub({ body: OK })
  await enrollAgent({ relayUrl: RELAY, inviteCode: 'code', stateFile: path, fetchImpl })

  const identity = await resolveIdentity({ stateFile: path })
  assert.equal(identity.agentId, 'agt_enrolled')
  assert.equal(identity.agentSecret, 'as_secret')
  assert.equal(identity.relayUrl, RELAY)
  // Nothing stale to rewrite: enrollment already persisted it.
  assert.equal(identity.persisted, undefined)
})

test('a rejected invite writes nothing at all', async () => {
  const path = await statePath()
  const cases = [
    ['enroll/used', /already been used/],
    ['enroll/unknown', /not valid/],
    ['enroll/expired', /expired/],
  ]
  for (const [code, expected] of cases) {
    const { fetchImpl } = relayStub({ status: 404, body: { ok: false, error: { code, message: 'nope' } } })
    await assert.rejects(
      () => enrollAgent({ relayUrl: RELAY, inviteCode: 'bad', stateFile: path, fetchImpl }),
      (error) => {
        assert.match(error.message, expected)
        return true
      },
    )
    await assert.rejects(() => readFile(path, 'utf8'), /ENOENT/, 'a failed enrollment must not create the file')
  }
})

test('an unreachable relay fails with the address, not a stack trace', async () => {
  const path = await statePath()
  const fetchImpl = async () => { throw new Error('getaddrinfo ENOTFOUND') }
  await assert.rejects(
    () => enrollAgent({ relayUrl: RELAY, inviteCode: 'code', stateFile: path, fetchImpl }),
    /cannot reach the relay at wss:\/\/relay\.test\/dsh-link/,
  )
})

test('a non-JSON answer is reported as an HTTP failure', async () => {
  const path = await statePath()
  const fetchImpl = async () => ({ ok: false, status: 502, json: async () => { throw new Error('not json') } })
  await assert.rejects(
    () => enrollAgent({ relayUrl: RELAY, inviteCode: 'code', stateFile: path, fetchImpl }),
    /HTTP 502/,
  )
})

test('an existing identity is never replaced', async () => {
  const path = await statePath()
  const { fetchImpl } = relayStub({ body: OK })
  await enrollAgent({ relayUrl: RELAY, inviteCode: 'first', stateFile: path, fetchImpl })

  const second = relayStub({ body: { ...OK, agentId: 'agt_other' } })
  const plan = await enrollPlan({ stateFile: path, inviteCode: 'second', relayUrl: RELAY })
  assert.equal(plan.needed, false)
  assert.equal(plan.agentId, 'agt_enrolled')
  assert.equal(second.calls.length, 0)

  // And the file still holds the first identity.
  assert.equal((await readState(path)).agentId, 'agt_enrolled')
})

test('enrollPlan reports what a fresh install needs', async () => {
  const path = await statePath()
  const bare = await enrollPlan({ stateFile: path, env: {} })
  assert.equal(bare.needed, true)
  assert.equal(bare.canEnroll, false, 'no invite code and no relay means it cannot enroll itself')

  const withEnv = await enrollPlan({ stateFile: path, env: { [INVITE_ENV]: 'ABCD-EFGH' }, relayUrl: RELAY })
  assert.equal(withEnv.canEnroll, true)
  assert.equal(withEnv.invite, 'ABCD-EFGH')
})

test('inviteFrom prefers the explicit argument over the environment', () => {
  const env = { [INVITE_ENV]: 'FROM-ENV' }
  assert.equal(inviteFrom({ inviteCode: 'FROM-ARG', env }), 'FROM-ARG')
  assert.equal(inviteFrom({ inviteCode: '  ', env }), 'FROM-ENV')
  assert.equal(inviteFrom({ env }), 'FROM-ENV')
  assert.equal(inviteFrom({ env: {} }), undefined)
})

test('the identity error explains the enrollment command', async () => {
  const path = await statePath()
  await assert.rejects(
    () => resolveIdentity({ stateFile: path }),
    (error) => {
      assert.ok(error instanceof MissingIdentity, 'a missing identity must be distinguishable from a failure')
      assert.match(error.message, /dsh-mobile-link enroll/)
      assert.match(error.message, /--invite/)
      return true
    },
  )
})

test('enrollEndpoint keeps the relay path prefix', () => {
  assert.equal(enrollEndpoint('wss://host/dsh-link'), 'https://host/dsh-link/agents/enroll')
  assert.equal(enrollEndpoint('http://127.0.0.1:8787'), 'http://127.0.0.1:8787/agents/enroll')
  assert.equal(enrollEndpoint('https://host/prefix/'), 'https://host/prefix/agents/enroll')
})
