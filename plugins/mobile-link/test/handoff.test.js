/**
 * 进程外交接文件：字段、权限、原子性，以及"连接器不读回它"这条不变量。
 *
 * 契约：`specs/001-connector-host-compat/contracts/out-of-process-handoff.md`。
 */

import assert from 'node:assert/strict'
import { readdir, readFile, stat } from 'node:fs/promises'
import test from 'node:test'

import { handoffFromEndpoint, writeHandoff } from '../lib/handoff.js'
import { withTempHome, handoffPath } from './helpers/tmp-home.js'

test('writes every contracted field with mode 0600', async () => {
  await withTempHome(async (home) => {
    const path = handoffPath(home)
    await writeHandoff({ url: 'http://127.0.0.1:19387/?token=t', port: 19387, source: 'host-service', path })

    const raw = JSON.parse(await readFile(path, 'utf8'))
    assert.equal(raw.url, 'http://127.0.0.1:19387/?token=t')
    assert.equal(raw.port, 19387)
    assert.equal(raw.source, 'host-service')
    assert.equal(raw.pid, process.pid)
    assert.match(raw.updatedAt, /^\d{4}-\d{2}-\d{2}T/)

    const mode = (await stat(path)).mode & 0o777
    assert.equal(mode, 0o600, `权限应为 0600，实际 ${mode.toString(8)}`)
  })
})

test('rewriting replaces the value and leaves no temporary file behind', async () => {
  await withTempHome(async (home) => {
    const path = handoffPath(home)
    await writeHandoff({ url: 'http://127.0.0.1:1/?token=old', port: 1, source: 'default', path })
    await writeHandoff({ url: 'http://127.0.0.1:2/?token=new', port: 2, source: 'host-service', path })

    const raw = JSON.parse(await readFile(path, 'utf8'))
    assert.equal(raw.port, 2)
    assert.equal(raw.url, 'http://127.0.0.1:2/?token=new')
    const entries = await readdir(`${home}/mobile-link`)
    assert.deepEqual(entries.filter((name) => name.endsWith('.tmp')), [])
  })
})

test('a missing url or port is refused instead of writing a half-usable file', async () => {
  await withTempHome(async (home) => {
    const path = handoffPath(home)
    await assert.rejects(() => writeHandoff({ port: 1, source: 'x', path }), TypeError)
    await assert.rejects(() => writeHandoff({ url: 'http://127.0.0.1:1/', source: 'x', path }), TypeError)
  })
})

test('handoffFromEndpoint needs both an address and a token', () => {
  assert.equal(handoffFromEndpoint(undefined), undefined)
  assert.equal(handoffFromEndpoint({ base: 'http://127.0.0.1:1', token: '' }), undefined)
  assert.deepEqual(
    handoffFromEndpoint({ base: 'http://127.0.0.1:1', port: 1, token: 'a b', source: 'host-service' }),
    { url: 'http://127.0.0.1:1/?token=a%20b', port: 1, source: 'host-service' },
  )
})
