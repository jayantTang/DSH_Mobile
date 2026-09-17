#!/usr/bin/env node
/**
 * Creates a throwaway session that is *holding a pending question*, and prints
 * its id.
 *
 * A case about the question card needs a session in a particular **state**, and
 * the runner's own pick is "the session with the most history" — a size, not a
 * state. So the state is set up here, the id goes into the case's front matter
 * (`会话:`), and the case is deleted with the session afterwards.
 *
 * Usage:
 *   node scripts/dev/ask-scratch-question.mjs [--dir /tmp/dsh-uitest-question]
 *   # then: 会话: <printed id>  in test/cases/current/*.md
 *   node scripts/dev/ask-scratch-question.mjs --cleanup <sessionId>
 *
 * The question itself is asked by a real agent turn (the tool is the same one
 * any session uses), so the pending request is genuine — a fabricated one would
 * not prove that answering it releases the host.
 */

import { readFileSync, rmSync, readdirSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

const HOME = homedir()
const ENDPOINT = join(HOME, '.dsh', 'desktop-shell', 'endpoint.json')

function endpoint() {
  const raw = JSON.parse(readFileSync(ENDPOINT, 'utf8'))
  const token = /token=([^&]+)/.exec(raw.url)?.[1]
  if (!raw.port || !token) throw new Error('endpoint.json carries port and token, or nothing here works')
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
      body: JSON.stringify({ type: 'client-request', rpcId: `ask${++seq}`, method, payload: { args } }),
    })
    const body = await response.json()
    if (!body.result?.ok) throw new Error(`${method}: ${JSON.stringify(body.result?.error)}`)
    return body.result.value
  }
  return { call }
}

const args = process.argv.slice(2)
const cleanupAt = args.indexOf('--cleanup')
if (cleanupAt >= 0) {
  const sessionId = args[cleanupAt + 1]
  if (!sessionId) throw new Error('--cleanup needs a session id')
  const cache = join(HOME, '.dsh', 'storages', 'session_projcache', 'sessions')
  for (const directory of readdirSync(join(HOME, '.dsh', 'sessions'))) {
    rmSync(join(HOME, '.dsh', 'sessions', directory, sessionId), { recursive: true, force: true })
  }
  rmSync(join(cache, `${sessionId}.json`), { force: true })
  console.log(`已删除 ${sessionId}`)
  process.exit(0)
}

const dirAt = args.indexOf('--dir')
const directory = dirAt >= 0 ? args[dirAt + 1] : '/tmp/dsh-uitest-question'
const { call } = await host()
const created = await call('session/create', { request: { cwd: directory, agentPreset: 'standard' } })
console.log(created.sessionId)
await call('session/prompt', {
  request: {
    requestId: `ask-${Date.now()}`,
    sessionId: created.sessionId,
    mode: 'queue',
    clientTimeZone: 'Asia/Shanghai',
    content: [{ type: 'text', text: [
      '请只做一件事：调用一次 ask_user_question 工具问下面这个问题，然后停下等我回答，',
      '不要自己回答、也不要做别的事。',
      'header: 图标方向',
      'question: 卷身鲸那版图标要不要也画出来？',
      'detail: 两个选项都行，区别只是像不像官方那只。',
      'options（单选）: 要 / 先放着',
    ].join('\n') }],
  },
})
console.log(`已让该会话提问，等它进入待答状态（约 20 秒）后跑用例；用完 --cleanup 删掉`)
