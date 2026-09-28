#!/usr/bin/env node
// 本地化一致性检查器（离线、零依赖、只读源文件）。
//
//   node scripts/dev/check-localization.mjs            # 或 npm run check:i18n
//   node scripts/dev/check-localization.mjs --json     # 机器可读
//   node scripts/dev/check-localization.mjs --explain  # 打印豁免清单与理由
//
// 四条规则（每条独立报出，带 `文件:行` 与键/字面量）：
//
//   missing-key          en.lproj ↔ zh-Hans.lproj 双向缺键
//   duplicate-key        同一个 .strings 文件里同一个键出现 ≥2 次（iOS 静默后者覆盖前者）
//   hardcoded-string     含 CJK 的 Swift 字符串字面量，在 en.lproj 里找不到任何匹配键
//   unlocalized-binding  键在表里、调用点却不走本地化（`Text(String)` 是 verbatim）
//
// 退出码：0 = 无未豁免发现；1 = 有未豁免发现（全部打印）；2 = 工具自身错误
// （文件缺失 / .strings 解析失败 / 豁免清单缺 `reason` / 违反设置页豁免禁令）。
//
// 口径：
//   - 扫描范围是全仓（`*.swift` + 两个 `Localizable.strings`），没有设置页特判。
//   - 注释与多行字符串按**等长**替换 mask 掉（保留换行），否则行号会漂。
//   - 插值归一化：Swift 的 `\(…)` 与键里的 `%lld` / `%@` 都归约成「占位符」，
//     于是 `上下文占用 \(Int(x))%` 与键 `上下文占用 %lld%%` 判为命中（`%%` 算一个字面 `%`）。
//   - `unlocalized-binding` 只看四类**非本地化绑定位置**（见 NON_LOCALIZING_POSITIONS）：
//     `return "…"`、`let/var x: String = "…"`、String 型字面量集合/字典的元素、
//     已知 verbatim sink 的实参。落在 `Text`/`Button`/`String(localized:)` 这类
//     本地化初始化器实参位置的，一律排除。
//
// 怎么加豁免（`scripts/dev/localization-exemptions.json`）：
//
//   { "rule": "unlocalized-binding", "file": "…/GitViews.swift", "snippet": "…",
//     "symbol": "GitView", "reason": "必填、非空", "backlog": "i18n-backlog-git" }
//
//   - `file` 支持 `*` / `**` 通配；`symbol` / `snippet` 是正则，可省。
//   - 缺 `reason` 直接 exit 2；`--explain` 打印全表。
//   - 末尾**永远**打印豁免总数，让它增长可见。
//   - `Features/Settings/**` 与 `Design/Components.swift` 不允许出现
//     `unlocalized-binding` 豁免（唯一例外：`SettingsLabels` 三张字典表）——
//     违反即 exit 2，设置页必须真改干净，不能靠豁免糊过去。

import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs'
import { join, relative, sep } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = fileURLToPath(new URL('../..', import.meta.url)).replace(/\/$/, '')

const STRINGS = {
  en: 'ios/DSHMobile/DSHMobile/en.lproj/Localizable.strings',
  'zh-Hans': 'ios/DSHMobile/DSHMobile/zh-Hans.lproj/Localizable.strings',
}
const EXEMPTIONS_PATH = 'scripts/dev/localization-exemptions.json'

/// 扫描时跳过的目录：构建产物、依赖、运行记录，都不是源。
const SKIP_DIRS = new Set([
  '.git', '.build', '.venv', 'node_modules', 'DerivedData', 'build', 'runs',
  'Pods', '.swiftpm', 'attachments', 'objects',
])

/// 含 CJK 才算「用户可见文案」。刻意不含通用标点区（`—` U+2014、`…` U+2026）：
/// 那是排版符号不是文案，算进来只会把 `"—"` 这种占位符变成噪音。
const CJK = /[\u3000-\u303F\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF\uFF00-\uFFEF]/

/// 把字面量当本地化值用的初始化器：实参位置天然会走 Localizable.strings。
const LOCALIZING_CALLS = new Set([
  'Text', 'Button', 'Label', 'LabeledContent', 'Toggle', 'Picker', 'TextField',
  'SecureField', 'TextEditor', 'Stepper', 'DatePicker', 'Link', 'Menu', 'Section',
  'DisclosureGroup', 'confirmationDialog', 'alert', 'navigationTitle',
  'navigationBarTitle', 'accessibilityLabel', 'accessibilityHint', 'help',
  'String', 'LocalizationValue', 'ProgressView', 'Menu', 'TabView',
  // `String(format: String(localized: "第 %lld 条"), …)`：字面量的紧邻 callee 是
  // 实参标签 `localized`，不是 `String`。不认它就会把这类已经本地化的行误报。
  'localized',
])

/// 已知**不**本地化的 String 出口：传进去的文案会原样显示。
///
/// 这是「初始清单」的性质，会随代码变化：`Badge` 曾经在这里（`Text(text)` 是
/// verbatim），`Design/Components.swift` 把 body 改成
/// `Text(String(localized: String.LocalizationValue(text)))` 之后它就不再是 sink 了
/// —— 再留着它，`Badge(text: "本机")` 会被误报成「调用点不走本地化」。
/// 往这里加名字之前先确认那个出口真的不本地化。
const VERBATIM_SINKS = new Set([
  'PanelSection', 'EmptyStateView', 'ErrorStateView',
])

/// 设置页范围：这里的 `unlocalized-binding` 只允许 `SettingsLabels` 例外。
const SETTINGS_SCOPE = [
  'ios/DSHMobile/DSHMobile/Features/Settings/**',
  'ios/DSHMobile/DSHMobile/Design/Components.swift',
]

/// 设置页唯一允许 `unlocalized-binding` 豁免的地方：`SettingsLabels` 的三张字典表。
/// 豁免的 `symbol` 正则必须**只**命中这些名字之一，否则 exit 2。
const SETTINGS_LABEL_TABLES = [
  'SettingsLabels', 'namespaceTitles', 'fieldLabels', 'valueLabels', 'credentialRefSibling',
]

const isSettingsLabelTable = (symbolPattern) => {
  if (typeof symbolPattern !== 'string' || !symbolPattern) return false
  let re
  try {
    re = new RegExp(symbolPattern)
  } catch {
    return false
  }
  return SETTINGS_LABEL_TABLES.some((name) => re.test(name))
}

class ToolError extends Error {}

// ---------------------------------------------------------------- .strings

/// 解析 `.strings`：`"键" = "值";`，键/值都可以跨行、可以带转义。
///
/// 手写扫描而不是正则：仓库里真的有一条键跨三行
/// （`NewSessionView.swift:90` 的 `"%@\n\n会先把它登记为一个工作区…"`），
/// 按行正则会把它的键算错，进而把它误报成硬编码。
function parseStrings(text, file) {
  const entries = []
  let i = 0
  let line = 1
  const N = text.length

  const bump = () => {
    if (text[i] === '\n') line += 1
    i += 1
  }
  const skipSpace = () => {
    while (i < N && /\s/.test(text[i])) bump()
  }
  const readQuoted = () => {
    if (text[i] !== '"') throw new ToolError(`${file}:${line} 期望字符串字面量，实际是 ${JSON.stringify(text[i])}`)
    bump()
    let raw = ''
    let closed = false
    while (i < N) {
      const c = text[i]
      if (c === '\\') {
        raw += c + (text[i + 1] ?? '')
        bump()
        bump()
        continue
      }
      if (c === '"') {
        bump()
        closed = true
        break
      }
      raw += c
      bump()
    }
    if (!closed) throw new ToolError(`${file}:${line} 字符串没有闭合`)
    return unescape(raw)
  }

  while (i < N) {
    if (text[i] === '/' && text[i + 1] === '*') {
      bump()
      bump()
      while (i < N && !(text[i] === '*' && text[i + 1] === '/')) bump()
      if (i >= N) throw new ToolError(`${file}: 块注释没有闭合`)
      bump()
      bump()
      continue
    }
    if (text[i] === '/' && text[i + 1] === '/') {
      while (i < N && text[i] !== '\n') bump()
      continue
    }
    if (/\s/.test(text[i])) {
      bump()
      continue
    }
    const startLine = line
    const key = readQuoted()
    skipSpace()
    if (text[i] !== '=') throw new ToolError(`${file}:${line} 键 ${JSON.stringify(key)} 后面不是 "="`)
    bump()
    skipSpace()
    const value = readQuoted()
    skipSpace()
    if (text[i] !== ';') throw new ToolError(`${file}:${line} 键 ${JSON.stringify(key)} 的赋值没有以 ";" 结束`)
    bump()
    entries.push({ key, value, line: startLine })
  }
  return entries
}

function unescape(raw) {
  let out = ''
  for (let i = 0; i < raw.length; i += 1) {
    const c = raw[i]
    if (c !== '\\') {
      out += c
      continue
    }
    const next = raw[i + 1]
    i += 1
    switch (next) {
      case 'n': out += '\n'; break
      case 't': out += '\t'; break
      case 'r': out += '\r'; break
      case '"': out += '"'; break
      case "'": out += "'"; break
      case '\\': out += '\\'; break
      case 'u': {
        const brace = /^\{([0-9A-Fa-f]+)\}/.exec(raw.slice(i + 1))
        if (brace) {
          out += String.fromCodePoint(parseInt(brace[1], 16))
          i += brace[0].length
        } else {
          out += '\\u'
        }
        break
      }
      default: out += `\\${next ?? ''}`
    }
  }
  return out
}

// ---------------------------------------------------------------- 归一化

/// 键里的 `%` 格式符：`%lld` / `%@` / `%1$@` / `%%`（`%%` 是字面 `%`）。
const SPECIFIER = /%(?:%|(?:[0-9]+\$)?[-+ #0]*[0-9]*(?:\.[0-9]+)?(?:hh|h|ll|l|z|t|j|q)?[@dDiuUxXoOfFeEgGcCsSaAp])/g

/// 一个键/字面量 → 「字面段」数组，占位符就是段与段之间的边界。
///
/// 于是「有没有插值」不再是字符串比较，而是数组比较：
///   `上下文占用 \(Int(x))%` → ["上下文占用 ", "%"]
///   `上下文占用 %lld%%`     → ["上下文占用 ", "%"]   ← 命中
function segmentsFromKey(key) {
  const segments = []
  let current = ''
  let last = 0
  SPECIFIER.lastIndex = 0
  let match
  while ((match = SPECIFIER.exec(key)) !== null) {
    current += key.slice(last, match.index)
    if (match[0] === '%%') {
      current += '%'
    } else {
      segments.push(current)
      current = ''
    }
    last = match.index + match[0].length
  }
  current += key.slice(last)
  segments.push(current)
  return segments
}

/// Swift 字面量的原始源码（引号之间、转义未解）→ 同样的「字面段」数组。
///
/// 两种占位符都算：`\(…)` 插值，以及字面量里已经写好的 `%lld` / `%@`。
/// 后者是仓库里真实存在的写法（`String(format: String(localized: "第 %lld 条"), …)`），
/// 不认它就会把已经本地化的行误报成硬编码。
function segmentsFromLiteral(raw) {
  const segments = []
  let current = ''
  let i = 0
  while (i < raw.length) {
    const c = raw[i]
    if (c === '\\' && raw[i + 1] === '(') {
      segments.push(current)
      current = ''
      i = skipInterpolation(raw, i + 1)
      continue
    }
    if (c === '\\') {
      const next = raw[i + 1]
      i += 2
      switch (next) {
        case 'n': current += '\n'; break
        case 't': current += '\t'; break
        case 'r': current += '\r'; break
        case '"': current += '"'; break
        case "'": current += "'"; break
        case '\\': current += '\\'; break
        case 'u': {
          const brace = /^\{([0-9A-Fa-f]+)\}/.exec(raw.slice(i))
          if (brace) {
            current += String.fromCodePoint(parseInt(brace[1], 16))
            i += brace[0].length
          }
          break
        }
        default: current += `\\${next ?? ''}`
      }
      continue
    }
    if (c === '%') {
      SPECIFIER.lastIndex = i
      const match = SPECIFIER.exec(raw)
      if (match && match.index === i) {
        if (match[0] === '%%') current += '%'
        else {
          segments.push(current)
          current = ''
        }
        i += match[0].length
        continue
      }
    }
    current += c
    i += 1
  }
  segments.push(current)
  return segments
}

/// `\(` 之后找到配对的 `)`，跳过其中的嵌套字符串与括号。
function skipInterpolation(raw, openIndex) {
  let depth = 0
  let i = openIndex
  while (i < raw.length) {
    const c = raw[i]
    if (c === '"') {
      i += 1
      while (i < raw.length && raw[i] !== '"') i += raw[i] === '\\' ? 2 : 1
      i += 1
      continue
    }
    if (c === '(') depth += 1
    if (c === ')') {
      depth -= 1
      if (depth === 0) return i + 1
    }
    i += 1
  }
  return raw.length
}

const signature = (segments) => JSON.stringify(segments)

// ---------------------------------------------------------------- Swift

/// 扫一个 Swift 文件：mask 掉注释与多行字符串，收集单行字符串字面量。
function scanSwift(src) {
  const out = src.split('')
  const literals = []
  const N = src.length
  const blank = (from, to) => {
    for (let k = from; k < to && k < N; k += 1) if (out[k] !== '\n') out[k] = ' '
  }

  let i = 0
  while (i < N) {
    const c = src[i]
    if (c === '/' && src[i + 1] === '/') {
      let j = i
      while (j < N && src[j] !== '\n') j += 1
      blank(i, j)
      i = j
      continue
    }
    if (c === '/' && src[i + 1] === '*') {
      let j = i + 2
      let depth = 1
      while (j < N && depth > 0) {
        if (src[j] === '/' && src[j + 1] === '*') { depth += 1; j += 2; continue }
        if (src[j] === '*' && src[j + 1] === '/') { depth -= 1; j += 2; continue }
        j += 1
      }
      blank(i, j)
      i = j
      continue
    }
    if (src.startsWith('"""', i)) {
      let j = i + 3
      while (j < N && !src.startsWith('"""', j)) j += src[j] === '\\' ? 2 : 1
      j = Math.min(N, j + 3)
      blank(i, j)
      i = j
      continue
    }
    if (c === '"') {
      const start = i
      let j = i + 1
      let raw = ''
      while (j < N) {
        const ch = src[j]
        if (ch === '\\') {
          if (src[j + 1] === '(') {
            const close = skipInterpolation(src, j + 1)
            raw += src.slice(j, close)
            j = close
            continue
          }
          raw += ch + (src[j + 1] ?? '')
          j += 2
          continue
        }
        if (ch === '"' || ch === '\n') break
        raw += ch
        j += 1
      }
      literals.push({ start, end: j, raw })
      i = j + 1
      continue
    }
    i += 1
  }
  return { masked: out.join(''), literals }
}

function lineIndex(src) {
  const starts = [0]
  for (let i = 0; i < src.length; i += 1) if (src[i] === '\n') starts.push(i + 1)
  return (offset) => {
    let lo = 0
    let hi = starts.length - 1
    while (lo < hi) {
      const mid = (lo + hi + 1) >> 1
      if (starts[mid] <= offset) lo = mid
      else hi = mid - 1
    }
    return lo + 1
  }
}

/// 字面量所在的最内层**调用**的 callee 名；直接躺在集合/闭包里时返回 null。
function enclosingCall(masked, offset) {
  let depth = 0
  for (let k = offset - 1; k >= 0; k -= 1) {
    const c = masked[k]
    if (c === ')' || c === ']' || c === '}') { depth += 1; continue }
    if (c === '(') {
      if (depth > 0) { depth -= 1; continue }
      const name = /([A-Za-z_][A-Za-z0-9_.]*)\s*$/.exec(masked.slice(0, k))
      return name ? name[1].split('.').pop() : null
    }
    if (c === '[' || c === '{') {
      if (depth > 0) { depth -= 1; continue }
      return null
    }
  }
  return null
}

/// 最内层未闭合的 `[` 的偏移（用于判断「字面量是不是集合/字典的元素」）。
function enclosingBracket(masked, offset) {
  let depth = 0
  for (let k = offset - 1; k >= 0; k -= 1) {
    const c = masked[k]
    if (c === ']') { depth += 1; continue }
    if (c === '[') {
      if (depth > 0) { depth -= 1; continue }
      return k
    }
  }
  return -1
}

/// 最近的外层声明名，给豁免的 `symbol` 用。
function enclosingSymbol(masked, offset) {
  const head = masked.slice(0, offset)
  const re = /\b(?:func|var|let|struct|enum|class|extension|actor|protocol)\s+([A-Za-z_][A-Za-z0-9_]*)/g
  let last = null
  let match
  while ((match = re.exec(head)) !== null) last = match[1]
  return last
}

/// 四类**非本地化绑定位置**里的哪一类（不在其中返回 null）。
function nonLocalizingPosition(masked, offset, callee) {
  const before = masked.slice(Math.max(0, offset - 600), offset)

  if (/\breturn\b[^;{}]*$/.test(before)) return 'return'
  if (/(?:let|var)\s+[A-Za-z_][A-Za-z0-9_]*\s*:\s*[^=;{}()]{0,80}String[^=;{}()]{0,80}=\s*$/.test(before)) {
    return 'typed-binding'
  }
  if (callee && VERBATIM_SINKS.has(callee)) return `sink:${callee}`

  const open = enclosingBracket(masked, offset)
  if (open >= 0) {
    const head = masked.slice(Math.max(0, open - 220), open)
    if (/:\s*\[[^[\]]{0,80}String[^[\]]{0,80}\]\s*=\s*$/.test(head)) return 'string-collection'
  }
  return null
}

// ---------------------------------------------------------------- 豁免

function globToRegExp(pattern) {
  if (!/[*?]/.test(pattern)) return null
  let out = '^'
  for (let i = 0; i < pattern.length; i += 1) {
    const c = pattern[i]
    if (c === '*') {
      if (pattern[i + 1] === '*') { out += '.*'; i += 1 } else out += '[^/]*'
      continue
    }
    if (c === '?') { out += '.'; continue }
    out += /[A-Za-z0-9_/.-]/.test(c) ? c : `\\${c}`
  }
  return new RegExp(`${out}$`)
}

function loadExemptions() {
  const path = join(ROOT, EXEMPTIONS_PATH)
  if (!existsSync(path)) throw new ToolError(`缺少豁免清单 ${EXEMPTIONS_PATH}`)
  let parsed
  try {
    parsed = JSON.parse(readFileSync(path, 'utf8'))
  } catch (error) {
    throw new ToolError(`${EXEMPTIONS_PATH} 不是合法 JSON：${error.message}`)
  }
  const list = parsed.exemptions
  if (!Array.isArray(list)) throw new ToolError(`${EXEMPTIONS_PATH} 缺少 exemptions 数组`)
  list.forEach((item, index) => {
    const at = `${EXEMPTIONS_PATH} exemptions[${index}]`
    if (typeof item.rule !== 'string' || !item.rule) throw new ToolError(`${at} 缺 rule`)
    if (typeof item.file !== 'string' || !item.file) throw new ToolError(`${at} 缺 file`)
    if (typeof item.reason !== 'string' || !item.reason.trim()) {
      throw new ToolError(`${at} 缺 reason —— 每条豁免都必须写明理由（design G7）`)
    }
    for (const key of ['symbol', 'snippet']) {
      if (item[key] === undefined) continue
      try {
        new RegExp(item[key])
      } catch (error) {
        throw new ToolError(`${at} 的 ${key} 不是合法正则：${error.message}`)
      }
    }
  })
  return list
}

function matchExemption(exemption, finding) {
  if (exemption.rule !== finding.rule) return false
  const glob = globToRegExp(exemption.file)
  if (glob ? !glob.test(finding.file) : exemption.file !== finding.file) return false
  if (exemption.symbol && !new RegExp(exemption.symbol).test(finding.symbol ?? '')) return false
  if (exemption.snippet && !new RegExp(exemption.snippet).test(finding.subject)) return false
  return true
}

const inSettingsScope = (file) =>
  SETTINGS_SCOPE.some((pattern) => {
    const glob = globToRegExp(pattern)
    return glob ? glob.test(file) : pattern === file
  })

// ---------------------------------------------------------------- 规则

function collectFindings() {
  const findings = []
  const tables = {}
  for (const [locale, path] of Object.entries(STRINGS)) {
    const absolute = join(ROOT, path)
    if (!existsSync(absolute)) throw new ToolError(`缺少 ${path}`)
    const entries = parseStrings(readFileSync(absolute, 'utf8'), path)
    tables[locale] = { path, entries }

    const byKey = new Map()
    for (const entry of entries) {
      if (!byKey.has(entry.key)) byKey.set(entry.key, [])
      byKey.get(entry.key).push(entry)
    }
    for (const [key, group] of byKey) {
      if (group.length < 2) continue
      findings.push({
        rule: 'duplicate-key',
        file: path,
        line: group[1].line,
        subject: key,
        extra: `出现 ${group.length} 次：${group.map((e) => `${e.line}:"${e.value}"`).join(' / ')}（iOS 后者覆盖前者）`,
      })
    }
    tables[locale].byKey = byKey
  }

  const en = tables.en
  const zh = tables['zh-Hans']
  for (const [key, group] of en.byKey) {
    if (zh.byKey.has(key)) continue
    findings.push({
      rule: 'missing-key',
      file: zh.path,
      line: 0,
      subject: key,
      extra: `en 有（${en.path}:${group[0].line}）而 zh-Hans 没有`,
    })
  }
  for (const [key, group] of zh.byKey) {
    if (en.byKey.has(key)) continue
    findings.push({
      rule: 'missing-key',
      file: en.path,
      line: 0,
      subject: key,
      extra: `zh-Hans 有（${zh.path}:${group[0].line}）而 en 没有`,
    })
  }

  const keyBySignature = new Map()
  for (const key of en.byKey.keys()) {
    const sig = signature(segmentsFromKey(key))
    if (!keyBySignature.has(sig)) keyBySignature.set(sig, key)
  }

  for (const file of swiftFiles()) {
    const source = readFileSync(join(ROOT, file), 'utf8')
    const { masked, literals } = scanSwift(source)
    const at = lineIndex(source)
    for (const literal of literals) {
      if (!CJK.test(literal.raw)) continue
      const segments = segmentsFromLiteral(literal.raw)
      const key = keyBySignature.get(signature(segments))
      const line = at(literal.start)
      const symbol = enclosingSymbol(masked, literal.start)
      if (!key) {
        findings.push({
          rule: 'hardcoded-string',
          file,
          line,
          subject: displayLiteral(literal.raw),
          symbol,
          extra: 'en.lproj 里没有匹配的键',
        })
        continue
      }
      const callee = enclosingCall(masked, literal.start)
      if (callee && LOCALIZING_CALLS.has(callee)) continue
      const position = nonLocalizingPosition(masked, literal.start, callee)
      if (!position) continue
      findings.push({
        rule: 'unlocalized-binding',
        file,
        line,
        subject: displayLiteral(literal.raw),
        symbol,
        extra: `键「${key}」在表里，但这里是 ${position} 位置（${callee ? `${callee}() 的实参` : '字面量直用'}）`,
      })
    }
  }
  return findings
}

const displayLiteral = (raw) => `"${raw.replace(/\n/g, '\\n')}"`

function swiftFiles() {
  const found = []
  const walk = (dir) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      if (entry.name.startsWith('.') && entry.name !== '.') continue
      const absolute = join(dir, entry.name)
      if (entry.isDirectory()) {
        if (SKIP_DIRS.has(entry.name)) continue
        walk(absolute)
        continue
      }
      if (entry.isFile() && entry.name.endsWith('.swift')) {
        found.push(relative(ROOT, absolute).split(sep).join('/'))
      }
    }
  }
  walk(ROOT)
  return found.sort()
}

// ---------------------------------------------------------------- 主流程

function main() {
  const argv = process.argv.slice(2)
  const asJson = argv.includes('--json')
  const explain = argv.includes('--explain')

  const exemptions = loadExemptions()
  const findings = collectFindings()

  const reported = []
  const exempted = []
  for (const finding of findings) {
    const hit = exemptions.find((exemption) => matchExemption(exemption, finding))
    if (!hit) {
      reported.push(finding)
      continue
    }
    if (finding.rule === 'unlocalized-binding' && inSettingsScope(finding.file) && !isSettingsLabelTable(hit.symbol)) {
      throw new ToolError(
        `${finding.file}:${finding.line} 命中了一条设置页的 unlocalized-binding 豁免` +
        `（symbol=${JSON.stringify(hit.symbol)}）——设置页不允许这种豁免，` +
        '唯一例外是 SettingsLabels 三张字典表。请改代码，不要改豁免清单。',
      )
    }
    exempted.push({ finding, exemption: hit })
  }

  reported.sort((a, b) => (a.file === b.file ? a.line - b.line : a.file < b.file ? -1 : 1))

  if (asJson) {
    console.log(JSON.stringify({
      root: ROOT,
      counts: countByRule(findings),
      exemptedCount: exempted.length,
      exemptionCount: exemptions.length,
      findings: reported.map((f) => ({ ...f })),
      exempted: exempted.map((e) => ({ ...e.finding, reason: e.exemption.reason, backlog: e.exemption.backlog ?? null })),
    }, null, 2))
  } else {
    for (const finding of reported) {
      const where = finding.line ? `${finding.file}:${finding.line}` : finding.file
      console.log(`ERROR ${finding.rule} ${where} ${finding.subject} ${finding.extra}`)
    }
    const counts = countByRule(reported)
    console.log('')
    console.log(`missing-key: ${counts['missing-key'] ?? 0}  duplicate-key: ${counts['duplicate-key'] ?? 0}` +
                `  hardcoded-string: ${counts['hardcoded-string'] ?? 0}  unlocalized-binding: ${counts['unlocalized-binding'] ?? 0}`)
    console.log(`扫描：${swiftFiles().length} 个 .swift + 2 个 Localizable.strings`)
    console.log(`豁免 ${exemptions.length} 条（其中 ${exempted.length} 条命中本次发现，` +
                `${exemptions.length - new Set(exempted.map((e) => e.exemption)).size} 条已过期）` +
                (reported.length ? `　未豁免发现 ${reported.length} 条` : '　未豁免发现 0 条'))
    if (explain) {
      console.log('')
      console.log('豁免清单：')
      for (const exemption of exemptions) {
        const backlog = exemption.backlog ? ` [${exemption.backlog}]` : ''
        console.log(`  - ${exemption.rule} ${exemption.file}${exemption.symbol ? ` symbol=${exemption.symbol}` : ''}` +
                    `${exemption.snippet ? ` snippet=/${exemption.snippet}/` : ''}${backlog}`)
        console.log(`      ${exemption.reason}`)
      }
    }
  }
  process.exit(reported.length ? 1 : 0)
}

function countByRule(list) {
  const counts = {}
  for (const finding of list) counts[finding.rule] = (counts[finding.rule] ?? 0) + 1
  return counts
}

try {
  main()
} catch (error) {
  if (error instanceof ToolError) {
    console.error(`工具错误：${error.message}`)
    process.exit(2)
  }
  throw error
}
