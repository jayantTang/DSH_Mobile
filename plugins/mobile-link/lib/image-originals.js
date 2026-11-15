/**
 * 预览 ↔ 原图 的关联索引（Host 侧持久状态）。
 *
 * 为什么需要它：Host 的 `session/attachment` 只认**图像**引用，没有按文件引用
 * 读回字节的 RPC；而一张图的原图是逐字节保存的 file 附件（`FileAttachmentRef`），
 * 与 Host 归一化后的预览图是两个内容地址。手机要"按需取原图"，就必须能从预览的
 * `attachmentId` 找到原图引用。
 *
 * 关联放在**电脑上**而不是 App 里：需求要求重装、重新配对、换设备后仍能取回原图，
 * 而客户端的任何缓存都会在重装时消失。键是预览的 `attachmentId`（内容哈希，全局唯一），
 * 所以索引不需要会话信息。写这条索引的有两处：连接器（手机发送的图）与
 * `send_image` 插件（工具结果图），格式见 `docs/IMAGE-VARIANTS.md` 与 /tmp 契约 §1.4。
 *
 * 追加写而不是重写：两个写者（连接器与图片插件）在同一进程里，但各自是独立的模块实例，
 * 读-改-写会互相覆盖。`O_APPEND` 的单次整行写入在 POSIX 上不会交错；读取端按行解析、
 * 同一预览取最后一条。索引坏掉最坏的后果是"原图不可用"，绝不会变成错误或数据丢失。
 */

import { closeSync, mkdirSync, openSync, readFileSync, statSync, writeSync } from 'node:fs'
import { dirname, join } from 'node:path'

import { dshHome } from './state.js'

/** 索引版本；字段变化时递增，读取端忽略不认识的版本。 */
export const INDEX_VERSION = 1

/** 索引文件最大可读字节数：超过说明文件被写坏了，宁可不认也不要整读进内存。 */
export const MAX_INDEX_BYTES = 8 * 1024 * 1024

/** 索引文件路径（`$DSH_HOME/mobile-link/image-originals.jsonl`）。 */
export function indexPath(home = dshHome()) {
  return join(home, 'mobile-link', 'image-originals.jsonl')
}

/** 一条索引记录。字段与图片插件的写入端必须一致。 */
export function indexEntry({ previewId, original, source = 'composer', savedAt = new Date().toISOString() }) {
  return {
    v: INDEX_VERSION,
    previewId,
    original: {
      attachmentId: original.attachmentId,
      name: original.name,
      bytes: original.bytes,
      ...(original.mediaType === undefined ? {} : { mediaType: original.mediaType }),
    },
    savedAt,
    source,
  }
}

/**
 * 追加一条记录。
 *
 * 失败只上报给日志，不抛给调用方：原图已经存进 Host 的对象库了，索引写不进去
 * 只意味着"这张图暂时取不到原图"，不该让整次发送失败。
 * @returns {boolean} 是否写入成功（测试与诊断使用）。
 */
export function appendIndex(entry, { home = dshHome(), logger = console } = {}) {
  const path = indexPath(home)
  try {
    mkdirSync(dirname(path), { recursive: true, mode: 0o700 })
    const line = `${JSON.stringify(entry)}\n`
    const fd = openSync(path, 'a', 0o600)
    try {
      writeSync(fd, line)
    } finally {
      closeSync(fd)
    }
    return true
  } catch (error) {
    logger.warn?.(`mobile-link: image-originals append failed: ${error?.message ?? error}`)
    return false
  }
}

/**
 * 把整个索引读成 `previewId → 原图元数据`。
 *
 * 坏行（半行、JSON 不完整、字段类型不对）逐行跳过；同键后写覆盖先写。
 * 文件不存在返回空表——"没有原图"是正常状态，不是错误。
 */
export function readIndex({ home = dshHome() } = {}) {
  const path = indexPath(home)
  let text
  try {
    if (statSync(path).size > MAX_INDEX_BYTES) return new Map()
    text = readFileSync(path, 'utf8')
  } catch {
    return new Map()
  }
  const map = new Map()
  for (const line of text.split('\n')) {
    if (!line.trim()) continue
    let parsed
    try {
      parsed = JSON.parse(line)
    } catch {
      continue
    }
    if (parsed?.v !== INDEX_VERSION) continue
    const previewId = parsed.previewId
    const original = parsed.original
    if (typeof previewId !== 'string' || previewId.length === 0) continue
    if (typeof original?.attachmentId !== 'string' || !original.attachmentId) continue
    if (typeof original.name !== 'string' || !original.name) continue
    if (!Number.isSafeInteger(original.bytes) || original.bytes < 0) continue
    map.set(previewId, {
      attachmentId: original.attachmentId,
      name: original.name,
      bytes: original.bytes,
      ...(typeof original.mediaType === 'string' ? { mediaType: original.mediaType } : {}),
    })
  }
  return map
}

/** 查一条原图元数据；没有就是 `undefined`（旧数据只有一份附件时正是这种）。 */
export function lookupOriginal(previewId, options = {}) {
  if (typeof previewId !== 'string' || !previewId) return undefined
  return readIndex(options).get(previewId)
}
