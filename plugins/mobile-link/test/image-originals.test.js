/**
 * `lib/image-originals.js` 的单测：预览 → 原图 关联索引。
 *
 * 索引是"重装 App 后还能不能取回原图"的唯一依据，所以断言的落点都是
 * **磁盘上的那几行 JSON**：写入后能读回、坏行不影响其它行、同一预览后写覆盖先写、
 * 文件不存在就是"没有原图"（正常状态）。
 */

import assert from 'node:assert/strict'
import { appendFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'

import {
  INDEX_VERSION,
  appendIndex,
  indexEntry,
  indexPath,
  lookupOriginal,
  readIndex,
} from '../lib/image-originals.js'

function tempHome(t) {
  const home = mkdtempSync(join(tmpdir(), 'dsh-image-originals-'))
  t.after(() => rmSync(home, { recursive: true, force: true }))
  return home
}

const original = { attachmentId: 'sha256:aa', name: 'photo.heic', bytes: 4096, mediaType: 'image/heic' }

test('追加一行后按预览 id 查得到原图元数据', (t) => {
  const home = tempHome(t)
  const entry = indexEntry({ previewId: 'sha256:p1', original, source: 'composer' })
  assert.equal(appendIndex(entry, { home }), true)

  const lines = readFileSync(indexPath(home), 'utf8').trim().split('\n')
  assert.equal(lines.length, 1)
  assert.equal(JSON.parse(lines[0]).v, INDEX_VERSION)

  assert.deepEqual(lookupOriginal('sha256:p1', { home }), original)
})

test('同一预览后写覆盖先写（最后一条为准）', (t) => {
  const home = tempHome(t)
  appendIndex(indexEntry({ previewId: 'sha256:p1', original }), { home })
  const newer = { attachmentId: 'sha256:bb', name: 'photo2.heic', bytes: 8192 }
  appendIndex(indexEntry({ previewId: 'sha256:p1', original: newer }), { home })

  assert.deepEqual(readIndex({ home }).get('sha256:p1'), newer)
})

test('坏行被跳过，不影响同文件里的好行', (t) => {
  const home = tempHome(t)
  mkdirSync(join(home, 'mobile-link'), { recursive: true })
  appendFileSync(indexPath(home), 'not json\n')
  appendIndex(indexEntry({ previewId: 'sha256:p1', original }), { home })
  appendFileSync(indexPath(home), '{"v":1,"previewId":"sha256:p2"}\n')
  appendFileSync(indexPath(home), '\n')

  const index = readIndex({ home })
  assert.equal(index.size, 1)
  assert.deepEqual(index.get('sha256:p1'), original)
})

test('不认识的版本与类型不对的字段也不进索引', (t) => {
  const home = tempHome(t)
  mkdirSync(join(home, 'mobile-link'), { recursive: true })
  writeFileSync(indexPath(home), [
    JSON.stringify({ v: 99, previewId: 'sha256:old', original }),
    JSON.stringify({ v: 1, previewId: 'sha256:bad-bytes', original: { ...original, bytes: '12' } }),
    JSON.stringify({ v: 1, previewId: 'sha256:no-name', original: { attachmentId: 'sha256:cc', bytes: 1 } }),
  ].join('\n'))

  assert.equal(readIndex({ home }).size, 0)
})

test('索引文件不存在时是空的，不是错误', (t) => {
  const home = tempHome(t)
  assert.equal(readIndex({ home }).size, 0)
  assert.equal(lookupOriginal('sha256:p1', { home }), undefined)
})

test('超出大小上限的索引按空的处理（不整读进内存）', (t) => {
  const home = tempHome(t)
  mkdirSync(join(home, 'mobile-link'), { recursive: true })
  writeFileSync(indexPath(home), Buffer.alloc(9 * 1024 * 1024, 0x20))
  assert.equal(readIndex({ home }).size, 0)
})

test('写入失败只记日志，不把失败抛给发送路径', (t) => {
  const home = tempHome(t)
  // 把 mobile-link 做成一个文件，mkdir 必然失败。
  writeFileSync(join(home, 'mobile-link'), 'blocked')
  const warnings = []
  const written = appendIndex(indexEntry({ previewId: 'sha256:p1', original }), {
    home,
    logger: { warn: (message) => warnings.push(message) },
  })
  assert.equal(written, false)
  assert.equal(warnings.length, 1)
  assert.match(warnings[0], /image-originals append failed/)
})
