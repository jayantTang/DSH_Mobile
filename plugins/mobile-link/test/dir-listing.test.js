/**
 * `_link/dirListing` 的单测（设计 20261024-工作区文件修改时间 §2.2）。
 *
 * 两条主线：
 *   ① 纯函数 `dirListing`：宿主清单是权威，连接器只往条目上加 `mtimeMs`，
 *      任何一步出问题都退回"未增强的原始清单"，装饰永不弄坏清单；
 *   ② 走完整设备路径：`handleRequest` 把 `_link/dirListing` 应答成 `res` 帧，
 *      且不做任何宿主转发（自答方法）。
 *
 * 失败语义逐条对应设计 §2.2 的表：宿主失败逐字透传、root 缺失/相对/越界、
 * 单条目 stat 失败、总预算超时。
 */

import assert from 'node:assert/strict'
import { mkdtempSync, mkdirSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'

import { DIR_LISTING_METHOD, LIMITS, dirListing, isDirListingMethod } from '../lib/dir-listing.js'
import { DeviceRouter } from '../lib/router.js'

/** 一个临时工作区目录，返回它的绝对路径与一个收尾函数。 */
function workspace() {
  const root = mkdtempSync(join(tmpdir(), 'dsh-dirlisting-'))
  return { root, done: () => rmSync(root, { recursive: true, force: true }) }
}

/** 宿主信封：`{ ok: true, value: { path, entries, truncated } }`。 */
function hostListing(path, entries, extra = {}) {
  return { ok: true, value: { path, entries, truncated: false, ...extra } }
}

/** 造一条宿主条目。 */
function entry(name, type = 'file', size) {
  return size === undefined ? { name, type } : { name, type, size }
}

test('文件与目录条目带上与 fs.stat 一致的 mtimeMs', async (t) => {
  const { root, done } = workspace()
  t.after(done)
  writeFileSync(join(root, 'a.txt'), 'hello')
  mkdirSync(join(root, 'sub'))

  const result = await dirListing({
    dsh: { async rpc() { return hostListing('', [entry('a.txt', 'file', 5), entry('sub', 'directory')]) } },
    args: { workspaceFileScopeId: 's-1', path: '.', root },
  })

  assert.equal(result.ok, true)
  const [file, dir] = result.value.entries
  assert.equal(file.name, 'a.txt')
  assert.equal(file.size, 5, '宿主给的 size 必须逐字保留')
  assert.equal(typeof file.mtimeMs, 'number')
  assert.equal(Number.isInteger(file.mtimeMs), true, 'mtimeMs 是整数毫秒')
  assert.ok(Math.abs(file.mtimeMs - Date.now()) < 60_000, '刚写的文件时间应当贴近现在')
  assert.equal(typeof dir.mtimeMs, 'number', '目录也给时间')
})

test('宿主返回的清单形状与字段逐字不变（只加字段）', async (t) => {
  const { root, done } = workspace()
  t.after(done)
  writeFileSync(join(root, 'a.txt'), 'hello')

  const hostValue = { path: 'docs', entries: [entry('a.txt', 'file', 5)], truncated: true }
  const result = await dirListing({
    dsh: { async rpc() { return { ok: true, value: hostValue } } },
    args: { path: 'docs', root },
  })

  assert.equal(result.value.path, 'docs')
  assert.equal(result.value.truncated, true)
  assert.deepEqual(
    Object.keys(result.value.entries[0]).filter((key) => key !== 'mtimeMs'),
    ['name', 'type', 'size'],
    '除 mtimeMs 外不许增删字段'
  )
  assert.deepEqual(
    result.value.entries.map((item) => item.name),
    hostValue.entries.map((item) => item.name),
    '顺序不改'
  )
  assert.equal(hostValue.entries[0].mtimeMs, undefined, '入参对象不许被改写')
})

test('入参不被修改（前后 JSON.stringify 一致）', async (t) => {
  const { root, done } = workspace()
  t.after(done)
  writeFileSync(join(root, 'a.txt'), 'hello')

  const args = { workspaceFileScopeId: 's-1', path: '.', root }
  const before = JSON.stringify(args)
  await dirListing({
    dsh: { async rpc() { return hostListing('', [entry('a.txt', 'file', 5)]) } },
    args,
  })
  assert.equal(JSON.stringify(args), before)
})

test('宿主错误信封逐字透传（含 workspace-file/* 原错误码）', async () => {
  const envelope = { ok: false, error: { code: 'workspace-file/not-directory', message: 'not a directory' } }
  const result = await dirListing({
    dsh: { async rpc() { return envelope } },
    args: { path: '.', root: '/tmp' },
  })
  assert.deepEqual(result, envelope, '不包装成新错误码')
})

test('宿主 rpc 抛异常时按 link/failed 回包（与 git 分支同款）', async () => {
  await assert.rejects(
    () => dirListing({ dsh: { async rpc() { throw new Error('host is gone') } }, args: { path: '.', root: '/tmp' } }),
    /host is gone/
  )
})

test('root 缺失时返回未增强的原始清单', async () => {
  const value = { path: '', entries: [entry('a.txt', 'file', 5)], truncated: false }
  for (const root of [undefined, null, '', 42]) {
    const result = await dirListing({ dsh: { async rpc() { return { ok: true, value } } }, args: { path: '.', root } })
    assert.deepEqual(result.value, value, `root=${String(root)} 应当降级`)
  }
})

test('root 不是绝对路径时返回未增强的原始清单', async () => {
  const value = { path: '', entries: [entry('a.txt', 'file', 5)], truncated: false }
  for (const root of ['relative/dir', './x']) {
    const result = await dirListing({ dsh: { async rpc() { return { ok: true, value } } }, args: { path: '.', root } })
    assert.deepEqual(result.value, value, `root=${root} 应当降级`)
  }
})

test('宿主回的 path 越出 root 时返回未增强的原始清单', async (t) => {
  const { root, done } = workspace()
  t.after(done)
  const outside = mkdtempSync(join(tmpdir(), 'dsh-outside-'))
  writeFileSync(join(outside, 'secret.txt'), 'x')
  try {
    // 绝对路径越界：`..` 也一并覆盖。
    for (const echoed of [`${outside}`, `${root}/../${outside.split('/').pop()}`]) {
      const value = { path: echoed, entries: [entry('secret.txt', 'file', 1)], truncated: false }
      const result = await dirListing({
        dsh: { async rpc() { return { ok: true, value } } },
        args: { path: '.', root },
      })
      assert.deepEqual(result.value, value, `path=${echoed} 应当降级`)
    }
    // 相对路径含 `..` 穿越：同样降级。
    const value = { path: '../outside', entries: [entry('secret.txt', 'file', 1)], truncated: false }
    const result = await dirListing({
      dsh: { async rpc() { return { ok: true, value } } },
      args: { path: '.', root },
    })
    assert.deepEqual(result.value, value, '相对 path 越界应当降级')
  } finally {
    rmSync(outside, { recursive: true, force: true })
  }
})

test('条目名含分隔符或 . / .. 时跳过该条目（纵深防御）', async (t) => {
  const { root, done } = workspace()
  t.after(done)
  writeFileSync(join(root, 'ok.txt'), 'x')

  const value = {
    path: '',
    entries: [entry('ok.txt', 'file', 1), entry('../escape.txt'), entry('nested/deep.txt'), entry('..'), entry('.'), entry('win\\path.txt')],
    truncated: false,
  }
  const result = await dirListing({ dsh: { async rpc() { return { ok: true, value } } }, args: { path: '.', root } })
  assert.deepEqual(result.value.entries.map((item) => item.name), ['ok.txt', '../escape.txt', 'nested/deep.txt', '..', '.', 'win\\path.txt'],
    '跳过的是 stat，不是把条目从清单里删掉')
  assert.deepEqual(result.value.entries.map((item) => item.mtimeMs === undefined), [false, true, true, true, true, true])
})

test('单条目 stat 失败只影响该条目（断链、竞态删除）', async (t) => {
  const { root, done } = workspace()
  t.after(done)
  writeFileSync(join(root, 'a.txt'), 'hello')
  symlinkSync(join(root, 'missing.txt'), join(root, 'broken'))

  const value = { path: '', entries: [entry('a.txt', 'file', 5), entry('broken'), entry('gone.txt')], truncated: false }
  const result = await dirListing({ dsh: { async rpc() { return { ok: true, value } } }, args: { path: '.', root } })

  assert.equal(typeof result.value.entries[0].mtimeMs, 'number')
  assert.equal(result.value.entries[1].mtimeMs, undefined, '断链省略字段')
  assert.equal(result.value.entries[2].mtimeMs, undefined, '不存在的条目省略字段')
  assert.equal('mtimeMs' in result.value.entries[1], false, '省略而不是 null / 0')
})

test('符号链接报目标的时间（跟随链接，不是链接自身）', async (t) => {
  const { root, done } = workspace()
  t.after(done)
  writeFileSync(join(root, 'target.txt'), 'x')
  symlinkSync(join(root, 'target.txt'), join(root, 'link.txt'))

  const value = { path: '', entries: [entry('target.txt', 'file', 1), entry('link.txt', 'file', 1)], truncated: false }
  const result = await dirListing({ dsh: { async rpc() { return { ok: true, value } } }, args: { path: '.', root } })
  assert.equal(result.value.entries[0].mtimeMs, result.value.entries[1].mtimeMs, '同一目标的 mtime 应当相同')
})

test('宿主回的 path 是绝对路径且位于 root 内时正常增强', async (t) => {
  const { root, done } = workspace()
  t.after(done)
  mkdirSync(join(root, 'docs'))
  writeFileSync(join(root, 'docs', 'a.txt'), 'hello')

  const value = { path: join(root, 'docs'), entries: [entry('a.txt', 'file', 5)], truncated: false }
  const result = await dirListing({ dsh: { async rpc() { return { ok: true, value } } }, args: { path: 'docs', root } })
  assert.equal(typeof result.value.entries[0].mtimeMs, 'number')
})

test('root 自身（path 为空或等于 root）不算越界', async (t) => {
  const { root, done } = workspace()
  t.after(done)
  writeFileSync(join(root, 'a.txt'), 'hello')

  for (const echoed of ['', '.', root]) {
    const value = { path: echoed, entries: [entry('a.txt', 'file', 5)], truncated: false }
    const result = await dirListing({ dsh: { async rpc() { return { ok: true, value } } }, args: { path: '.', root } })
    assert.equal(typeof result.value.entries[0].mtimeMs, 'number', `path=${JSON.stringify(echoed)} 应当增强`)
  }
})

test('语法上像 root 兄弟目录的路径不算越界（前缀相同但不是子路径）', async (t) => {
  const { root, done } = workspace()
  t.after(done)
  writeFileSync(join(root, 'a.txt'), 'hello')
  const sibling = `${root}-sibling`
  mkdirSync(sibling)
  try {
    const value = { path: sibling, entries: [entry('a.txt', 'file', 5)], truncated: false }
    const result = await dirListing({ dsh: { async rpc() { return { ok: true, value } } }, args: { path: '.', root } })
    assert.deepEqual(result.value, value, '前缀相同不等于在 root 内')
  } finally {
    rmSync(sibling, { recursive: true, force: true })
  }
})

test('全部 stat 超过总预算时返回未增强的原始清单', async () => {
  const value = { path: '', entries: [entry('slow-a.txt'), entry('slow-b.txt')], truncated: false }
  const result = await dirListing({
    dsh: { async rpc() { return { ok: true, value } } },
    args: { path: '.', root: '/tmp' },
    budgetMs: 20,
    statImpl: () => new Promise((resolve) => setTimeout(() => resolve({ mtimeMs: 1 }), 200)),
  })
  assert.deepEqual(result.value, value, '超预算降级为原始清单')
})

test('预算之内不误伤：慢一点但没超时的 stat 仍然给时间', async () => {
  const value = { path: '', entries: [entry('a.txt')], truncated: false }
  const result = await dirListing({
    dsh: { async rpc() { return { ok: true, value } } },
    args: { path: '.', root: '/tmp' },
    budgetMs: 500,
    statImpl: async () => ({ mtimeMs: 1_700_000_000_000 }),
  })
  assert.equal(result.value.entries[0].mtimeMs, 1_700_000_000_000)
})

test('stat 返回非整数 mtimeMs 时省略该条目的字段', async () => {
  const value = { path: '', entries: [entry('a.txt')], truncated: false }
  const result = await dirListing({
    dsh: { async rpc() { return { ok: true, value } } },
    args: { path: '.', root: '/tmp' },
    statImpl: async () => ({ mtimeMs: Number.NaN }),
  })
  assert.equal('mtimeMs' in result.value.entries[0], false)
})

test('mtimeMs 取整：小数毫秒四舍五入成整数', async () => {
  const value = { path: '', entries: [entry('a.txt')], truncated: false }
  const result = await dirListing({
    dsh: { async rpc() { return { ok: true, value } } },
    args: { path: '.', root: '/tmp' },
    statImpl: async () => ({ mtimeMs: 1_700_000_000_000.6 }),
  })
  assert.equal(result.value.entries[0].mtimeMs, 1_700_000_000_001)
})

test('宿主信封形状不对（entries 不是数组 / ok 不为 true / value 缺失）原样返回', async () => {
  const shapes = [
    { ok: true, value: { path: '', entries: 'nope' } },
    { ok: false, error: { code: 'x', message: 'y' } },
    { ok: true },
    null,
  ]
  for (const envelope of shapes) {
    const result = await dirListing({ dsh: { async rpc() { return envelope } }, args: { path: '.', root: '/tmp' } })
    assert.deepEqual(result, envelope)
  }
})

test('空目录：返回空清单而不是报错', async (t) => {
  const { root, done } = workspace()
  t.after(done)
  const result = await dirListing({
    dsh: { async rpc() { return hostListing('', []) } },
    args: { path: '.', root },
  })
  assert.deepEqual(result.value.entries, [])
})

test('方法名常量与判定函数', () => {
  assert.equal(DIR_LISTING_METHOD, '_link/dirListing')
  assert.equal(isDirListingMethod(DIR_LISTING_METHOD), true)
  assert.equal(isDirListingMethod('workspaceFiles/list'), false)
  assert.deepEqual(LIMITS, { statBudgetMs: 2000 })
})

test('handleRequest 把 _link/dirListing 应答成 res 帧，且不转发宿主', async (t) => {
  const { root, done } = workspace()
  t.after(done)
  writeFileSync(join(root, 'a.txt'), 'hello')

  const frames = []
  const rpcCalls = []
  const router = new DeviceRouter({
    dsh: { async rpc(method, args) { rpcCalls.push(method); return hostListing('', [entry('a.txt', 'file', 5)]) } },
    send: (deviceId, frame) => frames.push({ deviceId, frame }),
  })
  await router.handleRequest('dev_1', {
    t: 'req', id: 'r1', method: DIR_LISTING_METHOD,
    args: { workspaceFileScopeId: 's-1', path: '.', root },
  })

  assert.deepEqual(rpcCalls, ['workspaceFiles/list'], '只调宿主的 list，不调别的')
  assert.equal(frames.length, 1)
  assert.equal(frames[0].frame.t, 'res')
  assert.equal(frames[0].frame.id, 'r1')
  assert.equal(frames[0].frame.ok, true)
  assert.equal(typeof frames[0].frame.value.entries[0].mtimeMs, 'number')
})

test('handleRequest 的宿主失败原样透传错误码', async () => {
  const frames = []
  const router = new DeviceRouter({
    dsh: { async rpc() { return { ok: false, error: { code: 'workspace-file/not-directory', message: 'nope' } } } },
    send: (deviceId, frame) => frames.push({ deviceId, frame }),
  })
  await router.handleRequest('dev_1', { t: 'req', id: 'r2', method: DIR_LISTING_METHOD, args: { path: '.', root: '/tmp' } })
  assert.equal(frames[0].frame.ok, false)
  assert.equal(frames[0].frame.error.code, 'workspace-file/not-directory')
})

test('handleRequest 的内部异常包成 link/failed', async () => {
  const frames = []
  const router = new DeviceRouter({
    dsh: { async rpc() { throw new Error('boom') } },
    send: (deviceId, frame) => frames.push({ deviceId, frame }),
  })
  await router.handleRequest('dev_1', { t: 'req', id: 'r3', method: DIR_LISTING_METHOD, args: { path: '.', root: '/tmp' } })
  assert.equal(frames[0].frame.ok, false)
  assert.equal(frames[0].frame.error.code, 'link/failed')
})
