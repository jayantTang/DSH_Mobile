#!/usr/bin/env node
/**
 * Creates a throwaway session whose **last message is a picture**, and prints
 * its id.
 *
 * Why: a case about the image placeholder ("加载失败 → 点按重试") needs the
 * picture to be *on screen when the transcript opens*. A transcript opens at the
 * bottom, so in any working session the pictures are screens away — the first
 * version of TC-MOB-25 scrolled up six screens and still found none. Here the
 * picture is the last thing in a session of its own, so the case needs no
 * scrolling and no luck.
 *
 * The image is sent as a prompt attachment — the path a user's own picture takes
 * — and the agent turn it starts is cancelled immediately: the picture stays,
 * and no model tokens are spent on a reply nobody reads.
 *
 * Usage:
 *   node scripts/dev/image-scratch-session.mjs [--dir /tmp/dsh-uitest-image]
 *   # then: 会话: <printed id>  in test/cases/current/*.md
 *   node scripts/dev/image-scratch-session.mjs --cleanup <sessionId>
 */

import { readFileSync, readdirSync, rmSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const HOME = homedir()
const ENDPOINT = join(HOME, '.dsh', 'desktop-shell', 'endpoint.json')
const REPO = join(dirname(fileURLToPath(import.meta.url)), '..', '..')

function endpoint() {
  const raw = JSON.parse(readFileSync(ENDPOINT, 'utf8'))
  const token = /token=([^&]+)/.exec(raw.url)?.[1]
  if (!raw.port || !token) throw new Error('endpoint.json 里没有 port/token，什么都做不了')
  return { port: raw.port, token }
}

async function host() {
  const { port, token } = endpoint()
  const exchange = await fetch(`http://127.0.0.1:${port}/?token=${token}`, { redirect: 'manual' })
  const cookie = (exchange.headers.getSetCookie?.() ?? [])[0]?.split(';')[0]
  let seq = 0
  const call = async (method, args) => {
    const response = await fetch(`http://127.0.0.1:${port}/api/${method}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', cookie },
      body: JSON.stringify({ type: 'client-request', rpcId: `img${++seq}`, method, payload: { args } }),
    })
    const body = await response.json()
    if (!body.result?.ok) throw new Error(`${method}: ${JSON.stringify(body.result?.error)}`)
    return body.result.value
  }
  return { call }
}

const args = process.argv.slice(2)

if (args.includes('--cleanup')) {
  const sessionId = args[args.indexOf('--cleanup') + 1]
  if (!sessionId) throw new Error('--cleanup 需要会话 id')
  for (const directory of readdirSync(join(HOME, '.dsh', 'sessions'))) {
    rmSync(join(HOME, '.dsh', 'sessions', directory, sessionId), { recursive: true, force: true })
  }
  rmSync(join(HOME, '.dsh', 'storages', 'session_projcache', 'sessions', `${sessionId}.json`), { force: true })
  console.log(`已删除 ${sessionId}`)
  process.exit(0)
}

const dirAt = args.indexOf('--dir')
const directory = dirAt >= 0 ? args[dirAt + 1] : '/tmp/dsh-uitest-image'
const fileAt = args.indexOf('--file')
const file = fileAt >= 0 ? args[fileAt + 1] : join(REPO, 'test', 'fixtures', 'sample-image.png')

const { call } = await host()
const created = await call('session/create', { request: { cwd: directory, agentPreset: 'standard' } })

const bytes = readFileSync(file)
await call('session/prompt', {
  request: {
    requestId: `image-${Date.now()}`,
    sessionId: created.sessionId,
    mode: 'queue',
    clientTimeZone: 'Asia/Shanghai',
    content: [
      { type: 'text', text: '（这条会话只放一张图片，用来验图片占位的重试）' },
      { type: 'image', mediaType: 'image/png', data: bytes.toString('base64'), name: file.split('/').pop() },
    ],
  },
})
// Cancel the turn the prompt started: the picture is already stored, and a reply
// would only push it off the bottom of the transcript.
await call('session/cancel', { request: { sessionId: created.sessionId } }).catch(() => {})

console.log(created.sessionId)
console.log(`图片会话就绪（用完：node scripts/dev/image-scratch-session.mjs --cleanup ${created.sessionId}）`)
