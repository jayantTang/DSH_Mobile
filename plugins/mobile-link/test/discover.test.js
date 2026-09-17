// The connector must find the live host even when the desktop shell's handoff
// file is missing — that file is deleted when the shell quits, and a bare
// `dsh web --port 0` never writes one.
import assert from 'node:assert/strict'
import test from 'node:test'
import { mkdtemp, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import { discoverEndpoint } from '../lib/dsh-client.js'

test('endpoint.json wins when it is there', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'dlp-discover-'))
  const file = join(dir, 'endpoint.json')
  await writeFile(file, JSON.stringify({ url: 'http://127.0.0.1:5555/?token=aaa', port: 5555 }))
  const found = await discoverEndpoint({ endpointFile: file, shellLogFile: join(dir, 'none.log') })
  assert.equal(found.port, 5555)
  assert.equal(found.token, 'aaa')
  assert.match(found.source, /endpoint\.json/)
})

test('the shell log answers when the handoff file is gone', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'dlp-discover-'))
  const log = join(dir, 'dsh-shell.log')
  await writeFile(log, [
    '[2026-01-01T00:00:00Z] attached to running dsh (pid 1) at http://127.0.0.1:1111/?token=old',
    '[2026-01-02T00:00:00Z] ---- DSH.app launch ----',
    '[2026-01-02T00:00:01Z] attached to running dsh (pid 2) at http://127.0.0.1:65137/?token=sampleLaunchTokenForTheTestOnly',
  ].join('\n'))
  const found = await discoverEndpoint({ endpointFile: join(dir, 'missing.json'), shellLogFile: log })
  assert.equal(found.port, 65137, 'the last launch wins')
  assert.equal(found.token, 'sampleLaunchTokenForTheTestOnly')
  assert.match(found.source, /dsh-shell\.log/)
})

test('with neither source it falls back to the default port and reports that', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'dlp-discover-'))
  const saved = process.env.DSH_WEB_URL
  delete process.env.DSH_WEB_URL // the harness runs inside a host that sets it
  try {
    const found = await discoverEndpoint({ endpointFile: join(dir, 'missing.json'),
                                          shellLogFile: join(dir, 'missing.log') })
    assert.equal(found.source, 'default')
    assert.equal(found.token, '')
  } finally {
    if (saved !== undefined) process.env.DSH_WEB_URL = saved
  }
})
