/**
 * HTTP 代理：对上游是普通 OpenAI 兼容客户端，对客户端是普通 OpenAI 兼容服务。
 *
 * 只做三件事，不做第四件：
 *   1. 按 `router` 选一把 key，把请求**原样**转给上游（body 一个字不改：
 *      前缀只要差一个字节，上游的缓存就作废）；
 *   2. 把答复原样转回来（SSE 逐块透传，不缓冲、不改写）；
 *   3. 在"还没写给客户端任何字节"之前，失败可以换 key 重试——这一步客户端看不见。
 *
 * `/v1/models` 与 `/stats` 是给人和给 pi-ai 的目录发现用的。
 */
import { createServer } from 'node:http'
import { AffinityTable } from './affinity.mjs'
import { loadKeys } from './config.mjs'
import { KeyPool } from './keys.mjs'
import { KeyRouter } from './router.mjs'
import { sessionIdentity } from './session.mjs'
import { StatsStore } from './stats.mjs'

/** 响应里出现的用量字段：用来证明"缓存有没有保住"。 */
function usageOf(payload) {
  const usage = payload?.usage
  if (!usage || typeof usage !== 'object') return {}
  const details = usage.prompt_tokens_details ?? usage.prompt_tokens_details_extra ?? {}
  return {
    promptTokens: typeof usage.prompt_tokens === 'number' ? usage.prompt_tokens : undefined,
    cachedTokens: typeof details.cached_tokens === 'number' ? details.cached_tokens : undefined,
  }
}

/** 从一段 SSE 文本里尽量抠出 usage 与 finish_reason（两者都只在流末尾给）。 */
function usageFromSSE(text) {
  let found = {}
  let truncated = false
  for (const line of text.split('\n')) {
    if (!line.startsWith('data:')) continue
    const payload = line.slice(5).trim()
    if (!payload || payload === '[DONE]') continue
    try {
      const parsed = JSON.parse(payload)
      const usage = usageOf(parsed)
      if (Object.keys(usage).length) found = usage
      for (const choice of parsed.choices ?? []) {
        if (choice?.finish_reason === 'length') truncated = true
      }
    } catch {
      // 半截的 JSON（跨块）忽略：usage 与 finish_reason 那两帧都很小，实际不会跨块丢。
    }
  }
  return { ...found, truncated }
}

export function createRouterServer({ router, upstream, token, stats = new StatsStore(), logger = console }) {
  const inflight = { total: 0 }
  const counters = {
    requests: 0,
    retries: 0,
    failovers: 0,
    cacheHits: 0,
    promptTokens: 0,
    cachedTokens: 0,
    errors: 0,
    byModel: {},
  }

  const server = createServer(async (req, res) => {
    const url = new URL(req.url ?? '/', 'http://127.0.0.1')

    if (req.method === 'GET' && url.pathname === '/health') {
      return json(res, 200, { ok: true, upstream, ...router.snapshot() })
    }
    if (req.method === 'GET' && url.pathname === '/stats') {
      const days = Math.max(1, Math.min(90, Number(url.searchParams.get('days') ?? 7) || 7))
      return json(res, 200, {
        ...counters,
        inflight: inflight.total,
        ...router.snapshot(),
        history: stats.snapshot(days),
      })
    }

    // 本机令牌：不是安全边界（服务只监听 127.0.0.1），只是"配错了会立刻报错"。
    if (token) {
      const auth = String(req.headers.authorization ?? '')
      if (auth !== `Bearer ${token}`) {
        return json(res, 401, { error: { message: 'bad local router token', type: 'unauthorized' } })
      }
    }

    if (url.pathname === '/v1/models' && req.method === 'GET') {
      return forwardModels({ req, res, upstream, router, logger })
    }
    if (url.pathname === '/v1/chat/completions' && req.method === 'POST') {
      return forwardChat({ req, res, upstream, router, counters, inflight, stats, logger })
    }
    return json(res, 404, { error: { message: `no route for ${req.method} ${url.pathname}` } })
  })

  return { server, counters, inflight }
}

async function forwardModels({ req, res, upstream, router, logger }) {
  const key = router.pool.next()
  if (!key) return json(res, 503, { error: { message: 'no upstream key available' } })
  try {
    const response = await fetch(`${upstream}/v1/models`, {
      headers: { authorization: `Bearer ${key.secret}` },
    })
    const text = await response.text()
    if (!response.ok) {
      router.noteResult({ key, status: response.status, body: text, session: 'models' })
    }
    res.writeHead(response.status, { 'content-type': 'application/json' })
    res.end(text)
  } catch (error) {
    logger.warn?.(`models 转发失败：${error.message}`)
    json(res, 502, { error: { message: `upstream unreachable: ${error.message}` } })
  }
}

async function forwardChat({ req, res, upstream, router, counters, inflight, stats, logger }) {
  const bodyText = await readBody(req)
  let body
  try {
    body = JSON.parse(bodyText)
  } catch {
    return json(res, 400, { error: { message: 'request body is not JSON' } })
  }

  const session = sessionIdentity({ headers: req.headers, body })
  const model = String(body.model ?? 'unknown')
  // 上游真正收到的输出上限：pi-ai 用 route 的 defaultMaxTokens，没声明就是它自己的
  // 32768 —— 2026-09-24 长回合撞上它，turn 被截断（reason=max-tokens）。记下来，
  // 这类问题下次只看统计就能认出来。
  // pi-ai 按 compat.maxTokensField 二选一写：有的模型写 `max_tokens`，有的写
  // `max_completion_tokens`。两个都看，否则统计里会显示成"没带上限"。
  const declaredMax = body.max_tokens ?? body.max_completion_tokens
  const maxTokens = Number.isFinite(Number(declaredMax)) ? Number(declaredMax) : null
  // 思考档位同样要能看见：2026-09-24 的坑是 pi-ai 用 `thinkingFormat: deepseek` 时
  // 会同时发 `thinking:{type:enabled}` 和 `reasoning_effort`，而这条网关只认后者单独出现，
  // 于是"选 Max 其实没生效"。日志里带上 effort/thinking，下次一眼能看出手机上选了什么、
  // 线上到底发了什么。
  const effort = body.reasoning_effort ?? body.reasoning?.effort ?? null
  const thinking = body.thinking?.type ?? null
  const streaming = body.stream === true
  counters.requests += 1
  counters.byModel[model] = (counters.byModel[model] ?? 0) + 1
  inflight.total += 1

  const tried = new Set()
  let lastFailure = null
  try {
    for (let attempt = 1; attempt <= router.maxAttempts; attempt += 1) {
      const choice = router.pick(session, { tried })
      if (!choice) {
        return json(res, 503, {
          error: { message: 'no upstream key available', type: 'no_key' },
        })
      }
      const { key, reason } = choice
      tried.add(key.label)
      if (attempt > 1) {
        counters.retries += 1
        if (reason === 'migrated') counters.failovers += 1
      }

      let response
      try {
        key.noteRequest()
        response = await fetch(`${upstream}/v1/chat/completions`, {
          method: 'POST',
          headers: {
            authorization: `Bearer ${key.secret}`,
            'content-type': 'application/json',
            accept: req.headers.accept ?? '*/*',
          },
          body: bodyText,
        })
      } catch (error) {
        // 网络层失败：当作 5xx 抖动处理，规则与状态码一致。
        const verdict = router.noteResult({ key, status: 0, body: error.message, attempt, session })
        logger.warn?.(`上游连接失败（${key.label}）：${error.message}${verdict.retry ? '，换 key 重试' : ''}`)
        lastFailure = { status: 0, message: error.message }
        if (!verdict.retry) break
        continue
      }

      if (!response.ok) {
        const text = await response.text()
        const verdict = router.noteResult({
          key,
          status: response.status,
          body: text,
          retryAfter: response.headers.get('retry-after'),
          attempt,
          session,
        })
        lastFailure = { status: response.status, message: text.slice(0, 300) }
        logger.warn?.(
          `上游 ${response.status}（${key.label}，${verdict.reason}）`
          + `${verdict.retry ? ' → 换 key 重试' : ' → 直接回给客户端'}`
        )
        stats.noteRequest({ model, keyLabel: key.label, ok: false })
        if (attempt > 1) stats.noteRotation({ from: key.label, reason: verdict.reason, model, status: response.status })
        if (!verdict.retry) {
          res.writeHead(response.status, { 'content-type': 'application/json' })
          return res.end(text)
        }
        continue
      }

      // 成功：从这里开始，答复一旦写出就不能再换 key 了。
      if (!streaming) {
        const text = await response.text()
        let parsed = null
        try { parsed = JSON.parse(text) } catch { /* 原样转发 */ }
        let truncated = false
        if (parsed) {
          const u = usageOf(parsed)
          key.noteUsage(u)
          counters.promptTokens += u.promptTokens ?? 0
          counters.cachedTokens += u.cachedTokens ?? 0
          if ((u.cachedTokens ?? 0) > 0) counters.cacheHits += 1
          truncated = (parsed.choices ?? []).some((choice) => choice?.finish_reason === 'length')
        }
        stats.noteRequest({ model, keyLabel: key.label, ok: true, ...(parsed ? usageOf(parsed) : {}) })
        if (truncated) stats.noteTruncation({ model, keyLabel: key.label, maxTokens })
        if (truncated) counters.truncated = (counters.truncated ?? 0) + 1
        res.writeHead(response.status, { 'content-type': 'application/json' })
        return res.end(text)
      }

      res.writeHead(response.status, {
        'content-type': response.headers.get('content-type') ?? 'text/event-stream',
        'cache-control': 'no-cache',
        connection: 'keep-alive',
      })
      const decoder = new TextDecoder()
      let seen = ''
      for await (const chunk of response.body ?? []) {
        const bytes = chunk instanceof Uint8Array ? chunk : new Uint8Array(chunk)
        seen += decoder.decode(bytes, { stream: true })
        if (seen.length > 200_000) seen = seen.slice(-40_000)
        if (!res.write(bytes)) await new Promise((resolve) => res.once('drain', resolve))
      }
      res.end()
      const u = usageFromSSE(seen)
      key.noteUsage(u)
      counters.promptTokens += u.promptTokens ?? 0
      counters.cachedTokens += u.cachedTokens ?? 0
      if ((u.cachedTokens ?? 0) > 0) counters.cacheHits += 1
      stats.noteRequest({ model, keyLabel: key.label, ok: true, promptTokens: u.promptTokens, cachedTokens: u.cachedTokens })
      if (u.truncated) {
        counters.truncated = (counters.truncated ?? 0) + 1
        stats.noteTruncation({ model, keyLabel: key.label, maxTokens })
      }
      logger.info?.(
        `ok ${model} max=${maxTokens ?? '-'} effort=${effort ?? '-'} thinking=${thinking ?? '-'} session=${session.slice(0, 24)} key=${key.label}(${reason})`
        + `${u.cachedTokens ? ` cached=${u.cachedTokens}` : ''}`
        + `${u.truncated ? ' ⚠️ 被 max_tokens 截断' : ''}`
      )
      return undefined
    }

    counters.errors += 1
    return json(res, lastFailure?.status && lastFailure.status >= 400 ? lastFailure.status : 502, {
      error: {
        message: `all upstream keys failed: ${lastFailure?.message ?? 'unknown'}`,
        type: 'upstream_unavailable',
      },
    })
  } finally {
    inflight.total -= 1
  }
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = []
    req.on('data', (chunk) => chunks.push(chunk))
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')))
    req.on('error', reject)
  })
}

function json(res, status, payload) {
  const text = JSON.stringify(payload, null, 1)
  res.writeHead(status, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(text) })
  res.end(text)
}

/** 组装一个可直接 `listen` 的服务。 */
export function startRouterServer({ config, logger = console }) {
  const pool = new KeyPool(loadKeys(config))
  const affinity = new AffinityTable({ path: config.affinityPath, ttlMs: config.affinityTtlMs })
  const router = new KeyRouter({
    pool,
    affinity,
    cooldownSeconds: config.cooldownSeconds,
    maxAttempts: config.maxAttempts,
  })
  const stats = new StatsStore({ path: config.statsPath, keepDays: config.statsKeepDays })
  const { server, counters, inflight } = createRouterServer({
    router,
    upstream: config.upstream.replace(/\/+$/, ''),
    token: config.token,
    stats,
    logger,
  })
  // 退出前把这一批统计写盘（KeepAlive 重启、Ctrl-C、升级都走这条路）。
  for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => stats.save())
  return { server, router, counters, inflight, pool, affinity, stats }
}
