/**
 * `scripts/dev/check-contracts.mjs` 自身的用例。
 *
 * 为什么守门人也要有测试：一个永远 exit 0 的守卫比没有守卫更糟——它会让
 * 人以为漂移被盯着。这里用**临时改坏真实文件再改回**的方式，证明它真的会红。
 *
 * 用例在仓库根跑（`npm run test:scripts`），每条都自己收尾复原；任何一条
 * 中途失败也不会把工作区留在坏状态（用 try/finally）。
 */

import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import test from 'node:test'

const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..')

function runChecker() {
  try {
    const stdout = execFileSync('node', ['scripts/dev/check-contracts.mjs'], {
      cwd: REPO_ROOT, encoding: 'utf8',
    })
    return { code: 0, output: stdout }
  } catch (error) {
    return { code: error.status ?? 1, output: `${error.stdout ?? ''}${error.stderr ?? ''}` }
  }
}

/** 临时把某个文件改成 `mutate` 的结果，跑一次检查，然后**一定**改回。 */
function withBrokenFile(relative, mutate, assert_) {
  const path = join(REPO_ROOT, relative)
  const original = readFileSync(path, 'utf8')
  try {
    const mutated = mutate(original)
    assert.notEqual(mutated, original, `${relative}: mutate 没有真的改动内容`)
    writeFileSync(path, mutated)
    assert_(runChecker())
  } finally {
    writeFileSync(path, original)
  }
}

/**
 * 按文件名在 `ios/` 下定位一个 Swift 源文件（相对仓库根）。
 *
 * 025 的模块化重构把一批文件从 `DSHMobile/` 搬进了 `Modules/Sources/`，用例里写死的
 * 路径会随着下一次搬迁再断一次。按名字找，且要求**正好一处**——多了少了都说明
 * 这条用例该跟着改，而不是让它静默指错文件。
 */
function swiftFileNamed(name) {
  const found = execFileSync('find', [join(REPO_ROOT, 'ios'), '-name', name, '-not', '-path', '*/.build/*'],
    { encoding: 'utf8' }).split('\n').map((line) => line.trim()).filter(Boolean)
  assert.equal(found.length, 1, `${name} 应当正好一处，实得 ${found.length}：${found.join(', ')}`)
  return found[0].slice(REPO_ROOT.length + 1)
}

test('check-contracts passes on the current tree', () => {
  const result = runChecker()
  assert.equal(result.code, 0, `契约检查本应通过，实得：\n${result.output}`)
  assert.match(result.output, /ok {2}契约检查通过/)
})

test('check-contracts prints the four-copy anchor ladder', () => {
  const { output } = runChecker()
  for (const file of [
    'plugins/doubao-image/lib/dsh-install.mjs',
    'plugins/mobile-link/test/dsh-install.js',
    'docs/artifacts/samples/capture.mjs',
    'plugins/mobile-link/lib/ws.js',
  ]) {
    assert.ok(output.includes(file), `锚点表里没有 ${file}`)
  }
})

test('a swapped anchor order in one copy is reported', () => {
  withBrokenFile('docs/artifacts/samples/capture.mjs', (source) => {
    // 把 `self` 提到 `DSH_INSTALL_DIR` 前面 —— 只动一份，正是这个检查要拦的事。
    const canonical = `    process.env.DSH_INSTALL_DIR ? path.join(process.env.DSH_INSTALL_DIR, 'package.json') : undefined,
    import.meta.url,`
    const swapped = `    import.meta.url,
    process.env.DSH_INSTALL_DIR ? path.join(process.env.DSH_INSTALL_DIR, 'package.json') : undefined,`
    assert.ok(source.includes(canonical), 'capture.mjs 的锚点顺序与预期不同，用例需要更新')
    return source.replace(canonical, swapped)
  }, (result) => {
    assert.equal(result.code, 1, '改坏顺序后本应失败')
    assert.match(result.output, /capture\.mjs: 锚点集合\/顺序与契约不符/)
  })
})

test('a debug hook moved outside #if DEBUG is reported', () => {
  withBrokenFile(swiftFileNamed('DemoMode.swift'), (source) => {
    const gated = `        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-DSHDemoMode")
        #else
        false
        #endif`
    assert.ok(source.includes(gated), 'DemoMode.swift 的门与预期不同，用例需要更新')
    return source.replace(gated, '        ProcessInfo.processInfo.arguments.contains("-DSHDemoMode")')
  }, (result) => {
    assert.equal(result.code, 1, '把钩子移出门外后本应失败')
    assert.match(result.output, /-DSHDemoMode: 有 1 处在 #if DEBUG 之外/)
  })
})

test('a test file that stops reading the shared vectors is reported', () => {
  withBrokenFile('ios/DSHMobile/DSHKit/Tests/DSHKitTests/DLPContractTests.swift', (source) => (
    source.replace('"test/contract/dlp-vectors.json"', '"test/contract/own-copy.json"')
  ), (result) => {
    assert.equal(result.code, 1, '某一端改回自己的常量后本应失败')
    assert.match(result.output, /DLPContractTests\.swift: 没有引用共享向量/)
  })
})
