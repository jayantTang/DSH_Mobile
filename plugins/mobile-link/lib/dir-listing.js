/**
 * `_link/dirListing`：`workspaceFiles/list` 的同形增强副本，本机补 `mtimeMs`。
 *
 * 为什么要它：宿主 `workspaceFiles/list` 的条目只有 `name/type/size?`（宿主类型见
 * `@deepseek-ai/dsh-api-workspace-files` 的 `WorkspaceDirectoryEntry`），
 * 没有任何时间字段；`workspaceFiles/stat` 的 `version` 是 opaque token（类型注释明确
 * "never parsed"），推不出时间。用户要的是"哪个文件最近被动过"，所以由电脑侧补。
 *
 * 三条纪律（与 `session-digest.js` 同款）：
 *   1. **清单的所有者仍是宿主**：连接器只往条目上加一个字段，不删、不改、不重排；
 *      宿主报错时错误信封逐字透传。
 *   2. **拿不到就原样返回**：root 缺失/相对/越界、单条目 stat 失败、超出总预算——
 *      一律退回未增强的原始清单。装饰永不弄坏清单，目录本身一定能打开。
 *   3. **不提速、不重试**：一个条目最多 stat 一次；没有缓存（mtime 会变，缓存就要失效
 *      逻辑，而列目录本来就是低频动作）。
 *
 * 符号链接用 `fs.stat`（跟随链接）报**目标**的时间——宿主列的 `type`/`size` 本来就是
 * 按目标解析的（类型注释："A symlink reports the type of its destination"），
 * `lstat` 报的链接自身时间只在重指时变化，回答不了"内容什么时候改的"。
 */

import { stat } from 'node:fs/promises'
import { isAbsolute, resolve, sep } from 'node:path'

/** 方法名（设备发起；`_link/` 前缀 = 连接器自答，永不转发宿主）。 */
export const DIR_LISTING_METHOD = '_link/dirListing'

/** 宿主的清单方法：连接器只读它，不改它。 */
const HOST_LIST_METHOD = 'workspaceFiles/list'

/** 可调的上限。`statBudgetMs` 是全部条目补时间的总预算（见 §2.2 失败语义表）。 */
export const LIMITS = Object.freeze({
  statBudgetMs: 2000,
})

export function isDirListingMethod(method) {
  return method === DIR_LISTING_METHOD
}

/**
 * 给一份宿主目录清单补上 `mtimeMs`。
 *
 * 认两种输入形状（与 `digestSessionList` 同款）：宿主信封 `{ ok, value: { entries } }`
 * 以及直接给的 `{ entries }`。**返回的始终是同形状的值**，调用方不必再猜信封在哪一层。
 * 结构不是预期的样子就原样返回入参——装饰不许把"看不懂"变成"改掉"。
 *
 * @param {object} options
 * @param {{ rpc: (method: string, args: object) => Promise<unknown> }} options.dsh 宿主 RPC
 * @param {object} options.args 设备发来的参数（`workspaceFileScopeId` / `path` / `root`）
 * @param {{ debug?: (message: string) => void, warn?: (message: string) => void }} [options.logger]
 * @param {(path: string) => Promise<{ mtimeMs: number }>} [options.statImpl] 可注入，供单测
 * @param {number} [options.budgetMs] 总预算，缺省 `LIMITS.statBudgetMs`
 * @returns {Promise<unknown>} 增强后的同形值；降级时是原始值
 */
export async function dirListing({ dsh, args, logger, statImpl = stat, budgetMs = LIMITS.statBudgetMs }) {
  const request = args ?? {}
  const result = await dsh.rpc(HOST_LIST_METHOD, {
    workspaceFileScopeId: request.workspaceFileScopeId,
    path: typeof request.path === 'string' ? request.path : '.',
  })

  const entries = listingEntries(result)
  if (entries === null) {
    logger?.debug?.('dir-listing: host answered a shape this connector does not decorate')
    return result
  }

  const directory = resolveDirectory(request.root, entries.path)
  if (directory === null) {
    // root 缺失 / 非绝对 / 宿主回的 path 越出 root：不是错误，只是补不了时间。
    logger?.debug?.(`dir-listing: cannot resolve the listed directory from root ${JSON.stringify(request.root)}`)
    return result
  }

  const decorated = await withBudget(
    Promise.all(entries.items.map((entry) => decorate(entry, directory, statImpl))),
    budgetMs
  )
  if (decorated === null) {
    logger?.warn?.(`dir-listing: stat budget of ${budgetMs}ms ran out, answering the plain listing`)
    return result
  }
  return replaceEntries(result, decorated)
}

/**
 * 取出清单本体（`{ entries: [...], path }`），形状不对时返回 null。
 *
 * 信封可能是 `result` 本身，也可能是 `result.value`——按"哪一层有 entries 数组"判定，
 * 与 `digestSessionList` 同一读法。
 */
function listingEntries(result) {
  if (result === null || typeof result !== 'object') return null
  if (result.ok !== true) return null
  const container = Array.isArray(result.entries) ? result : result.value
  if (container === null || typeof container !== 'object' || !Array.isArray(container.entries)) return null
  return { path: container.path, items: container.entries }
}

/** 按原形状放回增强后的条目数组。 */
function replaceEntries(result, items) {
  if (Array.isArray(result.entries)) return { ...result, entries: items }
  return { ...result, value: { ...result.value, entries: items } }
}

/**
 * 宿主回的 `path` 词法解析成绝对目录；解析不了（要求降级）时返回 null。
 *
 * - `path` 可以是相对的（`""` 表根、`"docs"`）也可以是绝对的（App/宿主都有先例）。
 * - 结果必须位于 root 之内：`resolved === root || resolved.startsWith(root + sep)`。
 *   只比 `startsWith(root)` 会把 `/a/b-sibling` 当成 `/a/b` 的子路径。
 * - **不做 realpath 越界拦截**（设计 §2.2 决策 1）：符号链接的目标可以合法地在工作区
 *   之外，宿主今天已经按目标报 `type`/`size`，这里保持同一语义。
 */
function resolveDirectory(root, echoedPath) {
  if (typeof root !== 'string' || !isAbsolute(root)) return null
  const base = resolve(root)
  const echoed = typeof echoedPath === 'string' ? echoedPath : ''
  const resolved = isAbsolute(echoed) ? resolve(echoed) : resolve(base, echoed)
  if (resolved !== base && !resolved.startsWith(base + sep)) return null
  return resolved
}

/**
 * 一条条目：stat 成功且时间可用就加 `mtimeMs`，其余情况原样返回。
 *
 * 条目名逐段校验：含 `/`、`\` 或等于 `.` / `..` 的名字直接跳过（宿主契约说是 basename，
 * 这里是纵深防御，防的是异常回包，不是防用户）。跳过的意思是"不给它补时间"，
 * **不是把条目从清单里删掉**——清单的所有者是宿主。
 */
async function decorate(entry, directory, statImpl) {
  if (entry === null || typeof entry !== 'object') return entry
  if (typeof entry.name !== 'string' || !isPlainName(entry.name)) return entry
  try {
    const info = await statImpl(resolve(directory, entry.name))
    const mtimeMs = info?.mtimeMs
    if (typeof mtimeMs !== 'number' || !Number.isFinite(mtimeMs)) return entry
    const rounded = Math.round(mtimeMs)
    if (!Number.isFinite(rounded)) return entry
    return { ...entry, mtimeMs: rounded }
  } catch {
    // 断链、权限、竞态删除：这个条目没有时间，其余条目照旧。
    return entry
  }
}

function isPlainName(name) {
  return name.length > 0 && name !== '.' && name !== '..' && !name.includes('/') && !name.includes('\\')
}

/**
 * 给整批 stat 一个总预算。超时返回 `null`（调用方据此降级），
 * **不取消**后台的 stat——它们会自然收尾，取消反而要给每条挂一个 signal。
 */
async function withBudget(work, budgetMs) {
  if (!(budgetMs > 0)) return await work
  let timer
  const expiry = new Promise((resolve) => {
    timer = setTimeout(() => resolve(null), budgetMs)
  })
  try {
    const outcome = await Promise.race([work, expiry])
    return outcome === null ? null : outcome
  } finally {
    clearTimeout(timer)
  }
}
