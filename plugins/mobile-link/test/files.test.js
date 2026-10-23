import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { mkdtempSync, readFileSync, existsSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { FileInbox, FILE_BEGIN, FILE_CHUNK, FILE_END, isFileMethod } from '../lib/files.js'

// 隔离：收件箱在 `$DSH_HOME/inbox`。这条用例以前直接写真实 `~/.dsh/inbox`，
// 换到临时目录后既不会污染本机数据，也真的能验证隔离本身（宪法第 III 条）。
const TEST_HOME = mkdtempSync(join(tmpdir(), 'mobile-link-files-test-'))
process.env.DSH_HOME = TEST_HOME
process.on('exit', () => rmSync(TEST_HOME, { recursive: true, force: true }))

const sessionId = `test-${process.pid}`
const directory = join(TEST_HOME, 'inbox', sessionId)

function cleanup() {
  rmSync(directory, { recursive: true, force: true })
}

/** Splits a buffer the way the phone does. */
function chunksOf(buffer, size) {
  const parts = []
  for (let offset = 0; offset < buffer.length; offset += size) {
    parts.push(buffer.subarray(offset, offset + size))
  }
  return parts
}

/**
 * 本进程当前打开着、路径里含 `needle` 的文件。
 *
 * 这是"句柄真的被关掉了吗"的唯一直接证据：`.part` 被删除后，泄漏的 fd 在
 * POSIX 上仍然指着那个已被 unlink 的 inode，`existsSync` 看不见它，只有
 * `lsof` 这类按 fd 列进程资源的工具能看见。lsof 不可用时返回 `null`，
 * 调用方据此跳过（并会在前置断言处大声失败，不会静默变成"通过"）。
 */
function openFiles(needle) {
  try {
    const output = execFileSync('lsof', ['-p', String(process.pid), '-Fn'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
      maxBuffer: 8 << 20,
    })
    return output
      .split('\n')
      .filter((line) => line.startsWith('n') && line.includes(needle))
      .map((line) => line.slice(1))
  } catch (error) {
    if (error.code === 'ENOENT') return null
    if (error.status === 1) return []
    throw error
  }
}

/** `lsof` 缺失时跳过依赖它的用例（前置断言会把"扫不到"暴露成失败，不是通过）。 */
function requireLsof(t) {
  if (openFiles(`.lsof-probe-${process.pid}`) === null) {
    t.skip('本机没有 lsof，无法直接断言文件句柄')
    return false
  }
  return true
}

test('isFileMethod claims only the reserved names', () => {
  assert.ok(isFileMethod(FILE_BEGIN))
  assert.ok(isFileMethod(FILE_CHUNK))
  assert.ok(isFileMethod(FILE_END))
  // Everything else must keep going to the Host as an ordinary RPC.
  assert.equal(isFileMethod('session/list'), false)
  assert.equal(isFileMethod('_link/other'), false)
})

test('a chunked transfer lands byte-for-byte', () => {
  cleanup()
  const inbox = new FileInbox({})
  // Deliberately not text: binary is where an encoding mistake shows up.
  const body = Buffer.from(Array.from({ length: 5000 }, (_, i) => (i * 7) % 256))

  inbox.handle(FILE_BEGIN, { transferId: 't1', sessionId, name: 'report.pdf', bytes: body.length })
  chunksOf(body, 1024).forEach((part, seq) => {
    inbox.handle(FILE_CHUNK, { transferId: 't1', seq, data: part.toString('base64') })
  })
  const done = inbox.handle(FILE_END, { transferId: 't1' })

  assert.equal(done.bytes, body.length)
  assert.equal(done.path, join(directory, 'report.pdf'))
  assert.ok(existsSync(done.path), 'the file was not written')
  assert.ok(readFileSync(done.path).equals(body), 'the bytes changed in transit')
  // Nothing half-written is left behind for the agent to trip over.
  assert.equal(existsSync(join(directory, '.report.pdf.part')), false)
  cleanup()
})

test('the final name only appears once the transfer completes', () => {
  cleanup()
  const inbox = new FileInbox({})
  inbox.handle(FILE_BEGIN, { transferId: 't2', sessionId, name: 'half.txt', bytes: 10 })
  inbox.handle(FILE_CHUNK, { transferId: 't2', seq: 0, data: Buffer.from('12345').toString('base64') })
  assert.equal(existsSync(join(directory, 'half.txt')), false, 'an incomplete file is visible')
  cleanup()
})

test('an out-of-order chunk is refused', () => {
  cleanup()
  const inbox = new FileInbox({})
  inbox.handle(FILE_BEGIN, { transferId: 't3', sessionId, name: 'x.bin', bytes: 8 })
  inbox.handle(FILE_CHUNK, { transferId: 't3', seq: 0, data: Buffer.from('abcd').toString('base64') })
  assert.throws(
    () => inbox.handle(FILE_CHUNK, { transferId: 't3', seq: 5, data: 'AAAA' }),
    /out of order/,
  )
  cleanup()
})

test('a size mismatch is refused rather than written', () => {
  cleanup()
  const inbox = new FileInbox({})
  inbox.handle(FILE_BEGIN, { transferId: 't4', sessionId, name: 'short.bin', bytes: 100 })
  inbox.handle(FILE_CHUNK, { transferId: 't4', seq: 0, data: Buffer.from('abc').toString('base64') })
  assert.throws(() => inbox.handle(FILE_END, { transferId: 't4' }), /expected 100 bytes/)
  assert.equal(existsSync(join(directory, 'short.bin')), false, 'a truncated file was kept')
  cleanup()
})

test('a chunk without a transfer is refused', () => {
  const inbox = new FileInbox({})
  assert.throws(() => inbox.handle(FILE_CHUNK, { transferId: 'nope', seq: 0, data: '' }), /unknown transfer/)
})

test('a transfer needs a session and an id', () => {
  const inbox = new FileInbox({})
  assert.throws(() => inbox.handle(FILE_BEGIN, { name: 'a' }), /transferId/)
  assert.throws(() => inbox.handle(FILE_BEGIN, { transferId: 't' }), /sessionId/)
})

test('clear drops in-flight transfers', () => {
  cleanup()
  const inbox = new FileInbox({})
  inbox.handle(FILE_BEGIN, { transferId: 't5', sessionId, name: 'gone.bin', bytes: 4 })
  inbox.handle(FILE_CHUNK, { transferId: 't5', seq: 0, data: Buffer.from('ab').toString('base64') })
  inbox.clear()
  assert.throws(() => inbox.handle(FILE_END, { transferId: 't5' }), /unknown transfer/)
  cleanup()
})

// ── fsPut* 桥接帧（R-1 C-16）─────────────────────────────────────────────────
// 这一族帧由 relay 的 `PUT /files/up` 驱动，实现体复用 FileInbox。上行回复
// **只带 bid、不带 deviceId**（relay 靠 bid 关联回那个 HTTP 请求）。

test('the fsPut* bridge stages a file byte-for-byte, without a deviceId on the replies', async () => {
  const { DeviceRouter, FSPUT_BEGIN, FSPUT_CHUNK, FSPUT_END } = await import('../lib/router.js')
  cleanup()
  const sent = []
  const router = new DeviceRouter({
    dsh: { ensureMux: async () => {}, openStream() {}, cancelStream() {} },
    send: (deviceId, frame) => sent.push({ deviceId, frame }),
    logger: {},
  })
  await router.attachDevice('dev_1')

  const body = Buffer.from(Array.from({ length: 4096 }, (_, i) => (i * 11) % 256))
  const bid = 'bid-1'
  await router.handleRelayFrame({
    t: FSPUT_BEGIN, deviceId: 'dev_1', bid, sessionId, name: 'big.bin', bytes: body.length,
  })
  chunksOf(body, 700).forEach((part, seq) => {
    router.handleRelayFrame({ t: FSPUT_CHUNK, deviceId: 'dev_1', bid, seq, data: part.toString('base64') })
  })
  router.handleRelayFrame({ t: FSPUT_END, deviceId: 'dev_1', bid })

  const ack = sent.find((entry) => entry.frame.t === 'fsPutAck')
  assert.ok(ack, `没有收到 fsPutAck：${JSON.stringify(sent.map((e) => e.frame.t))}`)
  assert.equal(ack.frame.bid, bid)
  assert.equal(ack.frame.received, 0)
  // 回复帧本身不带 deviceId（`deviceId` 是这条测试桩自己记的"发给了谁"）。
  // **真正决定线上形状的是 link.js 的 sendToDevice**——那一层在
  // test/link.test.js 的「桥接帧不带 deviceId」用例里验。
  assert.equal('deviceId' in ack.frame, false)

  const done = sent.find((entry) => entry.frame.t === 'fsPutDone')
  assert.ok(done, '没有收到 fsPutDone')
  assert.equal(done.frame.bid, bid)
  assert.equal(done.frame.bytes, body.length)
  assert.ok(readFileSync(done.frame.path).equals(body), '桥接过来的字节变了')
  assert.equal('deviceId' in done.frame, false)
  cleanup()
})

test('the bridge reports a bad sequence over fsErr instead of throwing', async () => {
  const { DeviceRouter, FSPUT_BEGIN, FSPUT_CHUNK } = await import('../lib/router.js')
  cleanup()
  const sent = []
  const router = new DeviceRouter({
    dsh: { ensureMux: async () => {}, openStream() {}, cancelStream() {} },
    send: (deviceId, frame) => sent.push(frame),
    logger: {},
  })
  await router.attachDevice('dev_1')
  await router.handleRelayFrame({
    t: FSPUT_BEGIN, deviceId: 'dev_1', bid: 'b2', sessionId, name: 'x.bin', bytes: 8,
  })
  router.handleRelayFrame({
    t: FSPUT_CHUNK, deviceId: 'dev_1', bid: 'b2', seq: 0, data: Buffer.from('abcd').toString('base64'),
  })
  router.handleRelayFrame({ t: FSPUT_CHUNK, deviceId: 'dev_1', bid: 'b2', seq: 9, data: 'AAAA' })

  const failure = sent.find((frame) => frame.t === 'fsErr')
  assert.ok(failure, '乱序分片没有回 fsErr')
  assert.equal(failure.bid, 'b2')
  assert.match(failure.message, /out of order/)
  assert.equal('deviceId' in failure, false)
  cleanup()
})

test('the bridge reports a byte-count mismatch and a bad bid', async () => {
  const { DeviceRouter, FSPUT_BEGIN, FSPUT_END, FSPUT_CHUNK } = await import('../lib/router.js')
  cleanup()
  const sent = []
  const router = new DeviceRouter({
    dsh: { ensureMux: async () => {}, openStream() {}, cancelStream() {} },
    send: (deviceId, frame) => sent.push(frame),
    logger: {},
  })
  await router.attachDevice('dev_1')

  // 字节数不符：结束时报错，且**不留下半个文件**。
  await router.handleRelayFrame({
    t: FSPUT_BEGIN, deviceId: 'dev_1', bid: 'b3', sessionId, name: 'short.bin', bytes: 100,
  })
  router.handleRelayFrame({
    t: FSPUT_CHUNK, deviceId: 'dev_1', bid: 'b3', seq: 0, data: Buffer.from('abc').toString('base64'),
  })
  router.handleRelayFrame({ t: FSPUT_END, deviceId: 'dev_1', bid: 'b3' })
  const mismatch = sent.find((frame) => frame.t === 'fsErr')
  assert.match(mismatch.message, /expected 100 bytes/)
  assert.equal(existsSync(join(directory, 'short.bin')), false)

  // 未知 bid。
  router.handleRelayFrame({ t: FSPUT_CHUNK, deviceId: 'dev_1', bid: 'nope', seq: 0, data: '' })
  assert.equal(sent.filter((frame) => frame.t === 'fsErr').length, 2)
  assert.match(sent.filter((frame) => frame.t === 'fsErr')[1].message, /unknown transfer/)
  cleanup()
})

test('a 200 MB bridge sequence does not grow the heap with the file size', async () => {
  // 这是本项的核心验收：以前 FileInbox 把整份文件攒在内存里
  // （`this.parts` + `Buffer.concat`），一条大文件就能吃掉几百 MB RSS。
  // 现在逐片写盘，堆占用应该与**分片大小**成正比，与文件总大小无关。
  const { DeviceRouter, FSPUT_BEGIN, FSPUT_CHUNK, FSPUT_END } = await import('../lib/router.js')
  cleanup()
  const sent = []
  const router = new DeviceRouter({
    dsh: { ensureMux: async () => {}, openStream() {}, cancelStream() {} },
    send: (deviceId, frame) => sent.push(frame),
    logger: {},
  })
  await router.attachDevice('dev_1')

  const chunk = Buffer.alloc(1 << 20, 0x5a)          // 1 MiB
  const total = 200 * (1 << 20)                       // 200 MiB
  const pieces = total / chunk.length                 // 200 片
  const encoded = chunk.toString('base64')

  global.gc?.()
  const before = process.memoryUsage().heapUsed
  await router.handleRelayFrame({
    t: FSPUT_BEGIN, deviceId: 'dev_1', bid: 'big', sessionId, name: 'huge.bin', bytes: total,
  })
  for (let seq = 0; seq < pieces; seq += 1) {
    router.handleRelayFrame({ t: FSPUT_CHUNK, deviceId: 'dev_1', bid: 'big', seq, data: encoded })
  }
  router.handleRelayFrame({ t: FSPUT_END, deviceId: 'dev_1', bid: 'big' })
  const growth = process.memoryUsage().heapUsed - before

  const done = sent.find((frame) => frame.t === 'fsPutDone')
  assert.ok(done, '200 MB 序列没有走完')
  assert.equal(done.bytes, total, '落盘字节数不对')

  // 线性增长的话这里会是 200 MB 量级；给足余量仍然能把它和"攒内存"区分开
  // （实测增长在 1 MB 上下；阈值取 64 MB）。
  assert.ok(
    growth < 64 * 1024 * 1024,
    `堆增长 ${(growth / 1048576).toFixed(1)} MB，疑似又把文件攒进内存了`,
  )
  rmSync(done.path, { force: true })
  cleanup()
})

// ── 句柄所有权：中断上传必须释放 .part 与临时文件 ──────────────────────────
// M8 文件联调实测的缺陷：上传被中断（relay 不再发分片/不再发 fsPutEnd）后，
// `Transfer` 一直留在 FileInbox 里，`.part` 的 fd 不关；用新 bid 重传后旧 fd
// 仍然打开。下面几条用例从"进程当前打开了哪些文件"取证，而不只看对象状态。

test('一个再没有任何帧的上传，空闲超时后释放 .part 句柄并删掉暂存文件', (t) => {
  if (!requireLsof(t)) return
  t.mock.timers.enable({ apis: ['setInterval', 'Date'] })
  cleanup()
  const inbox = new FileInbox({}, { idleMs: 60_000, sweepMs: 10_000 })
  inbox.handle(FILE_BEGIN, { transferId: 'idle-1', sessionId, name: 'idle.bin', bytes: 8 })
  inbox.handle(FILE_CHUNK, {
    transferId: 'idle-1', seq: 0, data: Buffer.from('abcd').toString('base64'),
  })
  assert.equal(openFiles('.idle.bin.part')?.length, 1, '前置：.part 句柄没有打开')

  // 还没到空闲上限：正在慢慢传的上传不许被误杀。
  t.mock.timers.tick(59_000)
  assert.equal(openFiles('.idle.bin.part')?.length, 1, '还没到空闲上限就释放了上传')

  t.mock.timers.tick(1_000)
  assert.equal(openFiles('.idle.bin.part')?.length, 0, '空闲超时后 .part 句柄仍然打开')
  assert.equal(existsSync(join(directory, '.idle.bin.part')), false, '空闲超时后暂存文件没有删掉')
  // 被清扫之后，同一个 bid 的迟到分片只能得到"未知上传"，不会再写盘。
  assert.throws(
    () => inbox.handle(FILE_END, { transferId: 'idle-1' }),
    /unknown transfer/,
  )
  cleanup()
})

test('重传（新 bid，同会话同文件名）接管暂存路径，旧句柄当场释放', (t) => {
  if (!requireLsof(t)) return
  cleanup()
  const inbox = new FileInbox({}, { sweepMs: 60_000 })
  inbox.handle(FILE_BEGIN, { transferId: 'old', sessionId, name: 'retry.bin', bytes: 8 })
  inbox.handle(FILE_CHUNK, {
    transferId: 'old', seq: 0, data: Buffer.from('abcd').toString('base64'),
  })
  assert.equal(openFiles('.retry.bin.part')?.length, 1, '前置：旧上传的 .part 句柄没有打开')

  // 重传换了 bid，但落盘路径相同：一条暂存路径同时只允许一个写者。
  inbox.handle(FILE_BEGIN, { transferId: 'new', sessionId, name: 'retry.bin', bytes: 4 })
  assert.equal(openFiles('.retry.bin.part')?.length, 0, '重传开始后旧上传的 .part 句柄仍然打开')

  const body = Buffer.from('wxyz')
  inbox.handle(FILE_CHUNK, { transferId: 'new', seq: 0, data: body.toString('base64') })
  const done = inbox.handle(FILE_END, { transferId: 'new' })
  assert.ok(readFileSync(done.path).equals(body), '重传后的落盘内容不对')
  assert.equal(openFiles('.retry.bin.part')?.length, 0, '重传完成后 .part 句柄仍然打开')
  assert.throws(
    () => inbox.handle(FILE_CHUNK, { transferId: 'old', seq: 1, data: 'AAAA' }),
    /unknown transfer/,
  )
  cleanup()
})

test('乱序分片回 fsErr 的同时释放这次上传的句柄', async (t) => {
  const { DeviceRouter, FSPUT_BEGIN, FSPUT_CHUNK } = await import('../lib/router.js')
  if (!requireLsof(t)) return
  cleanup()
  const sent = []
  const router = new DeviceRouter({
    dsh: { ensureMux: async () => {}, openStream() {}, cancelStream() {} },
    send: (deviceId, frame) => sent.push(frame),
    logger: {},
  })
  await router.attachDevice('dev_1')
  await router.handleRelayFrame({
    t: FSPUT_BEGIN, deviceId: 'dev_1', bid: 'badseq', sessionId, name: 'badseq.bin', bytes: 8,
  })
  router.handleRelayFrame({
    t: FSPUT_CHUNK, deviceId: 'dev_1', bid: 'badseq', seq: 0, data: 'YWJjZA==',
  })
  assert.equal(openFiles('.badseq.bin.part')?.length, 1, '前置：.part 句柄没有打开')

  // 分片被拒之后这次上传不可能再完成：fsErr 已经发了，句柄也必须一起放掉。
  router.handleRelayFrame({
    t: FSPUT_CHUNK, deviceId: 'dev_1', bid: 'badseq', seq: 9, data: 'AAAA',
  })
  assert.ok(sent.find((frame) => frame.t === 'fsErr'), '乱序分片没有回 fsErr')
  assert.equal(openFiles('.badseq.bin.part')?.length, 0, 'fsErr 之后 .part 句柄仍然打开')
  assert.equal(existsSync(join(directory, '.badseq.bin.part')), false, 'fsErr 之后暂存文件没有删掉')
  cleanup()
})

test('链路断开（teardownAll）释放所有在传上传', async (t) => {
  const { DeviceRouter, FSPUT_BEGIN, FSPUT_CHUNK, FSPUT_END } = await import('../lib/router.js')
  if (!requireLsof(t)) return
  cleanup()
  const sent = []
  const router = new DeviceRouter({
    dsh: { ensureMux: async () => {}, openStream() {}, cancelStream() {} },
    send: (deviceId, frame) => sent.push(frame),
    logger: {},
  })
  await router.attachDevice('dev_1')
  await router.handleRelayFrame({
    t: FSPUT_BEGIN, deviceId: 'dev_1', bid: 'tear', sessionId, name: 'tear.bin', bytes: 8,
  })
  router.handleRelayFrame({
    t: FSPUT_CHUNK, deviceId: 'dev_1', bid: 'tear', seq: 0, data: 'YWJjZA==',
  })
  assert.equal(openFiles('.tear.bin.part')?.length, 1, '前置：.part 句柄没有打开')

  // 中转连接断了：这条链路上所有上传都不可能再完成。
  router.teardownAll()
  assert.equal(openFiles('.tear.bin.part')?.length, 0, '链路断开后 .part 句柄仍然打开')
  assert.equal(existsSync(join(directory, '.tear.bin.part')), false, '链路断开后暂存文件没有删掉')

  router.handleRelayFrame({ t: FSPUT_END, deviceId: 'dev_1', bid: 'tear' })
  const failure = sent.filter((frame) => frame.t === 'fsErr').at(-1)
  assert.match(failure.message, /unknown transfer/)
  cleanup()
})

test('fsPutCancel 释放对应上传，未知 bid 是空操作', async (t) => {
  const { DeviceRouter, FSPUT_BEGIN, FSPUT_CHUNK } = await import('../lib/router.js')
  if (!requireLsof(t)) return
  cleanup()
  const sent = []
  const router = new DeviceRouter({
    dsh: { ensureMux: async () => {}, openStream() {}, cancelStream() {} },
    send: (deviceId, frame) => sent.push(frame),
    logger: {},
  })
  await router.attachDevice('dev_1')
  await router.handleRelayFrame({
    t: FSPUT_BEGIN, deviceId: 'dev_1', bid: 'cancel-1', sessionId, name: 'cancel.bin', bytes: 8,
  })
  router.handleRelayFrame({
    t: FSPUT_CHUNK, deviceId: 'dev_1', bid: 'cancel-1', seq: 0, data: 'YWJjZA==',
  })
  assert.equal(openFiles('.cancel.bin.part')?.length, 1, '前置：.part 句柄没有打开')

  // 取消帧按 bid 寻址，**可以不带 deviceId**（与 fsGetCancel 同理）。
  router.handleRelayFrame({ t: 'fsPutCancel', bid: 'cancel-1' })
  assert.equal(openFiles('.cancel.bin.part')?.length, 0, '取消后 .part 句柄仍然打开')
  assert.equal(existsSync(join(directory, '.cancel.bin.part')), false, '取消后暂存文件没有删掉')

  // 重复取消、未知 bid 都不许抛，也不许发帧。
  const before = sent.length
  router.handleRelayFrame({ t: 'fsPutCancel', bid: 'cancel-1' })
  router.handleRelayFrame({ t: 'fsPutCancel', bid: 'no-such-bid' })
  router.handleRelayFrame({ t: 'fsPutCancel' })
  assert.equal(sent.length, before, '取消帧不应产生任何回帧')
  cleanup()
})

test('已完成的文件不会被清理路径误删', () => {
  cleanup()
  const inbox = new FileInbox({})
  const body = Buffer.from('done bytes')
  inbox.handle(FILE_BEGIN, { transferId: 'done-1', sessionId, name: 'done.bin', bytes: body.length })
  inbox.handle(FILE_CHUNK, { transferId: 'done-1', seq: 0, data: body.toString('base64') })
  const done = inbox.handle(FILE_END, { transferId: 'done-1' })
  inbox.clear()
  assert.ok(existsSync(done.path), '链路清理把已完成的文件删掉了')
  assert.ok(readFileSync(done.path).equals(body), '已完成的文件内容被改动')
  cleanup()
})
