/**
 * What `enroll` prints, end to end, against a stub relay.
 *
 * The first-run path is the one place a person has the phone in hand and the
 * terminal in front of them, and it used to end with a single line ("这台电脑已
 * 登记") that reads like the job is done — the first trial user enrolled a
 * computer and never paired a phone. The output now carries the next two steps
 * and a pairing code rendered as a terminal QR, and both halves of that are
 * worth a test: the hint can silently disappear in a refactor, and a QR that
 * renders as garbage is worse than no QR at all.
 *
 * No relay involved: two endpoints answered by a local stub, and a state file in
 * a temporary directory so the machine's real identity is never touched.
 */

import { execFile } from 'node:child_process'
import { createServer } from 'node:http'
import assert from 'node:assert/strict'
import test from 'node:test'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { promisify } from 'node:util'

const run = promisify(execFile)
const CLI = join(import.meta.dirname, '..', 'lib', 'cli.js')

/** A relay that answers enroll, and pairs codes the way the real one does. */
async function stubRelay({ mintFails = false } = {}) {
  const seen = []
  const server = createServer((request, response) => {
    let body = ''
    request.on('data', (chunk) => { body += chunk })
    request.on('end', () => {
      seen.push({ url: request.url, authorization: request.headers.authorization, body })
      response.setHeader('content-type', 'application/json')
      if (request.url.endsWith('/agents/enroll')) {
        response.end(JSON.stringify({
          ok: true, agentId: 'agt_stub', agentSecret: 'as_stub',
          agentName: 'stub computer',
        }))
        return
      }
      if (request.url.endsWith('/pair/code')) {
        if (mintFails) {
          response.statusCode = 500
          response.end(JSON.stringify({ ok: false, error: { message: 'stub says no' } }))
          return
        }
        response.end(JSON.stringify({
          ok: true, code: 'ABCD-EFGH', expiresAt: Date.now() + 10 * 60 * 1000,
        }))
        return
      }
      response.statusCode = 404
      response.end('{}')
    })
  })
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
  return { server, seen, port: server.address().port }
}

async function enrollAgainst(options) {
  const { server, seen, port } = await stubRelay(options)
  const directory = mkdtempSync(join(tmpdir(), 'dsh-enroll-cli-'))
  const stateFile = join(directory, 'agent.json')
  try {
    const { stdout } = await run(process.execPath, [
      CLI, 'enroll', '--invite', 'AAAA-BBBB-CCCC-DDDD',
      '--relay', `ws://127.0.0.1:${port}/dsh-link`,
      '--state-file', stateFile,
    ], { env: { ...process.env, DSH_HOME: directory } })
    return { stdout, stateFile, seen }
  } finally {
    server.close()
  }
}

test('enroll ends with the two remaining steps, not just "登记完成"', async () => {
  const { stdout } = await enrollAgainst()
  assert.match(stdout, /接下来还有两步/)
  assert.match(stdout, /重启 DSH/)
  assert.match(stdout, /扫码配对/)
  // And a way back to a fresh code if this one expires.
  assert.match(stdout, /mobile-link\/qr/)
  assert.match(stdout, /endpoint\.json/)
})

test('enroll prints a scannable symbol and the code it encodes', async () => {
  const { stdout, stateFile } = await enrollAgainst()
  const art = stdout.split('\n').filter((line) => /[▀▄█]/.test(line))
  assert.ok(art.length > 8, `终端二维码只有 ${art.length} 行`)
  // Every QR row is the same width, quiet zone included.
  const widths = new Set(art.map((line) => [...line].length))
  assert.equal(widths.size, 1, `二维码行宽不一致：${[...widths].join(', ')}`)
  // The human-readable code and its lifetime, so a phone that cannot scan is
  // not stuck.
  assert.match(stdout, /配对码 ABCD-EFGH/)
  assert.match(stdout, /一次性/)
  // The identity landed in the file we passed, not in the machine's real one.
  const state = JSON.parse(readFileSync(stateFile, 'utf8'))
  assert.equal(state.agentId, 'agt_stub')
})

test('a refused pairing code does not make a successful enroll look failed', async () => {
  // The code is a convenience; the enrollment is the job. Losing the first must
  // not take the second with it.
  const { stdout } = await enrollAgainst({ mintFails: true })
  assert.match(stdout, /这台电脑已登记/)
  assert.match(stdout, /这次没能预先申请配对码/)
  assert.match(stdout, /mobile-link\/qr/)
  assert.doesNotMatch(stdout, /[▀▄█]/, '失败时不该画出半个二维码')
})
