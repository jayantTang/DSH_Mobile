import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  DEFAULT_RESUME, parseArgs, readEndpoint as readRequesterEndpoint, stateDir,
} from './dsh-restart.mjs'
import {
  alive, appMainPids, clearStaleSingleton, hostFormOf, readEndpoint, resumePayload, stop, waitForNewBackend,
} from './dsh-restart-worker.mjs'

function fixtureHome() {
  const home = mkdtempSync(join(tmpdir(), 'dsh-restart-'))
  mkdirSync(join(home, 'mobile-link'), { recursive: true })
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
    const directory = join(home, 'mobile-link')
    writeFileSync(join(directory, 'endpoint.json'), JSON.stringify({
      url: 'http://127.0.0.1:58334/?token=abc',
      port: 58334,
      pid: 4321,
      source: 'host-service',
    }))
    const endpoint = readRequesterEndpoint(home)
    assert.equal(endpoint.port, 58334)
    assert.equal(endpoint.pid, 4321)
    assert.equal(endpoint.source, 'host-service')
    // The worker must keep the token-carrying url: dropping it turns the cookie
    // exchange into an unauthenticated GET, which answers 401 and leaves the
    // agent asleep after a restart that otherwise worked.
    const workerView = readEndpoint(join(directory, 'endpoint.json'))
    assert.equal(workerView.port, 58334)
    assert.equal(workerView.pid, 4321)
    assert.match(workerView.url, /token=abc/)
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

test('hostFormOf reads the process tree: the desktop app supervises its own backend', () => {
  const desktop = (args) => {
    if (args[0] === '-o' && args[1] === 'ppid=') return '79301\n'
    return '/Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness --expose-internals /x/dsh-desktop-host/lib/index.js\n'
  }
  assert.equal(hostFormOf(79322, { run: desktop }), 'desktop')

  const web = (args) => (args[1] === 'ppid=' ? '1\n' : '/opt/homebrew/bin/node /opt/homebrew/bin/dsh web --no-open --port 0\n')
  assert.equal(hostFormOf(28480, { run: web }), 'web', '终端里的 dsh web 不能判成桌面版')

  const broken = () => { throw new Error('ps: no such process') }
  assert.equal(hostFormOf(1, { run: broken }), 'unknown')
  assert.equal(hostFormOf(0, { run: broken }), 'unknown')
})

test('appMainPids picks the app main process, never the host child', () => {
  // 实测踩过两件事：① 整个应用包路径 pkill -f 会连宿主子进程一起命中，应用随即弹
  // 「宿主异常退出」；② pgrep -f 在这台机器上只列得出 Helper，主进程看不到。
  const psOutput = [
    '11032 /Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness',
    '11054 /Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness --expose-internals /Applications/DeepSeek Harness.app/Contents/Resources/app.asar/dsh/index.js',
    '11039 /Applications/DeepSeek Harness.app/Contents/Frameworks/DeepSeek Harness Helper.app/Contents/MacOS/DeepSeek Harness Helper --type=gpu-process',
    '12764 grep -F DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness',
  ].join('\n')
  assert.deepEqual(appMainPids({ run: () => psOutput }), ['11032'])

  const none = () => { throw new Error('ps: failed') }
  assert.deepEqual(appMainPids({ run: none }), [], '取不到进程列表时返回空数组，不抛')
})

test('clearStaleSingleton removes the lock only when the app is really gone', () => {
  const removed = []
  const fakeFs = {
    dir: '/tmp/whatever',
    log: () => {},
    exists: () => true,
    remove: (path) => removed.push(path),
    removeMissing: () => {},
  }
  const gone = clearStaleSingleton({ ...fakeFs, appAlive: () => false })
  assert.equal(gone.length, 3, '应用不在时才清三个文件')
  assert.ok(removed.every((path) => path.includes('Singleton')))

  removed.length = 0
  const running = clearStaleSingleton({ ...fakeFs, appAlive: () => true })
  assert.deepEqual(running, [], '应用在跑时一个都不动')
  assert.deepEqual(removed, [])
})

test('clearStaleSingleton tolerates a missing directory', () => {
  const cleared = clearStaleSingleton({ dir: '/tmp/definitely-not-here', appAlive: () => false, log: () => {} })
  assert.deepEqual(cleared, [])
})
