/**
 * App Store Connect 的只读访问：JWT 签发、GET、列构建。
 *
 * `scripts/dev/asc.mjs`（人工查询）与日报取数（「哪天发了 TestFlight」）共用这一份，
 * 签名与请求只实现一次。只做 GET：拿不到也不会动审核、构建、测试组之类的状态。
 *
 * 凭据口径见 asc.mjs 头部注释：`ASC_KEY_ID` / `ASC_ISSUER_ID`，
 * 私钥在 `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`（或 `ASC_KEY_PATH`）。
 */

import { execFileSync } from 'node:child_process'
import { createSign } from 'node:crypto'
import { existsSync, readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

const API = 'https://api.appstoreconnect.apple.com'

/// 凭据只从环境变量（含 `.env.local` 展开后的那份）与既定路径取，不写死在代码里。
export function credentials(env = process.env) {
  const keyId = env.ASC_KEY_ID
  const issuerId = env.ASC_ISSUER_ID
  if (!keyId || !issuerId) {
    throw new Error('缺 ASC_KEY_ID / ASC_ISSUER_ID（见 asc.mjs 头部注释）')
  }
  const path = env.ASC_KEY_PATH
    || join(homedir(), '.appstoreconnect', 'private_keys', `AuthKey_${keyId}.p8`)
  if (!existsSync(path)) throw new Error(`找不到私钥：${path}`)
  return { keyId, issuerId, privateKey: readFileSync(path, 'utf8') }
}

/// ES256 JWT，Apple 要求 20 分钟以内的有效期。
export function token({ keyId, issuerId, privateKey }) {
  const now = Math.floor(Date.now() / 1000)
  const encode = (value) => Buffer.from(JSON.stringify(value)).toString('base64url')
  const header = encode({ alg: 'ES256', kid: keyId, typ: 'JWT' })
  const payload = encode({ iss: issuerId, iat: now, exp: now + 900, aud: 'appstoreconnect-v1' })
  const signature = createSign('SHA256').update(`${header}.${payload}`).sign({
    key: privateKey, dsaEncoding: 'ieee-p1363',
  })
  return `${header}.${payload}.${signature.toString('base64url')}`
}

/// 同步 GET（curl）。Apple 的错误正文原样带进异常，排查时不用再翻网页。
export function ascGet(path, jwt, { timeoutMs = 20_000, exec = execFileSync } = {}) {
  const raw = String(exec('curl', ['-sS', '-g', '--max-time', String(Math.ceil(timeoutMs / 1000)),
    '-H', `Authorization: Bearer ${jwt}`, '-w', '\n%{http_code}', `${API}${path}`],
  { encoding: 'utf8' }))
  const cut = raw.lastIndexOf('\n')
  const body = raw.slice(0, cut)
  const status = Number(raw.slice(cut + 1).trim())
  if (!(status >= 200 && status < 300)) {
    let detail = ''
    try {
      detail = (JSON.parse(body)?.errors ?? []).map((e) => `${e.title}: ${e.detail}`).join('；')
    } catch {
      detail = body.trim().slice(0, 200)
    }
    throw new Error(`${status} ${path} → ${detail || body.trim().slice(0, 200)}`)
  }
  return JSON.parse(body)
}

/// 找到本项目的 App 记录 id，这样列构建时只列它自己的。
export function appIdForBundle(bundleId, jwt, { exec = execFileSync } = {}) {
  const { data } = ascGet(`/v1/apps?filter[bundleId]=${bundleId}&limit=1`, jwt, { exec })
  return data?.[0]?.id
}

/** 最近的构建（按上传时间倒序）。
    `appId` 省略 → 按 `bundleId` 解析本项目；`appId: null` → 账号下所有 App。 */
export function listBuilds({ jwt, appId, limit = 10, bundleId = 'com.jayanttang.dsh',
  exec = execFileSync } = {}) {
  const resolved = appId === null ? null : (appId || appIdForBundle(bundleId, jwt, { exec }))
  let path = `/v1/builds?limit=${limit}&sort=-uploadedDate`
  if (resolved) path += `&filter[app]=${resolved}`
  return ascGet(path, jwt, { exec })?.data ?? []
}
