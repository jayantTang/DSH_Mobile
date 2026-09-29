#!/usr/bin/env node
/**
 * 用 App Store Connect API Key 准备**带推送能力**的开发描述文件，并装到本机。
 *
 * 为什么需要它：`deploy-ota.sh` 原来靠 Xcode 的自动签名（`CODE_SIGN_STYLE =
 * Automatic` + `-allowProvisioningUpdates`）现场生成描述文件。这条路有两个前提，
 * 本机都不满足：
 *
 *   1. Xcode 里要有一个已登录的 Apple ID（`No Accounts` 报错）；
 *   2. 自动生成的那张 `iOS Team Provisioning Profile: *` 要包含 Push Notifications。
 *
 * 2026-09-28 加推送时，App ID 上原本**一个 capability 都没有**，所以旧描述文件里
 * 没有 `aps-environment`——归档直接失败（"doesn't include the aps-environment
 * entitlement"）。把自己变成那个卡点的人肉修复步骤是不可接受的：装机是编排层
 * 反复要做的事，所以这里把"打开 capability + 签一张带推送的描述文件"变成脚本。
 *
 *   node scripts/release/asc-dev-signing.mjs profile   # 幂等：确保 capability 与描述文件都在
 *   node scripts/release/asc-dev-signing.mjs list      # 看看现在的 capability / 描述文件 / 设备
 *
 * 产物落在 Xcode 的描述文件目录（与 `asc-dist-signing.mjs` 同一处），
 * 名字固定为 `DSH Mobile Development Push`，`deploy-ota.sh` 按这个名字手工签名。
 *
 * 凭据：ASC_KEY_ID / ASC_ISSUER_ID 从 .env.local 读，私钥在
 * ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8；团队 ID 从
 * Signing.local.plist 或 DSH_TEAM_ID 读（都不入库）。
 */

import { createSign } from 'node:crypto'
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { execFileSync } from 'node:child_process'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..')
const API = 'https://api.appstoreconnect.apple.com'
const BUNDLE_ID = process.env.DSH_BUNDLE_ID || 'com.jayanttang.dsh'
const PROFILE_NAME = 'DSH Mobile Development Push'

for (const line of readFileSync(join(ROOT, '.env.local'), 'utf8').split('\n')) {
  if (line.trimStart().startsWith('#')) continue
  const m = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/.exec(line)
  if (!m) continue
  const [, key, raw] = m
  if (process.env[key] === undefined) process.env[key] = raw.replace(/^(['"])(.*)\1$/, '$2')
}

const keyId = process.env.ASC_KEY_ID
const issuerId = process.env.ASC_ISSUER_ID
if (!keyId || !issuerId) {
  console.error('缺少 ASC_KEY_ID / ASC_ISSUER_ID：请写在 .env.local 里')
  process.exit(2)
}
const privateKey = readFileSync(
  join(homedir(), '.appstoreconnect/private_keys', `AuthKey_${keyId}.p8`), 'utf8'
)

const b64url = (value) => Buffer.from(JSON.stringify(value)).toString('base64url')

/** A fresh ES256 provider token. Apple caps these at 20 minutes. */
function token() {
  const now = Math.floor(Date.now() / 1000)
  const header = b64url({ alg: 'ES256', kid: keyId, typ: 'JWT' })
  const payload = b64url({ iss: issuerId, iat: now, exp: now + 900, aud: 'appstoreconnect-v1' })
  const signer = createSign('SHA256')
  signer.update(`${header}.${payload}`)
  signer.end()
  const signature = signer.sign({ key: privateKey, dsaEncoding: 'ieee-p1363' }).toString('base64url')
  return `${header}.${payload}.${signature}`
}

async function api(path, method = 'GET', body) {
  const response = await fetch(`${API}${path}`, {
    method,
    headers: { Authorization: `Bearer ${token()}`, 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  const text = await response.text()
  const parsed = text ? JSON.parse(text) : {}
  if (!response.ok) {
    const detail = parsed.errors?.map((e) => `${e.code}: ${e.detail}`).join('; ') || text
    throw new Error(`${method} ${path} → HTTP ${response.status} (${detail})`)
  }
  return parsed
}

/** The App ID row for this bundle, or a clear failure. */
async function bundleId() {
  const found = await api(`/v1/bundleIds?filter[identifier]=${encodeURIComponent(BUNDLE_ID)}`)
  const row = found.data?.[0]
  if (!row) throw new Error(`ASC 上没有这个 App ID：${BUNDLE_ID}`)
  return row
}

/**
 * Ensures PUSH_NOTIFICATIONS is on the App ID.
 *
 * Without it no profile for this bundle can carry `aps-environment`, whatever
 * else is done — the capability lives on the App ID, and profiles inherit it.
 * Idempotent: Apple answers 409 when it is already on, which is the good case.
 */
async function ensureCapability(id) {
  const current = await api(`/v1/bundleIds/${id}/bundleIdCapabilities`)
  const has = current.data?.some((c) => c.attributes.capabilityType === 'PUSH_NOTIFICATIONS')
  if (has) {
    console.log('· PUSH_NOTIFICATIONS 已在 App ID 上')
    return
  }
  await api('/v1/bundleIdCapabilities', 'POST', {
    data: {
      type: 'bundleIdCapabilities',
      attributes: { capabilityType: 'PUSH_NOTIFICATIONS' },
      relationships: { bundleId: { data: { type: 'bundleIds', id } } },
    },
  })
  console.log('· 已为 App ID 打开 PUSH_NOTIFICATIONS')
}

/**
 * The Apple Development certificate that this Mac can actually sign with.
 *
 * Matching by certificate *type* alone is not enough and was a real failure:
 * the profile picked a development certificate whose private key is not in any
 * local keychain, and the archive stopped with "doesn't include signing
 * certificate". The local identities are asked, their SHA-1 fingerprints
 * compared against each ASC certificate, and only a certificate that is both
 * a development one and present locally is used.
 */
async function localDevelopmentCertificate() {
  const local = execFileSync('security', ['find-identity', '-v', '-p', 'codesigning'], {
    encoding: 'utf8',
  })
  // Each line is `  1) <40 hex chars> "Apple Development: Name (TEAM)"`. The
  // fingerprint is asked for rather than the name: two development certificates
  // for the same person carry identical names and only the fingerprint tells
  // which one has a private key here.
  const fingerprints = new Set(
    [...local.matchAll(/\b([0-9A-F]{40})\b/g)].map((m) => m[1])
  )
  if (fingerprints.size === 0) {
    throw new Error('本机没有任何可用的签名身份（security find-identity 是空的）')
  }
  const listed = await api('/v1/certificates?limit=50')
  for (const certificate of listed.data ?? []) {
    if (certificate.attributes.certificateType !== 'DEVELOPMENT') continue
    const der = Buffer.from(certificate.attributes.certificateContent, 'base64')
    const tmp = join(ROOT, 'ios/DSHMobile/.build/dist-signing/.fingerprint.der')
    mkdirSync(dirname(tmp), { recursive: true })
    writeFileSync(tmp, der)
    let fingerprint
    try {
      fingerprint = execFileSync(
        'openssl', ['x509', '-inform', 'DER', '-in', tmp, '-fingerprint', '-noout', '-sha1'],
        { encoding: 'utf8' }
      ).trim().replace(/^.*=/, '').replace(/:/g, '')
    } catch {
      continue
    }
    if (fingerprints.has(fingerprint)) {
      console.log(`· 用本机可签的开发证书 ${certificate.id}（${certificate.attributes.displayName}）`)
      return certificate
    }
  }
  throw new Error(
    'ASC 上的开发证书没有一张的私钥在本机钥匙串里。'
    + '先在 Xcode 里登录 Apple ID 并下载证书，或用 asc-dist-signing.mjs cert 签一张。'
  )
}

/** Registered devices. A development profile is only installable on these. */
async function devices() {
  const listed = await api('/v1/devices?limit=200')
  return (listed.data ?? []).filter((d) => d.attributes.status === 'ENABLED')
}

/**
 * (Re)creates the development profile, always with the local certificate.
 *
 * Recreated rather than reused when a profile of that name exists: the
 * certificate relationship cannot be PATCHed (Apple answers 403
 * `FORBIDDEN_ERROR`), so "reuse" would keep a profile signed against a
 * certificate this Mac cannot use.
 */
async function ensureProfile(bundle, certificate) {
  const listed = await api('/v1/profiles?limit=200')
  for (const profile of listed.data ?? []) {
    if (profile.attributes.name !== PROFILE_NAME) continue
    await api(`/v1/profiles/${profile.id}`, 'DELETE')
    const stale = join(profileDirectory(), `${profile.id}.mobileprovision`)
    if (existsSync(stale)) execFileSync('rm', ['-f', stale])
    console.log(`· 删掉旧描述文件 ${profile.id}（证书关系不可改，只能重建）`)
  }

  const usable = await devices()
  if (usable.length === 0) throw new Error('ASC 上没有已注册的设备，开发描述文件无法安装到任何手机上')

  const created = await api('/v1/profiles', 'POST', {
    data: {
      type: 'profiles',
      attributes: { name: PROFILE_NAME, profileType: 'IOS_APP_DEVELOPMENT' },
      relationships: {
        bundleId: { data: { type: 'bundleIds', id: bundle.id } },
        certificates: { data: [{ type: 'certificates', id: certificate.id }] },
        devices: { data: usable.map((d) => ({ type: 'devices', id: d.id })) },
      },
    },
  })

  const directory = profileDirectory()
  mkdirSync(directory, { recursive: true })
  const path = join(directory, `${created.data.id}.mobileprovision`)
  writeFileSync(path, Buffer.from(created.data.attributes.profileContent, 'base64'))
  console.log(`· 描述文件 ${created.data.id}「${PROFILE_NAME}」已装入（${usable.length} 台设备）`)
  return path
}

/** Where Xcode looks for profiles it did not download itself. */
function profileDirectory() {
  return join(homedir(), 'Library/Developer/Xcode/UserData/Provisioning Profiles')
}

/** Reads one entitlement out of an installed profile, for the closing check. */
function profileEntitlement(path, key) {
  const plist = execFileSync('security', ['cms', '-D', '-i', path], { encoding: 'buffer' })
  const tmp = join(ROOT, 'ios/DSHMobile/.build/dist-signing/.profile.plist')
  mkdirSync(dirname(tmp), { recursive: true })
  writeFileSync(tmp, plist)
  try {
    return execFileSync('plutil', ['-extract', `Entitlements.${key}`, 'raw', '-o', '-', tmp], {
      encoding: 'utf8',
    }).trim()
  } catch {
    return null
  }
}

async function main() {
  const command = process.argv[2] || 'profile'
  const bundle = await bundleId()

  if (command === 'list') {
    const capabilities = await api(`/v1/bundleIds/${bundle.id}/bundleIdCapabilities`)
    console.log('App ID', bundle.id, BUNDLE_ID)
    console.log('capabilities:', (capabilities.data ?? []).map((c) => c.attributes.capabilityType).join(', ') || '(无)')
    const profiles = await api('/v1/profiles?limit=200')
    for (const p of profiles.data ?? []) {
      console.log(`profile ${p.id} | ${p.attributes.name} | ${p.attributes.profileType} | ${p.attributes.profileState}`)
    }
    for (const d of await devices()) {
      console.log(`device ${d.id} | ${d.attributes.name} | ${d.attributes.deviceClass}`)
    }
    return
  }

  if (command !== 'profile') {
    console.error(`未知子命令：${command}（可用：profile / list）`)
    process.exit(2)
  }

  await ensureCapability(bundle.id)
  const certificate = await localDevelopmentCertificate()
  const path = await ensureProfile(bundle, certificate)

  const environment = profileEntitlement(path, 'aps-environment')
  const identifier = profileEntitlement(path, 'application-identifier')
  console.log(`· aps-environment = ${environment ?? '(缺失！)'}，application-identifier = ${identifier}`)
  if (!environment) {
    console.error('描述文件里没有 aps-environment：推送注册一定会失败，先确认 App ID 的 capability。')
    process.exit(1)
  }
  if (environment !== 'development') {
    console.error(
      `aps-environment 是 ${environment}，而 OTA 走的是开发签名，应为 development（沙盒）。`
    )
    process.exit(1)
  }
  console.log('就绪：可以跑 ./scripts/release/deploy-ota.sh')
}

main().catch((error) => {
  console.error(String(error.message ?? error))
  process.exit(1)
})
