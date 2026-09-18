#!/usr/bin/env node
/**
 * 填 App Store 版本页的元数据（不是 TestFlight 那套，是正式上架用的那套）。
 *
 *   node scripts/dev/asc-store.mjs status   # 现在缺哪些字段（只读）
 *   node scripts/dev/asc-store.mjs fill     # 把下面这些文案写进去
 *
 * 只写**文案类**字段：说明、关键词、支持/隐私地址、分类、审核备注。
 * 不上传截图（那要人挑图）、不提交审核（那要人决定时机）。
 *
 * 名称与隐私地址这类"对外身份"改起来有代价，所以文案都写在本文件里，
 * 改一次就同时改了脚本与记录。
 */

import { createSign } from 'node:crypto'
import { existsSync, readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const API = 'https://api.appstoreconnect.apple.com'
const BUNDLE_ID = 'com.jayanttang.dsh'
const REPO = 'https://github.com/jayantTang/DSH_Mobile'
const RAW = 'https://raw.githubusercontent.com/jayantTang/DSH_Mobile/main'

const DESCRIPTION = `把电脑上的 DeepSeek Harness，装进口袋。

DSH Mobile 是你电脑上 DSH 的手机端：同一个 host、同一批会话、同一条消息流。通勤路上看一眼任务跑到哪了，躺床上把卡住的那一步答掉，电脑上的活不会因为你离开键盘而停下。

—— 它解决什么 ——

· 任务在电脑上跑，进度在手机上跟。锁屏、切 App、换网络都不会打断。
· agent 卡在提问上时不再干等：提问卡片直接推到手机，当场作答，任务继续。
· 通勤、排队、睡前，不用回到电脑前也能推进手上的活。

—— 能做什么 ——

会话：按项目目录分组、归档与找回、新建接续会话
对话：流式输出、思考过程折叠、工具调用卡片、Markdown 与表格渲染
问答：电脑端 agent 的提问卡片可在手机上直接作答，也支持自由输入
图片：查看与点开放大；从相册或文件 App 发图进对话，让 agent 直接看图
文件：分块上传任意文件到会话工作区；代码高亮、diff、HTML 报告预览
设备：已配对设备列表与自助撤销

—— 怎么连上的 ——

手机不直连你的电脑，而是各自连到一台中转（WSS）：中转只做鉴权与转发，不解析会话内容，会话数据只在你的手机与你的电脑之间流动。

中转可以自建（仓库里有幂等安装脚本），也就是说这套东西没有任何一环必须依赖别人。

—— 需要什么 ——

· 一台跑着 DSH 的电脑（macOS / Linux / Windows）
· 电脑上安装本项目的连接器插件（开源，见仓库）
· 一个中转：可以自建，也可以用别人提供的中转配合邀请码

—— 关于数据 ——

无内购、无广告、无账号体系，App 不收集任何数据，不含第三方统计或崩溃上报 SDK。设备令牌存在系统钥匙串里；提醒用本机音频保活实现，不经 Apple 推送服务。

连接器、中转、App 客户端全部开源（MIT）：https://github.com/jayantTang/DSH_Mobile
隐私说明：https://raw.githubusercontent.com/jayantTang/DSH_Mobile/main/docs/PRIVACY.md`

const KEYWORDS = 'DSH,DeepSeek,AI,agent,远程,客户端,编程,终端'
const PROMO_TEXT = '把电脑上的 DeepSeek Harness 装进手机：任务在电脑上跑，进度在手机上跟。'
const SUPPORT_URL = `${REPO}/issues`
const PRIVACY_URL = `${RAW}/docs/PRIVACY.md`
const MARKETING_URL = REPO
const CATEGORY = 'DEVELOPER_TOOLS'
// 审核备注。**演示环境另给**：邀请码是一次性凭据，中转地址也属于本机真值，
// 两者都只存在于 .env.local（不入库）——这个文件里出现过的后果是：公开仓库里
// 躺着一个能用的邀请码，谁先看到谁就能用掉，审核员反而兑换不了。
const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..')

/** 最小 .env.local 读取：只填没设过的变量，不覆盖调用方显式传入的值。 */
function loadLocalEnv() {
  const path = join(REPO_ROOT, '.env.local')
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

const REVIEW_INVITE = (process.env.ASC_REVIEW_INVITE ?? '').trim()
const REVIEW_RELAY = (process.env.DSH_RELAY_URL ?? '').trim()

const REVIEW_NOTES_HEAD = `本 App 是「远程客户端」：手机连到用户自己电脑上的 DeepSeek Harness（DSH）。App 不连我们的服务器，
只连用户自己配置的中转地址（WSS）。因此必须有一台电脑配合才能走完功能，我们准备了演示环境。`

const REVIEW_NOTES_STEPS = `【审核步骤，约 3 分钟】
1. 在一台 macOS / Linux 电脑上装好 DSH（npm i -g @deepseek-ai/dsh），然后依次执行：
     dsh plugin --profile web add dsh-plugin-mobile-link
     dsh-mobile-link enroll --invite <邀请码> --relay <中转地址>
     dsh web
2. 电脑上打开 http://127.0.0.1:端口/mobile-link/qr（端口是上一步启动时打印的），会显示配对二维码。
3. 手机上打开 App → 底部「扫码配对」对准该二维码；也可以把二维码里的配对码手输进「配对码」框
   → 点「配对并连接」。
4. 连接成功后即可看到该电脑上的会话列表：可打开转写、发消息、回答 agent 的提问。`

const REVIEW_NOTES_TAIL = `【若不方便配电脑】
App 启动后是连接页：可以完整查看中转地址输入、配对表单，以及右上角设置里的各项
（连接信息、权限说明、关于）。App 无内购、无广告、无登录、不含第三方 SDK，也不收集任何数据
（隐私政策见 App Store 页面里的链接）。

【网络】
中转是标准 WSS。若审核网络无法访问该域名，请告知，我们可以临时切到其他地区的中转。`

/** 演示环境那一段，只在真的配了邀请码时才有内容。 */
function demoBlock() {
  const missing = [!REVIEW_INVITE && 'ASC_REVIEW_INVITE', !REVIEW_RELAY && 'DSH_RELAY_URL'].filter(Boolean)
  if (missing.length) return { text: '', missing }
  return {
    text: `【演示环境（审核专用邀请码，60 天有效；通过后我们会撤销）】
邀请码：${REVIEW_INVITE}
中转地址：${REVIEW_RELAY}

${REVIEW_NOTES_STEPS.replace('<邀请码>', REVIEW_INVITE).replace('<中转地址>', REVIEW_RELAY)}`,
    missing: [],
  }
}

function reviewNotes() {
  const demo = demoBlock()
  const extra = process.env.ASC_REVIEW_NOTES_EXTRA
  const body = [REVIEW_NOTES_HEAD, demo.text, REVIEW_NOTES_TAIL].filter(Boolean).join('\n\n')
  return extra ? `${body}\n\n${extra}` : body
}

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

// `status` is the read-only half: it can be run without the demo code configured,
// but it must say so — a missing demo block is invisible in App Store Connect
// until a reviewer cannot connect. Checked before the API credentials so the
// warning still shows when those are absent too.
if (process.argv[2] !== 'fill') {
  const demo = demoBlock()
  if (demo.missing.length) {
    console.warn(`提示：审核备注的演示环境未配置（缺 ${demo.missing.join(' / ')}），` +
                 'fill 会因此拒绝执行。')
  }
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
    const error = new Error(`${response.status} ${method} ${path}\n   ${detail || text.slice(0, 300)}`)
    error.status = response.status
    throw error
  }
  return parsed
}

const get = (path) => call('GET', path)

async function context() {
  const { data: apps } = await get(`/v1/apps?filter[bundleId]=${BUNDLE_ID}&limit=1`)
  const app = apps[0]
  if (!app) throw new Error(`账号里没有 ${BUNDLE_ID}`)
  const { data: versions } = await get(`/v1/apps/${app.id}/appStoreVersions?limit=10`)
  // 取一个还能改的版本：正在准备中的那个，或者刚被拒可以继续改的那个。
  const editable = versions.find((item) =>
    ['PREPARE_FOR_SUBMISSION', 'REJECTED', 'DEVELOPER_REJECTED', 'METADATA_REJECTED']
      .includes(item.attributes.appStoreState)) ?? versions[0]
  const { data: infos } = await get(`/v1/apps/${app.id}/appInfos`)
  const info = infos[0]
  const { data: localizations } = await get(`/v1/appInfos/${info.id}/appInfoLocalizations`)
  const zh = localizations.find((item) => item.attributes.locale === 'zh-Hans') ?? localizations[0]
  // 「说明/关键词/支持网址/营销网址/审核备注」不是版本上的属性，而是
  // **版本本地化**（appStoreVersionLocalizations）上的——写在 appStoreVersions 上会被
  // 409 拒绝（unknown attribute，第一次就是这么撞的）。
  const { data: versionLocales } = await get(`/v1/appStoreVersions/${editable.id}/appStoreVersionLocalizations`)
  const versionZh = versionLocales.find((item) => item.attributes.locale === 'zh-Hans') ?? versionLocales[0]
  return { app, version: editable, info, localization: zh, versionLocalization: versionZh }
}

async function status() {
  const { app, version, localization, versionLocalization, info } = await context()
  // 审核备注与分类都不在版本/本地化上：备注是 appStoreReviewDetail，分类是 appInfo 的关系。
  // 读错地方会显示成"空"，第一次就这么被骗过一次。
  const reviewDetail = await get(`/v1/appStoreVersions/${version.id}/appStoreReviewDetail`)
    .catch(() => null)
  const category = await get(`/v1/appInfos/${info.id}/relationships/primaryCategory`)
    .catch(() => null)
  const v = version?.attributes ?? {}
  const l = localization?.attributes ?? {}
  const vl = versionLocalization?.attributes ?? {}
  const rows = [
    ['版本', v.versionString, v.appStoreState],
    ['版权', v.copyright, ''],
    ['说明', vl.description ? `${vl.description.length} 字` : null, ''],
    ['关键词', vl.keywords, ''],
    ['宣传文本', vl.promoText || '（可选，网页上填）', ''],
    ['支持网址', vl.supportUrl, ''],
    ['营销网址', vl.marketingUrl, ''],
    ['审核备注', reviewDetail?.data?.attributes?.notes
      ? `${reviewDetail.data.attributes.notes.length} 字` : null, ''],
    ['名称', l.name, ''],
    ['副标题', l.subtitle, ''],
    ['隐私政策网址', l.privacyPolicyUrl, ''],
  ]
  console.log(`App: ${app.attributes.name} (${app.attributes.bundleId}) · 版本 ${v.versionString} (${v.appStoreState})`)
  for (const [label, value, extra] of rows) {
    const filled = value !== null && value !== undefined && String(value).trim() !== ''
    console.log(`  ${filled ? '✓' : '✗'} ${label}：${filled ? String(value).slice(0, 60) : '**空**'} ${extra ?? ''}`)
  }
  // 分类的读法：先看 app 的 relationships（fields[apps] 那套在 App Store Connect API 上
  // 会 400，别用）。读不到不算错，填的时候会写。
  console.log(`  分类：${category?.data?.data?.id ?? category?.data?.id ?? '**空**'}`)
  // 把这些一并返回：fill() 直接复用 status() 的结果，省一次查询，也保证两边看到的是同一份。
  return { app, version, localization, versionLocalization, info }
}

async function fill() {
  const { app, version, localization, versionLocalization, info } = await status()
  if (!version) throw new Error('没有可编辑的 App Store 版本')
  if (!versionLocalization) throw new Error('这个版本还没有本地化记录（网页上打开一次版本页即可生成）')

  console.log('\n写入版本上的字段（版权）……')
  await call('PATCH', `/v1/appStoreVersions/${version.id}`, {
    data: { type: 'appStoreVersions', id: version.id, attributes: { copyright: '2026 jayantTang' } },
  })

  console.log('写入版本本地化（说明/关键词/网址/审核备注）……')
  await call('PATCH', `/v1/appStoreVersionLocalizations/${versionLocalization.id}`, {
    data: {
      type: 'appStoreVersionLocalizations',
      id: versionLocalization.id,
      // 只有这些是版本本地化上的属性。promoText / reviewNotes 挂在别的资源上
      // （写在这里会 409 unknown attribute，第一次就是这么撞的）。
      attributes: {
        description: DESCRIPTION,
        keywords: KEYWORDS,
        supportUrl: SUPPORT_URL,
        marketingUrl: MARKETING_URL,
      },
    },
  })

  // 演示环境没配就不写：一份没有可用邀请码的备注会让审核员卡在连接页，
  // 而那是「通过」与「被拒」之间最贵的差别。宁可这里失败，也不写半份。
  const demo = demoBlock()
  if (demo.missing.length) {
    throw new Error(
      `审核备注缺少演示环境：请在 .env.local 里设 ${demo.missing.join(' / ')}` +
      '（邀请码用 relay/admin.py invite-mint 铸一个，一次性的，别写进仓库）'
    )
  }

  console.log('写入审核备注（appStoreReviewDetails）……')
  const notes = reviewNotes()
  const existingDetail = await get(`/v1/appStoreVersions/${version.id}/appStoreReviewDetail`)
    .catch((error) => (error.status === 404 ? null : Promise.reject(error)))
  if (existingDetail?.data) {
    await call('PATCH', `/v1/appStoreReviewDetails/${existingDetail.data.id}`, {
      data: { type: 'appStoreReviewDetails', id: existingDetail.data.id, attributes: { notes } },
    })
  } else {
    await call('POST', '/v1/appStoreReviewDetails', {
      data: {
        type: 'appStoreReviewDetails',
        attributes: { notes, contactFirstName: 'Jingyang', contactLastName: 'Tang',
                      contactEmail: process.env.ASC_FEEDBACK_EMAIL || 'forwoshitjy@live.com',
                      contactPhone: process.env.ASC_CONTACT_PHONE || '+86 13800000000' },
        relationships: { appStoreVersion: { data: { type: 'appStoreVersions', id: version.id } } },
      },
    })
  }

  console.log('写入名称/副标题/隐私政策……')
  await call('PATCH', `/v1/appInfoLocalizations/${localization.id}`, {
    data: {
      type: 'appInfoLocalizations',
      id: localization.id,
      attributes: {
        // 名称必须与 App Store Connect 里登记的一致（改名字要走新建版本的流程）
        name: localization.attributes.name,
        subtitle: '手机上的 DeepSeek Harness',
        privacyPolicyUrl: PRIVACY_URL,
      },
    },
  })

  console.log('写入分类……')
  const { data: categories } = await get('/v1/appCategories?filter[platforms]=IOS&limit=200')
  const primary = categories.find((item) => item.id === CATEGORY)
  if (!primary) throw new Error(`找不到分类 ${CATEGORY}`)
  // 分类挂在 **appInfo** 上（不是 app）：写在 apps 上会 409 unknown relationship。
  await call('PATCH', `/v1/appInfos/${info.id}`, {
    data: {
      type: 'appInfos',
      id: info.id,
      relationships: {
        primaryCategory: { data: { type: 'appCategories', id: CATEGORY } },
      },
    },
  })
  console.log('\n完成。再跑一次 status 看还有哪些 ✗（截图与年龄分级只能在网页上填）。')
}

const command = process.argv[2]
if (command === 'fill') await fill()
else await status()
