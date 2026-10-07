import { test } from 'node:test'
import assert from 'node:assert/strict'
import { capture, classify, explainCaptureFailure, pruneScreenshots, screenshotDir } from '../lib/capture.js'

test('screencapture results are classified without ever faking a cancel', () => {
  assert.equal(classify({ produced: true }).kind, 'ok')
  // Esc：没有文件、没有输出（退出码可能是 0 也可能是 1，不能拿它判）
  assert.equal(classify({ produced: false, stderr: '', code: 1 }).kind, 'cancelled')
  assert.equal(classify({ produced: false, stderr: '', code: 0 }).kind, 'cancelled')
  // 拿不准的一律算失败，并且带上原文
  const failed = classify({ produced: false, stderr: 'screencapture: something odd', code: 2 })
  assert.equal(failed.kind, 'failed')
  assert.match(failed.message, /something odd/)
})

test('a permission failure explains where to grant it and refuses to name a deleted app', () => {
  const verdict = classify({
    produced: false,
    code: 1,
    stderr: 'could not create image from display',
  })
  assert.equal(verdict.kind, 'permission')
  assert.match(verdict.message, /隐私与安全性 → 屏幕录制/)
  assert.match(verdict.message, /完全退出并重新打开/)
  assert.match(verdict.message, /运行 DSH 的那个程序/)
  assert.doesNotMatch(verdict.message, /DSH\.app/) // 001 修过一次，不许退回去
  assert.equal(explainCaptureFailure('').includes('could not create image'), false)
})

function harness({ produced = true, stderr = '', code = 0, existing = false } = {}) {
  const removed = []
  const pruned = []
  return {
    removed,
    pruned,
    run: async (path) => {
      harness.path = path
      return { code, stderr }
    },
    options: {
      home: '/tmp/dsh-shot-home',
      now: 1_700_000_000_000,
      platform: 'darwin',
      mkdir: () => {},
      exists: () => existing || produced,
      stat: () => ({ size: produced ? 10 : 0, mtimeMs: 1_700_000_000_000 }),
      remove: (path) => removed.push(path),
      prune: (dir, opts) => pruned.push({ dir, opts }),
      run: undefined,
    },
  }
}

test('a successful capture lands in the DSH_HOME screenshot dir and prunes old ones', async () => {
  const h = harness({ produced: true })
  const result = await capture({ ...h.options, run: h.run })
  assert.equal(result.kind, 'ok')
  assert.equal(result.path, `${screenshotDir('/tmp/dsh-shot-home')}/shot-1700000000000.png`)
  assert.equal(h.pruned.length, 1, '成功之后清理一次超期文件')
  assert.deepEqual(h.removed, [])
})

test('a cancelled capture leaves no file and reports no error', async () => {
  const h = harness({ produced: false, stderr: '', code: 1, existing: true })
  const result = await capture({ ...h.options, run: h.run })
  assert.equal(result.kind, 'cancelled')
  assert.equal(result.message, undefined)
  assert.deepEqual(h.removed, [`${screenshotDir('/tmp/dsh-shot-home')}/shot-1700000000000.png`],
    '半截文件也要删掉')
  assert.equal(h.pruned.length, 0, '失败/取消不触发清理')
})

test('non-macOS hosts are told so instead of failing silently', async () => {
  const result = await capture({ ...harness().options, platform: 'win32', run: async () => ({ code: 0 }) })
  assert.equal(result.kind, 'unsupported')
  assert.match(result.message, /只支持 macOS/)
})

test('pruneScreenshots removes only expired .png files', () => {
  const removed = []
  const removedCount = pruneScreenshots('/shots', {
    now: 1_000_000,
    ttlMs: 1000,
    list: () => ['old.png', 'fresh.png', 'notes.txt'],
    stat: (path) => ({ mtimeMs: path.includes('old') ? 0 : 999_500 }),
    remove: (path) => removed.push(path),
  })
  assert.equal(removedCount, 1)
  assert.deepEqual(removed, ['/shots/old.png'])
})

test('the screenshot route registers on the host web server and fails closed without a fence', async () => {
  const { registerScreenshotRoute, SCREENSHOT_ROUTE } = await import('../lib/screenshot-route.js')
  const routes = []
  const scope = {
    get: () => ({ requestRejection: () => 403 }),
    webServer: { register: (route) => { routes.push(route); return () => {} } },
  }
  const dispose = registerScreenshotRoute(scope, { logger: { warn() {} } })
  assert.equal(routes.length, 1)
  assert.equal(routes[0].path, SCREENSHOT_ROUTE)
  assert.equal(routes[0].kind, 'exact')
  assert.equal(typeof dispose, 'function')

  // 围栏拒绝时不得触达截屏
  let captured = 0
  const closedScope = {
    get: () => ({ requestRejection: () => 403 }),
    webServer: { register: (route) => { routes.push(route); return () => {} } },
  }
  registerScreenshotRoute(closedScope, { captureFn: async () => { captured += 1; return { kind: 'cancelled' } } })
  const handler = routes.at(-1).handler
  const res = { statusCode: 0, setHeader() {}, end() { this.ended = true } }
  await handler({ method: 'POST' }, res)
  assert.equal(captured, 0, '围栏拒绝后不许去截图')
  assert.equal(res.statusCode, 403)
})

test('the fence is read from the injected scope property, not only from ctx.get', async () => {
  const { registerScreenshotRoute } = await import('../lib/screenshot-route.js')
  const routes = []
  const scope = {
    // 注入后的服务是属性；get() 在插件作用域里取不到它（001 实测）
    connection: { requestRejection: () => null },
    get: () => undefined,
    webServer: { register: (route) => { routes.push(route); return () => {} } },
  }
  registerScreenshotRoute(scope, {
    logger: { warn() {} },
    captureFn: async () => ({ kind: 'cancelled' }),
  })
  const res = { statusCode: 0, headers: {}, setHeader(k, v) { this.headers[k] = v }, end() { this.ended = true } }
  await routes[0].handler({ method: 'POST', [Symbol.asyncIterator]: async function* () { yield Buffer.from('{"sessionId":"s1"}') } }, res)
  assert.equal(res.statusCode, 200, '围栏放行后必须真的走到截屏，而不是 403')
})

test('an allowed request is one where the fence returns undefined, not a missing service', async () => {
  // 实测行为（dsh-client-connection）：不信任回 403、未认证回 401、**通过则返回 undefined**。
  const { registerScreenshotRoute } = await import('../lib/screenshot-route.js')
  const routes = []
  let captured = 0
  const scope = {
    connection: { requestRejection: () => undefined },
    webServer: { register: (route) => { routes.push(route); return () => {} } },
  }
  registerScreenshotRoute(scope, {
    logger: { warn() {} },
    captureFn: async () => { captured += 1; return { kind: 'cancelled' } },
  })
  const res = { statusCode: 0, setHeader() {}, end() {} }
  await routes[0].handler({ method: 'POST', [Symbol.asyncIterator]: async function* () { yield Buffer.from('{"sessionId":"s1"}') } }, res)
  assert.equal(captured, 1, 'undefined 必须被当作放行')
  assert.equal(res.statusCode, 200)
})

test('a missing fence service still fails closed', async () => {
  const { registerScreenshotRoute } = await import('../lib/screenshot-route.js')
  const routes = []
  let captured = 0
  const scope = { webServer: { register: (route) => { routes.push(route); return () => {} } } }
  registerScreenshotRoute(scope, {
    logger: { warn() {} },
    captureFn: async () => { captured += 1; return { kind: 'cancelled' } },
  })
  const res = { statusCode: 0, setHeader() {}, end() {} }
  await routes[0].handler({ method: 'POST' }, res)
  assert.equal(captured, 0)
  assert.equal(res.statusCode, 403)
})
