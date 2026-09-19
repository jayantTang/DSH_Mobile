#!/usr/bin/env node
/**
 * Standalone runner for the DLP agent, outside DSH.
 *
 * The cordis plugin is the normal entry point; this CLI exists so the agent can
 * be exercised (and the whole middle tier integration-tested) without booting a
 * DSH profile:
 *
 *   node lib/cli.js --relay ws://127.0.0.1:8787 \
 *     --agent-id agt_x --agent-secret as_y --status-file /tmp/mobile-link.json
 *
 * It prints one machine-readable line per connection state change:
 *   MOBILE_LINK_STATE {"state":"connected", ...}
 *
 * `--mint-pair-code` skips the link entirely and just asks the relay for a
 * pairing code (plus its `dsh://pair?...` payload) through the same
 * prefix-preserving URL join the live agent uses.
 *
 * `enroll` is the first-run path for someone else's computer: it redeems an
 * invite code for an identity and writes `~/.dsh/mobile-link/agent.json`, then
 * exits. Everything after that is the ordinary agent.
 */

import { rename, writeFile } from 'node:fs/promises'

import { enrollAgent, inviteFrom } from './enroll.js'
import { MobileLinkAgent } from './link.js'
import { mintPairCode } from './pairing.js'
import { INVITE_ENV, defaultStatePath, resolveIdentity } from './state.js'

/** Atomic status snapshot so readers never observe a half-written file. */
async function writeJsonAtomic(path, value) {
  const temporary = `${path}.${process.pid}.tmp`
  await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 })
  await rename(temporary, path)
}

function parseArgs(argv) {
  const args = { _: [] }
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index]
    if (!token.startsWith('--')) {
      args._.push(token)
      continue
    }
    const eq = token.indexOf('=')
    const key = (eq === -1 ? token.slice(2) : token.slice(2, eq)).replace(/-([a-z])/g, (_m, c) => c.toUpperCase())
    if (eq !== -1) {
      args[key] = token.slice(eq + 1)
    } else if (argv[index + 1] !== undefined && !argv[index + 1].startsWith('--')) {
      args[key] = argv[index + 1]
      index += 1
    } else {
      args[key] = true
    }
  }
  return args
}

async function main() {
  const args = parseArgs(process.argv.slice(2))
  if (args.help) {
    process.stdout.write(`usage: cli.js enroll --invite <code> [--relay <ws url>] [--name <label>]
  Redeem a one-time invite code for an identity in ${defaultStatePath()}.
  The invite may also arrive as ${INVITE_ENV}. Exits non-zero on failure.

  cli.js --relay <ws url> --agent-id <id> --agent-secret <secret>
  [--state-file <path>] [--dsh-url <url>] [--endpoint-file <path>]
  [--status-file <path>] [--heartbeat-ms <n>] [--log-level debug|info|warn]

  cli.js --mint-pair-code --relay <ws url> --agent-id <id> --agent-secret <secret>
  [--ttl-ms <n>]     print one pairing code as JSON and exit
`)
    return 0
  }

  if (args._[0] === 'enroll' || args.enroll) {
    const explicit = typeof args.enroll === 'string' ? args.enroll : undefined
    const settled = await enrollAgent({
      relayUrl: args.relay,
      inviteCode: inviteFrom({ inviteCode: explicit ?? args.invite }),
      name: args.name,
      stateFile: typeof args.stateFile === 'string' ? args.stateFile : undefined,
    })
    process.stdout.write(`${JSON.stringify({
      ok: true,
      agentId: settled.agentId,
      agentName: settled.agentName,
      relayUrl: settled.relayUrl,
      stateFile: settled.stateFile,
    }, null, 2)}\n`)
    // 登记只是第一步：还有两步（重启、扫码）不写在输出里，新用户就会以为"登记完就好了"。
    // 第一位试用用户正是这样——登记了电脑，却没有配对手机。
    process.stdout.write(
      '这台电脑已登记。接下来还有两步：\n' +
      '  1. 重启 DSH，让连接器用上这个身份；\n' +
      '  2. 在这台电脑的浏览器里打开 http://127.0.0.1:<DSH 端口>/mobile-link/qr，' +
      '用手机 App 底部的「扫码配对」扫它（端口启动时会打印）。\n'
    )
    return 0
  }

  if (args.mintPairCode) {
    const identity = await resolveIdentity({
      stateFile: typeof args.stateFile === 'string' ? args.stateFile : undefined,
      agentId: args.agentId,
      agentSecret: args.agentSecret,
      relayUrl: args.relay,
    })
    const minted = await mintPairCode({
      identity,
      ttlMs: Number(args.ttlMs) || 10 * 60 * 1000,
    })
    process.stdout.write(`${JSON.stringify(minted, null, 2)}\n`)
    return 0
  }

  const level = String(args.logLevel ?? process.env.DSH_MOBILE_LINK_LOG ?? 'info')
  const enabledLevels = level === 'debug' ? ['debug', 'info', 'warn', 'error'] : ['info', 'warn', 'error']
  const write = (stream, prefix) => (...parts) => {
    stream.write(`${prefix} ${parts.map(String).join(' ')}\n`)
  }
  const logger = {
    debug: enabledLevels.includes('debug') ? write(process.stdout, '[debug]') : () => {},
    info: write(process.stdout, '[info]'),
    warn: write(process.stderr, '[warn]'),
    error: write(process.stderr, '[error]'),
  }

  const agent = new MobileLinkAgent({
    relayUrl: args.relay,
    agentId: args.agentId,
    agentSecret: args.agentSecret,
    stateFile: typeof args.stateFile === 'string' ? args.stateFile : undefined,
    dshUrl: typeof args.dshUrl === 'string' ? args.dshUrl : undefined,
    endpointFile: typeof args.endpointFile === 'string' ? args.endpointFile : undefined,
    heartbeatMs: Number(args.heartbeatMs) || 20000,
    logger,
  })

  let previous = ''
  agent.on('status', () => {
    const status = agent.status()
    const stamp = JSON.stringify(status)
    if (stamp === previous) return
    previous = stamp
    if (args.statusFile) {
      void writeJsonAtomic(String(args.statusFile), status).catch(() => {})
    }
    process.stdout.write(`MOBILE_LINK_STATE ${JSON.stringify({
      state: status.state,
      connected: status.connected,
      agentId: status.agentId,
      relayUrl: status.relayUrl,
      deviceCount: status.deviceCount,
      lastError: status.lastError,
    })}\n`)
  })

  const shutdown = async (signal) => {
    logger.info(`received ${signal}, stopping`)
    await agent.stop()
    process.exit(0)
  }
  process.on('SIGINT', () => void shutdown('SIGINT'))
  process.on('SIGTERM', () => void shutdown('SIGTERM'))

  await agent.start()
  if (args.once) {
    if (agent.state !== 'connected') {
      await new Promise((resolve) => {
        const timer = setTimeout(resolve, Number(args.onceMs) || 5000)
        agent.on('status', () => {
          if (agent.state === 'connected') {
            clearTimeout(timer)
            resolve()
          }
        })
      })
    }
    const connected = agent.state === 'connected'
    await agent.stop()
    return connected ? 0 : 1
  }
  // Keep the process alive until a signal arrives.
  await new Promise(() => {})
  return 0
}

main().then(
  (code) => {
    process.exitCode = code
  },
  (error) => {
    process.stderr.write(`mobile-link: fatal: ${error instanceof Error ? error.stack : error}\n`)
    process.exitCode = 1
  },
)
