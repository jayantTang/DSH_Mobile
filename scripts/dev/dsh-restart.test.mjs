import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  DEFAULT_RESUME, parseArgs, readEndpoint as readRequesterEndpoint, stateDir,
} from './dsh-restart.mjs'
import {
  alive, readEndpoint, resumePayload, stop, waitForNewBackend,
} from './dsh-restart-worker.mjs'

function fixtureHome() {
  const home = mkdtempSync(join(tmpdir(), 'dsh-restart-'))
  mkdirSync(join(home, 'desktop-shell'), { recursive: true })
  return home
}

function withHome(body) {
  const home = fixtureHome()
  try {
    return body(home)
  } finally {
    rmSync(home, { recursive: true, force: true })
  }
}

test('reads the harness endpoint, port and supervising pid', () => {
  withHome((home) => {
    const directory = join(home, 'desktop-shell')
    writeFileSync(join(directory, 'endpoint.json'), JSON.stringify({
      url: 'http://127.0.0.1:58334/?token=abc',
      port: 58334,
      pid: 4321,
      desktopShell: true,
    }))
    const endpoint = readRequesterEndpoint(home)
    assert.equal(endpoint.port, 58334)
    assert.equal(endpoint.pid, 4321)
    assert.equal(endpoint.desktopShell, true)
    // The worker reads the same file the same way: two spellings of one fact
    // would drift the moment one of them changed.
    assert.deepEqual(readEndpoint(join(directory, 'endpoint.json')), { port: 58334, pid: 4321 })
  })
})

test('a missing or broken endpoint file is undefined, not a crash', () => {
  withHome((home) => {
    assert.equal(readEndpoint(join(home, 'nope.json')), undefined)
    writeFileSync(join(home, 'broken.json'), 'not json')
    assert.equal(readEndpoint(join(home, 'broken.json')), undefined)
  })
})

test('defaults keep the restart quick and the resume self-describing', () => {
  const args = parseArgs([])
  assert.equal(args.delayMs, 3000)
  assert.equal(args.dryRun, false)
  assert.match(args.resume, /restart\/state\.json/)
  assert.match(DEFAULT_RESUME, /继续/)
})

test('flags override the defaults', () => {
  const args = parseArgs(['--resume', '继续验证图片', '--delay', '7', '--session', 'session-1', '--dry-run'])
  assert.equal(args.resume, '继续验证图片')
  assert.equal(args.delayMs, 7000)
  assert.equal(args.session, 'session-1')
  assert.equal(args.dryRun, true)
  // A negative delay would mean "kill before the result is delivered".
  assert.equal(parseArgs(['--delay', '-3']).delayMs, 0)
})

test('the state directory is under the harness home', () => {
  assert.equal(stateDir('/tmp/x'), '/tmp/x/restart')
})

test('stop() reports a process that was already gone', async () => {
  // pid 0 is never a real backend; `kill(0, 0)` signals the process group, so the
  // worker must never be handed it — hence the explicit guard in `alive`.
  assert.equal(alive(undefined), false)
  assert.equal(await stop(undefined), 'gone')
  assert.equal(await stop(9_999_999), 'gone')
})

test('stop() escalates when SIGTERM is ignored', async () => {
  // A backend that will not die is worse than one that never started: it holds
  // the port and the new instance cannot publish its endpoint.
  const signals = []
  let running = true
  const result = await stop(4242, {
    timeoutMs: 120,
    pollMs: 20,
    isAlive: () => running,
    kill: (_pid, signal) => {
      signals.push(signal)
      if (signal === 'SIGKILL') running = false
    },
  })
  assert.deepEqual(signals, ['SIGTERM', 'SIGKILL'])
  assert.equal(result, 'kill')
})

test('waitForNewBackend ignores the pid we just stopped', async () => {
  // The old endpoint file survives the kill for a moment; treating it as "the
  // new backend" would resume against a corpse.
  // The "new" backend has to be a pid that is really alive: the worker checks,
  // because a pid in a stale file would be resumed against a corpse.
  let now = 0
  const sequence = [
    { port: 1, pid: 100 },
    { port: 1, pid: 100 },
    { port: 2, pid: process.pid },
  ]
  const endpoint = await waitForNewBackend({
    previousPid: 100,
    timeoutMs: 500,
    pollMs: 1,
    read: () => sequence[Math.min(now++, sequence.length - 1)],
  })
  assert.equal(endpoint.pid, process.pid)
})

test('waitForNewBackend gives up rather than hanging forever', async () => {
  const endpoint = await waitForNewBackend({
    previousPid: 100,
    timeoutMs: 30,
    pollMs: 5,
    read: () => ({ port: 1, pid: 100 }),
  })
  assert.equal(endpoint, undefined)
})

test('the resume prompt is a normal session prompt with a marked request id', () => {
  const payload = resumePayload('session-42', '继续')
  assert.equal(payload.request.sessionId, 'session-42')
  assert.equal(payload.request.mode, 'queue')
  assert.equal(payload.request.content[0].text, '继续')
  // Marked so the transcript can be read back: an unattended restart should be
  // identifiable, not look like the user typed something at 3am.
  assert.match(payload.request.requestId, /^restart-/)
})
