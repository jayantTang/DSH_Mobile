#!/usr/bin/env node
/**
 * 历史加载端到端基准（程序化，无 UI、不需要仿真器）。
 *
 * 链路与产品一致：DSHKit `LinkCarrier` → WSS 中转 → 连接器 `_link/sessionWindow`
 * → 宿主读页 → DSHKit 解码 → SessionPipeline → ChatTimeline + 过程折叠。
 * "到显示"定义为折完、可直接交给列表的行（不含 UIKit 插行）。
 *
 * 网络档位由本机 `history-live-bench/net_shim.py` 做单程时延与带宽整形，
 * 上游仍是真实 TLS 中转；`direct` 档不经 shim。
 *
 * 设备生命周期：每次运行配一台 `DSH-PerfBench`，结束（含失败）在 finally 里撤销；
 * 不会在用户设备列表里留痕。
 *
 * 用法：
 *   node scripts/perf/history-live-bench.mjs --session 5f074487 --rounds 8
 *   node scripts/perf/history-live-bench.mjs --profiles direct,4g --rounds 4 --skip-build
 *
 * 产物：`scripts/perf/results/<UTC 时间戳>/`（JSON + shim 字节日志 + summary.md）。
 */

import { spawn } from 'node:child_process'
import { mkdir, readFile, writeFile, access } from 'node:fs/promises'
import { constants } from 'node:fs'
import { connect, createServer } from 'node:net'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

import { identity, pairDevice, revokeDevice } from '../../test/tools/relaypair.mjs'

const HERE = fileURLToPath(new URL('.', import.meta.url))
const PKG = join(HERE, 'history-live-bench')
const BIN = join(PKG, '.build', 'release', 'history-live-bench')
const SHIM = join(PKG, 'net_shim.py')
const REPO = join(HERE, '..', '..')

const PROFILES = {
  direct: { shaped: false },
  lan: { shaped: true, rtt: 2, jitter: 0, down: 200000, up: 200000 },
  '4g': { shaped: true, rtt: 60, jitter: 15, down: 8000, up: 2000 },
  '3g': { shaped: true, rtt: 150, jitter: 40, down: 1500, up: 512 },
  congested: { shaped: true, rtt: 90, jitter: 25, down: 300, up: 200 },
}

function usage(message) {
  if (message) console.error(message)
  console.error('用法: node scripts/perf/history-live-bench.mjs [--session <id>] [--rounds N] '
    + '[--profiles direct,lan,4g,3g,congested] [--read-pause-ms N] [--skip-build] [--json]')
  process.exit(2)
}

function parse(argv) {
  const out = { session: '', rounds: 8, pause: 1000, profiles: Object.keys(PROFILES), build: true, json: false }
  for (let i = 2; i < argv.length; i += 1) {
    const key = argv[i]
    switch (key) {
      case '--session': out.session = argv[++i]; break
      case '--rounds': out.rounds = Number(argv[++i]); break
      case '--read-pause-ms': out.pause = Number(argv[++i]); break
      case '--profiles': out.profiles = argv[++i].split(',').map((s) => s.trim()).filter(Boolean); break
      case '--skip-build': out.build = false; break
      case '--json': out.json = true; break
      default: usage(`unknown argument: ${key}`)
    }
  }
  for (const name of out.profiles) {
    if (PROFILES[name] === undefined) usage(`unknown profile: ${name}`)
  }
  return out
}

async function exists(path) {
  try { await access(path, constants.X_OK); return true } catch {}
  return false
}

async function python() {
  const venv = join(REPO, 'relay', '.venv', 'bin', 'python')
  return (await exists(venv)) ? venv : 'python3'
}

async function freePort() {
  return new Promise((resolve, reject) => {
    const server = createServer()
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address()
      server.close(() => resolve(port))
    })
    server.on('error', reject)
  })
}

function wssToHttps(url) {
  const parsed = new URL(url)
  parsed.protocol = parsed.protocol === 'wss:' ? 'https:' : 'http:'
  parsed.search = ''
  parsed.hash = ''
  return parsed
}

async function run(command, args, { env = process.env, quiet = false } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: ['ignore', 'pipe', 'pipe'], env })
    let stdout = ''
    let stderr = ''
    child.stdout.on('data', (chunk) => { stdout += chunk })
    child.stderr.on('data', (chunk) => {
      stderr += chunk
      if (!quiet) process.stderr.write(chunk)
    })
    child.on('error', reject)
    child.on('close', (code) => {
      if (code === 0) resolve({ stdout, stderr })
      else reject(new Error(`${command} exited ${code}\n${stderr.slice(-2000)}`))
    })
  })
}

function wireBytes(logText) {
  let down = 0
  let up = 0
  for (const line of logText.split('\n')) {
    if (!line.trim()) continue
    let record
    try { record = JSON.parse(line) } catch { continue }
    if (record.ev !== 'frame') continue
    if (record.dir === 'down') down += record.bytes
    else up += record.bytes
  }
  return { down, up }
}

function median(values) {
  if (values.length === 0) return 0
  const sorted = [...values].sort((a, b) => a - b)
  return sorted[Math.floor((sorted.length - 1) / 2)]
}

async function startShim(profile, upstream, logPath) {
  const port = await freePort()
  const args = [
    SHIM, '--port', String(port), '--upstream', upstream.origin, '--log', logPath,
    '--rtt-ms', String(profile.rtt), '--jitter-ms', String(profile.jitter),
    '--down-kbps', String(profile.down), '--up-kbps', String(profile.up),
  ]
  const child = spawn(await python(), args, { stdio: ['ignore', 'ignore', 'pipe'] })
  let stderr = ''
  child.stderr.on('data', (chunk) => { stderr += chunk })
  // 等端口可连接：最多 3s。用 connect 探活，不能用 bind（会和新起的 shim 抢端口）。
  const deadline = Date.now() + 3000
  while (Date.now() < deadline) {
    const ok = await new Promise((resolve) => {
      const probe = connect(port, '127.0.0.1')
      probe.once('connect', () => { probe.destroy(); resolve(true) })
      probe.once('error', () => resolve(false))
    })
    if (ok) break
    await new Promise((resolve) => setTimeout(resolve, 100))
  }
  return { child, port, stderr: () => stderr }
}

async function main() {
  const options = parse(process.argv)
  const me = identity()
  const https = wssToHttps(me.relayUrl)
  const prefix = https.pathname.replace(/\/+$/, '')
  const stamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19)
  const outDir = join(HERE, 'results', stamp)
  await mkdir(outDir, { recursive: true })

  if (options.build) {
    process.stderr.write('building benchmark (release)…\n')
    await run('swift', ['build', '-c', 'release', '--package-path', PKG], { quiet: true })
  }
  if (!(await exists(BIN))) throw new Error(`missing benchmark binary: ${BIN} (rerun without --skip-build)`)

  const device = await pairDevice({
    deviceName: 'DSH-PerfBench', deviceModel: 'headless', appVersion: 'perf-harness',
  })
  const summary = []
  try {
    for (const name of options.profiles) {
      const profile = PROFILES[name]
      const logPath = join(outDir, `shim-${name}.jsonl`)
      let shim
      let relay
      if (profile.shaped) {
        shim = await startShim(profile, https, logPath)
        relay = `http://127.0.0.1:${shim.port}${prefix}`
      } else {
        relay = https.href
      }
      const outPath = join(outDir, `${name}.json`)
      const args = [
        '--relay', relay,
        '--agent', me.agentId,
        '--token', device.deviceToken,
        '--rounds', String(options.rounds),
        '--read-pause-ms', String(options.pause),
        '--label', name,
        '--out', outPath,
      ]
      if (options.session) args.push('--session', options.session)
      try {
        await run(BIN, args, { quiet: true })
      } catch (error) {
        // 单个档位失败不吞掉其它档位；把失败如实写进汇总。
        summary.push({ profile: name, error: String(error).slice(-500) })
        continue
      } finally {
        if (shim) {
          shim.child.kill('SIGTERM')
          await new Promise((resolve) => shim.child.once('close', resolve))
        }
      }
      const result = JSON.parse(await readFile(outPath, 'utf8'))
      let bytes = { down: 0, up: 0 }
      if (profile.shaped) {
        try { bytes = wireBytes(await readFile(logPath, 'utf8')) } catch {}
      }
      const payloadTotal = result.payloadBytesTotal
      summary.push({
        profile: name,
        sessionId: result.sessionId,
        asOfSeq: result.asOfSeq,
        pingMs: Math.round(result.pingMedianMs),
        openMs: Math.round(result.open.netMs),
        waitMedianMs: Math.round(result.waitMedianMs),
        waitP95Ms: Math.round(result.waitP95Ms),
        pageBytes: Math.round(result.payloadBytesMedian),
        payloadBytes: payloadTotal,
        wireDown: bytes.down,
        wireUp: bytes.up,
        fetches: result.fetchCount,
        visiblePerRound: Math.round(result.visiblePerRoundMedian * 10) / 10,
        capabilities: {
          compression: result.capabilities.includes('history-compression'),
          fold: result.capabilities.includes('history-fold-summary'),
        },
        foldCount: result.foldCount ?? 0,
        expandProbe: result.expandProbe,
        rounds: result.rounds,
      })
    }
  } finally {
    await revokeDevice({ relayUrl: me.relayUrl, deviceToken: device.deviceToken, deviceId: device.deviceId })
  }

  const payload = {
    generatedAt: new Date().toISOString(),
    relay: me.relayUrl,
    session: options.session || '(largest asOfSeq)',
    rounds: options.rounds,
    readPauseMs: options.pause,
    profiles: summary,
  }
  await writeFile(join(outDir, 'summary.json'), JSON.stringify(payload, null, 2))
  await writeFile(join(outDir, 'summary.md'), renderMarkdown(payload))

  if (options.json) console.log(JSON.stringify(payload, null, 2))
  else console.log(renderMarkdown(payload))
  console.log(`\nresults: ${outDir}`)
}

function renderMarkdown(payload) {
  const lines = [
    `# 历史加载端到端基准（${payload.generatedAt}）`,
    '',
    `中转 \`${payload.relay}\`；会话 \`${payload.session}\`；每次上翻 ${payload.rounds} 次、阅读间隔 ${payload.readPauseMs}ms。`,
    '',
    '| 档位 | ping | 开屏 | 上翻 p50 | p95 | 单页字节 | 下行字节 | 可见行/次 | 摘要数 |',
    '|---|---|---|---|---|---|---|---|---|',
  ]
  for (const row of payload.profiles) {
    if (row.error) {
      lines.push(`| ${row.profile} | - | - | - | - | - | - | 失败：${row.error.replace(/\|/g, '/')} |`)
      continue
    }
    lines.push(`| ${row.profile} | ${row.pingMs}ms | ${row.openMs}ms | ${row.waitMedianMs}ms | `
      + `${row.waitP95Ms}ms | ${row.pageBytes}B | ${row.wireDown ? `${Math.round(row.wireDown / 1024)}KB` : '-'} | `
      + `${row.visiblePerRound} | ${row.foldCount ?? 0} |`)
  }
  lines.push('')
  lines.push('能力：' + payload.profiles.filter((r) => !r.error)
    .map((r) => `${r.profile} 压缩=${r.capabilities.compression ? '有' : '无'} 折叠=${r.capabilities.fold ? '有' : '无'}`)
    .join('；'))
  return lines.join('\n') + '\n'
}

main().catch((error) => {
  console.error(error.message ?? error)
  process.exit(1)
})
