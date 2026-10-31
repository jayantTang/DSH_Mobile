#!/usr/bin/env node
/**
 * TestFlight 崩溃反馈的只读查询：列测试者提交的崩溃、把 .ips 原文落盘。
 *
 *   node scripts/dev/asc-crashes.mjs list            # 每条崩溃：时间、构建、机型、测试者备注
 *   node scripts/dev/asc-crashes.mjs download [id]   # 落盘到 maintainers/crashes/；省略 id 就全下
 *
 * 数据来源只有 App Store Connect API 的 `betaFeedbackCrashSubmissions`：
 * 列集合必须走 `apps/{id}/betaFeedbackCrashSubmissions`（顶层集合被 Apple 禁了 GET_COLLECTION），
 * 堆栈在 `betaFeedbackCrashSubmissions/{id}/crashLog` 的 `attributes.logText`。
 *
 * 边界（2026-10-29 实测）：这里能看到的是**测试者在崩溃界面点了反馈**的那些；
 * TestFlight 自动采集、测试者没留言的崩溃不一定出现在这个资源里，只在网页 / Xcode
 * Organizer 的 Crashes 里。所以 `list` 为空不等于没有崩溃。
 *
 * 只做 GET：不动审核、构建、测试组与本机任何状态（落盘目录在 maintainers/，已 gitignore）。
 */

import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

import { ascGet, appIdForBundle, credentials, token } from './asc-client.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))
const ROOT = join(HERE, '..', '..')
const BUNDLE_ID = 'com.jayanttang.dsh'
const OUT = join(ROOT, 'maintainers', 'crashes')

/** 本机真值（含 ASC Issuer ID）只写在 .env.local 里，不入库；这里按需读一次。 */
function loadLocalEnv() {
  const path = join(ROOT, '.env.local')
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

const FIELDS = 'createdDate,comment,email,deviceModel,osVersion,locale,architecture,connectionType,build'

/// 最近一次上传的构建在前，标签里带版本号，收件箱里对得上「哪个版本崩的」。
function submissions(jwt) {
  const appId = appIdForBundle(BUNDLE_ID, jwt)
  if (!appId) throw new Error(`账号里没有 ${BUNDLE_ID} 这个 App 记录`)
  const { data, included = [] } = ascGet(
    `/v1/apps/${appId}/betaFeedbackCrashSubmissions?limit=200&include=build`
    + `&fields[betaFeedbackCrashSubmissions]=${FIELDS}&fields[builds]=version,uploadedDate`,
    jwt,
  )
  const builds = new Map(included.filter((x) => x.type === 'builds').map((x) => [x.id, x]))
  return data
    .map((d) => {
      const build = builds.get(d.relationships?.build?.data?.id)?.attributes
      return { id: d.id, build: build?.version ?? '(未知构建)', ...d.attributes }
    })
    .sort((a, b) => String(b.createdDate).localeCompare(String(a.createdDate)))
}

/// 崩溃日志不是每条都有：没有 crashLog 资源的会 404，这不是错误，原样记一句。
function crashLog(id, jwt) {
  try {
    return ascGet(`/v1/betaFeedbackCrashSubmissions/${id}/crashLog`, jwt)?.data?.attributes?.logText ?? ''
  } catch (error) {
    if (String(error.message).startsWith('404')) return ''
    throw error
  }
}

/// 日志标题里取「Triggered by Thread」「Exception Type」与崩溃线程首帧，列表就够判断是不是同一类。
function summarize(text) {
  if (!text) return '（Apple 侧没有这条崩溃的日志）'
  const exception = /Exception Type:\s+(.+)/.exec(text)?.[1]?.trim() ?? '?'
  const thread = /Triggered by Thread:\s+(\d+)/.exec(text)?.[1]
  const frames = text.split('\n')
  const start = frames.findIndex((line) => thread !== undefined && line.startsWith(`Thread ${thread} Crashed:`))
  const stack = start >= 0
    ? frames.slice(start + 1, start + 4).map((line) => line.replace(/^\s*\d+\s+/, '').trim())
    : []
  return `${exception} · 线程 ${thread ?? '?'} · ${stack.slice(0, 2).join(' ← ') || '（无栈）'}`
}

const [command, argument] = process.argv.slice(2)
const jwt = token(credentials())

if (command === 'list') {
  const rows = submissions(jwt)
  if (!rows.length) {
    console.log('没有测试者附带反馈的崩溃提交（自动采集的崩溃只在 ASC 网页 / Xcode Organizer 里）')
  }
  for (const row of rows) {
    console.log(`${row.createdDate}  build ${row.build}  ${row.deviceModel}  iOS ${row.osVersion}`)
    console.log(`  ${row.id}  ${summarize(crashLog(row.id, jwt))}`)
    if (row.comment) console.log(`  留言：${row.comment.replace(/\s+/g, ' ').slice(0, 200)}`)
  }
} else if (command === 'download') {
  const rows = submissions(jwt)
  const picked = argument ? rows.filter((row) => row.id === argument) : rows
  if (!picked.length) {
    console.error(argument ? `没有 id 为 ${argument} 的崩溃提交` : '没有可下载的崩溃提交')
    process.exit(1)
  }
  mkdirSync(OUT, { recursive: true })
  for (const row of picked) {
    const text = crashLog(row.id, jwt)
    if (!text) {
      console.log(`跳过 ${row.id}：Apple 侧没有日志`)
      continue
    }
    const path = join(OUT, `${row.build}-${row.id}.ips`)
    writeFileSync(path, text)
    console.log(`${path}  (${text.length} 字节)`)
  }
} else {
  console.log(readFileSync(new URL(import.meta.url)).toString().split('*/')[0].replace(/^\/\*\*?/, '').trim())
}
