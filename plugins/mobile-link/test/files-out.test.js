/**
 * `fsGet*` 桥接帧：手机从电脑取文件（R-1 C-20）。
 *
 * 与 `files.test.js` 里 `fsPut*` 那几条对称。这一族由 relay 的
 * `GET /files/down` 驱动，连接器驱动 host 的 `workspaceFiles/readBytes`
 * 一片一片回。回复**只带 bid、不带 deviceId**——relay 靠 bid 把每个分片
 * 对回那条还在写的 HTTP 响应。
 *
 * 桩 host（`FakeDsh.responses`）按 `readBytes` 的调用分片作答，没有 DSH 进程、
 * 没有文件、没有 socket。
 */

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'

import { MobileLinkAgent } from '../lib/link.js'
import { FileFetcher, DEFAULT_WINDOW_BYTES, NON_RETRYABLE_CODES, isPermanent } from '../lib/files-out.js'

/**
 * Only the byte reads a Host saw.
 *
 * P-13b added one `workspaceFiles/stat` per fetch (it is what lets the relay
 * announce the total and the version), so "every call the Host saw" is no longer
 * the same set as "every window the Host read". Assertions about offsets,
 * windows and clamps mean the latter, and silently including the stat would make
 * them describe calls that have no `range` at all.
 */
function reads(dsh) {
  return dsh.calls.filter((call) => call.method === 'workspaceFiles/readBytes')
}

class FakeSocket {
  constructor() {
    this.sent = []
    this.closed = false
  }

  send(text) {
    this.sent.push(JSON.parse(text))
  }

  close() {
    this.closed = true
  }

  frames(type) {
    return this.sent.filter((frame) => frame.t === type)
  }

  last(type) {
    const frames = this.frames(type)
    return frames[frames.length - 1]
  }
}

/**
 * A Host that serves one in-memory body through `workspaceFiles/readBytes`.
 *
 * Reproduces the two things the real Host does that the connector must cope
 * with: it applies its own `length` clamp, and it reports `eof` on the window
 * that reaches the end.
 */
class FakeDsh extends EventEmitter {
  constructor(body, { clamp = DEFAULT_WINDOW_BYTES, failure = null, stallAt = null,
                       stat = null } = {}) {
    super()
    this.body = body
    this.clamp = clamp
    /**
     * What `workspaceFiles/stat` answers (P-13b). `null` = the default, a
     * `{version, bytes}` derived from the body — which is what the real Host
     * does. Pass `{ fail: true }` for a Host that refuses to stat, and
     * `{ value: {} }` for one that answers with neither field.
     */
    this.stat = stat
    /** Thrown (as `{ok:false, error}`) for every call, when set. */
    this.failure = failure
    /** Answer an empty, non-`eof` window at this offset (a Host that lost the file). */
    this.stallAt = stallAt
    this.calls = []
    this.muxReady = true
    this.cookie = 'dsh-auth-test=v1'
    this.endpoint = { base: 'http://127.0.0.1:54499', port: 54499, source: 'test' }
  }

  async ensureMux() {
    return { closed: false }
  }

  openStream() {}

  cancelStream() {}

  async rpc(method, args) {
    this.calls.push({ method, args })
    if (this.failure) return { ok: false, error: this.failure }
    if (method === 'workspaceFiles/stat') {
      if (this.stat?.fail) return { ok: false, error: { code: 'workspace-file/not-found', message: 'gone' } }
      if (this.stat?.value) return { ok: true, value: this.stat.value }
      return { ok: true, value: { absolutePath: '/w/f.bin', version: 'v-test', bytes: this.body.length } }
    }
    if (method !== 'workspaceFiles/readBytes') return { ok: true, value: {} }
    const range = args?.range ?? {}
    const offset = Number(range.offset ?? 0)
    const length = Math.min(Number(range.length ?? this.clamp), this.clamp)
    if (this.stallAt !== null && offset === this.stallAt) {
      return { ok: true, value: { data: '', eof: false } }
    }
    const piece = this.body.subarray(offset, offset + length)
    return {
      ok: true,
      value: {
        data: piece.toString('base64'),
        eof: offset + piece.length >= this.body.length,
      },
    }
  }
}

function makeAgent(body, options) {
  const dsh = new FakeDsh(body, options)
  const logger = { debug() {}, info() {}, warn() {}, error() {} }
  const agent = new MobileLinkAgent({
    dshClient: dsh, logger, relayUrl: 'ws://relay.test', agentId: 'agt_1',
  })
  agent.identity = { agentId: 'agt_1', agentSecret: 'as_1', relayUrl: 'ws://relay.test' }
  const socket = new FakeSocket()
  agent.socket = socket
  return { agent, dsh, socket }
}

const attach = (deviceId = 'dev_1') => ({
  t: 'deviceAttach', deviceId, device: { name: 'iPhone', model: 'iPhone17,1' },
})

/** Waits until `predicate()` holds, or fails the test. */
async function until(predicate, message, timeoutMs = 4000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (predicate()) return
    await new Promise((resolve) => setTimeout(resolve, 5))
  }
  assert.fail(message)
}

/** The bytes a run produced, in chunk order. */
function received(socket, bid) {
  return Buffer.concat(
    socket.frames('fsGetChunk').filter((frame) => frame.bid === bid)
      .map((frame) => Buffer.from(frame.data, 'base64'))
  )
}

// ── the happy path ──────────────────────────────────────────────────────────

test('a download arrives byte-for-byte, in window order, under one bid', async () => {
  // 故意不是文本：二进制才看得出编码错误。
  const body = Buffer.from(Array.from({ length: 500_000 }, (_, i) => (i * 13) % 256))
  const { agent, dsh, socket } = makeAgent(body, { clamp: 64 * 1024 })
  await agent.handleRelayFrame(attach('dev_1'))

  await agent.handleRelayFrame({
    t: 'fsGetBegin', deviceId: 'dev_1', bid: 'g1', scopeId: 's1', path: 'report.pdf',
  })
  await until(() => socket.frames('fsGetEnd').length === 1, '没有收到 fsGetEnd')

  assert.ok(received(socket, 'g1').equals(body), '字节在途中变了')
  // 依次要了正确的 offset，且每次都没超过 host 的 clamp。
  const offsets = reads(dsh).map((call) => call.args.range.offset)
  assert.deepEqual(offsets, [0, 64 * 1024, 128 * 1024, 192 * 1024, 256 * 1024, 320 * 1024, 384 * 1024, 448 * 1024])
  assert.ok(reads(dsh).every((call) => call.args.workspaceFileScopeId === 's1'))
  assert.ok(reads(dsh).every((call) => call.args.path === 'report.pdf'))
})

test('the ack goes out before any chunk, and every reply carries only the bid', async () => {
  // 这是线上真正生效的那一层：`send(undefined, frame)` 必须原样发出去，
  // 不能顺手补一个 deviceId。
  const body = Buffer.from('download bytes')
  const { agent, socket } = makeAgent(body)
  await agent.handleRelayFrame(attach('dev_1'))

  await agent.handleRelayFrame({
    t: 'fsGetBegin', deviceId: 'dev_1', bid: 'g2', scopeId: 's1', path: 'a.txt',
  })
  await until(() => socket.frames('fsGetEnd').length === 1, '没有收到 fsGetEnd')

  const order = socket.sent.map((frame) => frame.t)
  assert.equal(order[0], 'fsGetAck', `第一帧不是 ack：${order.join(',')}`)
  assert.equal(socket.last('fsGetAck').bid, 'g2')
  for (const frame of socket.sent) {
    assert.equal('deviceId' in frame, false, `桥接回复带了 deviceId：${JSON.stringify(frame)}`)
  }
  assert.equal(socket.frames('fsGetEnd')[0].bid, 'g2')
})

test('the last window is marked eof, and no extra read is made after it', async () => {
  const body = Buffer.from('x'.repeat(10))
  const { agent, dsh, socket } = makeAgent(body, { clamp: 4 })
  await agent.handleRelayFrame(attach('dev_1'))
  await agent.handleRelayFrame({
    t: 'fsGetBegin', deviceId: 'dev_1', bid: 'g3', scopeId: 's1', path: 'a.txt',
  })
  await until(() => socket.frames('fsGetEnd').length === 1, '没有收到 fsGetEnd')

  const chunks = socket.frames('fsGetChunk')
  assert.deepEqual(chunks.map((frame) => frame.eof), [false, false, true])
  assert.equal(reads(dsh).length, 3, 'eof 之后又多读了一次')
})

test('an empty file is a complete download, not a stall', async () => {
  const { agent, socket } = makeAgent(Buffer.alloc(0))
  await agent.handleRelayFrame(attach('dev_1'))
  await agent.handleRelayFrame({
    t: 'fsGetBegin', deviceId: 'dev_1', bid: 'g4', scopeId: 's1', path: 'empty.txt',
  })
  await until(() => socket.frames('fsGetEnd').length === 1, '空文件没有正常结束')
  assert.equal(socket.frames('fsErr').length, 0)
  assert.equal(received(socket, 'g4').length, 0)
})

// ── Range: offset ───────────────────────────────────────────────────────────

test('a non-zero offset makes the very first read start there', async () => {
  // 后台 `URLSessionDownloadTask` 不享受 `.part` 续传，所以这是续传能不能成立的
  // 全部依据：offset 传错就等于"断一次从头再来"。
  const body = Buffer.from(Array.from({ length: 3000 }, (_, i) => i % 256))
  const { agent, dsh, socket } = makeAgent(body, { clamp: 1000 })
  await agent.handleRelayFrame(attach('dev_1'))
  await agent.handleRelayFrame({
    t: 'fsGetBegin', deviceId: 'dev_1', bid: 'g5', scopeId: 's1', path: 'big.bin', offset: 1500,
  })
  await until(() => socket.frames('fsGetEnd').length === 1, '没有收到 fsGetEnd')

  assert.equal(reads(dsh)[0].args.range.offset, 1500, '第一片没有从 offset 开始')
  assert.deepEqual(received(socket, 'g5'), body.subarray(1500))
})

test('an offset past the end of the file completes with nothing', async () => {
  const { agent, socket } = makeAgent(Buffer.alloc(100))
  await agent.handleRelayFrame(attach('dev_1'))
  await agent.handleRelayFrame({
    t: 'fsGetBegin', deviceId: 'dev_1', bid: 'g6', scopeId: 's1', path: 'a.bin', offset: 5000,
  })
  await until(() => socket.frames('fsGetEnd').length === 1, 'offset 越界没有正常结束')
  assert.equal(received(socket, 'g6').length, 0)
  assert.equal(socket.frames('fsErr').length, 0)
})

// ── failures ────────────────────────────────────────────────────────────────

test('the Host error code travels verbatim, so the app can tell "do not retry"', async () => {
  for (const code of NON_RETRYABLE_CODES) {
    const { agent, socket } = makeAgent(Buffer.alloc(0), {
      failure: { code, message: `${code} detail` },
    })
    await agent.handleRelayFrame(attach('dev_1'))
    await agent.handleRelayFrame({
      t: 'fsGetBegin', deviceId: 'dev_1', bid: 'g7', scopeId: 's1', path: 'gone.bin',
    })
    await until(() => socket.frames('fsErr').length === 1, `${code} 没有回 fsErr`)
    const failure = socket.last('fsErr')
    assert.equal(failure.bid, 'g7')
    assert.equal(failure.code, code, `错误码被改写了：${failure.code}`)
    assert.match(failure.message, /detail/)
    assert.equal('deviceId' in failure, false)
    assert.equal(socket.frames('fsGetEnd').length, 0, '失败之后还回了 fsGetEnd')
  }
})

test('a retryable Host failure keeps its code too, and is not silently swallowed', async () => {
  const { agent, socket } = makeAgent(Buffer.alloc(0), {
    failure: { code: 'host/crashed', message: 'boom' },
  })
  await agent.handleRelayFrame(attach('dev_1'))
  await agent.handleRelayFrame({
    t: 'fsGetBegin', deviceId: 'dev_1', bid: 'g8', scopeId: 's1', path: 'a.bin',
  })
  await until(() => socket.frames('fsErr').length === 1, '没有回 fsErr')
  assert.equal(socket.last('fsErr').code, 'host/crashed')
})

test('a Host failure with no code at all still answers with something routable', async () => {
  const { agent, socket } = makeAgent(Buffer.alloc(0), { failure: {} })
  await agent.handleRelayFrame(attach('dev_1'))
  await agent.handleRelayFrame({
    t: 'fsGetBegin', deviceId: 'dev_1', bid: 'g9', scopeId: 's1', path: 'a.bin',
  })
  await until(() => socket.frames('fsErr').length === 1, '没有回 fsErr')
  assert.equal(socket.last('fsErr').code, 'file/rejected')
})

test('an empty window that is not eof is reported instead of spinning forever', async () => {
  // host 在这个 offset 上没东西了又不是结尾 —— 再问一次也是同样的答案，
  // 不拦就会变成一个每秒几百次的死循环。
  const { agent, dsh, socket } = makeAgent(Buffer.from('abcdefghij'), { clamp: 4, stallAt: 4 })
  await agent.handleRelayFrame(attach('dev_1'))
  await agent.handleRelayFrame({
    t: 'fsGetBegin', deviceId: 'dev_1', bid: 'g10', scopeId: 's1', path: 'a.bin',
  })
  await until(() => socket.frames('fsErr').length === 1, '空窗口没有报错')
  assert.equal(socket.last('fsErr').code, 'workspace-file/stalled')
  // 只读了一次那个 offset：不重试、不打转。
  assert.equal(reads(dsh).filter((call) => call.args.range.offset === 4).length, 1)
})

test('a missing bid or a missing path is refused without touching the Host', async () => {
  const { agent, dsh, socket } = makeAgent(Buffer.from('x'))
  await agent.handleRelayFrame(attach('dev_1'))

  await agent.handleRelayFrame({ t: 'fsGetBegin', deviceId: 'dev_1', scopeId: 's1', path: 'a.bin' })
  // 没有 bid：连 ack 都不该有。
  assert.equal(socket.sent.length, 0, '没有 bid 还是回了帧')

  await agent.handleRelayFrame({ t: 'fsGetBegin', deviceId: 'dev_1', bid: 'g11', scopeId: 's1' })
  await until(() => socket.frames('fsErr').length === 1, '缺 path 没有回 fsErr')
  assert.equal(socket.last('fsErr').bid, 'g11')
  assert.equal(dsh.calls.length, 0, '参数不全还是打了 host')
})

// ── window adaptation ───────────────────────────────────────────────────────

test('a too-large refusal halves the window instead of failing the download', async () => {
  // host 的上限是部署值，这一侧读不到，只能试出来（照 App 侧 downloader 的做法）。
  const body = Buffer.from(Array.from({ length: 4096 }, (_, i) => i % 256))
  const dsh = new FakeDsh(body, { clamp: 2048 })
  // 让第一次调用（请求 2 MiB）报 too-large，之后按 clamp 正常作答。
  const inner = dsh.rpc.bind(dsh)
  let refused = false
  dsh.rpc = async (method, args) => {
    if (!refused && Number(args?.range?.length) > dsh.clamp) {
      refused = true
      dsh.calls.push({ method, args })
      return { ok: false, error: { code: 'workspace-file/too-large', message: 'window too big' } }
    }
    return inner(method, args)
  }

  const logger = { debug() {}, info() {}, warn() {}, error() {} }
  const agent = new MobileLinkAgent({
    dshClient: dsh, logger, relayUrl: 'ws://relay.test', agentId: 'agt_1',
  })
  agent.identity = { agentId: 'agt_1', agentSecret: 'as_1', relayUrl: 'ws://relay.test' }
  const socket = new FakeSocket()
  agent.socket = socket

  await agent.handleRelayFrame(attach('dev_1'))
  await agent.handleRelayFrame({
    t: 'fsGetBegin', deviceId: 'dev_1', bid: 'g12', scopeId: 's1', path: 'a.bin',
  })
  await until(() => socket.frames('fsGetEnd').length === 1, '缩窗口之后没有传完')

  assert.equal(socket.frames('fsErr').length, 0, 'too-large 被当成了硬失败')
  assert.ok(received(socket, 'g12').equals(body), '缩窗口之后字节不对')
  assert.equal(reads(dsh)[1].args.range.length, DEFAULT_WINDOW_BYTES / 2)
})

test('the window never shrinks below the floor, and gives up rather than looping', async () => {
  // host 一直说 too-large：缩到底之后必须报错，不能无限缩下去。
  const dsh = new FakeDsh(Buffer.from('x'), {})
  dsh.rpc = async (method, args) => {
    dsh.calls.push({ method, args })
    return { ok: false, error: { code: 'workspace-file/too-large', message: 'nope' } }
  }
  const logger = { debug() {}, info() {}, warn() {}, error() {} }
  const agent = new MobileLinkAgent({
    dshClient: dsh, logger, relayUrl: 'ws://relay.test', agentId: 'agt_1',
  })
  agent.identity = { agentId: 'agt_1', agentSecret: 'as_1', relayUrl: 'ws://relay.test' }
  const socket = new FakeSocket()
  agent.socket = socket

  await agent.handleRelayFrame(attach('dev_1'))
  await agent.handleRelayFrame({
    t: 'fsGetBegin', deviceId: 'dev_1', bid: 'g13', scopeId: 's1', path: 'a.bin',
  })
  await until(() => socket.frames('fsErr').length === 1, '一直 too-large 却没有放弃')
  assert.equal(socket.last('fsErr').code, 'workspace-file/too-large')
  assert.ok(reads(dsh).length < 40, `缩窗口循环了 ${reads(dsh).length} 次`)
})

// ── cancellation ────────────────────────────────────────────────────────────

test('a retried bid cancels the run it replaces, and clear() stops every run', async () => {
  // 关键在"旧的那次还活着的时候开新的"。桩 host 太快，跑完一轮只要几毫秒，
  // 所以这里用一道闸把第一次的**第二片**卡住，再开同 bid 的第二次。
  const body = Buffer.from('y'.repeat(400_000))
  const dsh = new FakeDsh(body, { clamp: 64 * 1024 })
  const inner = dsh.rpc.bind(dsh)
  let byteReads = 0
  let release
  const gate = new Promise((resolve) => { release = resolve })
  dsh.rpc = async (method, args) => {
    // P-13b 起每次 fetch 先有一次 `stat`，所以「第几个 rpc」不再等于「第几片」。
    // 这里要卡住的是**第一路的第一片**，就按方法数数。
    if (method === 'workspaceFiles/readBytes') {
      byteReads += 1
      if (byteReads === 2) await gate      // 第一次停在这里
    }
    return inner(method, args)
  }

  const logger = { debug() {}, info() {}, warn() {}, error() {} }
  const agent = new MobileLinkAgent({
    dshClient: dsh, logger, relayUrl: 'ws://relay.test', agentId: 'agt_1',
  })
  agent.identity = { agentId: 'agt_1', agentSecret: 'as_1', relayUrl: 'ws://relay.test' }
  const socket = new FakeSocket()
  agent.socket = socket

  await agent.handleRelayFrame(attach('dev_1'))
  await agent.handleRelayFrame({
    t: 'fsGetBegin', deviceId: 'dev_1', bid: 'g14', scopeId: 's1', path: 'a.bin',
  })
  await until(() => socket.frames('fsGetChunk').length >= 1, '第一路没有开始发片')
  assert.equal(socket.frames('fsGetEnd').length, 0, '第一次不该已经结束')

  // 同 bid 再开一次：旧的那次必须停下——它的下一片一旦吐出来，就会插进
  // 第二次的流里，同一个 bid 的响应体就成了两段拼接的垃圾。
  const beforeRestart = socket.frames('fsGetChunk').length
  await agent.handleRelayFrame({
    t: 'fsGetBegin', deviceId: 'dev_1', bid: 'g14', scopeId: 's1', path: 'a.bin',
  })
  release()                              // 放行第一次那片"迟到的"回复
  await until(() => socket.frames('fsGetEnd').length === 1, '重开的 bid 没有传完')
  await new Promise((resolve) => setTimeout(resolve, 60))

  assert.equal(socket.frames('fsGetEnd').length, 1, '被顶掉的那次也回了 fsGetEnd')
  const second = socket.frames('fsGetChunk').slice(beforeRestart)
  const restarted = Buffer.concat(second.map((frame) => Buffer.from(frame.data, 'base64')))
  assert.ok(restarted.equals(body), `重开的那一路不完整：${restarted.length} != ${body.length}`)

  const sent = socket.frames('fsGetChunk').length
  agent.router.fileFetcher.clear()
  await new Promise((resolve) => setTimeout(resolve, 40))
  assert.equal(socket.frames('fsGetChunk').length, sent, 'clear 之后还在发')
})

// ── policy helper ───────────────────────────────────────────────────────────

test('isPermanent only claims the codes the app itself refuses to retry', () => {
  assert.ok(isPermanent({ code: 'workspace-file/not-found' }))
  assert.ok(!isPermanent({ code: 'host/unavailable' }))
  assert.ok(!isPermanent({ code: undefined }))
  assert.ok(!isPermanent(null))
  // 认不出来的一律当作可重试：多试一次只花一秒，误判成永久则是取不到文件。
  assert.ok(!isPermanent({ code: 'something/new' }))
})

test('FileFetcher.send is injected, so a frame with no relay socket is dropped quietly', () => {
  const fetcher = new FileFetcher({ send: () => false, rpc: async () => ({ ok: true, value: {} }) })
  assert.equal(fetcher.start({ bid: '', scopeId: 's', path: 'p' }), false)
  assert.equal(fetcher.start({ bid: 'b', scopeId: '', path: 'p' }), false)
})

// ── the stat that makes a download resumable (P-13b) ────────────────────────

test('the ack reports the file size and version the relay needs to answer resumably', async () => {
  // 中转要拿到总长才能回 `Content-Length` 与完整 `Content-Range`——那是系统
  // 产出 resume data 的硬前提；version 则成为 `ETag`，供续传时的 `If-Range`
  // 判断"还是同一个文件吗"。都没有的话，中断就只能从头下。
  const body = Buffer.from('resumable bytes')
  const { agent, socket } = makeAgent(body)
  await agent.handleRelayFrame(attach('dev_1'))

  await agent.handleRelayFrame({
    t: 'fsGetBegin', deviceId: 'dev_1', bid: 'g20', scopeId: 's1', path: 'a.bin',
  })
  await until(() => socket.frames('fsGetEnd').length === 1, '没有收到 fsGetEnd')

  const ack = socket.frames('fsGetAck')[0]
  assert.equal(ack.size, body.length, 'ack 没带总长')
  assert.equal(ack.version, 'v-test', 'ack 没带版本')
  // ack 仍必须只带 bid（relay 靠 bid 对回响应，多一个 deviceId 会破坏约定）。
  assert.deepEqual(Object.keys(ack).sort(), ['bid', 'size', 't', 'version'])
})

test('a Host that cannot stat still gets its download, just not a resumable one', async () => {
  // 向后兼容是加字段的前提：stat 失败（老 Host、文件在请求与 stat 之间被删）
  // 必须退化成改造前的行为，而不是把下载也一起弄失败。
  const body = Buffer.from('no stat for you')
  const { agent, socket } = makeAgent(body, { stat: { fail: true } })
  await agent.handleRelayFrame(attach('dev_1'))

  await agent.handleRelayFrame({
    t: 'fsGetBegin', deviceId: 'dev_1', bid: 'g21', scopeId: 's1', path: 'a.bin',
  })
  await until(() => socket.frames('fsGetEnd').length === 1, 'stat 失败把下载也弄挂了')

  const ack = socket.frames('fsGetAck')[0]
  assert.equal(ack.size, undefined, 'stat 失败却报了总长')
  assert.equal(ack.version, undefined)
  assert.ok(received(socket, 'g21').equals(body), '字节没传完')
})

test('a stat that answers with neither field is not treated as a size of zero', async () => {
  // `{value:{}}` 是"Host 答了但没说"——它必须和"没答"一样退化成不带字段，
  // 而不是变成 size=0（那会让 relay 回一个 `Content-Length: 0` 的空文件）。
  const body = Buffer.from('empty stat answer')
  const { agent, socket } = makeAgent(body, { stat: { value: {} } })
  await agent.handleRelayFrame(attach('dev_1'))

  await agent.handleRelayFrame({
    t: 'fsGetBegin', deviceId: 'dev_1', bid: 'g22', scopeId: 's1', path: 'a.bin',
  })
  await until(() => socket.frames('fsGetEnd').length === 1, '没有收到 fsGetEnd')

  const ack = socket.frames('fsGetAck')[0]
  assert.equal(ack.size, undefined)
  assert.equal(ack.version, undefined)
  assert.ok(received(socket, 'g22').equals(body))
})

// ── relay-driven cancellation (P-13b′) ──────────────────────────────────────

test('fsGetCancel stops a run whose reader has gone', async () => {
  // 读是连接器这一侧驱动的，所以"读的人走了"这里看不见：手机挂断或日额度截断
  // 响应时，relay 立刻知道、连接器不知道。没有这一帧，它会把整个文件读完，
  // 每一片都在 relay 那边被丢掉。
  const body = Buffer.from('c'.repeat(400_000))
  const dsh = new FakeDsh(body, { clamp: 64 * 1024 })
  const inner = dsh.rpc.bind(dsh)
  let byteReads = 0
  let release
  const gate = new Promise((resolve) => { release = resolve })
  dsh.rpc = async (method, args) => {
    if (method === 'workspaceFiles/readBytes') {
      byteReads += 1
      if (byteReads === 2) await gate
    }
    return inner(method, args)
  }

  const logger = { debug() {}, info() {}, warn() {}, error() {} }
  const agent = new MobileLinkAgent({
    dshClient: dsh, logger, relayUrl: 'ws://relay.test', agentId: 'agt_1',
  })
  agent.identity = { agentId: 'agt_1', agentSecret: 'as_1', relayUrl: 'ws://relay.test' }
  const socket = new FakeSocket()
  agent.socket = socket

  await agent.handleRelayFrame(attach('dev_1'))
  await agent.handleRelayFrame({
    t: 'fsGetBegin', deviceId: 'dev_1', bid: 'g30', scopeId: 's1', path: 'a.bin',
  })
  await until(() => socket.frames('fsGetChunk').length >= 1, '这一路没有开始发片')
  const beforeCancel = socket.frames('fsGetChunk').length

  await agent.handleRelayFrame({ t: 'fsGetCancel', bid: 'g30' })
  // 放行那片取消到达时**已经在路上**的回复。它必须被丢掉：读了但不再发，
  // 这正是取消要买的那个效果。被闸门卡住的这一次读取也顺带说明"停止发生
  // 在下一次检查处"——`#drive` 每片返回后看标志，所以闸门放开之前它不会停。
  release()
  await new Promise((resolve) => setTimeout(resolve, 80))

  assert.equal(socket.frames('fsGetEnd').length, 0, '被叫停的 run 不该报完成')
  assert.equal(socket.frames('fsErr').length, 0, '取消不是错误，不该回 fsErr')
  // 关键判据在**过网字节**：取消之后不许再发出任何一片。relay 那边丢掉的是
  // 已经发出去的；这里保证的是它不再生产新的。
  assert.equal(socket.frames('fsGetChunk').length, beforeCancel,
    '被叫停之后还在发片')
  // 闸门放开的那一次读取已经完成了，但它的字节必须被丢掉：读了不发正是取消
  // 要买的效果，也说明停止发生在 `#drive` 的下一处检查，而不是打断在读中间。
  assert.equal(byteReads, 2, `被叫停后还在继续读（${byteReads} 次）`)
  assert.ok(received(socket, 'g30').length < body.length, '整个文件还是发完了')
})

test('a cancel for a run that does not exist is a no-op, and a real one still runs', async () => {
  // relay 不必跟踪哪些 run 还活着：它每个死桥接都发一次取消，未知 bid 必须
  // 静默忽略（和 deviceDetach 同一约定），且**不许**误伤别的 run。
  const body = Buffer.from('d'.repeat(200_000))
  const { agent, socket } = makeAgent(body, { clamp: 64 * 1024 })
  await agent.handleRelayFrame(attach('dev_1'))

  await agent.handleRelayFrame({ t: 'fsGetCancel', bid: 'nobody' })
  await agent.handleRelayFrame({ t: 'fsGetBegin', deviceId: 'dev_1', bid: 'g31', scopeId: 's1', path: 'a.bin' })
  await until(() => socket.frames('fsGetEnd').length === 1, '未知 bid 的取消误伤了这次下载')

  assert.ok(received(socket, 'g31').equals(body), '字节不完整')
  assert.equal(socket.frames('fsErr').length, 0)
})

test('a cancel without a bid is ignored rather than cancelling everything', async () => {
  // `String(undefined)` 会变成 "undefined"——真去取消它倒是无害，但"没有 bid 的
  // 取消"等于一条坏帧，必须什么都不做，绝不能退化成 clear()。
  const body = Buffer.from('e'.repeat(200_000))
  const { agent, socket } = makeAgent(body, { clamp: 64 * 1024 })
  await agent.handleRelayFrame(attach('dev_1'))

  await agent.handleRelayFrame({
    t: 'fsGetBegin', deviceId: 'dev_1', bid: 'g32', scopeId: 's1', path: 'a.bin',
  })
  await agent.handleRelayFrame({ t: 'fsGetCancel' })
  await until(() => socket.frames('fsGetEnd').length === 1, '没有 bid 的取消把这次下载停了')

  assert.ok(received(socket, 'g32').equals(body))
})

test('`replaces` stops the run a fresh identifier supersedes', async () => {
  // relay 每个 HTTP 请求铸新 bid，所以中断那次留下的 run 用**本次**的 bid 是
  // 够不着的——而它还在：系统 resume data 冻结的是最初那条请求，续传时回来的
  // 正是旧 id。没有 `replaces`，旧 run 会一直读到新 fsGetBegin 抵达为止。
  const body = Buffer.from('r'.repeat(400_000))
  const dsh = new FakeDsh(body, { clamp: 64 * 1024 })
  const inner = dsh.rpc.bind(dsh)
  let byteReads = 0
  let release
  const gate = new Promise((resolve) => { release = resolve })
  dsh.rpc = async (method, args) => {
    if (method === 'workspaceFiles/readBytes') {
      byteReads += 1
      if (byteReads === 2) await gate
    }
    return inner(method, args)
  }

  const logger = { debug() {}, info() {}, warn() {}, error() {} }
  const agent = new MobileLinkAgent({
    dshClient: dsh, logger, relayUrl: 'ws://relay.test', agentId: 'agt_1',
  })
  agent.identity = { agentId: 'agt_1', agentSecret: 'as_1', relayUrl: 'ws://relay.test' }
  const socket = new FakeSocket()
  agent.socket = socket

  await agent.handleRelayFrame(attach('dev_1'))
  // 第一次尝试：App 的 bid（会被冻结进 resume data）。
  await agent.handleRelayFrame({
    t: 'fsGetBegin', deviceId: 'dev_1', bid: 'frozen', scopeId: 's1', path: 'a.bin',
  })
  await until(() => socket.frames('fsGetChunk').length >= 1, '旧 run 没有开始发片')
  const staleChunks = socket.frames('fsGetChunk').length

  // 续传：中转发来的是**新** bid，外加"我取代的是 frozen"。
  await agent.handleRelayFrame({
    t: 'fsGetBegin', deviceId: 'dev_1', bid: 'fresh', scopeId: 's1', path: 'a.bin',
    replaces: 'frozen',
  })
  release()
  await until(() => socket.frames('fsGetEnd').length === 1, '新 run 没有传完')
  await new Promise((resolve) => setTimeout(resolve, 60))

  const frozenChunks = socket.frames('fsGetChunk').filter((f) => f.bid === 'frozen')
  assert.equal(frozenChunks.length, staleChunks,
    '被取代的 run 还在发片——它的窗口正是 relay 收不回来的那些')
  assert.equal(socket.frames('fsGetEnd').filter((f) => f.bid === 'frozen').length, 0,
    '被取代的 run 不该报完成')
  assert.ok(received(socket, 'fresh').equals(body), '新 run 的字节不完整')
})

test('a `replaces` naming an unknown run is ignored', async () => {
  // 老 relay 不发这个字段；发了但名字不认识也必须什么都不做，绝不能顺手停掉
  // 正在跑的这一路。
  const body = Buffer.from('s'.repeat(200_000))
  const { agent, socket } = makeAgent(body, { clamp: 64 * 1024 })
  await agent.handleRelayFrame(attach('dev_1'))

  await agent.handleRelayFrame({
    t: 'fsGetBegin', deviceId: 'dev_1', bid: 'g40', scopeId: 's1', path: 'a.bin',
    replaces: 'never-existed',
  })
  await until(() => socket.frames('fsGetEnd').length === 1, '未知 replaces 误伤了这次下载')

  assert.ok(received(socket, 'g40').equals(body))
  assert.equal(socket.frames('fsErr').length, 0)
})
