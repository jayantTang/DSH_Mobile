#!/usr/bin/env node
/**
 * 在电脑上弹出「扫码配对」用的二维码。
 *
 * 手机端重装后要重新配对：App 里点「扫码配对」，扫的就是这张图。码由**连接器**
 * 向中转申请（一次性、默认 10 分钟有效），所以必须走连接器的 CLI，不能自己编。
 *
 * 用法：
 *   node scripts/dev/show-pair-qr.mjs            # 生成并打开二维码（默认浏览器/预览）
 *   node scripts/dev/show-pair-qr.mjs --no-open  # 只写文件，打印路径与码
 *   node scripts/dev/show-pair-qr.mjs --ttl 600000   # 自定义有效期（毫秒）
 *
 * 也可以不开脚本，直接在浏览器里打开 DSH 自己的这个路由（需已登录 DSH）：
 *   http://127.0.0.1:<port>/mobile-link/qr
 * 端口见 ~/.dsh/desktop-shell/endpoint.json。
 */

import { execFileSync } from 'node:child_process'
import { writeFileSync } from 'node:fs'
import { homedir, tmpdir } from 'node:os'
import { join } from 'node:path'

import { qrSvg } from '../../plugins/mobile-link/lib/qr.js'

const argv = process.argv.slice(2)
const wantsOpen = !argv.includes('--no-open')
const ttlIndex = argv.indexOf('--ttl')
const ttlMs = ttlIndex >= 0 ? Number(argv[ttlIndex + 1]) : undefined

const IDENTITY = join(homedir(), '.dsh', 'mobile-link', 'agent.json')
const CLI = join(import.meta.dirname, '..', '..', 'plugins', 'mobile-link', 'lib', 'cli.js')

const args = [CLI, '--mint-pair-code']
if (Number.isFinite(ttlMs) && ttlMs > 0) args.push('--ttl-ms', String(ttlMs))
const minted = JSON.parse(execFileSync('node', args, { encoding: 'utf8' }))

const path = join(tmpdir(), 'dsh-pair-qr.svg')
writeFileSync(path, qrSvg(minted.qrPayload, { scale: 10, quietZone: 3 }))
console.log(JSON.stringify(minted, null, 2))
console.log(`\n二维码：${path}`)
console.log('手机上：打开 App → 扫码配对 → 扫这张图（也可以手输上面的 code）')

// 显式交给 Safari：`.svg` 的默认打开方式可能是编辑器，那样人看到的是一堆标签而不是码。
if (wantsOpen) execFileSync('open', ['-a', 'Safari', path])
