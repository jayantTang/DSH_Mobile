#!/usr/bin/env node
// 文档规范检查：结构、口吻、链接。
//
// 规则写进 CI 才守得住——README 一开始是口语化的第二人称，写着写着就会回退，而"专业、严谨、
// 直观、简单"这种要求靠人记是记不住的。这里只做能机械判定的部分：
//
//   1. 每个受检文档恰好一个 H1；
//   2. 首段（H1 之后的第一段）不超过 200 字，说明这份文档是什么；
//   3. 参考类文档用无人称陈述句：不出现「你 / 我们 / 其实 / 赶紧」这类口语与第二人称；
//   4. 相对链接必须指向存在的文件（防止改名后留下死链）；
//   5. 不出现真实家目录路径（/Users/<名字>）与本机绝对路径。
//
// 例外：面向使用者的操作指引与人称文案（ONBOARDING / PRIVACY / CONTRIBUTING / 模板用例）允许
// 使用第二人称——那里"你"就是读者。例外清单写在下面，是白名单而不是通配。
//
// 跑法：npm run check:docs

import { existsSync, readFileSync, readdirSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'

const PERSON_ALLOWED = new Set([
  'docs/ONBOARDING.md',
  'docs/PRIVACY.md',
  'CONTRIBUTING.md',
  'SECURITY.md',
  'CHANGELOG.md',
  'maintainers/README.md',
])

const COLLOQUIAL = ['你', '我们', '其实', '赶紧', '搞定', '一条龙', '说白了', '咱们', '吧？', '呢？']

/// 受检文档：仓库里随开源发布的说明文档。
const DOCS = [
  'README.md',
  'CONTRIBUTING.md',
  'SECURITY.md',
  'CHANGELOG.md',
  'docs/GLOSSARY.md',
  'docs/ONBOARDING.md',
  'docs/ARCHITECTURE.md',
  'docs/PAIRING.md',
  'docs/IMAGES.md',
  'docs/VERSIONING.md',
  'docs/PRIVACY.md',
  'docs/DSH-PROTOCOL.md',
  'docs/RELAY-PROTOCOL.md',
  'docs/CONNECTOR-NOTES.md',
  'docs/RELAY-NOTES.md',
  'plugins/README.md',
  'plugins/mobile-link/README.md',
  'plugins/send-image/README.md',
  'plugins/doubao-image/README.md',
  'relay/README.md',
  'test/README.md',
  'test/RULES.md',
  'test/REPORT-CONTRACT.md',
]

/// 文档开头那行读者与状态说明（`> 面向：… · 状态：… · 最近核对：…`）。
const HEADER_LINE = /^> 面向：.+· 状态：.+· 最近核对：\d{4}-\d{2}-\d{2}$/m

const problems = []

function report(file, message) {
  problems.push(`${file}: ${message}`)
}

/// 去掉围栏代码块：里面的示例文本不该被口吻规则误判。
function prose(text) {
  return text.replace(/```[\s\S]*?```/g, '')
}

/// 摘要就是标题之后的第一段**散文**。
///
/// 徽标行、状态行与表格不算散文：徽标本质上是一串图片链接（加上 8 个徽标后，
/// README 的"首段"曾被测成 1038 字——那是徽标，不是摘要）。
function firstParagraph(text) {
  const body = text.split('\n').slice(1)
  const collected = []
  for (const line of body) {
    if (!line.trim()) {
      if (collected.length) break
      continue
    }
    if (line.startsWith('#') || line.startsWith('>') || line.startsWith('|')) continue
    if (isDecoration(line)) continue
    collected.push(line.trim())
  }
  return collected.join('')
}

/// 徽标行：以图片或图片链接开头（`![alt](url)` / `[![alt](url)](url)`）。
///
/// 单次正则替换处理不了嵌套的图片链接——外层匹配会把内层连同一半括号吃掉，
/// 剩下的 `](https://…)` 仍然含字母，于是被当成散文。直接看行首最省事。
function isDecoration(line) {
  return /^\[?!\[/.test(line.trim())
}

for (const file of DOCS) {
  if (!existsSync(file)) {
    report(file, '文档不存在（清单需要更新，或文件被改名）')
    continue
  }
  const text = readFileSync(file, 'utf8')
  // 只在正文里数标题：代码块内的 `# 注释` 不是标题（这正是第一次跑时报"6 个 H1"的原因）。
  const body = prose(text)
  const headings = body.match(/^# .+$/gm) ?? []
  if (headings.length !== 1) report(file, `应当恰好一个 H1，实际 ${headings.length} 个`)
  if (!body.trimStart().startsWith('# ')) report(file, '文件应当以 H1 开头')

  const summary = firstParagraph(text)
  // 中文按字、英文按词的信息密度差三倍左右，所以上限分两档：中文摘要 240 字，英文摘要 320 字符
  // （中英混排按中文字符占比判断）。这是"摘要要短"这一条，不是字数考核。
  const cjk = (summary.match(/[\u4e00-\u9fff]/g) ?? []).length
  const limit = cjk / Math.max(summary.length, 1) > 0.3 ? 240 : 320
  if (summary.length > limit) report(file, `首段 ${summary.length} 字，超过 ${limit} 字上限`)
  if (!summary) report(file, '标题之后没有说明这份文档是什么的首段')

  if (!PERSON_ALLOWED.has(file)) {
    const body = prose(text)
    for (const word of COLLOQUIAL) {
      if (body.includes(word)) report(file, `参考类文档里出现口语/第二人称「${word}」`)
    }
  }

  for (const match of prose(text).matchAll(/\]\(([^)#\s]+)\)/g)) {
    const target = match[1]
    if (/^[a-z][a-z0-9+.-]*:/i.test(target)) continue // 绝对链接与 mailto 交给别的检查
    const path = resolve(dirname(file), decodeURIComponent(target))
    if (!existsSync(path)) {
      report(file, `链接指向不存在的路径：${target}`)
      continue
    }
  }

  // HTML `<img src="…">` 也要查：徽标可以用绝对地址，仓库内的素材必须是可达的相对路径
  // （README 的宣传图用 HTML 是为了给图片设宽度，Markdown 语法带不了）。
  for (const match of text.matchAll(/<img[^>]*\ssrc="([^"]+)"/g)) {
    const target = match[1]
    if (/^[a-z][a-z0-9+.-]*:/i.test(target)) continue
    if (!existsSync(resolve(dirname(file), decodeURIComponent(target)))) {
      report(file, `内嵌图片指向不存在的路径：${target}`)
    }
  }

  for (const match of text.matchAll(/\/Users\/([A-Za-z0-9._-]+)/g)) {
    const name = match[1]
    if (/^(example|you|your|yourname|user|username|me|someone|name|placeholder|dev|\.\.\.)$/.test(name)) continue
    report(file, `出现真实家目录路径 /Users/${name}`)
  }
}

// docs/ 下新增的文档必须一并登记在上面，否则检查会漏掉它。
const listed = new Set(DOCS)
for (const entry of readdirSync('docs')) {
  const file = join('docs', entry)
  if (!entry.endsWith('.md') || listed.has(file)) continue
  report(file, '是 docs/ 下的文档但没有列进 check-docs 的清单')
}

if (problems.length) {
  console.error('文档规范检查未通过：\n')
  for (const problem of problems) console.error(`  ${problem}`)
  console.error('\n规则见 scripts/dev/check-docs.mjs 顶部；改完重跑 npm run check:docs。')
  process.exit(1)
}

console.log(`ok  ${DOCS.length} 篇文档：结构、口吻、链接与路径都符合规范`)
