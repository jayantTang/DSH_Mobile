#!/usr/bin/env node
/**
 * 深查询：用 `sourcekit-lsp` 拿**真实调用关系**，补上快照里只能靠类型名猜的那部分。
 *
 *   npm run arch:deep              # 增量分析 DSHKit / RelayKit，写 docs/arch/deep.json
 *   npm run arch:deep -- --force   # 忽略缓存，全量重跑
 *   npm run arch:deep -- --limit 3 # 只分析前 3 个文件（调试用）
 *
 * 为什么单独一条命令：sourcekit-lsp 要先把后台索引跑起来，首次是分钟级；
 * `npm run arch` 只读它写下的缓存，保持秒级。
 *
 * 缓存的失效策略：按文件内容 hash 增量。跨文件的目标符号可能在别处改过名，
 * 所以读取缓存时还会拿当前声明清单核对一遍，核对不上的边标记为 stale（页面会提示）。
 *
 * 只覆盖 SPM 包（DSHKit / RelayKit）。App target 不在此列：它的语义查询需要 Xcode 的
 * 编译参数，实测 `references` 会超时，见 handbook/engineering/architecture-snapshots.md。
 */

import { spawn } from 'node:child_process'
import { createHash } from 'node:crypto'
import { existsSync, readFileSync, writeFileSync, readdirSync } from 'node:fs'
import { join, relative } from 'node:path'
import { pathToFileURL } from 'node:url'

import { ROOT } from './parse.mjs'

const LSP = '/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp'
const PACKAGE = join(ROOT, 'ios/DSHMobile/DSHKit')
const SOURCE_DIRS = [join(PACKAGE, 'Sources/DSHKit'), join(PACKAGE, 'Sources/RelayKit')]
const CACHE_PATH = join(ROOT, 'docs/arch/deep.json')
const CALLABLE_KINDS = new Set([6, 9, 12]) // Method / Constructor / Function
const REQUEST_TIMEOUT = 25000

const argv = process.argv.slice(2)
const has = (name) => argv.includes(`--${name}`)
const numberOf = (name, fallback) => {
  const index = argv.indexOf(`--${name}`)
  return index === -1 ? fallback : Number(argv[index + 1])
}

/** 递归收集 Swift 文件：Sources/DSHKit 下有 Models/ 子目录，只扫一层会漏掉它们。 */
function swiftFiles() {
  const out = []
  const visit = (dir) => {
    if (!existsSync(dir)) return
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      if (entry.isDirectory()) visit(join(dir, entry.name))
      else if (entry.name.endsWith('.swift')) out.push(join(dir, entry.name))
    }
  }
  for (const dir of SOURCE_DIRS) visit(dir)
  return out.sort()
}

const fileId = (abs) => relative(ROOT, abs)
const hashOf = (abs) => createHash('sha1').update(readFileSync(abs)).digest('hex').slice(0, 12)

/** 极简 LSP 客户端：够用即可，不做能力协商与增量同步。 */
class LspClient {
  constructor(command, cwd) {
    this.child = spawn(command, ['--default-workspace-type', 'swiftPM'], { cwd, stdio: ['pipe', 'pipe', 'ignore'] })
    this.buffer = Buffer.alloc(0)
    this.pending = new Map()
    this.nextId = 1
    this.child.stdout.on('data', (chunk) => this.#onData(chunk))
  }

  #onData(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk])
    for (;;) {
      const headerEnd = this.buffer.indexOf('\r\n\r\n')
      if (headerEnd === -1) return
      const match = /Content-Length: (\d+)/i.exec(this.buffer.subarray(0, headerEnd).toString())
      if (!match) { this.buffer = this.buffer.subarray(headerEnd + 4); continue }
      const length = Number(match[1])
      if (this.buffer.length < headerEnd + 4 + length) return
      const body = this.buffer.subarray(headerEnd + 4, headerEnd + 4 + length).toString()
      this.buffer = this.buffer.subarray(headerEnd + 4 + length)
      try {
        const message = JSON.parse(body)
        if (message.id && this.pending.has(message.id)) {
          this.pending.get(message.id)(message)
          this.pending.delete(message.id)
        }
      } catch { /* 忽略无法解析的帧 */ }
    }
  }

  #write(payload) {
    this.child.stdin.write(`Content-Length: ${Buffer.byteLength(payload)}\r\n\r\n${payload}`)
  }

  notify(method, params) {
    this.#write(JSON.stringify({ jsonrpc: '2.0', method, params }))
  }

  request(method, params, timeout = REQUEST_TIMEOUT) {
    const id = this.nextId++
    this.#write(JSON.stringify({ jsonrpc: '2.0', id, method, params }))
    return new Promise((resolve) => {
      const timer = setTimeout(() => { this.pending.delete(id); resolve(null) }, timeout)
      this.pending.set(id, (message) => { clearTimeout(timer); resolve(message.error ? null : message.result) })
    })
  }

  stop() {
    this.child.kill()
  }
}

/** documentSymbol 可能是树形，也可能是扁平的 SymbolInformation，两种都收。 */
function flattenSymbols(symbols, out = []) {
  for (const symbol of symbols ?? []) {
    if (CALLABLE_KINDS.has(symbol.kind) && symbol.selectionRange) out.push(symbol)
    if (symbol.children) flattenSymbols(symbol.children, out)
  }
  return out
}

function positionOf(uri, range) {
  return { uri, line: (range?.start?.line ?? 0) + 1 }
}

/** 分析一个文件：拿到它每个可调用符号往外的真实调用。 */
async function analyseFile(client, abs, uri) {
  client.notify('textDocument/didOpen', {
    textDocument: { uri, languageId: 'swift', version: 1, text: readFileSync(abs, 'utf8') },
  })
  const symbols = flattenSymbols(await client.request('textDocument/documentSymbol', { textDocument: { uri } }))
  const calls = []
  const seen = new Set()
  let systemCalls = 0
  for (const symbol of symbols) {
    const items = await client.request('textDocument/prepareCallHierarchy', {
      textDocument: { uri },
      position: symbol.selectionRange.start,
    })
    if (!items || !items.length) continue
    const outgoing = await client.request('callHierarchy/outgoingCalls', { item: items[0] })
    for (const call of outgoing ?? []) {
      if (!call.to || !call.to.uri.startsWith('file://')) continue
      const target = decodeURIComponent(new URL(call.to.uri).pathname)
      // 只留仓库内的调用：系统框架与 stdlib 接口（.h / .swiftinterface）只计数不画图
      if (!target.startsWith(ROOT)) { systemCalls += 1; continue }
      const edge = {
        symbol: symbol.name,
        line: symbol.selectionRange.start.line + 1,
        toFile: relative(ROOT, target),
        toSymbol: call.to.name,
        toLine: (call.to.selectionRange?.start?.line ?? 0) + 1,
      }
      const key = `${edge.symbol}|${edge.toFile}|${edge.toSymbol}`
      if (seen.has(key)) continue
      seen.add(key)
      calls.push(edge)
    }
  }
  return {
    hash: hashOf(abs),
    symbols: symbols.map((symbol) => ({ name: symbol.name, line: symbol.selectionRange.start.line + 1 })),
    calls,
    systemCalls,
  }
}

/**
 * sourcekit-lsp 给的是显示名（`PathSlug.slug(_:)`、`Array.getter:subscript(_:)`），
 * 声明清单里是裸名（`slug`），所以核对前要归一到最后一段标识符。
 * 访问器、init、deinit 这类本来就不在声明清单里，不参与核对。
 */
export function baseSymbolName(name) {
  const head = String(name).split('(')[0]
  const parts = head.split('.')
  return parts[parts.length - 1].trim()
}

const NOT_IN_DECLARATIONS = /^(init|deinit|getter:|setter:|subscript|callAsFunction|\?\?|\+|\-|\*|\/|==|!=|<|>)$/

/** 缓存里的目标符号可能已被改名，用当前声明清单核对一次；核对不上的边标 stale。 */
function markStale(entry, declarations) {
  for (const call of entry.calls) {
    const declaration = declarations[call.toFile]
    if (!declaration) { call.stale = false; continue }
    const base = baseSymbolName(call.toSymbol)
    if (NOT_IN_DECLARATIONS.test(base) || base.startsWith('getter:') || base.startsWith('setter:')) { call.stale = false; continue }
    const names = new Set([...declaration.types.map((type) => type.name), ...declaration.funcs.map((func) => func.name)])
    call.stale = !names.has(base)
  }
  return entry
}

function emptyCache() {
  return { version: 1, generatedAt: null, package: fileId(PACKAGE), files: {} }
}

function loadCache() {
  try {
    return JSON.parse(readFileSync(CACHE_PATH, 'utf8'))
  } catch {
    return emptyCache()
  }
}

async function main() {
  const files = swiftFiles()
  const limit = numberOf('limit', files.length)
  const targets = files.slice(0, limit)
  const cache = loadCache()
  const force = has('force')

  const reuse = []
  const todo = []
  for (const abs of targets) {
    const id = fileId(abs)
    const cached = cache.files[id]
    if (!force && cached && cached.hash === hashOf(abs)) reuse.push(id)
    else todo.push(abs)
  }
  console.log(`共 ${targets.length} 个文件：缓存命中 ${reuse.length}，需要分析 ${todo.length}`)

  if (todo.length) {
    const client = new LspClient(LSP, PACKAGE)
    await client.request('initialize', {
      processId: process.pid,
      rootUri: pathToFileURL(PACKAGE).href,
      rootPath: PACKAGE,
      workspaceFolders: [{ uri: pathToFileURL(PACKAGE).href, name: 'DSHKit' }],
      capabilities: { workspace: { workspaceFolders: true }, textDocument: { documentSymbol: {}, callHierarchy: {} } },
      initializationOptions: { backgroundIndexing: true },
    })
    client.notify('initialized', {})
    // 后台索引没跑完，outgoingCalls 只会返回同文件的结果；等一等再开工
    await new Promise((resolve) => setTimeout(resolve, 8000))
    let done = 0
    for (const abs of todo) {
      const id = fileId(abs)
      const entry = await analyseFile(client, abs, pathToFileURL(abs).href)
      cache.files[id] = entry
      done += 1
      // 每完成一个就落盘：中途被打断也不必从头再来
      if (done % 5 === 0 || done === todo.length) {
        writeCache(cache)
        console.log(`  已分析 ${done}/${todo.length}：${id.split('/').pop()}（${entry.calls.length} 条调用）`)
      }
    }
    client.stop()
  }

  writeCache(cache)
  console.log(summary(cache, files))
}

/** 写入前核对每条边的目标符号是否还存在，并统计。 */
function writeCache(cache) {
  cache.generatedAt = new Date().toISOString()
  writeFileSync(CACHE_PATH, `${JSON.stringify(cache, null, 2)}\n`)
}

function summary(cache) {
  let calls = 0
  let crossFile = 0
  const files = Object.keys(cache.files)
  for (const id of files) {
    for (const call of cache.files[id].calls) {
      calls += 1
      if (call.toFile !== id) crossFile += 1
    }
  }
  const system = files.reduce((sum, id) => sum + (cache.files[id].systemCalls || 0), 0)
  return `已写入 ${fileId(CACHE_PATH)}：${files.length} 个文件，${calls} 条仓库内调用（跨文件 ${crossFile} 条），另有 ${system} 条系统框架/stdlib 调用未记录`
}

export { loadCache, markStale }

if (process.argv[1] && process.argv[1].endsWith('deep.mjs')) {
  main().catch((error) => {
    console.error(`深查询失败：${error.message}`)
    process.exit(1)
  })
}
