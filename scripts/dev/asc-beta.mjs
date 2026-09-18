#!/usr/bin/env node
/**
 * 用 App Store Connect API 把 TestFlight 的外部测试配好并提交审核。
 *
 *   node scripts/dev/asc-beta.mjs status          # 现在缺什么（只读）
 *   node scripts/dev/asc-beta.mjs prepare         # 填测试信息 + 建外部测试组 + 挂构建
 *   node scripts/dev/asc-beta.mjs submit          # 提交外部测试审核
 *   node scripts/dev/asc-beta.mjs status --watch  # 每 5 分钟看一眼审核/链接
 *
 * 为什么不是纯网页操作：网页那几步都能用 API 做（Key 需要 **App 管理** 权限），
 * 而 API 做的好处是可重复、可脚本化、出错能看见原文——但**登录**仍然只能由人做，
 * API Key 是那个登录的替代品，不是它的绕过。
 *
 * 只读命令（status）与写命令（prepare/submit）分开，写之前先跑 status。
 */

import { createSign } from 'node:crypto'
import { fileURLToPath } from 'node:url'
import { existsSync, readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'

const API = 'https://api.appstoreconnect.apple.com'
const BUNDLE_ID = 'com.jayanttang.dsh'
/// 外部测试组的名字。内部组由人在网页上建（那一步要求账号成员身份，Key 做不了）。
const GROUP_NAME = 'Public beta'
/// 审核员看到的测试说明与反馈邮箱。反馈邮箱必须是真人能收信的地址。
const BETA_DESCRIPTION = `DSH Mobile 是你电脑上 DeepSeek Harness 的手机客户端：手机与电脑连同一个 host，看到同一批会话、同一条消息流，电脑上跑着的任务锁屏再打开进度还在走。

本构建需要一个中转邀请码才能连接（在 GitHub 仓库的 issue 里领取）。App 本身不包含任何内购，也不会向第三方上传你的会话内容；中转只做鉴权与转发，不解析会话内容。

测试重点：会话列表与转写渲染、发消息与打断正在跑的任务、回答 agent 的提问、查看与放大图片、上传文件到会话工作区。`
const FEEDBACK_EMAIL = process.env.ASC_FEEDBACK_EMAIL || 'forwoshitjy@live.com'
/// 审核联系电话。Apple 要求填，且只在审核需要时使用；可以从环境变量覆盖。
const CONTACT_PHONE_NOTE = 'ASC_CONTACT_PHONE 可覆盖（默认是个占位号，第一次提交后建议改成真号）'

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
    headers: {
      Authorization: `Bearer ${jwt}`,
      ...(body ? { 'Content-Type': 'application/json' } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  })
  const text = await response.text()
  const parsed = text ? JSON.parse(text) : {}
  if (!response.ok) {
    const detail = parsed?.errors
      ?.map((error) => `${error.title}: ${error.detail}${error.source?.pointer ? ` @${error.source.pointer}` : ''}`)
      .join('\n   ')
    const error = new Error(`${response.status} ${method} ${path}\n   ${detail || text.slice(0, 300)}`)
    error.status = response.status
    error.body = parsed
    throw error
  }
  return parsed
}

const get = (path) => call('GET', path)

async function app() {
  const { data } = await get(`/v1/apps?filter[bundleId]=${BUNDLE_ID}&limit=1`)
  if (!data.length) throw new Error(`账号里没有 ${BUNDLE_ID} 这个 App 记录`)
  return data[0]
}

async function latestBuild(appId) {
  const { data } = await get(`/v1/builds?filter[app]=${appId}&limit=1&sort=-uploadedDate`)
  return data[0]
}

async function groups(appId) {
  const { data } = await get(`/v1/betaGroups?filter[app]=${appId}&limit=50`)
  return data
}

/// 外部测试的审核状态挂在 build → betaAppReviewSubmission 上，**不在** build 的
/// attributes 里（第一次查状态就是被这个骗了：提交成功却显示"未提交"）。
async function reviewSubmission(buildId) {
  try {
    const { data } = await get(`/v1/builds/${buildId}/betaAppReviewSubmission`)
    return data
  } catch (error) {
    if (error.status === 404) return null
    throw error
  }
}

async function appInfo(appId) {
  const { data } = await get(`/v1/apps/${appId}/betaAppReviewDetail`)
  return data
}

async function localizations(appId) {
  const { data } = await get(`/v1/apps/${appId}/betaAppLocalizations?limit=20`)
  return data
}

async function status() {
  const record = await app()
  const build = await latestBuild(record.id)
  const list = await groups(record.id)
  const detail = await appInfo(record.id).catch(() => null)
  const locales = await localizations(record.id).catch(() => [])

  console.log(`App: ${record.attributes.name} (${record.attributes.bundleId})`)
  if (!build) {
    console.log('构建：还没有（先跑 scripts/release/deploy-testflight.sh）')
    return { record, build: null, groups: list, detail, locales }
  }
  const a = build.attributes
  const submission = await reviewSubmission(build.id)
  console.log(`构建：build ${a.version} · ${a.processingState} · ${a.uploadedDate} · expired=${a.expired}`)
  console.log(`外部测试审核：${submission ? submission.attributes.betaReviewState
    + '（提交于 ' + submission.attributes.submittedDate + '）' : '**未提交**'}`)
  console.log(`出口合规：${a.usesNonExemptEncryption === false ? '已声明不使用非豁免加密'
    : '**未声明**（未声明时构建无法分配给外部测试组，报 Build is not assignable）'}`)
  // betaAppReviewDetails 的属性是平的：contactEmail / contactFirstName / ...
  // （没有嵌套的 betaAppReviewInfo，第一次就是按嵌套读才显示"未填"）。
  console.log(`审核联系人：${detail?.attributes?.contactEmail
    ? `${detail.attributes.contactFirstName ?? ''} ${detail.attributes.contactLastName ?? ''} <${detail.attributes.contactEmail}>`
    : '**未填**（提交审核前必须填）'}`)
  console.log(`本地化说明：${locales.length ? locales.map((l) => l.attributes.locale).join(', ') : '**没有**'}`)
  if (!list.length) console.log('外部测试组：**没有**（prepare 会建一个）')
  for (const group of list) {
    console.log(`测试组：${group.attributes.name} · 内部=${group.attributes.isInternalGroup}`
      + ` · 公开链接=${group.attributes.publicLink || '（审核通过后出现）'}`)
  }
  return { record, build, groups: list, detail, locales }
}

async function prepare() {
  const { record, build, groups: existing } = await status()
  if (!build) throw new Error('还没有构建，无法准备外部测试')

  // 1. 测试信息（反馈邮箱 + 测试说明）。已存在就更新，不重复建。
  const detail = await appInfo(record.id).catch((error) => (error.status === 404 ? null : Promise.reject(error)))
  // betaAppReviewDetails 上的属性只有这几个：反馈邮箱属于
  // betaAppLocalizations，营销地址属于 App 本身，写在这里会被 409 拒绝
  // （第一次跑就是这么被拒的：'feedbackEmail' is not an attribute ...）。
  const attributes = {
    // 审核联系人：Apple 要求名、姓、邮箱、电话四项齐全（缺一个就是 409）。
    contactFirstName: process.env.ASC_CONTACT_FIRST || 'Jingyang',
    contactLastName: process.env.ASC_CONTACT_LAST || 'Tang',
    contactPhone: process.env.ASC_CONTACT_PHONE || '+86 13800000000',
    contactEmail: FEEDBACK_EMAIL,
    demoAccountRequired: false,
    notes: '连接需要一个中转邀请码，我们在 GitHub issue 里公开提供；'
      + '也可以用仓库里的 relay/deploy/deploy.sh 自建中转。'
      + 'App 无内购、无需登录第三方服务。',
  }
  if (detail) {
    console.log('测试信息：已存在，更新反馈邮箱')
    await call('PATCH', `/v1/betaAppReviewDetails/${detail.id}`, {
      data: { type: 'betaAppReviewDetails', id: detail.id, attributes },
    })
  } else {
    console.log('测试信息：创建')
    const created = await call('POST', '/v1/betaAppReviewDetails', {
      data: {
        type: 'betaAppReviewDetails',
        attributes,
        relationships: { app: { data: { type: 'apps', id: record.id } } },
      },
    })
    console.log(`  id=${created.data.id}`)
  }

  // 2. 「测试内容」说明，审核员看到的那段。按语言各一条，简体中文优先。
  const locales = await localizations(record.id)
  const zh = locales.find((item) => item.attributes.locale === 'zh-Hans')
  const payload = {
    description: BETA_DESCRIPTION,
    feedbackEmail: FEEDBACK_EMAIL,
  }
  if (zh) {
    console.log('测试说明：更新 zh-Hans')
    // locale 只在创建时给；PATCH 里带上会被 409 拒绝
    // （'locale' can not be included in a 'UPDATE' operation）。
    await call('PATCH', `/v1/betaAppLocalizations/${zh.id}`, {
      data: { type: 'betaAppLocalizations', id: zh.id, attributes: payload },
    })
  } else {
    console.log('测试说明：创建 zh-Hans')
    await call('POST', '/v1/betaAppLocalizations', {
      data: {
        type: 'betaAppLocalizations',
        attributes: { ...payload, locale: 'zh-Hans' },
        relationships: { app: { data: { type: 'apps', id: record.id } } },
      },
    })
  }

  // 3. 外部测试组 + 把构建挂进去。
  let group = existing.find((item) => item.attributes.name === GROUP_NAME)
  if (!group) {
    console.log(`测试组：创建「${GROUP_NAME}」`)
    const created = await call('POST', '/v1/betaGroups', {
      data: {
        type: 'betaGroups',
        attributes: { name: GROUP_NAME, publicLinkEnabled: true, publicLinkLimitEnabled: false },
        relationships: { app: { data: { type: 'apps', id: record.id } } },
      },
    })
    group = created.data
  } else {
    console.log(`测试组：已存在（${group.id}）`)
  }
  try {
    await call('POST', `/v1/betaGroups/${group.id}/relationships/builds`, {
      data: [{ type: 'builds', id: build.id }],
    })
    console.log('构建已挂到测试组')
  } catch (error) {
    if (String(error.message).includes('409')) console.log('构建已在测试组里（跳过）')
    else throw error
  }
  console.log('\n下一步：node scripts/dev/asc-beta.mjs submit')
}

async function submit() {
  const { build } = await status()
  if (!build) throw new Error('还没有构建')
  const existing = await reviewSubmission(build.id)
  if (existing) {
    console.log(`已经提交过了，当前状态：${existing.attributes.betaReviewState}`)
    return
  }
  console.log('提交外部测试审核……')
  await call('POST', '/v1/betaAppReviewSubmissions', {
    data: {
      type: 'betaAppReviewSubmissions',
      relationships: { build: { data: { type: 'builds', id: build.id } } },
    },
  })
  console.log('已提交。Apple 通常在 1–2 天内出结果，通过后会发邮件，公开链接也会出现。')
}

const [command, ...flags] = process.argv.slice(2)
if (command === 'status') {
  const result = await status()
  if (flags.includes('--watch')) {
    const group = result.groups?.find((item) => item.attributes.name === GROUP_NAME)
    if (group?.attributes.publicLink) {
      console.log(`\n公开链接：${group.attributes.publicLink}`)
    } else {
      setInterval(() => {
        status().then((fresh) => {
          const found = fresh.groups?.find((item) => item.attributes.name === GROUP_NAME)
          if (found?.attributes.publicLink) {
            console.log(`\n★ 公开链接：${found.attributes.publicLink}（审核状态见上一行；通过后外人才装得上）`)
          }
        }).catch((error) => console.error('查询失败：', error.message))
      }, 300_000)
      console.log('\n每 5 分钟查一次审核状态与公开链接')
    }
  }
} else if (command === 'prepare') {
  await prepare()
} else if (command === 'submit') {
  await submit()
} else {
  console.log(readFileSync(new URL(import.meta.url)).toString().split('*/')[0].replace(/^\/\*\*?/, '').trim())
}
