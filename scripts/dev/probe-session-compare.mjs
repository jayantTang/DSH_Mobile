#!/usr/bin/env node
/**
 * 新旧会话列表方法的性能对比（spec 021 / T010）。
 *
 * 三条路径，同一份宿主数据、同一条真实链路（经公网中转、走设备通道）：
 *   ① `session/list`                     现状
 *   ② `_link/sessionDigest`              裁剪，不压缩
 *   ③ `_link/sessionDigest` + gzip       裁剪 + 压缩
 *
 * 每条记录：响应 JSON 字节、墙钟耗时、以及中转 `/stats` 的 `egressBytes` 增量（路上真跑了多少）。
 *
 * 为什么要经真实中转：本机直连只能测到"宿主+连接器"这一段，而瓶颈在手机那一跳。
 * 用 `test/tools/relaypair.mjs` 的配对/撤销，不另写一套设备生命周期；设备名固定 `DSH-` 前缀，
 * 跑完在 `finally` 里撤销（AGENTS.md 的硬要求）。
 *
 * 用法：
 *   node scripts/dev/probe-session-compare.mjs [--rounds 3] [--json]
 */

import { parseArgs as parseNodeArgs } from 'node:util'
import { inflateRawSync } from 'node:zlib'

import { connect } from '../../plugins/mobile-link/lib/ws.js'
import { pairDevice, revokeDevice, route } from '../../test/tools/relaypair.mjs'

const DEVICE_NAME = 'DSH-DigestProbe'
const METHODS = [
  { key: 'legacy', label: 'session/list（现状）', method: 'session/list', args: { _request: {} } },
  { key: 'digest', label: '_link/sessionDigest（裁剪）', method: '_link/sessionDigest', args: { _request: {} } },
  { key: 'deflate', label: '_link/sessionDigest + deflate-raw', method: '_link/sessionDigest', args: { _request: {}, encoding: 'deflate-raw' } },
]

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

/**
 * 一条简单的请求/响应客户端：发 `req`，等同 id 的 `res`。
 *
 * **必须自己拼帧**：中转把大于 512 K 字符的帧写成**多条 WebSocket 消息**（不是 continuation 帧），
 * 规则是"累积到能解析为止"（iOS 侧对应 `DSHKit/FrameAssembler.swift`）。不拼的话，
 * 第一条 664 KB 与第二条 62.8 KB 都会被当成"非法 JSON"丢掉，那个调用永远不回来——
 * 本脚本第一版就是这样在 `session/list` 上超时的。
 */
function makeClient(handle) {
  const pending = new Map()
  let buffer = ''
  handle.onMessage((text) => {
    buffer += String(text)
    let frame
    try { frame = JSON.parse(buffer) } catch { return }
    buffer = ''
    if (frame.t === 'res' && pending.has(frame.id)) {
      const { resolve, timer } = pending.get(frame.id)
      pending.delete(frame.id)
      clearTimeout(timer)
      resolve(frame)
    }
  })
  let seq = 0
  return {
    call(method, args, timeoutMs = 120_000) {
      const id = `probe-${++seq}`
      const started = Date.now()
      const body = JSON.stringify({ t: 'req', id, method, args })
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          pending.delete(id)
          reject(new Error(`${method} 超时（${timeoutMs} ms）`))
        }, timeoutMs)
        pending.set(id, { resolve: (frame) => resolve({ frame, ms: Date.now() - started }), timer })
        handle.send(body)
      })
    },
  }
}

/** 从中转地址里取出 ssh 主机名（`wss://host/dsh-link` → `host`）：不依赖环境变量。 */
function sshHost(relayUrl) {
  return new URL(relayUrl.replace(/^ws/, 'http')).hostname
}

/** 中转出口增量（只读 `/stats`；它只监听回环，所以走 ssh）。 */
async function relayEgress(host, agentId) {
  const { execFileSync } = await import('node:child_process')
  const text = execFileSync('ssh', ['-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', `root@${host}`,
    'curl -s localhost:8787/stats'], { encoding: 'utf8', timeout: 30_000 })
  const snapshot = JSON.parse(text)
  const agent = snapshot.snapshot?.agents?.find((item) => item.agentId === agentId)
  return agent?.egressBytes ?? null
}

function parseArgs(argv) {
  const { values } = parseNodeArgs({ args: argv, options: {
    rounds: { type: 'string', default: '1' }, json: { type: 'boolean', default: false },
  }, allowPositionals: true })
  return { rounds: Math.max(1, Number(values.rounds) || 1), json: values.json }
}

async function main() {
  const options = parseArgs(process.argv.slice(2))
  const paired = await pairDevice({ deviceName: DEVICE_NAME, deviceModel: 'probe', appVersion: 'probe' })
  const base = route(paired.relayUrl, '/link/device')
  const host = sshHost(paired.relayUrl)
  const rows = []
  let handle
  try {
    handle = await connect(base, { headers: { authorization: `Bearer ${paired.deviceToken}` } })
    const client = makeClient(handle)
    for (let round = 1; round <= options.rounds; round += 1) {
      for (const entry of METHODS) {
        const before = await relayEgress(host, paired.agentId).catch(() => null)
        const { frame, ms } = await client.call(entry.method, entry.args)
        const after = await relayEgress(host, paired.agentId).catch(() => null)
        if (frame.ok !== true) {
          rows.push({ round, ...entry, ok: false, error: frame.error?.code, ms, bytes: 0 })
          continue
        }
        const payload = JSON.stringify(frame.value)
        const encoding = frame.value?.encoding ?? 'identity'
        // 老方法的帧里直接是宿主的 `{items}`；新方法多一层 `{encoding, value}`。
        const inner = frame.value?.encoding ? frame.value.value : frame.value
        const items = encoding === 'deflate-raw'
          ? JSON.parse(inflateRawSync(Buffer.from(frame.value.value, 'base64')).toString('utf8'))
          : inner
        rows.push({
          round, key: entry.key, label: entry.label, ok: true, encoding, ms,
          bytes: Buffer.byteLength(payload, 'utf8'),
          sessions: items?.items?.length ?? null,
          egressDelta: before === null || after === null ? null : after - before,
        })
        await sleep(200)
      }
    }
  } finally {
    handle?.close?.()
    await revokeDevice(paired).catch((error) => process.stderr.write(`撤销设备失败：${error.message}\n`))
  }

  if (options.json) {
    process.stdout.write(`${JSON.stringify(rows, null, 2)}\n`)
    return
  }
  const byKey = new Map()
  for (const row of rows) {
    if (!byKey.has(row.key)) byKey.set(row.key, [])
    byKey.get(row.key).push(row)
  }
  const baseline = byKey.get('legacy')?.[0]?.bytes || 0
  process.stdout.write(`设备 ${paired.deviceId}（${DEVICE_NAME}）经真实中转，轮次 ${options.rounds}\n\n`)
  process.stdout.write(`${'路径'.padEnd(30)}${'响应字节'.padStart(12)}${'相对现状'.padStart(10)}${'耗时'.padStart(10)}${'中转出口增量'.padStart(14)}\n`)
  for (const entry of METHODS) {
    const group = byKey.get(entry.key) ?? []
    const ok = group.filter((row) => row.ok)
    if (ok.length === 0) {
      process.stdout.write(`${entry.label.padEnd(30)}${'失败'.padStart(12)}  ${group[0]?.error ?? ''}\n`)
      continue
    }
    const bytes = Math.round(ok.reduce((sum, row) => sum + row.bytes, 0) / ok.length)
    const ms = Math.round(ok.reduce((sum, row) => sum + row.ms, 0) / ok.length)
    const egress = ok.filter((row) => row.egressDelta !== null)
    const delta = egress.length ? Math.round(egress.reduce((sum, row) => sum + row.egressDelta, 0) / egress.length) : null
    process.stdout.write(`${entry.label.padEnd(30)}${String(bytes).padStart(12)}`
      + `${(baseline ? `${(bytes / baseline * 100).toFixed(1)}%` : '—').padStart(10)}`
      + `${`${ms} ms`.padStart(10)}${(delta === null ? '—' : String(delta)).padStart(14)}\n`)
  }
  process.stdout.write(`\n会话条数：${byKey.get('legacy')?.[0]?.sessions ?? '?'}\n`)
}

main().catch((error) => {
  process.stderr.write(`${error.stack ?? error.message}\n`)
  process.exit(1)
})
