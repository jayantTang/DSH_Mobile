/**
 * 会话图片的"预览 + 可选原图"两变体能力（连接器侧）。
 *
 * 这一层只做三件事，且都在电脑上完成：
 *   1. 把手机已经落盘的暂存字节交给 Host 的附件服务：预览走
 *      `fileUploads.uploadImageStream`（Host 归一化，返回 prompt 可引用的 receipt），
 *      原图走 `attachments.saveFileStream`（逐字节保存，不做任何重编码）。
 *   2. 把"预览 attachmentId → 原图 file 引用"写进 Host 侧的索引
 *      （`lib/image-originals.js`），于是重装 App / 换设备后仍能取回原图。
 *   3. 按需把原图按区间读回给手机（元数据 + 分片），供"查看原图/保存原图"使用。
 *
 * 为什么不改 Host：Host 没有"按预览 id 读原图文件"的 RPC，`session/attachment`
 * 也只认图像引用。连接的保留方法（`_link/*`）本来就是连接器自己回答的通道，
 * 把这一段放在这里既不需要改 Host 契约，也不会新增中转的帧类型。
 *
 * 服务是**可选注入**：宿主缺少 `attachments` / `fileUploads`（老版本或裁剪部署）时，
 * 三个方法都回 `link/unsupported`，手机据此显示"原图不可用"，预览仍照常工作。
 */

import { closeSync, createReadStream, openSync, readSync, statSync, unlinkSync } from 'node:fs'
import { basename, dirname, resolve } from 'node:path'

import { appendIndex, indexEntry, lookupOriginal } from './image-originals.js'
import { dshHome } from './state.js'

/** 手机侧调用的三个保留方法（`_link/` 前缀，永不转发给 Host）。 */
export const IMAGE_COMMIT = '_link/imageCommit'
export const IMAGE_ORIGINAL = '_link/imageOriginal'
export const IMAGE_ORIGINAL_CHUNK = '_link/imageOriginalChunk'

/** 一次分片读取的默认字节数与上限：base64 后仍远低于 32 MB 的帧上限。 */
export const DEFAULT_CHUNK_BYTES = 512 * 1024
export const MAX_CHUNK_BYTES = 1024 * 1024

/** 手机发来的图必须落在这个目录里（`FileInbox` 的落盘位置）。 */
function inboxDirectory(home, sessionId) {
  return resolve(home, 'inbox', sessionId)
}

/**
 * 交给 Host 的字节流。
 *
 * 挂一个空错误处理：Host 可能在读完之前就拒绝（超限、格式不接受），而我们随后会删掉
 * 暂存文件——被丢弃的流在 unlink 之后再打开会抛 ENOENT，没人接住的 `error` 事件会变成
 * 进程级 uncaughtException。消费方替身靠 async iterator 仍能拿到真正的失败，这里只是
 * 保证"我们自己制造的那条尾巴"不会冒到进程上。
 */
function readStream(path) {
  const stream = createReadStream(path)
  stream.on('error', () => {})
  return stream
}

/** 一个带稳定错误码的失败：路由把它原样翻成 `{ok:false,error}`。 */
class ImageVariantError extends Error {
  constructor(code, message, details = {}) {
    super(message)
    this.code = code
    this.details = details
  }
}

/** 宿主失败 → 保留方法错误码。认不出的按上传失败处理。 */
function commitFailure(error) {
  const code = error?.code
  const reason = error?.details?.reason
  if (code === 'session/not-found') return new ImageVariantError('session/not-found', '会话不存在或未挂上 Agent。')
  if (reason === 'UNSUPPORTED_IMAGE_TYPE') {
    return new ImageVariantError('image/unsupported-type', '这个部署不接受该图片格式。')
  }
  if (reason === 'IMAGE_TOO_LARGE' || reason === 'IMAGES_TOO_LARGE') {
    return new ImageVariantError('image/too-large', '预览图超过宿主的单图上限。')
  }
  return new ImageVariantError('image/upload-failed', error?.message ?? String(error))
}

/** 是否是本模块回答的方法。 */
export function isImageVariantMethod(method) {
  return method === IMAGE_COMMIT || method === IMAGE_ORIGINAL || method === IMAGE_ORIGINAL_CHUNK
}

/** Owns the image-variant methods for one connector. */
export class ImageVariants {
  /**
   * @param {object} options
   * @param {object} [options.attachments] 宿主附件服务（`ctx.attachments`）
   * @param {object} [options.fileUploads] 宿主上传服务（`ctx.fileUploads`）
   * @param {object} [options.logger]
   * @param {string} [options.home] 索引与收件箱所在的 DSH_HOME（测试注入）
   */
  constructor({ attachments, fileUploads, logger = console, home = dshHome() } = {}) {
    this.attachments = attachments
    this.fileUploads = fileUploads
    this.logger = logger
    this.home = home
  }

  /** 两个宿主服务都到位才答原图；缺一个就如实报不支持。 */
  get available() {
    return Boolean(this.attachments && this.fileUploads)
  }

  /** Answers one reserved call. Throws an `ImageVariantError` for the router to report. */
  async handle(method, args = {}) {
    switch (method) {
      case IMAGE_COMMIT: return this.#commit(args)
      case IMAGE_ORIGINAL: return this.#metadata(args)
      case IMAGE_ORIGINAL_CHUNK: return this.#chunk(args)
      default: throw new ImageVariantError('link/unknown-method', `unknown image method ${method}`)
    }
  }

  /**
   * 校验并解析一个暂存路径。
   *
   * 只接受收件箱的**直接子文件**：手机本来就只能把文件写进那里，
   * 放宽到子目录或任意路径等于让手机指定电脑上的任意文件。
   */
  #stagedPath(rawPath, sessionId) {
    if (typeof rawPath !== 'string' || rawPath.length === 0) {
      throw new ImageVariantError('image/invalid-path', '缺少暂存文件路径。')
    }
    const resolved = resolve(rawPath)
    if (dirname(resolved) !== inboxDirectory(this.home, sessionId)) {
      throw new ImageVariantError('image/invalid-path', '暂存文件不在本会话的收件箱里。')
    }
    try {
      if (!statSync(resolved).isFile()) throw new Error('not a file')
    } catch {
      throw new ImageVariantError('image/invalid-path', '暂存文件不存在。')
    }
    return resolved
  }

  /** 删掉本次用到的暂存文件：成品已经进了 Host 对象库，留在收件箱只会越积越多。 */
  #discard(paths) {
    for (const path of paths) {
      if (!path) continue
      try {
        unlinkSync(path)
      } catch {
        /* best effort：删不掉不影响已经完成的上传 */
      }
    }
  }

  async #commit(args) {
    if (!this.available) {
      throw new ImageVariantError('link/unsupported', '这台电脑的宿主不支持图片变体上传。')
    }
    const sessionId = typeof args.sessionId === 'string' ? args.sessionId : ''
    if (!sessionId) throw new ImageVariantError('session/not-found', '缺少 sessionId。')

    const previewPath = args.preview ? this.#stagedPath(args.preview.path, sessionId) : undefined
    const previewMediaType = typeof args.preview?.mediaType === 'string' && args.preview.mediaType
      ? args.preview.mediaType
      : 'image/jpeg'
    const previewName = typeof args.preview?.name === 'string' && args.preview.name
      ? basename(args.preview.name)
      : 'image.jpg'

    const originalPath = args.original ? this.#stagedPath(args.original.path, sessionId) : undefined
    const originalName = typeof args.original?.name === 'string' && args.original.name
      ? basename(args.original.name)
      : basename(originalPath ?? 'original')
    const originalMediaType = typeof args.original?.mediaType === 'string' ? args.original.mediaType : undefined
    const sendOriginalAsFile = args.sendOriginalAsFile === true
    if (!previewPath && !originalPath) {
      throw new ImageVariantError('image/invalid-path', '预览与原图至少要有一份。')
    }
    if (sendOriginalAsFile && !originalPath) {
      throw new ImageVariantError('image/invalid-path', '要求按文件发送原图，但没有提供原图文件。')
    }
    if (!previewPath && !sendOriginalAsFile) {
      // 没有预览还能发出去的唯一形态就是"按文件发送原图"；否则用户既看不到图，
      // 也不知道原图在哪。
      throw new ImageVariantError('image/invalid-path', '没有预览时只能按文件发送原图。')
    }

    const discard = [previewPath, originalPath]
    try {
      let preview
      if (previewPath) {
        try {
          preview = await this.fileUploads.uploadImageStream({
            sessionId,
            data: readStream(previewPath),
            mediaType: previewMediaType,
            name: previewName,
          })
        } catch (error) {
          throw commitFailure(error)
        }
      }

      const result = {
        preview: preview ? { receiptId: preview.receiptId, image: preview.image } : null,
        original: null,
      }

      if (originalPath) {
        if (sendOriginalAsFile) {
          // 超限或不可解码：按**文件**交回给手机，由它额外发一个 file part。
          // 不写索引、不产生 original 变体——预览绝不会被当成原图。
          let file
          try {
            file = await this.fileUploads.uploadStream({
              sessionId,
              data: readStream(originalPath),
              name: originalName,
            })
          } catch (error) {
            throw commitFailure(error)
          }
          result.fileReceiptId = file.receiptId
          result.originalReason = typeof args.originalReason === 'string' && args.originalReason
            ? args.originalReason
            : 'tooLarge'
        } else {
          try {
            const stored = await this.attachments.saveFileStream({
              data: readStream(originalPath),
              name: originalName,
            })
            const metadata = {
              attachmentId: stored.attachmentId,
              name: stored.name,
              bytes: stored.bytes,
              ...(originalMediaType === undefined ? {} : { mediaType: originalMediaType }),
            }
            if (preview) {
              appendIndex(
                indexEntry({ previewId: preview.image.attachmentId, original: metadata, source: 'composer' }),
                { home: this.home, logger: this.logger },
              )
            }
            result.original = metadata
          } catch (error) {
            // 原图存不进去不该挡下发图：预览照发，手机显示"原图不可用"。
            this.logger.warn?.(`mobile-link: original save failed: ${error?.message ?? error}`)
            result.originalReason = 'failed'
          }
        }
      }

      return result
    } finally {
      this.#discard(discard)
    }
  }

  /** 原图是否存在、多大、叫什么。不读字节。 */
  #metadata(args) {
    const previewId = typeof args.attachmentId === 'string' ? args.attachmentId : ''
    if (!previewId) return { available: false, reason: 'missing' }
    const entry = lookupOriginal(previewId, { home: this.home })
    if (!entry) return { available: false, reason: 'missing' }
    if (!this.available) return { available: false, reason: 'unsupported' }
    const path = this.#hostPath(entry)
    if (!path) return { available: false, reason: 'cleaned' }
    return { available: true, original: entry }
  }

  /** 原图对象在电脑上的路径；Host 不提供（对象已清理、提供者不支持）时返回 undefined。 */
  #hostPath(entry) {
    try {
      const path = this.attachments.fileHostPath({
        attachmentId: entry.attachmentId,
        name: entry.name,
        bytes: entry.bytes,
      })
      if (typeof path !== 'string' || !path) return undefined
      if (!statSync(path).isFile()) return undefined
      return path
    } catch {
      return undefined
    }
  }

  /** 读原图的一个区间。只读请求的那一段，不把整文件塞进内存。 */
  #chunk(args) {
    const previewId = typeof args.attachmentId === 'string' ? args.attachmentId : ''
    const entry = previewId ? lookupOriginal(previewId, { home: this.home }) : undefined
    if (!entry) throw new ImageVariantError('image-original/missing', '没有这张图的原图。')
    if (!this.available) throw new ImageVariantError('image-original/unsupported', '这台电脑的宿主读不到原图。')
    const path = this.#hostPath(entry)
    if (!path) throw new ImageVariantError('image-original/cleaned', '原图已被清理。')

    const total = entry.bytes
    const offset = Number.isFinite(args.offset) ? Math.max(0, Math.trunc(args.offset)) : 0
    const requested = Number.isFinite(args.length) && args.length > 0
      ? Math.trunc(args.length)
      : DEFAULT_CHUNK_BYTES
    const length = Math.min(requested, MAX_CHUNK_BYTES)
    if (offset >= total) {
      return { data: '', offset, eof: true, bytes: total }
    }
    const toRead = Math.min(length, total - offset)
    const buffer = Buffer.alloc(toRead)
    const fd = openSync(path, 'r')
    try {
      const read = readSync(fd, buffer, 0, toRead, offset)
      return {
        data: buffer.subarray(0, read).toString('base64'),
        offset,
        eof: offset + read >= total,
        bytes: total,
      }
    } catch (error) {
      throw new ImageVariantError('image-original/read-failed', error?.message ?? String(error))
    } finally {
      closeSync(fd)
    }
  }
}
