/**
 * `lib/logs.js` 与 `_link/logs` 接收路径的单测。
 *
 * 要钉住的性质：
 *   1. 落盘按「设备 / 本地日」分文件，清理只需 unlink 整天文件；
 *   2. 保留期 7 天，清理**在写入路径上**发生（没有定时任务可用）；
 *   3. 单设备超限按天淘汰最旧的；
 *   4. 序号水位幂等，`full` 重推不受水位限制；
 *   5. 长正文截断而不是整条丢弃；坏条目计入 dropped。
 */

import assert from 'node:assert/strict'
import { existsSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'

import {
  DEFAULT_RETENTION_MS, LogSpool, MAX_TEXT_CHARS, dayStamp, safeDeviceId,
} from '../lib/logs.js'
import { DeviceRouter } from '../lib/router.js'

function makeSpool(options = {}) {
  const root = mkdtempSync(join(tmpdir(), 'dsh-logs-'))
  let clock = Date.UTC(2026, 9, 18, 12, 0, 0)
  const spool = new LogSpool({ root, now: () => clock, ...options })
  return {
    spool,
    root,
    advance(ms) { clock += ms },
    setNow(ms) { clock = ms },
    lines(deviceId) {
      return readFileSync(spool.pathFor(deviceId), 'utf8').trim().split('\n').map((line) => JSON.parse(line))
    },
  }
}

test('按设备与本地日分文件，条目带时刻与级别', () => {
  const { spool, root } = makeSpool()
  const result = spool.append('dev_1', [
    { seq: 1, ms: Date.UTC(2026, 9, 18, 3, 0, 0), level: 'warn', source: 'ui', text: 'slow frame' },
  ])
  assert.equal(result.accepted, 1)
  assert.equal(result.lastSeq, 1)
  const name = `${dayStamp(Date.UTC(2026, 9, 18, 3, 0, 0))}.jsonl`
  const files = readdirSync(join(root, 'dev_1'))
  assert.deepEqual(files, [name])
  const [entry] = readFileSync(join(root, 'dev_1', name), 'utf8').trim().split('\n').map(JSON.parse)
  assert.equal(entry.deviceId, 'dev_1')
  assert.equal(entry.level, 'warn')
  assert.equal(entry.text, 'slow frame')
})

test('序号水位幂等：同一批重推不会写两遍', () => {
  const { spool } = makeSpool()
  const entry = { seq: 7, ms: Date.now(), text: 'once' }
  assert.equal(spool.append('dev_1', [entry]).accepted, 1)
  assert.equal(spool.append('dev_1', [entry]).accepted, 0)
})

test('full 重推绕过水位（冷启动回填与 export 用）', () => {
  const { spool, lines } = makeSpool()
  spool.append('dev_1', [{ seq: 1, ms: Date.now(), text: 'a' }])
  const again = spool.append('dev_1', [{ seq: 1, ms: Date.now(), text: 'a' }], { full: true })
  assert.equal(again.accepted, 1)
  assert.equal(lines('dev_1').length, 2)
})

test('超过保留期（7 天）的整天文件在写入时被清理', () => {
  const { spool, root, setNow, advance } = makeSpool()
  setNow(Date.UTC(2026, 9, 1, 12, 0, 0))
  spool.append('dev_1', [{ seq: 1, ms: Date.UTC(2026, 9, 1, 12, 0, 0), text: 'old' }])
  const oldFile = spool.pathFor('dev_1', Date.UTC(2026, 9, 1, 12, 0, 0))
  assert.ok(readFileSync(oldFile, 'utf8').includes('old'))

  // 60 秒节流：先把时钟拨到保留期之后，再写一条触发清理。
  // 保留期按天判定：8 天前那一整天必须消失（7 天整仍在保留期内）。
  advance(DEFAULT_RETENTION_MS + 24 * 60 * 60 * 1000 + 60_000)
  spool.append('dev_1', [{ seq: 2, ms: Date.now(), text: 'new' }])
  const names = readdirSync(join(root, 'dev_1')).sort()
  assert.equal(names.includes(`${dayStamp(Date.UTC(2026, 9, 1, 12, 0, 0))}.jsonl`), false,
    '超过 7 天的文件必须被删掉')
  assert.equal(names.includes(`${dayStamp(new Date().valueOf())}.jsonl`), true)
})

test('单设备超限按天淘汰最旧的，保留最新一天', () => {
  // 单设备上限有 1KB 下限，所以每条写 1.5KB、上限 2KB：三天的量必须淘汰到一天以内。
  const { spool, root, setNow } = makeSpool({ maxDeviceBytes: 2048 })
  const days = [Date.UTC(2026, 9, 15), Date.UTC(2026, 9, 16), Date.UTC(2026, 9, 17)]
  days.forEach((ms, index) => {
    setNow(ms)
    spool.append('dev_1', [{ seq: index + 1, ms, text: 'x'.repeat(1500) }])
  })
  const names = readdirSync(join(root, 'dev_1')).sort()
  assert.equal(names.length, 1, `应只留最新一天，实际 ${names.join(',')}`)
  assert.equal(names[0], `${dayStamp(Date.UTC(2026, 9, 17))}.jsonl`)
})

test('长正文截断、坏条目计入 dropped，而不是整批失败', () => {
  const { spool, lines } = makeSpool()
  const result = spool.append('dev_1', [
    { seq: 1, ms: Date.now(), text: 'y'.repeat(MAX_TEXT_CHARS + 100) },
    { seq: 2, ms: 'not-a-number', text: 'bad' },
  ])
  assert.equal(result.accepted, 1)
  assert.equal(result.dropped, 1)
  const [entry] = lines('dev_1')
  assert.equal(entry.text.length, MAX_TEXT_CHARS)
})

test('设备 id 不能穿出目录', () => {
  assert.equal(safeDeviceId('../../etc/passwd'), '______etc_passwd')
  const { spool, root } = makeSpool()
  spool.append('../../evil', [{ seq: 1, ms: Date.now(), text: 'x' }])
  const dirs = readdirSync(root)
  assert.equal(dirs.some((name) => name.startsWith('..')), false)
})

test('清理节流：60 秒内的写入不重复扫盘，过了窗口才清', () => {
  const { spool, root, setNow } = makeSpool()
  const base = Date.UTC(2026, 9, 18, 12, 0, 0)
  setNow(base)
  spool.append('dev_1', [{ seq: 1, ms: base, text: 'a' }]) // 首次写入顺带清一次，节流窗口起算
  const dir = join(root, 'dev_1')
  const stale = join(dir, '20260901.jsonl')
  writeFileSync(stale, '{"text":"stale"}\n')
  // 40 秒后再写：仍在节流窗口内，过期文件还在。
  setNow(base + 40_000)
  spool.append('dev_1', [{ seq: 2, ms: base + 40_000, text: 'b' }])
  assert.equal(existsSync(stale), true, '节流窗口内不该扫盘')
  // 再过一个窗口：这次必须清掉。
  setNow(base + 80_000)
  spool.append('dev_1', [{ seq: 3, ms: base + 80_000, text: 'c' }])
  assert.equal(existsSync(stale), false, '过了节流窗口必须清理过期文件')
})

test('_link/logs 走 router 落到 spool；未配置 spool 时明确拒绝', () => {
  const { spool } = makeSpool()
  const router = new DeviceRouter({ dsh: {}, send: () => {}, logs: spool })
  const result = router.acceptLogs('dev_1', {
    entries: [{ seq: 1, ms: Date.now(), level: 'info', text: 'via router' }],
  })
  assert.equal(result.ok, true)
  assert.equal(result.value.accepted, 1)

  const withoutSpool = new DeviceRouter({ dsh: {}, send: () => {} })
  const refused = withoutSpool.acceptLogs('dev_1', { entries: [] })
  assert.equal(refused.ok, false)
  assert.equal(refused.error.code, 'logs/disabled')
})

test('handleRequest 把 _link/logs 应答成 res 帧', async () => {
  const { spool } = makeSpool()
  const frames = []
  const router = new DeviceRouter({
    dsh: {}, logs: spool,
    send: (deviceId, frame) => frames.push({ deviceId, frame }),
  })
  await router.handleRequest('dev_1', {
    t: 'req', id: 'r1', method: '_link/logs',
    args: { entries: [{ seq: 1, ms: Date.now(), text: 'from wire' }] },
  })
  assert.equal(frames.length, 1)
  assert.equal(frames[0].frame.t, 'res')
  assert.equal(frames[0].frame.id, 'r1')
  assert.equal(frames[0].frame.ok, true)
  assert.equal(frames[0].frame.value.accepted, 1)
})
