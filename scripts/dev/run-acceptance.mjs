#!/usr/bin/env node
// 顺序执行验收子集；任一条失败即停。需要真实宿主与中转。
import { spawnSync } from 'node:child_process'
import { readdirSync } from 'node:fs'
import { join } from 'node:path'

const cases = readdirSync('test/acceptance').filter((name) => name.endsWith('.md') && name !== 'README.md').sort()
for (const name of cases) {
  const result = spawnSync('./test/run.sh', ['run', join('test/acceptance', name)], {
    stdio: 'inherit',
    env: { ...process.env, DSH_CONNECT: process.env.DSH_CONNECT ?? 'relay' },
  })
  if (result.status !== 0) {
    console.error(`验收失败：${name}`)
    process.exit(result.status ?? 1)
  }
}
console.log(`验收子集 ${cases.length} 条全部执行完毕`)
