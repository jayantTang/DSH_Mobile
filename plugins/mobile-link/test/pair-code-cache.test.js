import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, readFile, rm, stat } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import { MobileLinkAgent } from '../lib/link.js'

/**
 * 「小窗复用同一张持久码」（docs/PAIRING.md）在连接器这一侧的唯一实现：
 * 铸出来的持久码落一份缓存，下次要码先给缓存里的，不再请求中转。
 *
 * 这几条用例锁的就是这个承诺——没有缓存的话，面板每开一次、App 每重载一次，
 * 中转就多一张永久有效、且永远不会被作废的码。
 */

const IDENTITY = {
  relayUrl: 'wss://relay.test/dsh-link',
  agentId: 'agt_cache_test',
  agentSecret: 'as_cache_test',
}

function makeAgent(dir, overrides = {}) {
  const agent = new MobileLinkAgent({
    ...IDENTITY,
    ...overrides,
    stateFile: join(dir, 'agent.json'),
    journalPath: false,
    logs: false,
    logger: { warn: () => {} },
    dshClient: {},
  })
  return agent
}

function makeRelay({ prefix = 'CODE' } = {}) {
  const calls = []
  let mints = 0
  const fetchImpl = async (url, init) => {
    calls.push({ url: String(url), body: init?.body })
    const json = (body) => ({ ok: true, status: 200, json: async () => body })
    if (String(url).includes('/pair/code/regenerate')) {
      mints += 1
      return json({
        ok: true, code: `${prefix}-REGEN-${mints}`, persistent: true, expiresAt: null,
        revoked: 1, maxPairedDevices: 8, pairedDevices: 2,
      })
    }
    mints += 1
    return json({
      ok: true, code: `${prefix}-${mints}`, persistent: true, expiresAt: null,
      maxPairedDevices: 8, pairedDevices: 2,
    })
  }
  return { fetchImpl, calls, mintCount: () => mints }
}

async function withTempDir(fn) {
  const dir = await mkdtemp(join(tmpdir(), 'dsh-pair-code-'))
  try {
    return await fn(dir)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
}

test('a persistent code is reused instead of minting another one', async () => {
  await withTempDir(async (dir) => {
    const relay = makeRelay()
    const agent = makeAgent(dir)

    const first = await agent.mintPairCode({ fetchImpl: relay.fetchImpl })
    const second = await agent.mintPairCode({ fetchImpl: relay.fetchImpl })

    assert.equal(second.code, first.code, '同一次安装里，重开面板拿到的必须是同一张码')
    assert.equal(relay.mintCount(), 1, '第二次取码不许再请求中转')
    assert.equal(second.qrPayload, first.qrPayload, '二维码payload 跟着同一张码')
    assert.equal(second.persistent, true)
    assert.equal(second.maxPairedDevices, 8)
  })
})

test('the remembered code survives a fresh agent (panel reload / host restart)', async () => {
  await withTempDir(async (dir) => {
    const relay = makeRelay()
    const first = await makeAgent(dir).mintPairCode({ fetchImpl: relay.fetchImpl })

    // 新实例 = 宿主重启后重新构造的连接器；缓存文件在，就该拿到同一张。
    const restarted = await makeAgent(dir).mintPairCode({ fetchImpl: relay.fetchImpl })
    assert.equal(restarted.code, first.code)
    assert.equal(relay.mintCount(), 1)
  })
})

test('the cache file is private to this user', async () => {
  await withTempDir(async (dir) => {
    const relay = makeRelay()
    await makeAgent(dir).mintPairCode({ fetchImpl: relay.fetchImpl })

    const file = join(dir, 'pair-code.json')
    const mode = (await stat(file)).mode & 0o777
    assert.equal(mode, 0o600, '配对码是凭据：缓存文件必须 0600')
    const saved = JSON.parse(await readFile(file, 'utf8'))
    assert.equal(saved.agentId, IDENTITY.agentId)
    assert.equal(saved.relayUrl, IDENTITY.relayUrl)
  })
})

test('regenerating replaces the remembered code', async () => {
  await withTempDir(async (dir) => {
    const relay = makeRelay()
    const agent = makeAgent(dir)
    const before = await agent.mintPairCode({ fetchImpl: relay.fetchImpl })

    const regenerated = await agent.regeneratePairCode({ fetchImpl: relay.fetchImpl })
    assert.notEqual(regenerated.code, before.code)

    const after = await agent.mintPairCode({ fetchImpl: relay.fetchImpl })
    assert.equal(after.code, regenerated.code, '重新生成之后要码，拿到的是新的那张')
    assert.equal(relay.mintCount(), 2)
  })
})

test('a different identity does not reuse another computer\'s code', async () => {
  await withTempDir(async (dir) => {
    const relay = makeRelay()
    const first = await makeAgent(dir).mintPairCode({ fetchImpl: relay.fetchImpl })

    const other = makeAgent(dir, { agentId: 'agt_other', agentSecret: 'as_other' })
    const second = await other.mintPairCode({ fetchImpl: relay.fetchImpl })

    assert.notEqual(second.code, first.code)
    assert.equal(relay.mintCount(), 2)
  })
})

test('a time-limited code is never served from the cache', async () => {
  await withTempDir(async (dir) => {
    const relay = makeRelay()
    const agent = makeAgent(dir)
    await agent.mintPairCode({ fetchImpl: relay.fetchImpl })

    const limited = await agent.mintPairCode({ ttlMs: 60000, fetchImpl: relay.fetchImpl })
    assert.equal(relay.mintCount(), 2, '限时码每次都向中转要新的')
    assert.equal(limited.code, 'CODE-2')
  })
})
