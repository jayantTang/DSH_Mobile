/**
 * 哪些会话值得提醒手机（SR-02.08 / SR-02.15）。
 *
 * 只有**正式会话**算数：属于某个工作区、未归档、且不是子会话。未分组、子会话与
 * 已归档会在列表里以行、桶头或转写出现，但它们不该让手机弹窗，也不该进顶部的
 * 「等你回应」计数——一个子智能体跑完或停下来问问题，不是用户要处理的事。
 *
 * 判据全部来自宿主自己的账本，不做目录推断：
 * - 子会话：`Session.header.origin === 'subagent'`（历史 fork 也可能有
 *   `parentSession`，所以只认 `origin`，与 `@deepseek-ai/dsh-session` 的分类口径一致）；
 * - 归档：`workspaceRegistry.archivedSessionIds`；
 * - 属于工作区：某个 `Workspace.sessionIds` 里含这个 id。
 *
 * 服务没绑上时返回 `true`（保持旧行为）：拿不到宿主账本就断言"非正式"会把正式会话的
 * 提醒一起吞掉。两种失败模式里，漏一条提醒比整类提醒消失更容易被发现。
 */

function sessionFrom(sessions, sessionId) {
  if (typeof sessions?.get === 'function') {
    try {
      const found = sessions.get(sessionId)
      if (found !== undefined && found !== null) return found
    } catch {
      // 会话在枚举与读取之间消失：交给下面的 list 兜底。
    }
  }
  if (typeof sessions?.list !== 'function') return undefined
  try {
    const listed = sessions.list()
    if (!Array.isArray(listed)) return undefined
    return listed.find((entry) => (entry?.id ?? entry?.sessionId) === sessionId)
  } catch {
    return undefined
  }
}

function archivedIds(workspaces) {
  try {
    const ids = workspaces?.archivedSessionIds
    return Array.isArray(ids) ? ids : []
  } catch {
    // 账本还没装好：按"没有归档"处理，不让一次读失败吞掉全部提醒。
    return []
  }
}

function workspaceMembers(workspaces) {
  try {
    const listed = workspaces?.list?.()
    return Array.isArray(listed) ? listed : undefined
  } catch {
    return undefined
  }
}

/**
 * @param {{
 *   sessions?: { get?: (id: string) => object | undefined, list?: () => object[] },
 *   workspaces?: {
 *     archivedSessionIds?: readonly string[],
 *     list?: () => Array<{ sessionIds?: readonly string[] }>,
 *   },
 * }} [services]
 * @returns {{ isFormal: (sessionId: string) => boolean }}
 */
export function createSessionScope({ sessions, workspaces } = {}) {
  const canReadSessions = typeof sessions?.get === 'function' || typeof sessions?.list === 'function'
  const canReadWorkspaces = typeof workspaces?.list === 'function'
  const available = canReadSessions && canReadWorkspaces

  function isFormal(sessionId) {
    if (typeof sessionId !== 'string' || sessionId === '') return false
    // 宿主服务还没绑上：保持旧行为，见文件头。
    if (!available) return true

    const session = sessionFrom(sessions, sessionId)
    if (session === undefined) return false
    if ((session?.header?.origin ?? session?.origin) === 'subagent') return false
    if (archivedIds(workspaces).includes(sessionId)) return false
    const members = workspaceMembers(workspaces)
    // 工作区账本读不出来：无法判定，维持旧行为，别把整类提醒一起吞掉。
    if (members === undefined) return true
    return members.some((workspace) => (
      Array.isArray(workspace?.sessionIds) && workspace.sessionIds.includes(sessionId)
    ))
  }

  return { isFormal }
}
