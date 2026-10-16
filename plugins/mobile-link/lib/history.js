import { HOST_CALL_TIMEOUT_MS, withTimeout, messageOf } from './history/shared.js'
import {
  DEFAULT_LIMIT, DEFAULT_MAX_BYTES, WINDOW_CHUNK,
  bytesOfRecords, displayRoleOf, roleOf, toRecord, trimRecordForWire, trimRecordsForWire,
} from './history/records.js'
import { pageFrom, scanOlder } from './history/window.js'
import { filteredScan } from './history/filter-scan.js'
import { createSnapshotCache, scanSnapshot } from './history/session-snapshot.js'

// Re-exported for the caller/tests that read them off this module (single source
// is `history/records.js`; the call ceiling lives in `history/shared.js`).
export { DEFAULT_MAX_BYTES, DEFAULT_LIMIT, WINDOW_CHUNK } from './history/records.js'
export { HOST_CALL_TIMEOUT_MS } from './history/shared.js'

/**
 * History window reads and in-session search, answered **locally** by the connector.
 *
 * Why local: the Host already owns a correct, seq-exact reader
 * (`ctx.sessionQuery`, see @deepseek-ai/dsh-session-query) but does **not** expose
 * it over the remote API the phone talks to. The only history method on that
 * surface is `session/page`, whose `beforeSeq` lands in log-offset space, so a
 * session containing offset-only events silently skips a stretch of history —
 * measured at 235 seqs on a real session (see DSHKit's TranscriptPageBoundary).
 *
 * So the connector reads the Host's own state through the injected service and
 * answers two extra methods:
 *
 *   _link/sessionWindow  exact window ending before a given seq
 *   _link/sessionFind    literal text search within one session
 *
 * Feature detection is the switch, not version comparison: a connector that
 * lacks the injected service answers `link/unsupported`, and the phone keeps
 * using `session/page`. Nothing about the existing methods changes.
 */

export const WINDOW_METHOD = '_link/sessionWindow'
export const FIND_METHOD = '_link/sessionFind'

/// Declared in `_link/hello`; the phone switches channels on these.
/// `history-role-filter`: `_link/sessionWindow` accepts an optional `roles`
/// array (e.g. `["me"]`) and returns only matching records; the seq cursor
/// semantics are unchanged (spec 009 T031).
/// `history-scan-boundary`: a `roles`-filtered page also carries `scanBoundary`,
/// the seq the scan really reached, so a caller can advance its cursor when a
/// whole page is filtered empty (spec 009 T039). Purely additive: a client that
/// does not read the field keeps the old cursor rule.
export const HISTORY_CAPABILITIES = [
  'history-window', 'session-search', 'history-role-filter', 'history-scan-boundary',
  // search-progress: a scanned page also carries `totalChunks` / `remainingChunks`,
  // so the reader can be told "已扫 k/N 片" from the first page on. Purely additive:
  // `totalChunks` comes from the log's newest seq, which a scan already fetches.
  'search-progress',
]

export function isHistoryMethod(method) {
  return method === WINDOW_METHOD || method === FIND_METHOD
}

/// One search chunk, and how many of them one call may scan. Measured on a
/// 12968-event session: ~320ms per 2000-event chunk, so four chunks keep a call
/// near 1.3s — well inside the 8s host-call budget and short enough not to hold
/// the connector's single inbound chain for long (spec 007 FR-019).
export const SEARCH_CHUNK = 2000
export const MAX_SEARCH_CHUNKS_PER_CALL = 4
export const DEFAULT_SEARCH_LIMIT = 50
/// 查询下限：**1 个字符**（owner 2026-10-17 决定）。
///
/// 原来卡在 2 个字，理由是「一个字几乎命中整段历史、翻不完」。这个代价在 2026-10-17
/// 变成可接受：搜索有了分页与片数进度（`search-progress`，界面显示「已扫 k/N 片」），
/// 一页仍只回 50 条、一次调用仍最多扫 4 块（≈1.3 秒），所以下限降到 1。
///
/// 仍然拒绝的是**空关键词且没带 roles**：那不是搜索，是一次没有范围的全表扫描
/// （「浏览我的提问」必须带 roles，见 `browsing`）。
export const MIN_QUERY_LENGTH = 1

function idOfAddress(address) {
  if (address === null || typeof address !== 'object') return undefined
  if (address.kind === 'session') return typeof address.sessionId === 'string' ? address.sessionId : undefined
  if (address.kind === 'subagent') {
    return typeof address.childSessionId === 'string' ? address.childSessionId : undefined
  }
  return undefined
}

/// Validate the optional `roles` argument: unknown values would silently match
/// nothing, so the caller gets a bad-request instead of an empty page.
const KNOWN_ROLES = new Set(['me', 'agent', 'tool'])

function parseRoles(value) {
  if (value === undefined) return { roles: undefined }
  if (!Array.isArray(value) || value.length === 0) return { roles: undefined }
  const roles = new Set(value)
  for (const role of roles) {
    if (!KNOWN_ROLES.has(role)) {
      return { error: failure('gateway/bad-request', `unknown role "${String(role)}"`) }
    }
  }
  return { roles }
}

/// A hit snippet with the highlight offsets the phone's list already renders.
///
/// Offsets, not ranges: the value crosses the wire and a character offset stays
/// meaningful on the other side.
function makeSnippet(text, query, radius = 36) {
  const haystack = String(text ?? '')
  const at = haystack.toLowerCase().indexOf(query.toLowerCase())
  if (at < 0) {
    const head = haystack.slice(0, radius * 2).replace(/\s+/g, ' ').trim()
    return { snippet: head, highlightStart: 0, highlightLength: 0 }
  }
  const start = Math.max(0, at - radius)
  const end = Math.min(haystack.length, at + query.length + radius)
  const snippet = haystack.slice(start, end).replace(/\s+/g, ' ').trim()
  // Re-find the match inside the flattened snippet so the offsets line up with
  // what is actually displayed.
  const flatAt = snippet.toLowerCase().indexOf(query.toLowerCase())
  return {
    snippet,
    highlightStart: flatAt < 0 ? 0 : flatAt,
    highlightLength: flatAt < 0 ? 0 : query.length,
  }
}

function failure(code, message, details = {}) {
  return { ok: false, error: { code, message, details } }
}

/// 搜索命中项按契约只带 `seq`/`role`/`snippet`（不带记录本身），所以今天**没有**
/// 宿主日志可删。这里仍然逐条过一遍清洗：万一将来命中项带上记录（例如为了跳转
/// 预取），它就不会成为那条绕过统一口径的旁路。
function trimHitsForWire(hits) {
  return hits.map((hit) => (hit?.record === undefined ? hit : trimRecordForWire(hit)))
}

/// Map a thrown Host/gateway error onto the contract's codes.
function hostFailure(error) {
  const message = messageOf(error)
  if (/timed out after/.test(message)) return failure('link/timeout', message)
  if (/not found|no such session/i.test(message)) return failure('session/unknown', message)
  return failure('gateway/failed', message)
}

/**
 * @param {{ logger?: { warn?: Function, info?: Function } }} deps
 */
export function createHistoryService({ logger = console } = {}) {
  let sessionQuery
  /// 会话日志快照（只给**按角色过滤**的读取用）：一个会话读一次整份、本地过滤、短 TTL。
  /// 它把"每条命中一次宿主调用"那道墙去掉——灌库一个会话从十几次往返变成一次读。
  const snapshots = createSnapshotCache({
    readSession: (sessionId) => withTimeout(sessionQuery.readSession(sessionId), HOST_CALL_TIMEOUT_MS, 'readSession'),
  })
  /// Set to false after the Host has told us its full-text index is closed
  /// (`openAt: "never"`), so later searches go straight to the scan.
  let indexSearchable = true
  const inFlight = new Set()
  const lastSeqCache = new Map()

  /// The log's newest seq, cached briefly: it is only needed to clamp a request
  /// that runs past the end (a session can be trimmed between two pages).
  async function newestSeq(sessionId) {
    const cached = lastSeqCache.get(sessionId)
    if (cached !== undefined && Date.now() - cached.at < 5000) return cached.seq
    const records = await withTimeout(sessionQuery.listEvents(sessionId), HOST_CALL_TIMEOUT_MS, 'listEvents')
    const seq = records.length > 0 ? records[records.length - 1].seq : -1
    lastSeqCache.set(sessionId, { at: Date.now(), seq })
    return seq
  }

  /// One exact backward window ending at `seq` (inclusive).
  ///
  /// `clamped` is reported upward: when the session was trimmed, the page cannot
  /// abut the phone's window, and the phone needs to know that the gap is the
  /// log's doing rather than a hole it should treat as a bug (FR-002/FR-041).
  async function readChunk(sessionId, seq) {
    try {
      const window = await withTimeout(
        sessionQuery.readEvent({ sessionId, seq, before: WINDOW_CHUNK, after: 0 }),
        HOST_CALL_TIMEOUT_MS,
        'readEvent',
      )
      return { window, clamped: false }
    } catch (error) {
      // Past the end of a trimmed log: clamp once and retry, never guess.
      if (!/has no event at seq/.test(messageOf(error))) throw error
      const newest = await newestSeq(sessionId)
      if (newest < 0 || newest >= seq) throw error
      lastSeqCache.delete(sessionId)
      const window = await withTimeout(
        sessionQuery.readEvent({ sessionId, seq: newest, before: WINDOW_CHUNK, after: 0 }),
        HOST_CALL_TIMEOUT_MS,
        'readEvent(clamped)',
      )
      return { window, clamped: true }
    }
  }

  /**
   * 一个 seq 段的**消息类文档**（`filterEvents`）：比 `readEvent` 每块 51 条快约 20 倍/seq，
   * 但只回消息类事件（user/assistant/tool 那一族）——角色过滤要的正是这些。
   *
   * 宿主没挂这个接口时（老宿主）回 undefined，`window()` 会退回原来的分块扫描。
   */
  async function readFilterChunk(sessionId, from, to) {
    if (typeof sessionQuery?.filterEvents !== 'function') return undefined
    const docs = await withTimeout(
      sessionQuery.filterEvents(sessionId, [{ kind: 'seq', from, to }]),
      HOST_CALL_TIMEOUT_MS,
      'filterEvents(window)',
    )
    return { docs: Array.isArray(docs) ? docs : [] }
  }

  /// One page of in-session literal search (spec 007 FR-010…FR-012).
  ///
  /// Preferred path is the Host's indexed `searchEvents`; this deployment ships it
  /// disabled (`openAt: "never"`), so the working path is a bounded scan: chunks of
  /// `SEARCH_CHUNK` seqs, filtered by seq range **and** the literal text, newest
  /// first. Each call scans at most `MAX_SEARCH_CHUNKS_PER_CALL` chunks and hands
  /// back a cursor, so "keep looking older" is the reader's next request rather
  /// than one call that holds the tunnel.
  async function find(args) {
    const sessionId = idOfAddress(args.address)
    if (sessionId === undefined) return failure('gateway/bad-request', 'address must name a session')
    const query = typeof args.query === 'string' ? args.query.trim() : ''
    const roles = Array.isArray(args.roles) && args.roles.length > 0 ? new Set(args.roles) : undefined
    // 浏览模式：**没有关键词但带了 roles**（读者要看"我问过的全部提问"）。
    // 这时不按文本过滤，只按 seq 段扫，按角色筛。
    const browsing = query.length === 0 && roles !== undefined
    if (!browsing && query.length < MIN_QUERY_LENGTH) {
      return failure('link/query-too-short',
        `query must be at least ${MIN_QUERY_LENGTH} character (or pass roles to browse)`)
    }
    const limit = Number.isSafeInteger(Number(args.limit)) && Number(args.limit) > 0
      ? Math.min(Number(args.limit), 200) : DEFAULT_SEARCH_LIMIT
    // Advanced knob (also used by the measurement route and the tests): a smaller
    // chunk makes the cursor path reachable on short sessions. Clamped, never 0.
    const chunk = Number.isSafeInteger(Number(args.chunk)) && Number(args.chunk) > 0
      ? Math.min(Number(args.chunk), SEARCH_CHUNK) : SEARCH_CHUNK
    const key = `find:${sessionId}`
    if (inFlight.has(key)) return failure('link/busy', 'another search is in flight for this session')
    inFlight.add(key)
    try {
      // Fast path when the deployment has the index open. One attempt, and a
      // refusal is remembered: the scan below is the path that always works.
      if (indexSearchable && args.cursor === undefined && typeof sessionQuery.searchEvents === 'function') {
        try {
          const page = await withTimeout(
            sessionQuery.searchEvents({ sessionId, query, limit }),
            HOST_CALL_TIMEOUT_MS,
            'searchEvents',
          )
          const indexed = (page.items ?? [])
            .map((item) => {
              const role = roleOf(item)
              if (roles !== undefined && (role === undefined || !roles.has(role))) return undefined
              const display = displayRoleOf(item)
              if (display === undefined) return undefined
              return { seq: item.seq, role: display, ...makeSnippet(item.snippet ?? item.text ?? '', query) }
            })
            .filter(Boolean)
          return {
            ok: true,
            value: {
              hits: trimHitsForWire(indexed),
              cursor: page.hasMore === true && page.cursor !== undefined ? String(page.cursor) : null,
              hasMore: page.hasMore === true,
              source: 'index',
            },
          }
        } catch (error) {
          indexSearchable = false
          logger.info?.(`mobile-link: full-text index unavailable, scanning instead: ${messageOf(error)}`)
        }
      }
      const from = parseSearchCursor(args.cursor)
      // `newestSeq` also carries the progress denominator below; it is cached for
      // 5s, and a scan would have fetched it anyway on the first page.
      const newest = await newestSeq(sessionId)
      // 游标是上一页留下的 seq，可能**越过**当前最新（日志被裁剪过、或手机拿着旧游标回来）。
      // 越界时不夹住的话，扫描会从一个不存在的 seq 往下空跑满 4 块，`remainingChunks`
      // 还会算出比 `totalChunks` 更大的数（实测 996/2），界面的"已扫 k/N"随即变成假的。
      const cursorSeq = from !== undefined && newest >= 0 ? Math.min(from, newest) : from
      const ceiling = cursorSeq !== undefined ? cursorSeq : newest
      // 片数（进度的分母）：由日志最新 seq 算出，与游标无关，所以第一页就是精确的。
      const total = newest >= 0 ? Math.floor(newest / chunk) + 1 : 0
      const hits = []
      let to = ceiling
      let scanned = 0
      while (to >= 0 && hits.length < limit && scanned < MAX_SEARCH_CHUNKS_PER_CALL) {
        const chunkFrom = Math.max(0, to - chunk + 1)
        const filters = [{ kind: 'seq', from: chunkFrom, to }]
        if (!browsing) filters.push({ kind: 'text', text: query })
        const docs = await withTimeout(
          sessionQuery.filterEvents(sessionId, filters),
          HOST_CALL_TIMEOUT_MS,
          'filterEvents(search)',
        )
        scanned += 1
        // Newest first inside the chunk: the reader asked about something recent
        // far more often than about something old.
        for (let index = docs.length - 1; index >= 0; index -= 1) {
          const doc = docs[index]
          // **已知局限**：这里只能按文档判角色，而宿主的 `filterEvents` 文档不带 `data.source`，
          // 所以 `roles:['me']` 会把 `source.kind = "agent-instructions"` 这类**注入消息**也算进来
          // （真机实测：AGENTS.md 注入那条被判成 me）。窗口路径（`_link/sessionWindow`）已改成
          // 取回原始事件后复判，这里没有原始事件、逐条回读的代价又太大（50 条命中 ≈ 11 秒），
          // 因此保留现状并在 `session-search` 的说明里标注：**角色过滤对注入消息不可靠**。
          // App 侧「只看我的提问」自 T040 起走本地库，不走这条路；要恢复这条能力需先让宿主
          // 在文档里带上 `data.source`。
          const role = roleOf(doc)
          if (roles !== undefined && (role === undefined || !roles.has(role))) continue
          const display = displayRoleOf(doc)
          if (display === undefined) continue
          hits.push({ seq: doc.seq, role: display, ...(query.length > 0
            ? makeSnippet(doc.text, query)
            : { snippet: String(doc.text ?? '').slice(0, 72).replace(/\s+/g, ' ').trim(),
                highlightStart: 0, highlightLength: 0 }) })
          if (hits.length >= limit) break
        }
        to = chunkFrom - 1
      }
      const hasMore = to >= 0 && hits.length >= limit ? true : to >= 0
      return {
        ok: true,
        value: {
          hits: trimHitsForWire(hits),
          cursor: hasMore ? String(to) : null,
          hasMore,
          scannedChunks: scanned,
          // 进度：片数是**扫描单位**（一段 `chunk` 个 seq，从新往旧），不是命中页数。
          // `totalChunks` 由日志最新 seq 算出，所以从第一页起就是精确的；命中的**条数**
          // 仍然要扫到最早那一片才定稿（不开宿主全文索引的必然结果）。
          totalChunks: total,
          // 剩余片数不可能多于总片数：越界游标、被裁剪的日志都不该让进度超过 100%。
          remainingChunks: to >= 0 ? Math.min(Math.floor(to / chunk) + 1, total) : 0,
          source: 'scan',
        },
      }
    } catch (error) {
      logger.warn?.(`mobile-link: sessionFind failed: ${messageOf(error)}`)
      return hostFailure(error)
    } finally {
      inFlight.delete(key)
    }
  }

  /// The cursor is the next `to` seq — opaque to the phone, validated here.
  function parseSearchCursor(cursor) {
    if (typeof cursor !== 'string' || cursor.length === 0) return undefined
    const value = Number(cursor)
    return Number.isSafeInteger(value) && value >= 0 ? value : undefined
  }

  async function window(args) {
    const sessionId = idOfAddress(args.address)
    const before = Number(args.before)
    if (sessionId === undefined) return failure('gateway/bad-request', 'address must name a session')
    if (!Number.isSafeInteger(before) || before < 0) return failure('gateway/bad-request', 'before must be a non-negative integer')
    const limit = Number.isSafeInteger(Number(args.limit)) && Number(args.limit) > 0 ? Number(args.limit) : DEFAULT_LIMIT
    const maxBytes = Number.isSafeInteger(Number(args.maxBytes)) && Number(args.maxBytes) > 0
      ? Number(args.maxBytes) : DEFAULT_MAX_BYTES
    const through = Number.isSafeInteger(Number(args.through)) ? Number(args.through) : undefined
    // Optional role filter (spec 009 T031): e.g. `roles: ["me"]` returns only
    // the caller's own questions. Filtering affects **which records come back,
    // never the cursor**: the window is still read as contiguous seqs and
    // `before` still bounds the newest edge exactly. Since T039 a filtered page
    // also carries `scanBoundary` (see history/window.js) so a caller can keep
    // moving when a whole page is filtered empty.
    const { roles, error: rolesError } = parseRoles(args.roles)
    if (rolesError) return rolesError

    const key = `window:${sessionId}`
    if (inFlight.has(key)) return failure('link/busy', 'another window read is in flight for this session')
    inFlight.add(key)
    try {
      // 按角色过滤时走"先定位命中 seq、再定向取完整记录"（spec 016 的"来回次数"一条）：
      // 同样一段日志，过滤路径实测从 2.5–4.1 s 降到数百毫秒；未过滤的浏览翻页保持原样
      // （它要的是精确的一段原始事件，`readEvent` 每块 51 条正合适）。
      const useFilterScan = roles !== undefined && typeof sessionQuery?.filterEvents === 'function'
      // 三级：① 角色过滤 + 宿主能整份读 → 从快照出（一次读、之后每页零往返）；
      //       ② 角色过滤但快照不可用（没有 readSession / 太大 / 读失败）→ A1 的分块定位；
      //       ③ 不带角色 → 原来的分块扫描（浏览翻页要的是精确的一段原始事件）。
      const snapshot = roles !== undefined && typeof sessionQuery?.readSession === 'function'
        ? await snapshots.get(sessionId)
        : undefined
      const scan = snapshot !== undefined
        ? scanSnapshot(snapshot, { before, through, limit, maxBytes, roles, roleOf })
        : useFilterScan
          ? await filteredScan({
              readFilterChunk, readRecords: readChunk, newestSeq, sessionId, before, through, limit,
              roles, roleOf,
            })
          : await scanOlder({ readChunk, sessionId, before, through, limit, maxBytes, roles })
      const page = pageFrom(scan, { limit, maxBytes, roles })
      // 016：下发前统一清掉只用于诊断的宿主模型输出日志（口径只有一份，
      // 见 specs/016-history-load-perf/contracts/history-record-trim.md）。
      return { ok: true, value: { ...page, records: trimRecordsForWire(page.records) } }
    } catch (error) {
      logger.warn?.(`mobile-link: sessionWindow failed: ${messageOf(error)}`)
      return hostFailure(error)
    } finally {
      inFlight.delete(key)
    }
  }

  return {
    /// Called from an optional injection; absent on Hosts that predate the service.
    bindQuery(service) {
      sessionQuery = service
      logger.info?.('mobile-link: history service bound to ctx.sessionQuery')
    },
    get available() {
      return sessionQuery !== undefined
    },

    /// Frame handler for the two methods.
    async handle(method, args = {}) {
      if (sessionQuery === undefined) {
        return failure('link/unsupported', 'this Host does not expose the session query service')
      }
      if (method === WINDOW_METHOD) return window(args)
      if (method === FIND_METHOD) return find(args)
      return failure('link/unknown-method', String(method))
    },

  }
}
