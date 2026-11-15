/**
 * 预览 ↔ 原图索引的写入端（send_image 这一侧）。
 *
 * 为什么不直接引用连接器的同名模块：npm 用户装的是 `dsh-plugin-send-image`
 * 这一个包，仓库里的 `plugins/mobile-link` 并不在包里；跨包 import 会让
 * 「装了插件却取不到原图」。格式只认契约（§1.4）：两边写出的行必须逐字段一致，
 * 读取端按 `previewId` 取最后一条，所以这里不做读-改-写，只追加。
 *
 * 索引坏掉最坏的结果是「原图不可用」，绝不能反过来让发图失败；写失败只记日志。
 */

import { closeSync, mkdirSync, openSync, writeSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'

/** 索引版本；连接器与插件必须写同一个值。 */
export const INDEX_VERSION = 1

/** `$DSH_HOME` 的解析必须与采集脚本、连接器一致（测试会改它）。 */
export function dshHome() {
  return process.env.DSH_HOME || join(homedir(), '.dsh')
}

/** 索引文件路径（`$DSH_HOME/mobile-link/image-originals.jsonl`）。 */
export function indexPath(home = dshHome()) {
  return join(home, 'mobile-link', 'image-originals.jsonl')
}

/** 一条索引记录；字段顺序与连接器一致，便于人工比对。 */
export function indexEntry({
  previewId,
  original,
  source = 'tool',
  savedAt = new Date().toISOString(),
}) {
  return {
    v: INDEX_VERSION,
    previewId,
    original: {
      attachmentId: original.attachmentId,
      name: original.name,
      bytes: original.bytes,
      // FileAttachmentRef 本身不带 mediaType；这里记的是原图来源的类型。
      ...(typeof original.mediaType === 'string' && original.mediaType.length > 0
        ? { mediaType: original.mediaType }
        : {}),
    },
    savedAt,
    source,
  }
}

/**
 * 追加一条索引记录。
 *
 * 用一次 `writeSync` 写整行：POSIX 的 `O_APPEND` 保证两个写者（连接器与插件）
 * 不会把彼此的半行插进中间。失败只上报日志，不抛给调用方——预览已经存好了，
 * 索引写不进去只意味着这张图暂时取不到原图。
 *
 * @returns {boolean} 是否写入成功（测试与诊断使用）。
 */
export function appendIndex(entry, { home = dshHome(), logger = console } = {}) {
  const path = indexPath(home)
  try {
    mkdirSync(dirname(path), { recursive: true, mode: 0o700 })
    const fd = openSync(path, 'a', 0o600)
    try {
      writeSync(fd, `${JSON.stringify(entry)}\n`)
    } finally {
      closeSync(fd)
    }
    return true
  } catch (error) {
    logger?.warn?.(`send-image: image-originals append failed: ${error?.message ?? error}`)
    return false
  }
}
