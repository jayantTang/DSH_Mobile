#!/usr/bin/env node
/**
 * 检查**被 git 跟踪的文件**里有没有本机真值。
 *
 *   node scripts/dev/check-secrets.mjs        # 有问题就非零退出
 *
 * 为什么要单独一个脚本：这个仓库最容易犯的错就是把本机真值写进一个"顺手"的文件
 * 里——审核备注里的一次性邀请码、示例命令里的真实中转地址、调试脚本里复制来的
 * deviceToken。CI 里已经查了「本机专用文件没被跟踪」和「家目录/凭据形状」，
 * 那份检查漏掉的正是邀请码与中转地址本身：邀请码形状规整、地址是个正常域名，
 * 靠肉眼和靠通用规则都拦不住。这里补齐这两类，顺便把家目录与凭据形状也查一遍，
 * 让本机一条命令就能过闸。
 *
 * 真值来源：`.env.local`（不入库）与 `~/.dsh/mobile-link/agent.json`。没有这些
 * 文件时（例如 CI 的公共 runner）只跑形状检查——形状检查不需要知道真值，
 * 这也是它能在 CI 里跑的原因。
 */

import { execFileSync } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..')

/**
 * 文档与夹具里可以出现的"码"。
 *
 * 判真码靠形状是不够的——真码就是随机四组四位，和夹具长得一样。所以这里反过来：
 * 每个**不是**「每组都是同一个字符」的码都必须登记在案，并写清它为什么不是真码。
 * 漏登记只会让人多看一眼，不会放过真值。
 */
const ALLOWED_CODES = new Set([
  'ABCD-EFGH-JKLM-NPQR', // docs/ONBOARDING.md 里的示例命令
  'ABCD-EFGH-JKMN-PQRS', // 连接器 enroll 测试的夹具
  'JKMN-PQRS-TUVW-XYZ2', // 连接器插件测试的夹具
  '2345-6789-ABCD-EFGH', // 文档里演示"连字符随便写"的夹具
])

/** 同一组四位全是同一个字符：只可能是人写出来的假码。 */
const obviouslyFake = (code) => {
  const groups = code.split('-')
  if (groups.every((group) => group === groups[0])) return true
  return groups.every((group) => /^(.)\1*$/.test(group))
}

/** 文档与样例统一写这些占位主机；测试域（RFC 2606/6761）也算占位。 */
const PLACEHOLDER_HOSTS = new Set([
  'relay.example.com', 'your.host', 'example.com', 'localhost', '127.0.0.1', 'host',
])
const RESERVED_TLDS = ['example', 'test', 'invalid', 'localhost']
const RESERVED_DOMAINS = ['example.com', 'example.net', 'example.org']
const isPlaceholderHost = (host) => {
  const bare = host.replace(/^\[|\]$/g, '').split(':')[0].toLowerCase()
  if (!bare || PLACEHOLDER_HOSTS.has(bare)) return true
  if (/[<>{}$…*]/.test(host)) return true
  if (RESERVED_DOMAINS.some((domain) => bare === domain || bare.endsWith(`.${domain}`))) return true
  return RESERVED_TLDS.some((tld) => bare.endsWith(`.${tld}`))
}

/** 允许出现的家目录（与 CI 里那份一致：白名单，免得把真名写进检查脚本）。 */
const ALLOWED_HOMES = new Set([
  'example', 'you', 'your', 'yourname', 'user', 'username', 'me', 'someone',
  'name', 'placeholder', 'x', 'dev', '...',
])

function loadLocalEnv() {
  const path = join(REPO_ROOT, '.env.local')
  if (!existsSync(path)) return
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    if (line.trimStart().startsWith('#')) continue
    const match = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/.exec(line)
    if (!match) continue
    const [, key, raw] = match
    if (process.env[key] === undefined) process.env[key] = raw.replace(/^(['"])(.*)\1$/, '$2')
  }
}

/** 本机真值：只有存在时才比较。 */
function localSecrets() {
  loadLocalEnv()
  const secrets = new Map()
  const remember = (value, what) => {
    const text = String(value ?? '').trim()
    if (text.length >= 6) secrets.set(text, what)
  }
  remember(process.env.ASC_REVIEW_INVITE, '审核演示邀请码')
  // Issuer ID 是本机真值；Key ID **不列入**——它出现在私钥文件名里，文档里
  // 需要写出 `AuthKey_<KeyID>.p8` 的完整路径（maintainers/PROMOTION.md），
  // 那既不是凭据也不能用来换 token，列进来只会每天误报一次。
  remember(process.env.ASC_ISSUER_ID, 'App Store Connect Issuer ID')
  remember(process.env.DSH_OTA_HOST, '中转主机')
  for (const key of ['DSH_SITE', 'DSH_RELAY_URL']) {
    const value = String(process.env[key] ?? '').trim()
    if (!value) continue
    remember(value, '中转地址')
    try {
      remember(new URL(value.includes('://') ? value : `wss://${value}`).host, '中转主机')
    } catch {
      // 不是 URL 就当纯文本比过一次就够了
    }
  }
  try {
    const identity = JSON.parse(
      readFileSync(join(homedir(), '.dsh', 'mobile-link', 'agent.json'), 'utf8')
    )
    remember(identity.agentId, 'agentId')
    remember(identity.agentSecret, 'agentSecret')
  } catch {
    // 没装连接器就没有这份身份
  }
  return secrets
}

function trackedFiles() {
  return execFileSync('git', ['ls-files', '-z'], { cwd: REPO_ROOT, encoding: 'utf8' })
    .split('\0')
    .filter(Boolean)
}

const findings = []
const add = (file, line, what, text) => findings.push({ file, line, what, text })

for (const file of trackedFiles()) {
  let content
  try {
    content = readFileSync(join(REPO_ROOT, file), 'utf8')
  } catch {
    continue // 二进制或读不了：没有可比较的文本
  }
  if (content.includes('\0')) continue
  content.split('\n').forEach((text, index) => {
    const line = index + 1
    for (const [secret, what] of localSecrets()) {
      if (text.includes(secret)) add(file, line, `本机真值（${what}）`, text.trim())
    }
    // 前后不能再接十六进制或连字符：UUID 的中间段（…-0000-4000-8000-…）正是
    // 这个形状，早期版本把它们全报了出来。
    for (const match of text.matchAll(/(?<![0-9A-Za-z-])[A-Z0-9]{4}(?:-[A-Z0-9]{4}){3}(?![0-9A-Za-z-])/g)) {
      const code = match[0]
      if (ALLOWED_CODES.has(code) || obviouslyFake(code)) continue
      add(file, line, '邀请码/配对码形状', text.trim())
    }
    for (const match of text.matchAll(/\b(?:agt|acc|dev|dt)_[A-Za-z0-9_-]{16,}\b/g)) {
      add(file, line, `凭据形状（${match[0].split('_')[0]}_…）`, text.trim())
    }
    if (/\bas_[A-Za-z0-9_-]{16,}\b/.test(text)) add(file, line, '凭据形状（as_…）', text.trim())
    if (/-----BEGIN [A-Z ]*PRIVATE KEY-----/.test(text)) {
      add(file, line, '私钥', text.trim())
    }
    for (const match of text.matchAll(/wss?:\/\/([^/\s"'`]+)\/dsh-link/g)) {
      if (!isPlaceholderHost(match[1])) add(file, line, '真实中转地址（应写占位符）', text.trim())
    }
    for (const match of text.matchAll(/\/Users\/([A-Za-z0-9._-]+)/g)) {
      if (!ALLOWED_HOMES.has(match[1])) add(file, line, '真实家目录路径', text.trim())
    }
  })
}

if (findings.length) {
  console.error('发现可能的本机真值（这些文件是入库的）：\n')
  for (const finding of findings) {
    console.error(`  ${finding.file}:${finding.line}  ${finding.what}`)
    console.error(`      ${finding.text.slice(0, 120)}`)
  }
  console.error(
    '\n处理办法：真值挪进 .env.local（不入库），文件里只留占位符；' +
    '确实是夹具的码，登记进本脚本的 ALLOWED_CODES 并写明它为什么不是真码。'
  )
  process.exit(1)
}

const secrets = localSecrets().size
console.log(
  `ok  跟踪文件里没有本机真值（比对了 ${secrets} 个本机值）` +
  '：家目录、凭据形状、邀请码形状、真实中转地址都干净'
)
