#!/usr/bin/env node
/**
 * 把 canonical 的 send-image 采集脚本同步进 npm 包。
 *
 *   node scripts/dev/sync-send-image-script.mjs
 *
 * 两份必须逐字节相同（`check:contracts` 会拦漂移）。改了 `skills/` 下那份之后跑一次这个。
 */

import { copyFileSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..')
const contract = JSON.parse(readFileSync(join(REPO_ROOT, 'test/contract/send-image-script.json'), 'utf8'))

for (const { file, canonical } of contract.copies) {
  copyFileSync(join(REPO_ROOT, canonical), join(REPO_ROOT, file))
  console.log(`已同步 ${canonical} → ${file}`)
}
