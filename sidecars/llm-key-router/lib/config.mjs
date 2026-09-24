/**
 * 配置与 key 文件的读取。
 *
 * 配置住在 `~/.dsh/llm-key-router/config.json`，key 住在它旁边一个 600 的
 * 纯文本文件里（一行一把，可以写 `标签:key`）。两者都不进仓库：仓库里只放
 * `config.example.json`，真值留在本机——这个项目的既有约定。
 */
import { existsSync, readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

export const DEFAULT_HOME = join(homedir(), '.dsh', 'llm-key-router')

export function defaultConfig() {
  return {
    /** 本机监听端口；pi-ai 的 route 指向 http://127.0.0.1:<port>/v1 */
    port: 8799,
    /** 上游（兼容 OpenAI 的 /v1）基地址，末尾不带斜杠 */
    upstream: '',
    /** key 文件：一行一把，允许 `标签:key`，`#` 开头的行忽略 */
    keysFile: join(DEFAULT_HOME, 'keys.txt'),
    /** 会话粘性表落盘位置 */
    affinityPath: join(DEFAULT_HOME, 'affinity.json'),
    /** 轮换统计落盘位置（按天累计，重启不丢） */
    statsPath: join(DEFAULT_HOME, 'stats.json'),
    /** 统计保留天数 */
    statsKeepDays: 90,
    /** 粘性有效期（小时）：24 小时内回来接着聊仍然命中同一把 key */
    affinityTtlHours: 24,
    /** 429 时该 key 冷却多久（秒），上游给了 Retry-After 就以它为准 */
    cooldownSeconds: 60,
    /** 一次请求最多换几把 key（都在"还没写给客户端"之前） */
    maxAttempts: 3,
    /** 本机令牌：pi-ai route 的 apiKeyEnv 指向它；只防配错，不是安全边界 */
    token: '',
  }
}

export function loadConfig(path = join(DEFAULT_HOME, 'config.json')) {
  const config = defaultConfig()
  if (path && existsSync(path)) {
    const raw = JSON.parse(readFileSync(path, 'utf8'))
    Object.assign(config, raw)
  }
  config.affinityTtlMs = Math.max(1, Number(config.affinityTtlHours) || 24) * 3600 * 1000
  if (process.env.LLM_ROUTER_PORT) config.port = Number(process.env.LLM_ROUTER_PORT)
  if (process.env.LLM_ROUTER_UPSTREAM) config.upstream = process.env.LLM_ROUTER_UPSTREAM
  if (process.env.LLM_ROUTER_KEYS) config.keysFile = process.env.LLM_ROUTER_KEYS
  if (process.env.LLM_ROUTER_TOKEN) config.token = process.env.LLM_ROUTER_TOKEN
  return config
}

/**
 * 读 key 文件。
 *
 * 重复与空行在这里去掉：同一把 key 出现两次会让"轮换"看起来在换、其实没换，
 * 而这种错在日志里很难看出来。
 */
export function loadKeys(config) {
  const path = config.keysFile
  if (!path || !existsSync(path)) return []
  const seen = new Set()
  const entries = []
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    const trimmed = line.trim()
    if (!trimmed || trimmed.startsWith('#')) continue
    const separator = trimmed.indexOf(':')
    const label = separator > 0 ? trimmed.slice(0, separator).trim() : undefined
    const secret = (separator > 0 ? trimmed.slice(separator + 1) : trimmed).trim()
    if (!secret || seen.has(secret)) continue
    seen.add(secret)
    entries.push({ secret, ...(label ? { label } : {}) })
  }
  return entries
}
