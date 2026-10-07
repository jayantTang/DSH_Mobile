#!/usr/bin/env node
/**
 * 结构检查（宪法第 VII 条的门禁）：**只报告，不卡人**。
 *
 *   node scripts/dev/check-structure.mjs                # 看本次改动的文件
 *   node scripts/dev/check-structure.mjs --all          # 看全仓库（慢，仅人工排查用）
 *   node scripts/dev/check-structure.mjs --json         # 机器可读
 *
 * 为什么只报告：行数类指标误伤率高（`plugins/mobile-link/lib/qr.js` 600 行里大部分是数据表），
 * 硬失败最常见的后果是"为过闸把函数拆得更难读"。所以脚本给证据，判定归人
 * （超限项要在 plan/tasks 里写明理由）。
 *
 * 退出码恒为 0；工具自身出错才是非零（避免"检查失败"被误读成"代码有问题"）。
 */

import { execFileSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { dirname, extname, join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..')
const FUNCTION_LIMIT = 50
const FILE_LIMIT = 500
const CODE_EXT = new Set(['.js', '.mjs', '.cjs', '.ts', '.swift', '.py', '.sh'])

const argv = process.argv.slice(2)
const has = (name) => argv.includes(`--${name}`)

/** 本次改动的文件（相对 HEAD + 未跟踪），或全仓库。 */
function changedFiles() {
  if (has('all')) {
    return execFileSync('git', ['ls-files'], { cwd: ROOT, encoding: 'utf8' })
      .split('\n').filter(Boolean).map((path) => join(ROOT, path))
  }
  const out = new Set()
  const run = (args) => {
    try {
      return execFileSync('git', args, { cwd: ROOT, encoding: 'utf8' })
    } catch {
      return ''
    }
  }
  for (const line of run(['diff', '--name-only', 'HEAD']).split('\n').filter(Boolean)) out.add(line)
  for (const line of run(['ls-files', '--others', '--exclude-standard']).split('\n').filter(Boolean)) out.add(line)
  return [...out].map((path) => join(ROOT, path))
}

/**
 * 逐行数函数体：靠"缩进回退"判断结束，够用且不引入解析器依赖（零新增依赖）。
 * @returns {{name: string, line: number, lines: number}[]}
 */
function functionsIn(text) {
  const lines = text.split('\n')
  const found = []
  const start = /^\s*(?:export\s+)?(?:async\s+)?function\s+([A-Za-z_$][\w$]*)|^\s*(?:export\s+)?(?:async\s+)?([A-Za-z_$][\w$]*)\s*\([^;]*\)\s*\{\s*$|=>\s*\{\s*$/
  for (let index = 0; index < lines.length; index += 1) {
    const match = start.exec(lines[index])
    if (!match) continue
    const indent = lines[index].length - lines[index].trimStart().length
    let end = index + 1
    while (end < lines.length) {
      const line = lines[end]
      if (line.trim() !== '' && (line.length - line.trimStart().length) <= indent) break
      end += 1
    }
    const body = end - index
    if (body > 5) found.push({ name: match[1] ?? match[2] ?? '(arrow)', line: index + 1, lines: body })
  }
  return found
}

/** 新增的 import/依赖（只看被检查文件里出现的模块名，去重）。 */
function importsIn(text) {
  const names = new Set()
  for (const match of text.matchAll(/^\s*import\s+(?:[^'"]*from\s+)?['"]([^'"]+)['"]/gm)) names.add(match[1])
  for (const match of text.matchAll(/require\(\s*['"]([^'"]+)['"]\s*\)/g)) names.add(match[1])
  return [...names]
}

/** 收集事实：哪些函数/文件超限、用到哪些外部依赖。 */
function collect(files) {
  const bigFunctions = []
  const bigFiles = []
  const importMap = new Map()

  for (const path of files) {
    let text
    try {
      text = readFileSync(path, 'utf8')
    } catch {
      continue // 删除的文件
    }
    const shown = relative(ROOT, path)
    const lineCount = text.split('\n').length
    if (lineCount > FILE_LIMIT) bigFiles.push({ file: shown, lines: lineCount })
    for (const fn of functionsIn(text)) {
      if (fn.lines > FUNCTION_LIMIT) bigFunctions.push({ file: shown, ...fn })
    }
    for (const spec of importsIn(text)) {
      if (!importMap.has(spec)) importMap.set(spec, [])
      importMap.get(spec).push(shown)
    }
  }

  const external = [...importMap.entries()].filter(([spec]) => !spec.startsWith('.') && !spec.startsWith('node:'))
  return {
    checked: files.length,
    limits: { functionLines: FUNCTION_LIMIT, fileLines: FILE_LIMIT },
    bigFunctions: bigFunctions.sort((a, b) => b.lines - a.lines),
    bigFiles: bigFiles.sort((a, b) => b.lines - a.lines),
    externalImports: external.map(([spec, where]) => ({ spec, files: [...new Set(where)] })),
  }
}

/** 打印人类可读的报告。 */
function render(result) {
  process.stdout.write(`结构检查：扫了 ${result.checked} 个代码文件（阈值：函数 ${FUNCTION_LIMIT} 行 / 文件 ${FILE_LIMIT} 行）\n`)
  process.stdout.write('只报告、不卡人：超限项由人判定是否接受，并在 plan/tasks 里写明理由。\n\n')

  process.stdout.write(`函数超过 ${FUNCTION_LIMIT} 行：${result.bigFunctions.length} 个\n`)
  for (const fn of result.bigFunctions.slice(0, 20)) {
    process.stdout.write(`  ${String(fn.lines).padStart(4)} 行  ${fn.file}:${fn.line}  ${fn.name}()\n`)
  }
  if (result.bigFunctions.length > 20) process.stdout.write(`  …另有 ${result.bigFunctions.length - 20} 个\n`)

  process.stdout.write(`\n文件超过 ${FILE_LIMIT} 行：${result.bigFiles.length} 个\n`)
  for (const file of result.bigFiles) process.stdout.write(`  ${String(file.lines).padStart(4)} 行  ${file.file}\n`)

  process.stdout.write(`\n非内建的外部依赖：${result.externalImports.length} 个\n`)
  for (const item of result.externalImports) {
    process.stdout.write(`  ${item.spec}  ← ${item.files.join(', ')}\n`)
  }
  process.stdout.write('\n（连接器要求运行时零依赖：上面出现第三方包名时，需要逐条说明理由。）\n')
}

function report() {
  const files = changedFiles().filter((path) => CODE_EXT.has(extname(path)))
  const result = collect(files)
  if (has('json')) process.stdout.write(`${JSON.stringify(result, null, 2)}\n`)
  else render(result)
  return 0
}

try {
  process.exitCode = report()
} catch (error) {
  process.stderr.write(`check-structure: ${error?.stack ?? error}\n`)
  process.exitCode = 2
}
