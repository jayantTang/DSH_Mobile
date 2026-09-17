#!/usr/bin/env node
/**
 * Manual driver for the Doubao image path — the same code the tool calls.
 *
 * Kept as a script because it is the only way to exercise the flow (and to
 * bisect a failure) without spending a model turn:
 *
 *   node lib/generate.mjs --prompt "..." [--out DIR] [--port N] [--count N]
 *                        [--reuse] [--no-relaunch] [--timeout SECONDS]
 */

import { parseArgs } from 'node:util'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { IMAGE_PROMPT_PREFIX, generateImage } from './doubao.mjs'

const { values } = parseArgs({
  options: {
    prompt: { type: 'string' },
    out: { type: 'string' },
    port: { type: 'string' },
    count: { type: 'string' },
    timeout: { type: 'string' },
    reuse: { type: 'boolean', default: false },
    'no-relaunch': { type: 'boolean', default: false },
    'no-prefix': { type: 'boolean', default: false },
    help: { type: 'boolean', default: false },
  },
  allowPositionals: true,
})

if (values.help || !values.prompt) {
  console.log(`用法: node lib/generate.mjs --prompt "中文描述" [选项]

  --out DIR        输出目录（默认 ~/Pictures/doubao）
  --port N         CDP 端口（默认 19222）
  --count N        最多取回几张（默认 1）
  --timeout SEC    等待生成的上限秒数（默认 300）
  --reuse          沿用当前会话，不新建（用于基于上一张改图）
  --no-relaunch    豆包在跑但不带调试端口时直接报错，不重启它
  --no-prefix      不自动加「生成图片：」前缀
`)
  process.exit(values.help ? 0 : 1)
}

const prompt = values['no-prefix'] ? values.prompt : IMAGE_PROMPT_PREFIX + values.prompt
const dir = values.out ?? join(homedir(), 'Pictures', 'doubao')

try {
  const result = await generateImage({
    prompt,
    dir,
    count: Number(values.count ?? 1),
    port: Number(values.port ?? 19222),
    relaunch: !values['no-relaunch'],
    reuseCurrentChat: Boolean(values.reuse),
    timeoutMs: Number(values.timeout ?? 300) * 1000,
    log: (message) => console.log(`[doubao] ${message}`),
  })
  console.log(JSON.stringify({ ok: true, files: result.files }, null, 2))
  process.exit(0)
} catch (error) {
  console.error(`[doubao] 失败: ${error.message}`)
  process.exit(1)
}
