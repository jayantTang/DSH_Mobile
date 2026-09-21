#!/usr/bin/env node
/**
 * 用 App Store Connect API Key 在 portal 上签一张 Apple Distribution 证书，并建一张
 * App Store 描述文件装到本机——`deploy-testflight.sh` 的「API Key + 云签名」这条路在
 * 本团队走不通（Cloud signing permission error，团队里原本一张分发证书都没有），
 * 所以分发签名靠这里准备，导出改成 manual（见 maintainers/APPSTORE.md）。
 *
 *   node scripts/release/asc-dist-signing.mjs cert      # 签证书 → 导进 ~/Library/Keychains/dshbuild.keychain-db
 *   node scripts/release/asc-dist-signing.mjs profile <证书 id>   # 建 App Store 描述文件并装入 Xcode
 *   node scripts/release/asc-dist-signing.mjs list      # 看看现在有哪些证书/描述文件
 *
 * 凭据：ASC_KEY_ID / ASC_ISSUER_ID 从 .env.local 读，私钥在
 * ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8；团队 ID 从 Signing.local.plist
 * 或 DSH_TEAM_ID 读（不入库）。私钥只落在本机钥匙串里，Apple 只回签好的证书。
 */

import { createSign } from 'node:crypto'
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { execFileSync } from 'node:child_process'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..')
const API = 'https://api.appstoreconnect.apple.com'
const BUNDLE_ID = 'com.jayanttang.dsh'
const KEYCHAIN = join(homedir(), 'Library/Keychains/dshbuild.keychain-db')
const KEYCHAIN_PASSWORD = 'dsh'
const WORK = join(ROOT, 'ios/DSHMobile/.build/dist-signing')
const PROFILE_NAME = 'DSH Mobile App Store'

for (const line of readFileSync(join(ROOT, '.env.local'), 'utf8').split('\n')) {
  if (line.trimStart().startsWith('#')) continue
  const m = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/.exec(line)
  if (!m) continue
  const [, key, raw] = m
  if (process.env[key] === undefined) process.env[key] = raw.replace(/^(['"])(.*)\1$/, '$2')
}

function teamId() {
  if (process.env.DSH_TEAM_ID) return process.env.DSH_TEAM_ID
  const plist = join(ROOT, 'ios/DSHMobile/Signing.local.plist')
  if (existsSync(plist)) {
    const out = execFileSync('plutil', ['-extract', 'teamID', 'raw', '-o', '-', plist]).toString().trim()
    if (out) return out
  }
  throw new Error('没有团队 ID：设 DSH_TEAM_ID=<TeamID> 或写 ios/DSHMobile/Signing.local.plist')
}

const keyId = process.env.ASC_KEY_ID
const issuerId = process.env.ASC_ISSUER_ID
if (!keyId || !issuerId) throw new Error('缺 ASC_KEY_ID / ASC_ISSUER_ID（在 .env.local）')
const p8 = readFileSync(process.env.ASC_KEY_PATH
  || join(homedir(), '.appstoreconnect', 'private_keys', `AuthKey_${keyId}.p8`), 'utf8')

const now = Math.floor(Date.now() / 1000)
const enc = (v) => Buffer.from(JSON.stringify(v)).toString('base64url')
const head = enc({ alg: 'ES256', kid: keyId, typ: 'JWT' })
const body = enc({ iss: issuerId, iat: now, exp: now + 900, aud: 'appstoreconnect-v1' })
const sig = createSign('SHA256').update(`${head}.${body}`).sign({ key: p8, dsaEncoding: 'ieee-p1363' })
const jwt = `${head}.${body}.${sig.toString('base64url')}`

async function call(method, path, payload) {
  const response = await fetch(`${API}${path}`, {
    method,
    headers: { Authorization: `Bearer ${jwt}`, 'Content-Type': 'application/json' },
    body: payload ? JSON.stringify(payload) : undefined,
  })
  const json = await response.json().catch(() => ({}))
  if (response.status >= 300) {
    const detail = json?.errors?.map((e) => `${e.title}: ${e.detail}`).join('；')
    throw new Error(`${response.status} ${method} ${path} → ${detail || JSON.stringify(json).slice(0, 300)}`)
  }
  return json
}

const run = (cmd, args) => execFileSync(cmd, args, { stdio: 'pipe' }).toString()

async function list() {
  const certs = await call('GET', '/v1/certificates?limit=20')
  for (const c of certs.data ?? []) {
    console.log(`证书 ${c.id} ${c.attributes.certificateType} 到期 ${c.attributes.expirationDate}`)
  }
  const profiles = await call('GET', '/v1/profiles?limit=20')
  for (const p of profiles.data ?? []) {
    console.log(`描述文件 ${p.id} ${p.attributes.name} ${p.attributes.profileType} 到期 ${p.attributes.expirationDate}`)
  }
}

async function cert() {
  mkdirSync(WORK, { recursive: true })
  // 私钥留在本机：Apple 只回签好的证书，没有私钥这张证书就不能用来签名。
  run('openssl', ['req', '-new', '-newkey', 'rsa:2048', '-nodes',
    '-keyout', join(WORK, 'dist.key'), '-out', join(WORK, 'dist.csr'),
    '-subj', `/CN=DSH Mobile Distribution/O=${teamId()}/C=CN`])
  const csr = readFileSync(join(WORK, 'dist.csr'), 'utf8')
  const created = await call('POST', '/v1/certificates', {
    data: { type: 'certificates', attributes: { certificateType: 'DISTRIBUTION', csrContent: csr } },
  })
  const cert = created.data
  const der = Buffer.from(cert.attributes.certificateContent, 'base64')
  writeFileSync(join(WORK, 'dist.cer'), der)
  console.log(`证书 ${cert.id}（到期 ${cert.attributes.expirationDate}）`)

  // 导进专用钥匙串：带上 -A 才不会在签名时弹一个点不到的授权框（login 钥匙串会卡死）。
  const pem = join(WORK, 'dist.pem')
  const p12 = join(WORK, 'dist.p12')
  writeFileSync(pem, run('openssl', ['x509', '-inform', 'DER', '-in', join(WORK, 'dist.cer')]))
  // openssl 3 默认的 PKCS#12 算法 Security.framework 读不了，必须 -legacy。
  run('openssl', ['pkcs12', '-export', '-legacy', '-inkey', join(WORK, 'dist.key'),
    '-in', pem, '-out', p12, '-passout', `pass:${KEYCHAIN_PASSWORD}`])
  try { run('security', ['create-keychain', '-p', KEYCHAIN_PASSWORD, KEYCHAIN]) } catch { /* 已存在 */ }
  run('security', ['unlock-keychain', '-p', KEYCHAIN_PASSWORD, KEYCHAIN])
  run('security', ['import', p12, '-k', KEYCHAIN, '-P', KEYCHAIN_PASSWORD, '-A'])
  run('security', ['set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:',
    '-s', '-k', KEYCHAIN_PASSWORD, KEYCHAIN])
  console.log(run('security', ['find-identity', '-v', '-p', 'codesigning', KEYCHAIN]).trim())
  console.log(`私钥在 ${KEYCHAIN}（密码 ${KEYCHAIN_PASSWORD}）；导出前把这张钥匙串加进 search list`)
}

async function profile(certId) {
  if (!certId) throw new Error('用法：profile <证书 id>（先跑 cert，或看 list）')
  const bundles = await call('GET', `/v1/bundleIds?filter[identifier]=${BUNDLE_ID}&limit=5`)
  const bundle = bundles.data?.[0]
  if (!bundle) throw new Error(`portal 上找不到 ${BUNDLE_ID}`)
  // 同名的先删掉，免得堆一串同名描述文件（描述文件数量也有上限）。
  const existing = await call('GET', `/v1/profiles?filter[name]=${encodeURIComponent(PROFILE_NAME)}&limit=10`)
  for (const p of existing.data ?? []) await call('DELETE', `/v1/profiles/${p.id}`)
  const created = await call('POST', '/v1/profiles', {
    data: {
      type: 'profiles',
      attributes: { name: PROFILE_NAME, profileType: 'IOS_APP_STORE' },
      relationships: {
        bundleId: { data: { type: 'bundleIds', id: bundle.id } },
        certificates: { data: [{ type: 'certificates', id: certId }] },
      },
    },
  })
  const attrs = created.data.attributes
  const dir = join(homedir(), 'Library/Developer/Xcode/UserData/Provisioning Profiles')
  mkdirSync(dir, { recursive: true })
  const file = join(dir, `${attrs.uuid}.mobileprovision`)
  writeFileSync(file, Buffer.from(attrs.profileContent, 'base64'))
  console.log(`描述文件「${attrs.name}」uuid ${attrs.uuid} → ${file}`)
}

const [verb, argument] = process.argv.slice(2)
if (verb === 'list') await list()
else if (verb === 'cert') await cert()
else if (verb === 'profile') await profile(argument)
else console.log('用法：asc-dist-signing.mjs list | cert | profile <证书 id>')
