#!/usr/bin/env node
// 本机 LLM key 轮换代理的入口。
//
//   node bin/llm-key-router.mjs start            前台跑（或交给 launchd）
//   node bin/llm-key-router.mjs status           读一次 /stats 并打印
//   node bin/llm-key-router.mjs import <file>    把一份 key 清单导入 keys.txt（去重、600）
//   node bin/llm-key-router.mjs keys             只列 key 的标签与状态，不打印 key 正文
//   node bin/llm-key-router.mjs route-yaml       打印可直接贴进 settings.yaml 的 pi-ai route
//
// key 正文永远只在内存与 keys.txt 之间流转：日志、/stats、本命令的输出里都没有它。

import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'

import { DEFAULT_HOME, loadConfig, loadKeys } from '../lib/config.mjs'
import { startRouterServer } from '../lib/proxy.mjs'

const [command, argument] = process.argv.slice(2)
const config = loadConfig()

if (command === 'import') {
  if (!argument) fail('用法: llm-key-router.mjs import <装着 key 的文件>')
  const source = readFileSync(resolve(argument), 'utf8')
  const existing = existsSync(config.keysFile) ? readFileSync(config.keysFile, 'utf8') : ''
  const seen = new Set(existing.split('\n').map((line) => line.trim()).filter(Boolean))
  const added = []
  for (const line of source.split('\n')) {
    const trimmed = line.trim()
    if (!trimmed || trimmed.startsWith('#') || seen.has(trimmed)) continue
    seen.add(trimmed)
    added.push(trimmed)
  }
  mkdirSync(dirname(config.keysFile), { recursive: true })
  writeFileSync(config.keysFile, `${[...seen].join('\n')}\n`, { mode: 0o600 })
  chmodSync(config.keysFile, 0o600)
  console.log(`导入 ${added.length} 把，keys.txt 现在共 ${seen.size} 把（${config.keysFile}）`)
} else if (command === 'keys') {
  const keys = loadKeys(config)
  console.log(`${keys.length} 把 key：`)
  for (const key of keys) console.log(`  ${key.label ?? `${key.secret.slice(0, 8)}…`}`)
} else if (command === 'route-yaml') {
  const token = config.token || '<在 config.json 里设一个 token>'
  console.log(`# 贴进 ~/.dsh/settings.yaml（或电脑端「设置 → 模型」里加一条自定义提供方）
llm-pi-ai:
  providers:
    company-gateway:
      displayName: 公司网关
      api: openai-completions
      baseURL: http://127.0.0.1:${config.port}/v1
      apiKeyEnv: LLM_ROUTER_TOKEN
      # 关键：让 DSH 把会话 id 随请求发出来，代理才能做"会话粘性"
      compat:
        sendSessionAffinityHeaders: true
`)
  console.log(`# 同时把令牌写进凭据（这样手机端也能改）：
#   dsh 的 credentials：ref=LLM_ROUTER_TOKEN，值=${token}`)
} else if (command === 'status') {
  try {
    const response = await fetch(`http://127.0.0.1:${config.port}/stats`, {
      headers: config.token ? { authorization: `Bearer ${config.token}` } : {},
    })
    console.log(JSON.stringify(await response.json(), null, 1))
  } catch (error) {
    fail(`代理没有在 127.0.0.1:${config.port} 上跑：${error.message}`)
  }
} else if (command === 'start') {
  if (!config.upstream) fail('config.json 里还没有 upstream（上游 /v1 基地址）')
  const keys = loadKeys(config)
  if (keys.length === 0) fail(`没有读到 key：${config.keysFile}（先用 import 导入）`)
  const { server, router } = startRouterServer({ config })
  server.listen(config.port, '127.0.0.1', () => {
    const snapshot = router.snapshot()
    console.log(`key router 在 http://127.0.0.1:${config.port} 上跑：`
      + `${snapshot.pool.size} 把 key（${snapshot.pool.healthy} 把可用），`
      + `上游 ${config.upstream}，粘性 ${snapshot.policy.affinityTtlHours}h，`
      + `冷却 ${snapshot.policy.cooldownSeconds}s`)
  })
  const shutdown = () => {
    router.affinity.save()
    server.close(() => process.exit(0))
  }
  process.on('SIGINT', shutdown)
  process.on('SIGTERM', shutdown)
} else {
  console.log(`用法:
  llm-key-router.mjs import <file>   导入 key 清单（一行一把，可「标签:key」）
  llm-key-router.mjs keys            列 key 标签
  llm-key-router.mjs route-yaml      打印 pi-ai route 配置
  llm-key-router.mjs start           启动代理
  llm-key-router.mjs status          读一次 /stats

配置文件：${DEFAULT_HOME}/config.json（见 config.example.json）`)
}

function fail(message) {
  console.error(message)
  process.exit(1)
}
