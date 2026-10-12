#!/usr/bin/env node
// 把 `admin.py ops-report --days N` 的 JSON 渲染成一页自带图表的 HTML（014 运营日报）。
//
// 为什么在本机画：服务器只出原始数据、不装图形依赖，改样式不必重新部署（plan.md 12）。
// 为什么手写 SVG：`package.json` 的 dependencies 是空的，不新增第三方依赖（宪法 VII.4）。
//
//   node scripts/dev/feedback-report.mjs report.json > report.html
//   node scripts/dev/feedback-report.mjs < report.json > report.html
//
// 三张图（每日出口字节 / 每日新增设备 / 反馈状态占比）+ 四张表（反馈 / 设备 / 流量 / 邀请码）。
// 正文一律过 escapeHtml——反馈摘要、设备名、邀请码备注都是外部可控字符串。

import { readFileSync } from 'node:fs'
import { pathToFileURL } from 'node:url'

/// 图表配色与画布尺寸：viewBox 固定，实际宽度交给 CSS（窄屏能整页缩放）。
const COLORS = { line: '#2563eb', bar: '#7c3aed', open: '#f59e0b', replied: '#10b981' }
const CHART = { w: 720, h: 220, left: 68, right: 16, top: 14, bottom: 30 }
const STATUS_LABEL = { open: '待回复', replied: '已回复' }

const STYLE = `
* { box-sizing: border-box; }
/* 字体里**不要**写 \`-apple-system\`：在 App 那个锁死的 WKWebView 里，一旦点名它，
   中文会整片变成方框（拉丁字符照旧）——同一页里默认字体、\`"PingFang SC"\`、\`sans-serif\`
   三种写法的中文都正常，只有带 \`-apple-system\` 的两行是方框（2026-10-12 在仿真器上逐行对比过）。
   报告要同时在桌面浏览器与手机里好看，就按 \`"PingFang SC"\` 打头、后面接通用族。 */
body { margin: 0 auto; padding: 24px 20px 64px; max-width: 1080px; background: #f9fafb; color: #111827;
  font-family: "PingFang SC", "Helvetica Neue", Arial, sans-serif;
  font-size: 15px; line-height: 1.55; }
h1 { margin: 0 0 4px; font-size: 22px; }
h2 { margin: 28px 0 10px; padding-bottom: 6px; border-bottom: 1px solid #e5e7eb; font-size: 17px; }
p.meta { margin: 0; color: #6b7280; font-size: 13px; }
.cards { display: flex; flex-wrap: wrap; gap: 10px; margin: 18px 0 0; }
.card { flex: 1 1 150px; padding: 10px 12px; border: 1px solid #e5e7eb; border-radius: 8px; background: #fff; }
.card .k { display: block; color: #6b7280; font-size: 12px; }
.card strong { font-size: 20px; }
figure.chart { margin: 0 0 18px; padding: 12px; border: 1px solid #e5e7eb; border-radius: 8px; background: #fff; }
figure.chart figcaption { margin-bottom: 6px; }
figure.chart .note { margin-left: 8px; color: #6b7280; font-size: 12px; }
figure.chart svg { display: block; width: 100%; height: auto; }
figure.chart svg.narrow { max-width: 560px; }
svg text { font-family: "PingFang SC", Arial, sans-serif; font-size: 11px; fill: #6b7280; }
svg text.legend { font-size: 12px; fill: #374151; }
svg text.donutTotal { font-size: 24px; fill: #111827; }
section.block { margin-top: 26px; }
p.note { color: #6b7280; font-size: 13px; }
table { width: 100%; border-collapse: collapse; background: #fff; font-size: 13px; }
th, td { padding: 7px 9px; border-bottom: 1px solid #eef0f3; text-align: left; vertical-align: top; }
th { background: #f3f4f6; font-weight: 600; white-space: nowrap; }
td.wide { max-width: 420px; }
p.empty { margin: 8px 0; padding: 12px; border: 1px dashed #d1d5db; border-radius: 8px; color: #6b7280; }
ul.sub { margin: 8px 0 0; padding-left: 18px; color: #374151; font-size: 13px; }
`

/** HTML 转义。反馈摘要、设备名、备注都可能带标签或引号。 */
export function escapeHtml(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;')
}

const num = (value) => (Number.isFinite(Number(value)) ? Number(value) : 0)
const text = (value, fallback = '—') => (value === null || value === undefined || value === '' ? fallback : String(value))
// 服务端的 `day` 是本地日 `YYYYMMDD` 整数。轴标签写 `MM-DD`（只切后三位会变成
// "913" 这种看不出年月的写法，2026-10-12 第一版日报上就是这样），表格里写全 `YYYY-MM-DD`。
const dayText = (day) => {
  const raw = String(day ?? '')
  return /^\d{8}$/.test(raw) ? raw : ''
}
const shortDay = (day) => {
  const raw = dayText(day)
  return raw ? `${raw.slice(4, 6)}-${raw.slice(6, 8)}` : '—'
}
const fullDay = (day) => {
  const raw = dayText(day)
  return raw ? `${raw.slice(0, 4)}-${raw.slice(4, 6)}-${raw.slice(6, 8)}` : '—'
}

function formatBytes(bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB']
  let value = num(bytes)
  let unit = 0
  while (value >= 1024 && unit < units.length - 1) { value /= 1024; unit += 1 }
  const shown = unit === 0 || value >= 10 ? Math.round(value) : value.toFixed(1)
  return `${shown} ${units[unit]}`
}

function formatHours(hours) {
  return Number.isFinite(Number(hours)) ? `${Number(hours).toFixed(1)} h` : '—'
}

function formatTime(ms) {
  if (!Number.isFinite(Number(ms)) || Number(ms) <= 0) return '—'
  const at = new Date(Number(ms))
  const pad = (n) => String(n).padStart(2, '0')
  return `${at.getFullYear()}-${pad(at.getMonth() + 1)}-${pad(at.getDate())} ${pad(at.getHours())}:${pad(at.getMinutes())}`
}

/** x 轴标签只留最多 `max` 个，避免 30 天挤成一团。 */
function spread(count, max) {
  if (count <= max) return [...Array(count).keys()]
  const step = (count - 1) / (max - 1)
  return [...Array(max).keys()].map((i) => Math.round(i * step))
}

function figure(title, note, svg, cls = '') {
  const caption = `<strong>${escapeHtml(title)}</strong>`
    + (note ? `<span class="note">${escapeHtml(note)}</span>` : '')
  const draw = cls ? svg.replace('<svg ', `<svg class="${cls}" `) : svg
  return `<figure class="chart"><figcaption>${caption}</figcaption>${draw}</figure>`
}

const emptyFigure = (title, note) => figure(title, note, '<p class="empty">窗口内没有数据</p>')

/** 横向网格线 + 纵轴刻度；y() 由调用方给出，保证与图形同一套坐标。 */
function gridLines(max, y, format) {
  return [0, 0.5, 1].map((ratio) => {
    const at = y(max * ratio)
    return `<line x1="${CHART.left}" x2="${CHART.w - CHART.right}" y1="${at.toFixed(1)}" y2="${at.toFixed(1)}" stroke="#e5e7eb"/>`
      + `<text x="${CHART.left - 8}" y="${(at + 4).toFixed(1)}" text-anchor="end">${escapeHtml(format(max * ratio))}</text>`
  }).join('')
}

/** 折线图：每日出口字节。points = [{label, value}]。 */
function lineChart({ title, note, points, format }) {
  const list = (points ?? []).map((point) => ({ label: shortDay(point.label), value: num(point.value) }))
  if (!list.length) return emptyFigure(title, note)
  const { w, h, left, right, top, bottom } = CHART
  const max = Math.max(...list.map((point) => point.value), 1)
  const x = (i) => (list.length === 1 ? left : left + (i * (w - left - right)) / (list.length - 1))
  const y = (value) => h - bottom - (value / max) * (h - top - bottom)
  const path = list.map((point, i) => `${x(i).toFixed(1)},${y(point.value).toFixed(1)}`).join(' ')
  const dots = list.map((point, i) => `<circle cx="${x(i).toFixed(1)}" cy="${y(point.value).toFixed(1)}" r="2.5" fill="${COLORS.line}"/>`).join('')
  const labels = spread(list.length, 8)
    .map((i) => `<text x="${x(i).toFixed(1)}" y="${h - 10}" text-anchor="middle">${escapeHtml(list[i].label)}</text>`).join('')
  const svg = `<svg viewBox="0 0 ${w} ${h}" role="img" aria-label="${escapeHtml(title)}">`
    + gridLines(max, y, format)
    + `<polygon points="${left},${h - bottom} ${path} ${x(list.length - 1).toFixed(1)},${h - bottom}" fill="${COLORS.line}" opacity="0.12"/>`
    + `<polyline points="${path}" fill="none" stroke="${COLORS.line}" stroke-width="2"/>${dots}${labels}</svg>`
  return figure(title, note, svg)
}

/** 柱状图：每日新增设备。bars = [{label, value}]。 */
function barChart({ title, note, bars, format }) {
  const list = (bars ?? []).map((bar) => ({ label: shortDay(bar.label), value: num(bar.value) }))
  if (!list.length) return emptyFigure(title, note)
  const { w, h, left, right, top, bottom } = CHART
  const max = Math.max(...list.map((bar) => bar.value), 1)
  const band = (w - left - right) / list.length
  const y = (value) => h - bottom - (value / max) * (h - top - bottom)
  const rects = list.map((bar, i) => {
    const bx = left + i * band + band * 0.15
    const height = Math.max(h - bottom - y(bar.value), bar.value > 0 ? 1 : 0)
    const tip = `<title>${escapeHtml(bar.label)}：${escapeHtml(format(bar.value))}</title>`
    return `<rect x="${bx.toFixed(1)}" y="${y(bar.value).toFixed(1)}" width="${(band * 0.7).toFixed(1)}" height="${height.toFixed(1)}" rx="2" fill="${COLORS.bar}">${tip}</rect>`
  }).join('')
  const labels = spread(list.length, 8)
    .map((i) => `<text x="${(left + i * band + band / 2).toFixed(1)}" y="${h - 10}" text-anchor="middle">${escapeHtml(list[i].label)}</text>`).join('')
  const svg = `<svg viewBox="0 0 ${w} ${h}" role="img" aria-label="${escapeHtml(title)}">`
    + gridLines(max, y, format) + rects + labels + '</svg>'
  return figure(title, note, svg)
}

/** 环形图：反馈状态占比。slices = [{label, value, color}]。 */
function donutChart({ title, note, slices }) {
  const list = (slices ?? []).filter((slice) => num(slice.value) > 0)
  const total = list.reduce((sum, slice) => sum + num(slice.value), 0)
  if (!total) return emptyFigure(title, note)
  const radius = 62
  const circumference = 2 * Math.PI * radius
  let offset = 0
  const arcs = list.map((slice) => {
    const length = (num(slice.value) / total) * circumference
    const arc = `<circle cx="110" cy="110" r="${radius}" fill="none" stroke="${slice.color}" stroke-width="30"`
      + ` stroke-dasharray="${length.toFixed(2)} ${(circumference - length).toFixed(2)}"`
      + ` stroke-dashoffset="${(-offset).toFixed(2)}" transform="rotate(-90 110 110)"/>`
    offset += length
    return arc
  }).join('')
  const legend = list.map((slice, i) => `<text x="250" y="${64 + i * 26}" class="legend">`
    + `<tspan fill="${slice.color}">■</tspan> ${escapeHtml(slice.label)} ${num(slice.value)}`
    + `（${Math.round((num(slice.value) / total) * 100)}%）</text>`).join('')
  const center = `<text x="110" y="106" text-anchor="middle" class="donutTotal">${total}</text>`
    + '<text x="110" y="126" text-anchor="middle">条</text>'
  const svg = `<svg viewBox="0 0 480 220" role="img" aria-label="${escapeHtml(title)}">${arcs}${center}${legend}</svg>`
  return figure(title, note, svg, 'narrow')
}

function section(title, note, inner) {
  return `<section class="block"><h2>${escapeHtml(title)}</h2>`
    + (note ? `<p class="note">${escapeHtml(note)}</p>` : '') + inner + '</section>'
}

/** columns = [{label, text(row), raw?}]；cell 默认转义，raw 用于本就是 HTML 的格子。 */
function table(columns, rows, empty) {
  const head = columns.map((column) => `<th>${escapeHtml(column.label)}</th>`).join('')
  const cell = (column, row) => (column.raw ? column.text(row) : escapeHtml(column.text(row)))
  const body = rows.length
    ? rows.map((row) => `<tr>${columns.map((column) => `<td>${cell(column, row)}</td>`).join('')}</tr>`).join('')
    : `<tr><td colspan="${columns.length}" class="empty">${escapeHtml(empty)}</td></tr>`
  return `<table><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table>`
}

function cards(items) {
  return `<section class="cards">${items.map(([label, value]) =>
    `<div class="card"><span class="k">${escapeHtml(label)}</span><strong>${escapeHtml(value)}</strong></div>`).join('')}</section>`
}

/** 服务端漏字段时保住默认值，避免 `undefined` 渲染成表格里的空洞（只加字段、不改名）。 */
function withDefaults(value, fallback) {
  const given = Object.entries(value ?? {}).filter(([, item]) => item !== undefined)
  return { ...fallback, ...Object.fromEntries(given) }
}

export function normalize(data) {
  const source = data && typeof data === 'object' ? data : {}
  return {
    feedback: withDefaults(source.feedback, { new: 0, open: 0, replied: 0, medianFirstReplyHours: null, threads: [] }),
    devices: withDefaults(source.devices, { paired: 0, active7d: 0, revoked: 0, newPerDay: [], list: [] }),
    usage: withDefaults(source.usage, { perDay: [], topAccounts: [], totals: {} }),
    invites: withDefaults(source.invites, { minted: 0, used: 0, remaining: 0, enrollments: [] }),
  }
}

function sourceText(source) {
  if (!source || typeof source !== 'object') return '匿名'
  const kind = source.kind === 'device' ? text(source.deviceModel, '已配对设备') : '匿名'
  return [kind, source.appVersion].filter(Boolean).join(' · ')
}

function feedbackSection(report) {
  const columns = [
    { label: '线程', text: (row) => text(row.threadId) },
    { label: '提交时间', text: (row) => formatTime(row.createdAt) },
    { label: '状态', text: (row) => STATUS_LABEL[row.status] ?? text(row.status) },
    { label: '来源', text: (row) => sourceText(row.source) },
    { label: '摘要', text: (row) => text(row.excerpt, '（无正文）') },
  ]
  const note = `新增 ${report.feedback.new} · 待回复 ${report.feedback.open} · 已回复 ${report.feedback.replied}`
    + ` · 首次回复中位 ${formatHours(report.feedback.medianFirstReplyHours)}`
  return section('反馈', note, table(columns, report.feedback.threads, '窗口内没有反馈'))
}

function deviceSection(report) {
  const columns = [
    { label: '设备', text: (row) => text(row.deviceId) },
    { label: '名称', text: (row) => text(row.name) },
    { label: '机型', text: (row) => text(row.model) },
    { label: 'App', text: (row) => text(row.appVersion) },
    { label: '配对时间', text: (row) => formatTime(row.createdAt) },
    { label: '最近在线', text: (row) => formatTime(row.lastSeenAt) },
    { label: '状态', text: (row) => (row.revoked ? '已撤销' : '正常') },
  ]
  const note = `已配对 ${report.devices.paired} · 7 日活跃 ${report.devices.active7d} · 已撤销 ${report.devices.revoked}`
    + (num(report.devices.debug) > 0 ? ` · 已剔除调试设备 ${num(report.devices.debug)}` : '')
  return section('设备', note, table(columns, report.devices.list, '窗口内没有设备'))
}

function usageSection(report) {
  const columns = [
    { label: '日期', text: (row) => fullDay(row.day) },
    { label: '出口字节', text: (row) => formatBytes(row.egressBytes) },
    { label: '连接数', text: (row) => String(num(row.connections)) },
    { label: '设备数', text: (row) => String(num(row.devices)) },
  ]
  const totals = `合计 ${formatBytes(report.usage.totals?.egressBytes)} · 连接 ${num(report.usage.totals?.connections)}`
  const top = (report.usage.topAccounts ?? [])
    .map((row) => `<li>${escapeHtml(text(row.name, text(row.accountId)))}：${escapeHtml(formatBytes(row.egressBytes))}</li>`)
    .join('')
  const inner = table(columns, report.usage.perDay, '窗口内没有用量记录')
    + (top ? `<h3>出口流量前几名</h3><ul class="sub">${top}</ul>` : '')
  return section('流量', totals, inner)
}

function inviteSection(report) {
  const columns = [
    { label: '使用时间', text: (row) => formatTime(row.usedAt) },
    { label: '备注', text: (row) => text(row.inviteNote, '（无备注）') },
    { label: '账号', text: (row) => text(row.accountName, text(row.accountId)) },
    { label: '电脑', text: (row) => text(row.agentName, text(row.agentId)) },
    { label: '设备数', text: (row) => String(num(row.devices)) },
    { label: '最近在线', text: (row) => formatTime(row.lastSeenAt) },
  ]
  const note = `已发出 ${report.invites.minted} · 已使用 ${report.invites.used} · 剩余 ${report.invites.remaining}`
  return section('邀请码', note, table(columns, report.invites.enrollments, '还没有人用邀请码登记'))
}

/** 组装整页。`now` 只在 ops-report 没给 generatedAt 时兜底（测试用固定值）。 */
export function renderReport(data, { now = Date.now() } = {}) {
  const report = normalize(data)
  const generatedAt = num(data?.generatedAt) || now
  const days = num(data?.days) || 30
  const head = cards([
    ['新增反馈', String(num(report.feedback.new))],
    ['待回复', String(num(report.feedback.open))],
    ['已配对设备', String(num(report.devices.paired))],
    ['7 日活跃', String(num(report.devices.active7d))],
    ['窗口出口', formatBytes(report.usage.totals?.egressBytes)],
    ['邀请码剩余', String(num(report.invites.remaining))],
  ])
  const charts = '<h2>图表</h2>'
    + lineChart({
      title: '每日出口字节',
      note: `最近 ${days} 天`,
      points: (report.usage.perDay ?? []).map((row) => ({ label: row.day, value: row.egressBytes })),
      format: formatBytes,
    })
    + barChart({
      title: '每日新增设备',
      note: `最近 ${days} 天`,
      bars: (report.devices.newPerDay ?? []).map((row) => ({ label: row.day, value: row.count })),
      format: (value) => String(Math.round(value)),
    })
    + donutChart({
      title: '反馈状态占比',
      note: '历史全部线程',
      slices: [
        { label: '待回复', value: report.feedback.open, color: COLORS.open },
        { label: '已回复', value: report.feedback.replied, color: COLORS.replied },
      ],
    })
  const body = [
    head,
    charts,
    feedbackSection(report),
    deviceSection(report),
    usageSection(report),
    inviteSection(report),
  ].join('\n')
  return `<!DOCTYPE html>
<html lang="zh-Hans">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>DSH Mobile 运营日报 · ${escapeHtml(formatTime(generatedAt).slice(0, 10))}</title>
<style>${STYLE}</style>
</head>
<body>
<h1>DSH Mobile 运营日报</h1>
<p class="meta">生成时间 ${escapeHtml(formatTime(generatedAt))} · 统计窗口最近 ${days} 天</p>
${body}
</body>
</html>
`
}

/** 读取 JSON（文件参数或 stdin）并打印 HTML。 */
function main(argv) {
  const source = argv[0] && argv[0] !== '-' ? readFileSync(argv[0], 'utf8') : readFileSync(0, 'utf8')
  process.stdout.write(renderReport(JSON.parse(source)))
  return 0
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exit(main(process.argv.slice(2)))
}
