/**
 * 连接器写给**进程外**消费者的交接文件。
 *
 * 为什么需要它：跑在 DSH 宿主进程之外的脚本（`scripts/dev/dsh-probe.mjs`、`verify-simulator.sh`、
 * `test/tools/host.mjs` 等）与 iOS 的集成测试辅助都没有进程内上下文，拿不到注入的服务；
 * 它们需要一个本机可读的"带凭据本机地址"。契约见
 * `specs/001-connector-host-compat/contracts/out-of-process-handoff.md`。
 *
 * 安全取舍：该文件含可用凭据，因此权限固定 0600、只写本机、不进日志；
 * 这是"让进程外工具可用"与"凭据不落盘"之间**有意识接受**的代价。
 *
 * 不变量：连接器**不读回**这个文件（避免自证循环）；连接器停止时**不删除**它
 * （宿主短暂重启期间，进程外工具仍要能读到最近一次的值）。
 */

import { chmod, mkdir, rename, writeFile } from 'node:fs/promises'
import { dirname } from 'node:path'

import { defaultHandoffFile } from './state.js'

/**
 * 原子写入交接文件。
 *
 * @param {object} input
 * @param {string} input.url 带凭据的本机地址（`http://127.0.0.1:<port>/?token=...`）
 * @param {number} input.port 本机 DSH 端口
 * @param {string} input.source 该地址来自哪一级（通常是 `host-service`）
 * @param {string} [input.path] 覆盖默认路径（测试用）
 * @param {number} [input.pid] 写入进程 pid
 * @param {string} [input.updatedAt] ISO-8601 时间戳
 * @returns {Promise<string>} 写好的文件路径
 */
export async function writeHandoff({ url, port, source, path = defaultHandoffFile(), pid = process.pid, updatedAt = new Date().toISOString() }) {
  if (typeof url !== 'string' || url === '') throw new TypeError('handoff: url is required')
  if (!Number.isFinite(Number(port)) || Number(port) <= 0) throw new TypeError('handoff: port is required')
  const payload = { url, port: Number(port), pid, source: source ?? null, updatedAt }
  await mkdir(dirname(path), { recursive: true })
  const temporary = `${path}.${process.pid}.tmp`
  await writeFile(temporary, `${JSON.stringify(payload, null, 2)}\n`, { mode: 0o600 })
  await rename(temporary, path)
  await chmod(path, 0o600).catch(() => {})
  return path
}

/** 由已认证的 endpoint 组出交接文件内容所需的字段。 */
export function handoffFromEndpoint(endpoint) {
  if (!endpoint?.base || !endpoint?.token) return undefined
  return {
    url: `${endpoint.base}/?token=${encodeURIComponent(endpoint.token)}`,
    port: endpoint.port,
    source: endpoint.source,
  }
}
