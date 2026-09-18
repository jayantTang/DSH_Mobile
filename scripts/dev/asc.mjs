#!/usr/bin/env node
/**
 * App Store Connect 的只读查询：构建处理到哪一步了、外部测试的链接是什么。
 *
 *   node scripts/dev/asc.mjs builds [appId]    # 最近的构建与处理状态（默认找 DSH_Mobile）
 *   node scripts/dev/asc.mjs builds --all      # 账号下所有 App 的构建
 *   node scripts/dev/asc.mjs apps              # 账号下的 App（确认记录建对了）
 *   node scripts/dev/asc.mjs groups            # 外部测试组与公开链接
 *   node scripts/dev/asc.mjs build-info <id>   # 某个构建的详细信息
 *
 * 为什么需要它：`altool --upload-app` 成功只代表**上传**成功，构建还要在 Apple 那边
 * 处理几分钟；处理期间 TestFlight 里看不到，处理失败（例如 Info.plist 缺项）只会发邮件。
 * 用 API 查一下比反复刷新网页快，也方便脚本化。
 *
 * 凭据（都从环境变量或仓库文件的既定位置取，不写死在代码里）：
 *   ASC_KEY_ID     Key ID，也就是 AuthKey_<KEY_ID>.p8 里的那串
 *   ASC_ISSUER_ID  App Store Connect → 用户和访问 → 集成 → App Store Connect API 页面顶部
 *   .p8 放在 ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8（或 ASC_KEY_PATH）
 *
 * 只做 GET：这个脚本拿不到也不会去动审核、构建、测试组之类的状态。
 */

import { createSign } from 'node:crypto'
import { fileURLToPath } from 'node:url'
import { existsSync, readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'

const API = 'https://api.appstoreconnect.apple.com'

/** 本机真值（含 ASC Issuer ID）只写在 .env.local 里，不入库；这里按需读一次。 */
function loadLocalEnv() {
  const path = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '.env.local')
  if (!existsSync(path)) return
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    if (line.trimStart().startsWith('#')) continue
    const match = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/.exec(line)
    if (!match) continue
    const [, key, raw] = match
    if (process.env[key] === undefined) process.env[key] = raw.replace(/^(['"])(.*)\1$/, '$2')
  }
}
loadLocalEnv()

function credentials() {
  const keyId = process.env.ASC_KEY_ID
  const issuerId = process.env.ASC_ISSUER_ID
  if (!keyId || !issuerId) {
    throw new Error('缺 ASC_KEY_ID / ASC_ISSUER_ID（见本文件头部注释）')
  }
  const path = process.env.ASC_KEY_PATH
    || join(homedir(), '.appstoreconnect', 'private_keys', `AuthKey_${keyId}.p8`)
  if (!existsSync(path)) throw new Error(`找不到私钥：${path}`)
  return { keyId, issuerId, privateKey: readFileSync(path, 'utf8') }
}

/// ES256 JWT，Apple 要求 20 分钟以内的有效期。
function token({ keyId, issuerId, privateKey }) {
  const now = Math.floor(Date.now() / 1000)
  const encode = (value) => Buffer.from(JSON.stringify(value)).toString('base64url')
  const header = encode({ alg: 'ES256', kid: keyId, typ: 'JWT' })
  const payload = encode({ iss: issuerId, iat: now, exp: now + 900, aud: 'appstoreconnect-v1' })
  const signature = createSign('SHA256').update(`${header}.${payload}`).sign({
    key: privateKey, dsaEncoding: 'ieee-p1363',
  })
  return `${header}.${payload}.${signature.toString('base64url')}`
}

async function get(path, jwt) {
  const response = await fetch(`${API}${path}`, { headers: { Authorization: `Bearer ${jwt}` } })
  const body = await response.json().catch(() => ({}))
  if (!response.ok) {
    const detail = body?.errors?.map((error) => `${error.title}: ${error.detail}`).join('；')
    throw new Error(`${response.status} ${path} → ${detail || JSON.stringify(body).slice(0, 200)}`)
  }
  return body
}

/// 找到本项目的 App 记录 id，这样 builds 只列它自己的构建。
async function appIdForBundle(bundleId, jwt) {
  const { data } = await get(`/v1/apps?filter[bundleId]=${bundleId}&limit=1`, jwt)
  return data[0]?.id
}

const [command, argument] = process.argv.slice(2)
const jwt = token(credentials())

if (command === 'apps') {
  const { data } = await get('/v1/apps?limit=20', jwt)
  if (!data.length) console.log('账号下还没有 App 记录')
  for (const app of data) {
    console.log(`${app.attributes.name}  ·  ${app.attributes.bundleId}  ·  ${app.id}`)
  }
} else if (command === 'builds') {
  // 默认只看本项目的 App：不筛的话会混进账号里其他 App 的构建，看起来像"上传成功了"
  // 其实不是这一个（第一次跑就差点被这个骗过去）。
  let path = '/v1/builds?limit=10&sort=-uploadedDate'
  if (argument !== '--all') {
    const appId = argument || await appIdForBundle('com.jayanttang.dsh', jwt)
    if (appId) path += `&filter[app]=${appId}`
  }
  const { data } = await get(path, jwt)
  if (!data.length) console.log('还没有构建（或仍在处理队列里）')
  for (const build of data) {
    const a = build.attributes
    console.log(`build ${a.version}  ·  ${a.processingState}  ·  ${a.uploadedDate}`
      + (a.expired ? '  ·  已过期' : ''))
    if (a.processingState === 'INVALID' || a.processingState === 'FAILED') {
      console.log('   ⚠️ 处理失败，Apple 会发邮件说明原因（常见：Info.plist 缺 CFBundleIconName、缺隐私描述）')
    }
  }
} else if (command === 'groups') {
  const { data } = await get('/v1/betaGroups?limit=20', jwt)
  for (const group of data) {
    const a = group.attributes
    console.log(`${a.name}  ·  内部=${a.isInternalGroup}  ·  公开链接=${a.publicLink || '（还没有）'}`)
  }
} else if (command === 'build-info') {
  if (!argument) throw new Error('build-info 需要一个构建 id（先跑 builds 看 id）')
  const { data } = await get(`/v1/builds/${argument}?include=betaBuildLocalizations,app`, jwt)
  console.log(JSON.stringify(data.attributes, null, 2))
} else {
  console.log(readFileSync(new URL(import.meta.url)).toString().split('*/')[0].replace(/^\/\*\*?/, '').trim())
}
