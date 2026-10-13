/**
 * 诊断包的自动判读（spec 020 的 US9 / FR-029–FR-031）。
 *
 * 为什么要它：这套能力的用途是"下次不用再像第一次那样逐条看"。第一次现场诊断（2026-10-13）
 * 花了很久才从流水里读出"手机侧处理 9.6 秒、连接器只用 246 ms 就答完了"——那次是靠人肉相减。
 * 规则如果不机器化，每次都要重来一遍，而且**判据会漂**：今天觉得 2 秒算慢，明天可能觉得 5 秒。
 *
 * 两条纪律：
 *   1. **判据只在 `FINDING_THRESHOLDS` 一处**，且可被调用方覆盖；
 *   2. 每条 finding 都要带 `evidence`，指向包内的文件与键——判读不许是黑箱结论。
 *
 * 契约：`specs/020-link-diagnostics/contracts/collect-command.md` §6
 */

/** 判据阈值（唯一一处；调用方可用 `thresholds` 覆盖）。 */
export const FINDING_THRESHOLDS = Object.freeze({
  /** 手机侧处理耗时超过它就算慢。 */
  phoneSlowMs: 2000,
  /** 而且要"比连接器侧慢这么多倍"才算（避免把两边都慢的情形只算到手机头上）。 */
  phoneSlowRatio: 10,
  /** 连接器侧单次接入的处理耗时超过它算慢（默认与连接器的 slowRequestMs 一致）。 */
  connectorSlowMs: 2000,
})

/** 一条 finding。`evidence` 里的字符串要能指到包内文件（人拿它复核）。 */
function finding(id, level, summary, { deviceId = null, evidence = [] } = {}) {
  return { id, level, deviceId, summary, evidence }
}

/**
 * 阶段缺失：某次接入有 `missing`（没发生的那几段）。
 *
 * **只在"这台设备本来有手机侧记录"时算告警**：一台设备一条 `app.*` 都没有，说明它跑的是老构建
 * 或 App 没在跑，那种情况归 `no-dial`（提示级）。否则老构建的每次接入都刷一条告警，
 * 告警刷多了等于没有告警。
 */
export function stageMissingFindings(attaches, appEvents = []) {
  // "这台设备当时在记"的判据：它在本**次接入之后**有过手机侧记录。用"窗口内有过记录"不够——
  // 那样重装/升级之前的那几次接入也会被算成告警（那次是 App 根本没在记）。
  const recording = (attach) => appEvents.some((event) =>
    event.deviceId === attach.deviceId && event.ms >= attach.attachMs)
  const out = []
  for (const attach of attaches) {
    if (!recording(attach)) continue
    const missing = [...(attach.appMissing ?? []), ...(attach.connectorMissing ?? [])]
    if (missing.length === 0) continue
    // 连接器刚重启（插件热更 / dsh 重启）后的重挂：手机没重新拨号，阶段本来就该缺，
    // 这是"半次接入"，不是故障。归提示级，别混进告警里。
    if (attach.afterConnectorRestartMs !== null && attach.afterConnectorRestartMs !== undefined) continue
    out.push(finding('stage-missing', 'warn',
      `接入 ${attach.attachAt.slice(11, 19)} 缺阶段：${[...new Set(missing)].join(' / ')}（没发生，不是 0）`,
      { deviceId: attach.deviceId, evidence: [`attaches.jsonl#${attach.deviceId}@${attach.attachAt}`] }))
  }
  return out
}

/** 双 socket：同一设备出现"又开一条"（连接器侧 `device.attach-again` 或中转侧 `device-replaced`）。 */
export function duplicateSocketFindings(connectorEvents, relayEvents) {
  const byDevice = new Map()
  const bump = (deviceId, kind, ms) => {
    if (!deviceId) return
    if (!byDevice.has(deviceId)) byDevice.set(deviceId, [])
    byDevice.get(deviceId).push({ kind, ms })
  }
  for (const event of connectorEvents) {
    if (event.kind === 'device.attach-again') bump(event.deviceId, 'attach-again', event.ms)
  }
  for (const event of relayEvents) {
    if (event.kind === 'relay.device-replaced') bump(event.deviceId, 'replaced', event.ms)
  }
  const out = []
  for (const [deviceId, hits] of byDevice) {
    const kinds = hits.map((hit) => hit.kind)
    out.push(finding('duplicate-socket', 'warn',
      `设备在旧 socket 还活着时又开了一条：连接器侧 attach-again ${kinds.filter((k) => k === 'attach-again').length} 次、`
      + `中转侧 replaced ${kinds.filter((k) => k === 'replaced').length} 次`,
      { deviceId, evidence: hits.map((hit) => `sources/connector.jsonl#${deviceId}@${new Date(hit.ms).toISOString()}`) }))
  }
  return out
}

/** 手机侧慢：`phoneHandlingMs` 超过阈值、且比连接器侧慢出倍数。 */
export function phoneSlowFindings(attaches, thresholds) {
  const out = []
  for (const attach of attaches) {
    const phone = attach.phoneHandlingMs
    const connector = attach.connectorHandlingMs
    if (typeof phone !== 'number' || phone <= thresholds.phoneSlowMs) continue
    const ratio = typeof connector === 'number' && connector > 0 ? phone / connector : Infinity
    if (ratio < thresholds.phoneSlowRatio) continue
    const bytes = attach.appStages?.firstResponseMs === null ? null : attach.appBytes
    out.push(finding('phone-slow', 'warn',
      `手机侧处理用了 ${phone} ms，连接器侧只用 ${connector ?? '?'} ms`
      + (bytes ? `（响应 ${Math.round(bytes / 1024)} KiB）` : ''),
      { deviceId: attach.deviceId, evidence: [`attaches.jsonl#${attach.deviceId}@${attach.attachAt}`] }))
  }
  return out
}

/** 连接器侧慢：单次接入的处理耗时超过阈值，或窗口内有 `request.slow`。 */
export function connectorSlowFindings(attaches, connectorEvents, thresholds) {
  const out = []
  for (const attach of attaches) {
    if (typeof attach.connectorHandlingMs !== 'number') continue
    if (attach.connectorHandlingMs <= thresholds.connectorSlowMs) continue
    out.push(finding('connector-slow', 'warn',
      `连接器处理这次请求用了 ${attach.connectorHandlingMs} ms（阈值 ${thresholds.connectorSlowMs} ms）`,
      { deviceId: attach.deviceId, evidence: [`attaches.jsonl#${attach.deviceId}@${attach.attachAt}`] }))
  }
  const slow = connectorEvents.filter((event) => event.kind === 'request.slow')
  if (slow.length > 0) {
    const devices = [...new Set(slow.map((event) => event.deviceId))]
    out.push(finding('connector-slow', 'warn',
      `窗口内有 ${slow.length} 条超过阈值的单次请求（最慢 ${Math.max(...slow.map((event) => event.elapsedMs ?? 0))} ms）`,
      { deviceId: devices[0] ?? null, evidence: ['sources/connector.jsonl#request.slow'] }))
  }
  return out
}

/** 链路异常关闭：`link.close.reason` 带 1006，或留下了 `socketError`。 */
export function linkAbnormalFindings(connectorEvents) {
  const out = []
  for (const event of connectorEvents) {
    if (event.kind !== 'link.close') continue
    const reason = String(event.reason ?? '')
    const abnormal = /1006/.test(reason) || Boolean(event.socketError)
    if (!abnormal) continue
    out.push(finding('link-closed-abnormally', 'warn',
      `链路异常关闭：${reason}${event.socketError ? `（系统错误：${event.socketError}）` : '（没有系统错误文本）'}`,
      { evidence: [`sources/connector.jsonl#link.close@${event.at ?? ''}`] }))
  }
  return out
}

/** 没拨号：窗口内有接入记录，但该设备一条 `app.*` 都没有（老构建或 App 没在跑）。按设备汇总一条。 */
export function noDialFindings(attaches, appEvents) {
  const recording = (attach) => appEvents.some((event) =>
    event.deviceId === attach.deviceId && event.ms >= attach.attachMs)
  const counted = new Map()
  for (const attach of attaches) {
    if (recording(attach)) continue
    counted.set(attach.deviceId, (counted.get(attach.deviceId) ?? 0) + 1)
  }
  return [...counted].map(([deviceId, count]) => finding('no-dial', 'info',
    `${count} 次接入在它之后没有任何手机侧记录（老构建、App 没在跑，或重装/升级前后）`
    + `——"没拨号"这类问题要等它升到会记录的构建才能归因`,
    { deviceId, evidence: [`attaches.jsonl#${deviceId}`] }))
}

/** 连接器重启后的重挂：手机没重新拨号，阶段本来就缺。提示级，用来解释"为什么这次接入不全"。 */
export function connectorRestartFindings(attaches) {
  const out = []
  for (const attach of attaches) {
    const delta = attach.afterConnectorRestartMs
    if (delta === null || delta === undefined) continue
    out.push(finding('connector-restart', 'info',
      `接入发生在连接器重启后 ${Math.round(delta / 1000)} 秒（插件热更或 dsh 重启）：手机没有重新拨号，`
      + `阶段缺失是预期的`,
      { deviceId: attach.deviceId, evidence: [`attaches.jsonl#${attach.deviceId}@${attach.attachAt}`] }))
  }
  return out
}

/** 采集范围：中转切片里被排除的条数（收窄生效的如实记账）。 */
export function collectorScopeFindings(coverage) {
  const relay = coverage?.relay
  if (!relay) return []
  const excluded = (relay.excludedOtherAgent ?? 0) + (relay.excludedUnknownDevice ?? 0)
  if (excluded === 0) return []
  return [finding('collector-scope', 'info',
    `中转切片按设备收窄：保留 ${relay.kept ?? 0} 条，排除别的账号 ${relay.excludedOtherAgent ?? 0} 条、`
    + `归属不明 ${relay.excludedUnknownDevice ?? 0} 条（已知本机设备 ${relay.knownDevices ?? 0} 台）`,
    { evidence: ['coverage.json#relay'] })]
}

/**
 * 汇总所有规则。`level: 'warn'` 的条目要出现在 README 顶部。
 *
 * @param {{attaches?: Array, connectorEvents?: Array, appEvents?: Array, relayEvents?: Array,
 *          coverage?: object, thresholds?: object}} input
 * @returns {Array<{id: string, level: string, deviceId: string|null, summary: string, evidence: string[]}>}
 */
export function buildFindings({
  attaches = [], connectorEvents = [], appEvents = [], relayEvents = [], coverage = null,
  thresholds = {},
} = {}) {
  const limits = { ...FINDING_THRESHOLDS, ...thresholds }
  const findings = [
    ...stageMissingFindings(attaches, appEvents),
    ...duplicateSocketFindings(connectorEvents, relayEvents),
    ...phoneSlowFindings(attaches, limits),
    ...connectorSlowFindings(attaches, connectorEvents, limits),
    ...linkAbnormalFindings(connectorEvents),
    ...noDialFindings(attaches, appEvents),
    ...connectorRestartFindings(attaches),
    ...collectorScopeFindings(coverage),
  ]
  for (const attach of attaches) {
    if (!attach.phoneHandlingNegative) continue
    findings.push(finding('stage-missing', 'info',
      `手机侧处理耗时算出来是负数——对齐或归属可能配错了（接入 ${attach.attachAt.slice(11, 19)}）`,
      { deviceId: attach.deviceId, evidence: [`attaches.jsonl#${attach.deviceId}@${attach.attachAt}`] }))
  }
  return findings
}

/** 一句话结论：哪一侧慢（给 README 顶部用）。 */
export function slowSideSummary(attaches) {
  const rows = attaches.filter((attach) => typeof attach.phoneHandlingMs === 'number')
  if (rows.length === 0) return null
  let worst = null
  for (const attach of rows) {
    const ratio = attach.connectorHandlingMs > 0 ? attach.phoneHandlingMs / attach.connectorHandlingMs : Infinity
    if (worst === null || ratio > worst.ratio) worst = { attach, ratio }
  }
  const phone = worst.attach.phoneHandlingMs
  const connector = worst.attach.connectorHandlingMs
  if (worst.ratio >= FINDING_THRESHOLDS.phoneSlowRatio && phone > FINDING_THRESHOLDS.phoneSlowMs) {
    return `最慢的一次接入慢在**手机侧**：手机 ${phone} ms vs 连接器 ${connector} ms（最后一次接入 ${worst.attach.attachAt.slice(11, 19)}）`
  }
  return `最慢的一次接入两侧都在同一量级：手机 ${phone} ms vs 连接器 ${connector} ms（${worst.attach.attachAt.slice(11, 19)}）`
}
