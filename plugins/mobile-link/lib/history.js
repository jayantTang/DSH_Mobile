import { HOST_CALL_TIMEOUT_MS, withTimeout, messageOf } from './history/shared.js'
import { sliceRangeSafe, truncateSafe } from './unicode.js'
import {
  DEFAULT_LIMIT, DEFAULT_MAX_BYTES, WINDOW_CHUNK,
  bytesOfRecords, displayRoleOf, roleOf, toRecord, trimRecordForWire, trimRecordsForWire,
} from './history/records.js'
import { pageFrom, scanOlder } from './history/window.js'
import { filteredScan } from './history/filter-scan.js'
import { createSnapshotCache, scanSnapshot, snapshotOlderReader } from './history/session-snapshot.js'
import {
  HISTORY_COMPRESSION_CAPABILITY, maybeCompressHistoryValue,
} from './history/compress.js'
import { FOLD_CAPABILITY, foldProcessRuns } from './history/fold.js'
import { SUMMARY_FOLD_CAPABILITY, SUMMARY_FOLD_MODE } from './history/fold-summary.js'
import { readSummaryPage } from './history/summary-window.js'
import { emptySpans } from './history/coverage.js'

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
  // history-compression: `_link/sessionWindow` 接受 `encoding: "deflate-raw"`，
  // 回包变成 `{encoding, value(base64), rawBytes}`。手机只在看到这条能力时才请求；
  // 老客户端不传 encoding，拿到的仍是纯 JSON。
  HISTORY_COMPRESSION_CAPABILITY,
  // history-fold-summary: `_link/sessionWindow` 接受 `fold: true`，把本页内
  // 已完成的轮次折成一条 `+link/fold` 摘要记录（展开时用不带 fold 的普通窗口取回）。
  FOLD_CAPABILITY,
  // history-fold-summary-v2: `fold: "summary"` —— 概要先行取数模式（设计
  // 20261025 §3.4/M6）。只回讲话 + `+link/fold` v2 概要 + 正式回答，按整轮切页。
  // 独立能力位：老连接器不认识这个值，老客户端也不会传它，两边都没有行为变化。
  SUMMARY_FOLD_CAPABILITY,
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

/// 一条文档里所有可读正文：宿主给的 `text`、`data.text`、`data.content[].text`
/// （blocks 形态，可能**不止一段**）、`data.message.content[].text`，以及工具结果的
/// `output` / `result` / `stdout` / `stderr`。
///
/// 为什么自己做匹配、不把 `{kind:'text'}` 交给宿主：宿主的文本过滤只看它自己认定的那一段，
/// 2026-10-17 真机实测（搜"我"/"的"拿不到全部用户输入）说明会漏掉 `content` 里靠后的部分。
/// 改成"取回这一段全部文档、在这里逐字匹配"之后，命中集合只由我们自己的规则决定。
function docText(doc) {
  const data = doc?.data ?? {}
  const parts = []
  const push = (value) => {
    if (typeof value === 'string' && value.length > 0) parts.push(value)
  }
  push(doc?.text)
  push(data.text)
  for (const blocks of [data.content, data.message?.content]) {
    if (!Array.isArray(blocks)) continue
    for (const block of blocks) push(block?.text)
  }
  for (const key of ['output', 'result', 'stdout', 'stderr']) push(data[key])
  return parts.join('\n')
}

/// A hit snippet with the highlight offsets the phone's list already renders.
///
/// Offsets, not ranges: the value crosses the wire and a character offset stays
/// meaningful on the other side.
function makeSnippet(text, query, radius = 36) {
  const haystack = String(text ?? '')
  const at = haystack.toLowerCase().indexOf(query.toLowerCase())
  if (at < 0) {
    const head = truncateSafe(haystack, radius * 2).replace(/\s+/g, ' ').trim()
    return { snippet: head, highlightStart: 0, highlightLength: 0 }
  }
  const start = Math.max(0, at - radius)
  const end = Math.min(haystack.length, at + query.length + radius)
  const snippet = sliceRangeSafe(haystack, start, end).replace(/\s+/g, ' ').trim()
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
export function createHistoryService({
  logger = console,
  cacheTtlMs = 15_000,
  cacheLimit = 32,
} = {}) {
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
  /// 最近读过的页（spec 016 后续）：回看、回收后再水合、重复请求同一段时不再走网络。
  /// 只缓存"已经结束在 before-1"的页：日志只追加，旧 seq 段的内容不会变；
  /// 会话被裁剪是唯一例外，用短 TTL 兜底（默认 15s）。键里带全部影响结果的参数，
  /// 少一个就可能把过滤页当成浏览页返回。
  const pageCache = new Map()

  /// 缓存键里带**折叠模式**（`none` / `v1` / `summary`）而不是布尔值：三种模式的回包
  /// 形状不同，混用一个键会把概要页当普通页发出去。
  function cacheKey({ sessionId, before, through, limit, maxBytes, roles, foldMode, coverage }) {
    return [sessionId, before, through ?? '', limit, maxBytes,
            roles === undefined ? '' : [...roles].sort().join(','), foldMode,
            coverage === true ? '1' : '0'].join('|')
  }

  function cacheGet(key, now = Date.now()) {
    const hit = pageCache.get(key)
    if (hit === undefined) return undefined
    if (now - hit.at > cacheTtlMs) {
      pageCache.delete(key)
      return undefined
    }
    // 重新插入：Map 的插入序当作 LRU 序，命中也要刷新位置。
    pageCache.delete(key)
    pageCache.set(key, hit)
    return hit.value
  }

  function cachePut(key, value, now = Date.now()) {
    if (cacheLimit <= 0) return
    pageCache.delete(key)
    pageCache.set(key, { at: now, value })
    while (pageCache.size > cacheLimit) {
      const oldest = pageCache.keys().next().value
      pageCache.delete(oldest)
    }
  }

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
      const needle = query.toLowerCase()
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
        // 只按 seq 段取文档；正文匹配在下面自己做（见 `docText` 的头注）。
        const filters = [{ kind: 'seq', from: chunkFrom, to }]
        const docs = await withTimeout(
          sessionQuery.filterEvents(sessionId, filters),
          HOST_CALL_TIMEOUT_MS,
          'filterEvents(search)',
        )
        scanned += 1
        // Newest first inside the chunk: the reader asked about something recent
        // far more often than about something old.
        //
        // **游标必须落在"这一页读到哪儿"**，不能一律跳到整块之前：一页在块中途装满时，
        // 块尾还没读过的文档会被永久跳过——2026-10-17 owner 报的"全局搜索不是用户提问的超集"
        // 就是这条（用户提问正好落在片尾时被吞掉；索引路径不受影响）。
        // `resumeFrom` 默认 = 整块之前（读完这块才成立），中途停下时改成"下一条还没读的 seq"。
        let resumeFrom = chunkFrom - 1
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
          const text = docText(doc)
          if (!browsing && !text.toLowerCase().includes(needle)) continue
          hits.push({ seq: doc.seq, role: display, ...(query.length > 0
            ? makeSnippet(text, query)
            : { snippet: truncateSafe(String(text), 72).replace(/\s+/g, ' ').trim(),
                highlightStart: 0, highlightLength: 0 }) })
          if (hits.length >= limit) {
            // 装满了：这一条已经收进本页，下一页从它的**前一条**继续——不能从整块之前
            // （会丢块尾），也不能从这一条本身（会重复）。
            resumeFrom = doc.seq - 1
            break
          }
        }
        to = resumeFrom
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

  /// 概要 v2 的一页（能力 `history-fold-summary-v2`，`fold: "summary"`）。
  ///
  /// 为什么走**整份快照**：这一页的单位是"整轮"，而一轮可以长达两千级 seq。
  /// 分块回读一次只有 51 条（宿主 `readEvent` 的硬上限），一页要几十次往返；
  /// 快照一次读完整份（本机 13k 事件实测 116–315 ms），之后每页零往返。
  /// 快照不可用（老宿主没 `readSession`、会话超过内存护栏、读失败）时退回分块回读：
  /// 语义不变（仍按整轮、仍不切半轮），只是慢一些，并且在单轮超过回读预算时
  /// 如实回 `link/too-large` 让客户端重试，而不是下发半轮。
  async function summaryWindowValue({ sessionId, before, through, limit, maxBytes }) {
    let snapshot = await snapshots.get(sessionId)
    // 与浏览翻页同一条护栏：快照必须是"这段的上界之内"的。请求上界比快照还新
    // （刚发出去一条消息，或快照刚好过期一瞬）时不能拿旧快照夹上界——那会把
    // 最新的一轮整段漏掉，还谎报 `clamped`（"日志变短了"）。改走实时读。
    if (snapshot !== undefined && before - 1 > snapshot.newestSeq) snapshot = undefined
    let newest = snapshot?.newestSeq
    if (!Number.isInteger(newest)) newest = await newestSeq(sessionId)
    let upper = Math.min(before - 1, through ?? Number.MAX_SAFE_INTEGER)
    let clamped = false
    if (Number.isInteger(newest) && upper > newest) {
      upper = newest
      clamped = true
    }
    const readOlder = snapshot !== undefined
      ? snapshotOlderReader(snapshot)
      : async (cursor) => {
          const { window: result, clamped: chunkClamped } = await readChunk(sessionId, cursor)
          const events = Array.isArray(result.events) ? result.events : []
          const floorSeq = Number.isInteger(result.startSeq) ? result.startSeq : (events[0]?.seq ?? 0)
          return { events, floorSeq, exhausted: floorSeq === 0, clamped: chunkClamped }
        }
    const page = await readSummaryPage({ readOlder, upper, limit, maxBytes, clamped })
    if (page.error !== undefined) return page
    // 字段与普通窗口同形（`startSeq`/`endSeq`/`hasMore`/`truncatedBy`/`clamped`/
    // `scanBoundary`），客户端沿用同一套游标规则即可。**不带 `folds` 副本**：
    // 摘要已经在记录里，再抄一份就是白白多一倍概要字节（设计 §十一 的预算是按一份算的）。
    return {
      records: page.records,
      startSeq: page.startSeq,
      endSeq: page.endSeq,
      hasMore: page.hasMore,
      truncatedBy: page.truncatedBy,
      clamped: page.clamped === true,
      scanBoundary: page.startSeq,
    }
  }

  async function window(args) {
    const sessionId = idOfAddress(args.address)
    const before = Number(args.before)
    if (sessionId === undefined) return failure('gateway/bad-request', 'address must name a session')
    if (!Number.isSafeInteger(before) || before < 0) return failure('gateway/bad-request', 'before must be a non-negative integer')
    // `limit` 的单位随模式变：普通窗口是**记录条数**；概要 v2（`fold: "summary"`）是
    // **轮数**，因为这一模式的页单位就是整轮（字节预算由 `maxBytes` 兜）。客户端按
    // 自己要知道的"首屏几轮"传即可。
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

    // 折叠模式三态：`none`（不传）/ `v1`（`fold: true`）/ `summary`（`fold: "summary"`）。
    // 只有精确的 `"summary"` 切到概要 v2；`fold: true` 与所有其它取值一律按老规矩走，
    // 所以老客户端的回包与改动前逐字节相同（`test/helpers/fold-v1-golden.json`）。
    const summaryFold = args.fold === SUMMARY_FOLD_MODE
    const fold = !summaryFold && args.fold === true
    const foldMode = summaryFold ? 'summary' : fold ? 'v1' : 'none'
    const coverage = args.coverage === true
    // 概要 v2 的语义是"整轮 + 只讲话与概要"：角色过滤会切碎轮次，覆盖区间也按原始
    // 记录算，两者与它拼不到一起。明确拒绝，不静默退回另一种语义（否则回包看起来
    // 正常、内容却是错的）。
    if (summaryFold && (roles !== undefined || coverage)) {
      return failure('gateway/bad-request',
        'fold "summary" cannot be combined with roles or coverage')
    }
    const requestKey = cacheKey({ sessionId, before, through, limit, maxBytes, roles, foldMode, coverage })
    const cachedPage = cacheGet(requestKey)
    if (cachedPage !== undefined) {
      return { ok: true, value: maybeCompressHistoryValue(cachedPage, args.encoding) }
    }

    const key = `window:${sessionId}`
    if (inFlight.has(key)) return failure('link/busy', 'another window read is in flight for this session')
    inFlight.add(key)
    try {
      if (summaryFold) {
        const summary = await summaryWindowValue({ sessionId, before, through, limit, maxBytes })
        if (summary.error !== undefined) return failure(summary.error.code, summary.error.message)
        cachePut(requestKey, summary)
        return { ok: true, value: maybeCompressHistoryValue(summary, args.encoding) }
      }
      // 按角色过滤时走"先定位命中 seq、再定向取完整记录"（spec 016 的"来回次数"一条）：
      // 同样一段日志，过滤路径实测从 2.5–4.1 s 降到数百毫秒；未过滤的浏览翻页保持原样
      // （它要的是精确的一段原始事件，`readEvent` 每块 51 条正合适）。
      const useFilterScan = roles !== undefined && typeof sessionQuery?.filterEvents === 'function'
      // 三级：① 角色过滤 + 宿主能整份读 → 从快照出（一次读、之后每页零往返）；
      //       ② 角色过滤但快照不可用（没有 readSession / 太大 / 读失败）→ A1 的分块定位；
      //       ③ 不带角色 → 原来的分块扫描（浏览翻页要的是精确的一段原始事件）。
      // 未过滤的浏览翻页也走整份快照：本机 13k 会话一次 `readSession` 约 0.3s，
      // 而逐页 `readEvent` 每页都要付一次宿主地板价（实测 300–500ms/页）。
      // 第一次请求仍走实时读（首屏不能等快照），同时在后台预热；之后的更早页命中快照。
      // 只有"请求上界落在快照最新 seq 之内"才用快照——更新的那段必须实时读，
      // 否则刚发出去的消息会被旧快照挡住。
      let snapshot
      if (roles !== undefined) {
        snapshot = typeof sessionQuery?.readSession === 'function'
          ? await snapshots.get(sessionId)
          : undefined
      } else {
        snapshot = snapshots.peek(sessionId)
        if (snapshot === undefined) snapshots.warm(sessionId)
        if (snapshot !== undefined && before - 1 > snapshot.newestSeq) snapshot = undefined
      }
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
      const trimmed = trimRecordsForWire(page.records)
      const folded = fold ? foldProcessRuns(trimmed) : { records: trimmed, folds: [] }
      const value = { ...page, records: folded.records }
      // 已知为空：只覆盖"最老返回记录..窗口上界"。版本取会话最新号；
      // 客户端版本不一致时不采纳（宿主重排号段后旧结论失效）。
      if (coverage) {
        const upper = before - 1
        const lower = Math.max(1, before - limit)
        value.knownEmpty = emptySpans(trimmed, lower, upper)
        value.revision = String(await newestSeq(sessionId))
      }
      // `folds` 只在折叠时出现：老客户端不认识这个字段也不会读它；新客户端没有它
      // 就按普通记录折（老连接器）。
      if (folded.folds.length > 0) value.folds = folded.folds
      cachePut(requestKey, value)
      // 压缩只改回包形态，不改分页语义：解压后逐字段等于不压缩的那份。
      return { ok: true, value: maybeCompressHistoryValue(value, args.encoding) }
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
