#!/usr/bin/env node
// 归档已完成开发周期的 agent 会话（owner 2026-09-29 规则：已通过验收/已收尾的周期，
// 其 agent 会话自动归档，免得会话列表越堆越多）。
//
// 用法：
//   node tools/archive-sessions.mjs <sessionId> [<sessionId> …]   归档指定会话
//   node tools/archive-sessions.mjs --dry-run <id> …              只看会不会成功，不动
//
// 安全设计：
//   - 归档是「移出列表」，不删任何数据（磁盘会话与产物都在；桌面端 Web 客户端可以恢复）。
//   - 调用前先查 session/list，**running=true 的会话一律拒绝归档**（正在跑的轮次不许动）。
//   - 归档是单向的（host 忽略 archived:false；没有取消归档的接口），所以这里默认逐个确认结果。
//
// 认证方式与 scripts/dev/ask-scratch-question.mjs 相同：endpoint.json 换 cookie，POST /api/<method>。
import { readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

const raw = JSON.parse(readFileSync(join(homedir(), '.dsh', 'mobile-link', 'endpoint.json'), 'utf8'))
const token = /token=([^&]+)/.exec(raw.url)?.[1]
if (!raw.port || !token) throw new Error('endpoint.json 里没有 port/token')

const exchange = await fetch(`http://127.0.0.1:${raw.port}/?token=${token}`, { redirect: 'manual' })
const cookie = (exchange.headers.getSetCookie?.() ?? [])[0]?.split(';')[0]
if (!cookie) throw new Error('没有拿到会话 cookie')

let seq = 0
async function call(method, args) {
  const response = await fetch(`http://127.0.0.1:${raw.port}/api/${method}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', cookie },
    body: JSON.stringify({ type: 'client-request', rpcId: `arch${++seq}`, method, payload: { args } }),
  })
  const body = await response.json()
  if (!body.result?.ok) return { error: body.result?.error ?? body }
  return { value: body.result.value }
}

const dry = process.argv[2] === '--dry-run'
const ids = process.argv.slice(dry ? 3 : 2).filter((id) => id && !id.startsWith('--'))
if (ids.length === 0) throw new Error('用法: archive-sessions.mjs [--dry-run] <sessionId> …')

const listed = await call('session/list', { _request: {} })
if (!listed.value) throw new Error(`session/list 失败: ${JSON.stringify(listed.error).slice(0, 200)}`)
const items = listed.value.items ?? []

for (const arg of ids) {
  // 参数允许只给前缀（会话 id 太长，抄全容易错），按前缀匹配；恰好匹配多个时拒绝动手。
  const hits = items.filter((it) => it.sessionId === arg || it.sessionId.startsWith(arg))
  if (hits.length === 0) {
    console.log(`${arg}  跳过：host 列表里没有这个会话（可能已不在或已归档）`)
    continue
  }
  if (hits.length > 1) {
    console.log(`${arg}  拒绝：前缀匹配到 ${hits.length} 个会话，请给更长的前缀`)
    continue
  }
  const item = hits[0]
  if (item.running) {
    console.log(`${item.sessionId.slice(0, 8)}  拒绝：正在运行（running=true），不许归档`)
    continue
  }
  if (dry) {
    console.log(`${item.sessionId.slice(0, 8)}  dry-run：可归档（title=${String(item.projections?.values?.title ?? '').slice(0, 30)}）`)
    continue
  }
  const r = await call('workspace/archiveSession', { request: { sessionId: item.sessionId, archived: true } })
  if (r.value) console.log(`${item.sessionId.slice(0, 8)}  已归档（title=${String(item.projections?.values?.title ?? '').slice(0, 30)}）`)
  else console.log(`${item.sessionId.slice(0, 8)}  失败：${JSON.stringify(r.error).slice(0, 160)}`)
}
