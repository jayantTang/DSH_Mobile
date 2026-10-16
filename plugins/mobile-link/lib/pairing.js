/**
 * Pairing helper: ask the relay to mint a pairing code and build the QR payload
 * the desktop shows. Spec §2.1 plus docs/RELAY-NOTES.md §2 (the endpoint the spec's
 * table is missing).
 *
 * 032：默认铸**持久码**（不过期，直到用户点「重新生成」）。传 `ttlMs` 仍然得到一张
 * 限时码——那是老行为，留给还用它的调用方与老测试。
 */

import { pairCodeEndpoint, pairCodeRegenerateEndpoint, qrPayload } from './dlp.js'

/**
 * @param {object} options
 * @param {{agentId: string, agentSecret: string, relayUrl: string}} options.identity
 * @param {number|null} [options.ttlMs] requested lifetime; `null`/省略 = 持久码
 * @param {typeof fetch} [options.fetchImpl] injectable for tests
 */
export async function mintPairCode({ identity, ttlMs = null, fetchImpl = fetch }) {
  // 032：**持久码那条路不能把 `ttlMs` 放进请求体**。中转的判据是 `"ttlMs" not in body`
  // （`relay/api.py` 的 `pair_code`）：带一个 `ttlMs: null` 会被读成"限时、但没给时长"，
  // 于是落到中转的默认 10 分钟——面板显示倒计时，码十分钟后就废（用户看到的就是这个）。
  const payload = ttlMs == null
    ? { agentId: identity.agentId }
    : { agentId: identity.agentId, ttlMs }
  const response = await fetchImpl(pairCodeEndpoint(identity.relayUrl), {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      authorization: `Bearer ${identity.agentSecret}`,
    },
    body: JSON.stringify(payload),
  })
  let body
  try {
    body = await response.json()
  } catch {
    throw new Error(`relay returned HTTP ${response.status} for /pair/code`)
  }
  if (!response.ok || body?.ok !== true) {
    throw new Error(body?.error?.message ?? `relay rejected the pairing request (HTTP ${response.status})`)
  }
  return {
    code: body.code,
    expiresAt: body.expiresAt ?? null,
    ttlMs: body.ttlMs ?? ttlMs ?? null,
    persistent: body.persistent === true || body.expiresAt == null,
    // 「已配对 N/8」以中转的库为准：连接器只知道自己这次见过的设备。
    maxPairedDevices: Number(body.maxPairedDevices ?? 0) || null,
    pairedDevices: Number(body.pairedDevices ?? 0),
    relayUrl: identity.relayUrl,
    agentId: identity.agentId,
    qrPayload: qrPayload({ relay: identity.relayUrl, code: body.code }),
  }
}

/**
 * 用户点「重新生成」：让中转作废旧码、铸一枚新的。
 *
 * **不碰已配对的设备**（032 FR-002）：那台手机/浏览器靠自己的 deviceToken 活着，
 * 换码只影响"还没来配的人"。所以这个动作可以放心点，不需要提醒"会把手机踢下线"。
 */
export async function regeneratePairCode({ identity, fetchImpl = fetch }) {
  const response = await fetchImpl(pairCodeRegenerateEndpoint(identity.relayUrl), {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      authorization: `Bearer ${identity.agentSecret}`,
    },
    body: JSON.stringify({ agentId: identity.agentId }),
  })
  let body
  try {
    body = await response.json()
  } catch {
    throw new Error(`relay returned HTTP ${response.status} for /pair/code/regenerate`)
  }
  if (!response.ok || body?.ok !== true) {
    throw new Error(body?.error?.message ?? `relay refused the regeneration (HTTP ${response.status})`)
  }
  return {
    code: body.code,
    expiresAt: null,
    ttlMs: null,
    persistent: true,
    revoked: Number(body.revoked ?? 0),
    maxPairedDevices: Number(body.maxPairedDevices ?? 0) || null,
    pairedDevices: Number(body.pairedDevices ?? 0),
    relayUrl: identity.relayUrl,
    agentId: identity.agentId,
    qrPayload: qrPayload({ relay: identity.relayUrl, code: body.code }),
  }
}
