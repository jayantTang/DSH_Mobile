import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, existsSync, rmSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { FileInbox, FILE_BEGIN, FILE_CHUNK, FILE_END, isFileMethod } from '../lib/files.js'

const sessionId = `test-${process.pid}`
const directory = join(homedir(), '.dsh', 'inbox', sessionId)

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
