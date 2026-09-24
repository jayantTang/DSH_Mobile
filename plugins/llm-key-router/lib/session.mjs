/**
 * 从一个上游请求里认出"这是哪个会话"。
 *
 * 有正经身份就用正经身份：DSH 的会话 id 由 pi-ai 在
 * `compat.sendSessionAffinityHeaders: true` 时随请求发出（`session_id`、
 * `x-session-affinity`、`x-client-request-id`，视 `sessionAffinityFormat` 而定）。
 *
 * 没有身份（别的客户端、或没开那个开关）时退回**前缀指纹**：取
 * `model + system + 第一条 user 消息` 做哈希。为什么是前缀而不是整个请求：
 * 会话每轮都在变长，整串哈希每轮都不一样，等于没有粘性；前缀在整个会话里不变。
 * 代价是"开头一模一样"的两个会话会被认成同一个——那只是共用一把 key，不影响正确性。
 */
import { createHash } from 'node:crypto'

const HEADER_NAMES = ['session_id', 'x-session-affinity', 'x-session-id', 'x-client-request-id']

/** @returns {string|null} 直接来自请求头的会话身份。 */
export function sessionFromHeaders(headers = {}) {
  for (const name of HEADER_NAMES) {
    const value = headers[name]
    if (typeof value === 'string' && value.trim().length > 0) return value.trim()
  }
  return null
}

/** @returns {string|null} 请求体里能当身份用的字段（部分网关会带）。 */
export function sessionFromBody(body) {
  if (!body || typeof body !== 'object') return null
  if (typeof body.user === 'string' && body.user.trim()) return body.user.trim()
  if (typeof body.prompt_cache_key === 'string' && body.prompt_cache_key.trim()) {
    return body.prompt_cache_key.trim()
  }
  const meta = body.metadata
  if (meta && typeof meta === 'object') {
    for (const field of ['session_id', 'sessionId', 'conversation_id']) {
      if (typeof meta[field] === 'string' && meta[field].trim()) return meta[field].trim()
    }
  }
  return null
}

/**
 * 前缀指纹：**第一条 user 消息**的短哈希（没有 user 消息时退回 system）。
 *
 * 只用第一条 user 消息，实测踩过两次：
 *  - 带上 system 不行——DSH 的系统提示每轮都会变（待处理项、时间、工具清单），
 *    指纹跟着变，等于没有粘性；
 *  - 带上 model 也不行——会话中途换模型会把粘性打断，而换模型并不需要换 key。
 * 第一条 user 消息在整个会话里一个字都不变，这才是"这个会话"的稳定标识。
 * 代价：开头一模一样的两个会话会共用一把 key——那只是共用，不影响正确性。
 */
export function prefixFingerprint(body) {
  if (!body || typeof body !== 'object') return null
  const messages = Array.isArray(body.messages) ? body.messages : []
  const user = messages.find((message) => message?.role === 'user')
  const system = messages.find((message) => message?.role === 'system')
  const seed = user ? textOf(user) : system ? textOf(system) : ''
  if (!seed) return null
  return `fp-${createHash('sha256').update(seed).digest('hex').slice(0, 16)}`
}

function textOf(message) {
  const content = message?.content
  if (typeof content === 'string') return content
  if (Array.isArray(content)) {
    return content.map((block) => (typeof block?.text === 'string' ? block.text : '')).join('')
  }
  return ''
}

/**
 * 会话身份：头 > 请求体字段 > 前缀指纹。
 * @returns {string} 一定能拿到的键（最坏情况是按前缀指纹，仍能保住长会话的粘性）。
 */
export function sessionIdentity({ headers = {}, body = {} } = {}) {
  return sessionFromHeaders(headers) ?? sessionFromBody(body) ?? prefixFingerprint(body) ?? 'anonymous'
}
