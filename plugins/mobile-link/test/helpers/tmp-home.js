/**
 * 测试用的临时 `DSH_HOME`。
 *
 * 为什么需要它（宪法第 III 条"不碰真实数据"）：连接器的收件箱、身份文件、交接文件都落在
 * `DSH_HOME` 下；早先的用例直接写真实的 `~/.dsh/inbox`，既是脏数据也是风险。
 * 用例统一用这里的工厂拿到一个隔离目录，并在结束时删掉。
 */

import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

/** 建一个空的临时 DSH_HOME（不设置环境变量，调用方自己决定）。 */
export async function makeTempHome(prefix = 'dsh-mobile-link-test-') {
  return mkdtemp(join(tmpdir(), prefix))
}

/** 跑 fn(home)，无论成败都删掉临时目录。 */
export async function withTempHome(fn, prefix) {
  const home = await makeTempHome(prefix)
  try {
    return await fn(home)
  } finally {
    await rm(home, { recursive: true, force: true })
  }
}

/** 交接文件路径（与 lib/state.js 的口径一致）。 */
export function handoffPath(home) {
  return join(home, 'mobile-link', 'endpoint.json')
}

/** 身份文件路径。 */
export function statePath(home) {
  return join(home, 'mobile-link', 'agent.json')
}

/** 手机上传的收件箱根目录。 */
export function inboxPath(home) {
  return join(home, 'inbox')
}
