#!/usr/bin/env node
/**
 * App Store 上架的收尾：截图上传、年龄分级、价格、提交审核。
 *
 *   node scripts/dev/asc-submit.mjs status            # 还缺什么（只读）
 *   node scripts/dev/asc-submit.mjs screenshots <dir> # 上传截图（dir 里是 6.9" 的 PNG）
 *   node scripts/dev/asc-submit.mjs basics            # 年龄分级 + 免费价格
 *   node scripts/dev/asc-submit.mjs submit            # 提交审核
 *
 * 顺序：basics → screenshots → submit。每一步都会先打印现状，所以可以重复跑。
 *
 * 截图上传是两步：先 PUT 到预留的 uploadOperations 地址，再 PATCH 提交校验和。
 * 图由 `test/cases/current/15-上架截图` 拍、`deploy-testflight.sh` 同一套流程导出，
 * 尺寸档位见 docs/notes/APPSTORE.md。
 */

import { createHash, createSign } from 'node:crypto'
import { fileURLToPath } from 'node:url'
import { existsSync, readFileSync, readdirSync } from 'node:fs'
import { homedir } from 'node:os'
import { basename, dirname, join } from 'node:path'

const API = 'https://api.appstoreconnect.apple.com'
const BUNDLE_ID = 'com.jayanttang.dsh'
/// 6.9" iPhone（1320×2868）。这是目前 iPhone 最大档，App Store 只要求提供这一档。
const DISPLAY_TYPE = process.env.ASC_DISPLAY_TYPE || 'APP_IPHONE_67'

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
  if (!keyId || !issuerId) throw new Error('缺 ASC_KEY_ID / ASC_ISSUER_ID')
  const path = process.env.ASC_KEY_PATH
    || join(homedir(), '.appstoreconnect', 'private_keys', `AuthKey_${keyId}.p8`)
  if (!existsSync(path)) throw new Error(`找不到私钥：${path}`)
  return { keyId, issuerId, privateKey: readFileSync(path, 'utf8') }
}

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

const jwt = token(credentials())

async function call(method, path, body) {
  const response = await fetch(`${API}${path}`, {
    method,
    headers: { Authorization: `Bearer ${jwt}`, ...(body ? { 'Content-Type': 'application/json' } : {}) },
    ...(body ? { body: JSON.stringify(body) } : {}),
  })
  const text = await response.text()
  const parsed = text ? JSON.parse(text) : {}
  if (!response.ok) {
    const detail = parsed?.errors?.map((error) =>
      `${error.title}: ${error.detail}${error.source?.pointer ? ` @${error.source.pointer}` : ''}`).join('\n   ')
    const error = new Error(`${response.status} ${method} ${path}\n   ${detail || text.slice(0, 400)}`)
    error.status = response.status
    error.body = parsed
    throw error
  }
  return parsed
}

const get = (path) => call('GET', path)

async function context() {
  const { data: apps } = await get(`/v1/apps?filter[bundleId]=${BUNDLE_ID}&limit=1`)
  const app = apps[0]
  const { data: versions } = await get(`/v1/apps/${app.id}/appStoreVersions?limit=10`)
  const version = versions.find((item) =>
    ['PREPARE_FOR_SUBMISSION', 'REJECTED', 'DEVELOPER_REJECTED', 'METADATA_REJECTED', 'WAITING_FOR_REVIEW']
      .includes(item.attributes.appStoreState)) ?? versions[0]
  const { data: infos } = await get(`/v1/apps/${app.id}/appInfos`)
  const info = infos[0]
  const { data: locales } = await get(`/v1/appStoreVersions/${version.id}/appStoreVersionLocalizations`)
  const locale = locales.find((item) => item.attributes.locale === 'zh-Hans') ?? locales[0]
  return { app, version, info, locale }
}

async function ageRating(infoId) {
  const { data } = await get(`/v1/appInfos/${infoId}/ageRatingDeclaration`)
  return data
}

async function screenshotSets(localeId) {
  const { data } = await get(`/v1/appStoreVersionLocalizations/${localeId}/appScreenshotSets`)
  return data
}

async function status() {
  const { version, info, locale } = await context()
  const rating = await ageRating(info.id)
  const answered = Object.entries(rating.attributes).filter(([, value]) => value !== null)
  const sets = await screenshotSets(locale.id)
  const app = (await get(`/v1/apps/${(await context()).app.id}/appPriceSchedules`).catch(() => null))
  console.log(`版本 ${version.attributes.versionString} · ${version.attributes.appStoreState}`)
  console.log(`年龄分级：已回答 ${answered.length} 项${answered.length ? '（' + answered.map(([k]) => k).slice(0, 4).join(',') + '…）' : ' —— **未填**'}`)
  console.log(`截图：${sets.length ? sets.map((s) => `${s.attributes.screenshotDisplayType}(${s.attributes.screenshotDisplayType})`).join(', ') : '**没有截图集**'}`)
  const review = await get(`/v1/appStoreVersions/${version.id}/appStoreReviewDetail`).catch(() => null)
  console.log(`审核备注：${review?.data?.attributes?.notes ? '已填' : '**空**'}`)
  const submission = await get(`/v1/appStoreVersions/${version.id}/appStoreVersionSubmission`).catch(() => null)
  console.log(`提交记录：${submission?.data ? JSON.stringify(submission.data.attributes) : '（还没提交）'}`)
  return { app: (await context()).app, version, info, locale, rating, sets }
}

/// 年龄分级：这个 App 没有任何受限内容，所以把 API 认识的每个字段都答成"无"。
///
/// 三个坑（都撞过）：
///   * 这个 PATCH **要求把整套问卷一次给全**——只给一个字段会回
///     "You must provide a value for the attribute 'xxx' with this request"。
///   * 字段类型分两种：布尔类（广告、社交、用户生成内容…）与枚举类
///     （暴力、性、恐怖…），混用会回 "Unexpected json type"。
///   * `ageRatingOverride` 与 `ageRatingOverrideV2` **不能同时给**
///     （STATE_ERROR.AGE_RATING_OVERRIDE_V1_AND_V2_NOT_ALLOWED），新账号用 V2。
async function basics() {
  const { info } = await context()
  const declaration = await ageRating(info.id)
  const current = declaration.attributes
  const enumKeys = new Set(Object.entries(current)
    .filter(([, value]) => typeof value === 'string')
    .map(([key]) => key))
  const attributes = {}
  for (const [key, value] of Object.entries(current)) {
    if (['kidsAgeBand', 'developerAgeRatingInfoUrl', 'ageRatingOverride'].includes(key)) continue
    attributes[key] = enumKeys.has(key) ? 'NONE' : false
  }
  await call('PATCH', `/v1/ageRatingDeclarations/${declaration.id}`, {
    data: { type: 'ageRatingDeclarations', id: declaration.id, attributes },
  })
  const after = (await ageRating(info.id)).attributes
  const empty = Object.entries(after).filter(([, value]) => value === null).map(([key]) => key)
  console.log(`年龄分级：已填 ${Object.keys(attributes).length} 项；未答 ${empty.length ? empty.join(', ') : '（无）'}`)

  // 免费：价格表要基线地区 + 0 价。API 上这一步偶尔会 409（已有价格表 / 缺价点），
  // 失败不影响上架——网页上"定价与销售范围 → 免费"两下就好，所以只提示不报错。
  try {
    const app = (await context()).app
    await call('POST', '/v1/appPriceSchedules', {
      data: {
        type: 'appPriceSchedules',
        relationships: {
          app: { data: { type: 'apps', id: app.id } },
          baseTerritory: { data: { type: 'territories', id: 'USA' } },
        },
      },
    })
    console.log('价格：已设为免费')
  } catch (error) {
    console.log(`价格：API 没设成（${String(error.message).split('\n')[0]}）`)
    console.log('      → 去 App Store Connect → 定价与销售范围 选「免费」，这一步网页上很快。')
  }
}

/// 上传一组截图：预留 → PUT 每张 → 提交校验和。
async function screenshots(dir) {
  if (!dir || !existsSync(dir)) throw new Error('用法：asc-submit.mjs screenshots <装着 PNG 的目录>')
  const files = readdirSync(dir).filter((name) => name.endsWith('.png')).sort()
  if (!files.length) throw new Error(`${dir} 里没有 PNG`)
  const { locale, sets } = await status()

  let set = sets.find((item) => item.attributes.screenshotDisplayType === DISPLAY_TYPE)
  if (!set) {
    console.log(`创建截图集 ${DISPLAY_TYPE}（6.9" iPhone）`)
    const created = await call('POST', '/v1/appScreenshotSets', {
      data: {
        type: 'appScreenshotSets',
        attributes: { screenshotDisplayType: DISPLAY_TYPE },
        relationships: { appStoreVersionLocalization: { data: { type: 'appStoreVersionLocalizations', id: locale.id } } },
      },
    })
    set = created.data
  }
  const existing = await get(`/v1/appScreenshotSets/${set.id}/appScreenshots`)
  for (const shot of existing.data ?? []) {
    await call('DELETE', `/v1/appScreenshots/${shot.id}`)
    console.log(`  删掉旧图 ${shot.id}`)
  }

  for (const [index, name] of files.entries()) {
    const bytes = readFileSync(join(dir, name))
    const reserved = await call('POST', '/v1/appScreenshots', {
      data: {
        type: 'appScreenshots',
        attributes: { fileName: name, fileSize: bytes.length },
        relationships: { appScreenshotSet: { data: { type: 'appScreenshotSets', id: set.id } } },
      },
    })
    const shot = reserved.data
    for (const operation of shot.attributes.uploadOperations ?? []) {
      const headers = Object.fromEntries((operation.requestHeaders ?? []).map((h) => [h.name, h.value]))
      const response = await fetch(operation.url, {
        method: operation.method,
        headers,
        body: bytes.subarray(operation.offset, operation.offset + operation.length),
      })
      if (!response.ok) throw new Error(`上传 ${name} 失败：HTTP ${response.status}`)
    }
    await call('PATCH', `/v1/appScreenshots/${shot.id}`, {
      data: {
        type: 'appScreenshots',
        id: shot.id,
        attributes: {
          uploaded: true,
          sourceFileChecksum: createHash('md5').update(bytes).digest('hex'),
        },
      },
    })
    console.log(`  ✓ ${index + 1}/${files.length} ${name}（${(bytes.length / 1024).toFixed(0)} KB）`)
  }
  console.log('截图上传完成。App Store Connect 处理几分钟后会出现在版本页。')
}

async function submit() {
  const { app, version, sets } = await status()
  if (!sets.length) throw new Error('还没有截图，先跑 screenshots')
  if (version.attributes.appStoreState === 'WAITING_FOR_REVIEW') {
    console.log('这个版本已经在等待审核了，无需重复提交')
    return
  }

  // 构建：提交时必须挂一个已处理完成的构建。
  const { data: builds } = await get(`/v1/builds?filter[app]=${app.id}&limit=10&sort=-uploadedDate`)
  // 按上传时间倒序取第一个可用的——别只 find 第一个 VALID：列表里旧构建也在，
  // 会把上一版重新挂上去（第一次就差点这样）。
  const build = builds.find((item) => item.attributes.processingState === 'VALID')
  if (!build) throw new Error('没有可用的构建（先跑 scripts/release/deploy-testflight.sh）')
  await call('PATCH', `/v1/appStoreVersions/${version.id}/relationships/build`, {
    data: { type: 'builds', id: build.id },
  })
  console.log(`已挂上构建 build ${build.attributes.version}`)

  // 提交走 reviewSubmissions（新 API）。旧的 appStoreVersionSubmissions 现在只允许 DELETE。
  //
  // 两个坑（都撞过）：
  //   * 先创建提交通道、再单独 POST items —— 服务端会静默不收（items 保持为空），
  //     提交时报 "must have an approved appStoreVersions ... or an appStoreVersions
  //     must be included in this review submission"。正确做法是**创建时就把 items 带上**。
  //   * `appStoreVersionForReview` 这个关系**没有** allowed operations，不能 PATCH。
  // 顺序很讲究（每一步都试错过）：
  //   1. POST /v1/reviewSubmissions            建通道（**不能**内联 items：服务端回
  //      "inline include id ... is not allowed for this request"）
  //   2. POST /v1/reviewSubmissionItems        单独把版本加进去
  //      （版本元数据不全时这一步回 409 STATE_ERROR.ENTITY_STATE_INVALID，
  //       那才是"还缺东西"的真正信号——截图/年龄分级没填完就是这里卡住）
  //   3. PATCH submitted=true                  提交
  // 另外：空通道删不掉（reviewSubmissions 不允许 DELETE），留一个空的没关系。
  const created = await call('POST', '/v1/reviewSubmissions', {
    data: { type: 'reviewSubmissions', relationships: { app: { data: { type: 'apps', id: app.id } } } },
  })
  const submission = created.data
  console.log(`提交通道 ${submission.id}（${submission.attributes.state}）`)

  const item = await call('POST', '/v1/reviewSubmissionItems', {
    data: {
      type: 'reviewSubmissionItems',
      relationships: {
        reviewSubmission: { data: { type: 'reviewSubmissions', id: submission.id } },
        appStoreVersion: { data: { type: 'appStoreVersions', id: version.id } },
      },
    },
  })
  console.log(`已加入版本 ${version.attributes.versionString}（item ${item.data.id}）`)

  await call('PATCH', `/v1/reviewSubmissions/${submission.id}`, {
    data: { type: 'reviewSubmissions', id: submission.id, attributes: { submitted: true } },
  })
  console.log('已提交审核。通常 1–3 天出结果，Apple 会发邮件到审核联系人邮箱。')
}

const [command, argument] = process.argv.slice(2)
if (command === 'screenshots') await screenshots(argument)
else if (command === 'basics') await basics()
else if (command === 'submit') await submit()
else await status()
