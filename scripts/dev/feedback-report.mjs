#!/usr/bin/env node
// 把 `admin.py ops-report --days N` 的 JSON 渲染成一页自带图表的 HTML（014 运营日报）。
//
// 版面分两段，各回答一个问题：
//   【今日】  今天有没有事——出口流量（含与昨日、前 7 日均值的对比）、活跃设备与时段、
//             今日账号/设备/反馈/登记（只列前几条）。
//   【最近 N 天】趋势与谁在用——总量与日均、每日出口折线与新增设备柱状、账号排名、
//             设备与反馈清单、邀请码的账。
//
// 为什么在本机画：服务器只出原始数据、不装图形依赖，改样式不必重新部署（plan.md 12）。
// 为什么手写 SVG：`package.json` 的 dependencies 是空的，不新增第三方依赖（宪法 VII.4）。
// 为什么图表的 viewBox 只有 360 宽：这份报告主要在手机上看，卡片内宽就是 330–360pt。
// 旧版按 720 宽画、再被 CSS 压到一半，12px 的轴标签实际渲染成 6px，等于看不见。
//
//   node scripts/dev/feedback-report.mjs report.json > report.html
//   node scripts/dev/feedback-report.mjs < report.json > report.html
//
// 正文一律过 escapeHtml——反馈摘要、设备名、邀请码备注都是外部可控字符串。

import { readFileSync } from 'node:fs'
import { pathToFileURL } from 'node:url'

/// 图表配色与画布尺寸：viewBox 固定，实际宽度交给 CSS（窄屏能整页缩放）。
const COLORS = { line: '#2563eb', bar: '#7c3aed', open: '#f59e0b', replied: '#10b981',
  peak: '#dc2626', grid: '#eef2f7' }
const CHART = { w: 360, h: 168, left: 46, right: 10, top: 16, bottom: 24 }
const STATUS_LABEL = { open: '待回复', replied: '已回复' }
const WEEKDAYS = ['周日', '周一', '周二', '周三', '周四', '周五', '周六']

/// 一张清单最多列几条：手机上要一屏能扫完，剩下的用「共 N 条」交代。
const LIMIT = { todayAccounts: 4, todayBuilds: 3, todayDevices: 4, todayFeedback: 4, todayEnrolls: 3,
  accounts: 6, devices: 8, feedback: 6, enrolls: 6, recentDays: 7 }

const STYLE = `
* { box-sizing: border-box; }
/* 字体里**不要**写 \`-apple-system\`：在 App 那个锁死的 WKWebView 里，一旦点名它，
   中文会整片变成方框（拉丁字符照旧）——同一页里默认字体、\`"PingFang SC"\`、\`sans-serif\`
   三种写法的中文都正常，只有带 \`-apple-system\` 的两行是方框（2026-10-12 在仿真器上逐行对比过）。
   报告要同时在桌面浏览器与手机里好看，就按 \`"PingFang SC"\` 打头、后面接通用族。 */
body { margin: 0; padding: 14px 12px 32px; background: #f5f6f8; color: #0f172a;
  font-family: "PingFang SC", "Helvetica Neue", Arial, sans-serif;
  font-size: 14px; line-height: 1.5; -webkit-text-size-adjust: 100%; }
.wrap { max-width: 720px; margin: 0 auto; }
h1 { margin: 0; font-size: 19px; letter-spacing: .2px; }
header.page .sub { margin: 3px 0 0; color: #64748b; font-size: 12px; }
h2 { display: flex; align-items: center; gap: 7px; margin: 20px 0 8px; font-size: 15px; }
h2 .tag { padding: 2px 8px; border-radius: 999px; background: #2563eb; color: #fff;
  font-size: 11px; font-weight: 600; letter-spacing: .3px; }
h2 .tag.range { background: #475569; }
h2 .h2note { color: #94a3b8; font-size: 11px; font-weight: 400; }
h3 { display: flex; align-items: baseline; gap: 6px; margin: 14px 0 7px; color: #334155;
  font-size: 13px; font-weight: 600; }
.hero { padding: 13px 14px; border: 1px solid #dbeafe; border-radius: 14px;
  background: linear-gradient(155deg, #eff6ff 0%, #ffffff 72%); }
.hero .k { color: #1d4ed8; font-size: 12px; }
.hero .v { display: block; margin: 1px 0 7px; font-size: 30px; font-weight: 700;
  letter-spacing: -.6px; }
.hero .meta { margin: 8px 0 0; color: #475569; font-size: 12px; }
.chips { display: flex; flex-wrap: wrap; gap: 6px; }
.chip { padding: 2px 8px; border-radius: 999px; background: #f1f5f9; color: #475569;
  font-size: 11px; white-space: nowrap; }
/* 流量涨跌不判好坏，所以 chip 只用中性色，不用红绿。 */
.chip.up { background: #e0e7ff; color: #3730a3; }
.chip.down { background: #f1f5f9; color: #64748b; }
.chip.open { background: #fef3c7; color: #92400e; }
.chip.replied { background: #d1fae5; color: #065f46; }
.chip.warn { background: #fee2e2; color: #991b1b; }
.kpis { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 8px;
  margin-top: 10px; }
.kpi { padding: 9px 11px; border: 1px solid #e8ecf1; border-radius: 11px; background: #fff; }
.kpi .k { display: block; color: #64748b; font-size: 11.5px; }
.kpi strong { font-size: 19px; font-weight: 600; letter-spacing: -.3px; }
.kpi em { margin-left: 6px; color: #94a3b8; font-size: 11px; font-style: normal; }
.bars { margin-top: 10px; }
.bar { display: flex; align-items: center; gap: 8px; margin-top: 5px; font-size: 12px; }
.bar .bar-k { flex: 0 0 74px; color: #64748b; }
.bar .track { flex: 1 1 auto; height: 8px; border-radius: 999px; background: #eff2f6; }
.bar .track i { display: block; height: 100%; border-radius: 999px; }
.bar .bar-v { flex: 0 0 auto; min-width: 62px; text-align: right; color: #334155;
  font-variant-numeric: tabular-nums; }
table { width: 100%; border-collapse: collapse; background: #fff; border-radius: 11px;
  overflow: hidden; font-size: 12.5px; }
th, td { padding: 7px 9px; border-bottom: 1px solid #eef1f5; text-align: left; }
tr:last-child td { border-bottom: none; }
th { background: #f8fafc; color: #64748b; font-size: 11px; font-weight: 600;
  white-space: nowrap; }
td.num, th.num { text-align: right; font-variant-numeric: tabular-nums; white-space: nowrap; }
td.name { max-width: 40vw; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
ul.rows { margin: 0; padding: 0; list-style: none; background: #fff; border-radius: 11px;
  overflow: hidden; }
ul.rows li { padding: 8px 10px; border-bottom: 1px solid #eef1f5; }
ul.rows li:last-child { border-bottom: none; }
ul.rows .l1 { display: flex; align-items: baseline; gap: 8px; }
ul.rows .l1 .t { flex: 1 1 auto; min-width: 0; overflow: hidden; text-overflow: ellipsis;
  white-space: nowrap; }
ul.rows .l2 { margin-top: 2px; color: #8b98a9; font-size: 11.5px; }
.chips.legend { margin-top: 8px; }
.stack { display: flex; height: 10px; margin-top: 8px; border-radius: 999px; overflow: hidden;
  background: #eff2f6; }
.stack i { display: block; height: 100%; }
figure.chart { margin: 0 0 10px; padding: 10px 12px 4px; background: #fff; border-radius: 11px;
  border: 1px solid #eef1f5; }
figure.chart figcaption { display: flex; align-items: baseline; justify-content: space-between;
  gap: 8px; font-size: 12.5px; }
figure.chart .note { color: #94a3b8; font-size: 11px; text-align: right; }
figure.chart svg { display: block; width: 100%; max-width: 540px; height: auto; margin: 2px auto 0; }
svg text { font-family: "PingFang SC", Arial, sans-serif; font-size: 9.5px; fill: #94a3b8; }
svg text.peakLabel { fill: ${COLORS.peak}; font-weight: 600; }
p.empty { margin: 0; padding: 11px 12px; border: 1px dashed #d7dde5; border-radius: 11px;
  background: #fff; color: #94a3b8; font-size: 12.5px; }
p.foot { margin: 18px 2px 0; color: #94a3b8; font-size: 11px; line-height: 1.6; }
@media (min-width: 600px) {
  .kpis { grid-template-columns: repeat(4, minmax(0, 1fr)); }
  .hero .v { font-size: 34px; }
}
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
const last = (list) => (Array.isArray(list) && list.length ? list[list.length - 1] : undefined)
/// 手机上清单只给一行，长摘要/长设备名截断（完整内容在 App 的反馈页里）。
const clip = (value, max = 42) => {
  const raw = String(value ?? '')
  return raw.length > max ? `${raw.slice(0, max - 1)}…` : raw
}
/// 构建号形如 `1.0 20261012.1056` 或 `1.0 (20261012.1056)`，手机上只留日期版本那一段。
const shortBuild = (build) => {
  const match = String(build ?? '').match(/\d{8}\.\d{4}/)
  return match ? match[0] : String(build ?? '').split(' ').pop()
}
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

function formatInt(value) {
  return num(value).toLocaleString('en-US')
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

/// 清单里的时间写 `MM-DD HH:MM`：窗口最长 30 天，年份是废话，省下的位置留给账号名与机型。
function shortTime(ms) {
  if (!Number.isFinite(Number(ms)) || Number(ms) <= 0) return '—'
  const at = new Date(Number(ms))
  const pad = (n) => String(n).padStart(2, '0')
  return `${pad(at.getMonth() + 1)}-${pad(at.getDate())} ${pad(at.getHours())}:${pad(at.getMinutes())}`
}

function clock(ms) {
  const at = new Date(Number(ms))
  const pad = (n) => String(n).padStart(2, '0')
  return `${pad(at.getHours())}:${pad(at.getMinutes())}`
}

/// x 轴标签只留最多 `max` 个，避免 30 天挤成一团。
function spread(count, max) {
  if (count <= max) return [...Array(count).keys()]
  const step = (count - 1) / (max - 1)
  return [...Array(max).keys()].map((i) => Math.round(i * step))
}

function figure(title, note, svg) {
  const caption = `<strong>${escapeHtml(title)}</strong>`
    + (note ? `<span class="note">${escapeHtml(note)}</span>` : '')
  return `<figure class="chart"><figcaption>${caption}</figcaption>${svg}</figure>`
}

const emptyFigure = (title, note) => figure(title, note, '<p class="empty">窗口内没有数据</p>')

/** 横向网格线 + 纵轴刻度；y() 由调用方给出，保证与图形同一套坐标。 */
function gridLines(max, y, format) {
  return [0, 0.5, 1].map((ratio) => {
    const at = y(max * ratio)
    return `<line x1="${CHART.left}" x2="${CHART.w - CHART.right}" y1="${at.toFixed(1)}" y2="${at.toFixed(1)}" stroke="${COLORS.grid}"/>`
      + `<text x="${CHART.left - 7}" y="${(at + 3.4).toFixed(1)}" text-anchor="end">${escapeHtml(format(max * ratio))}</text>`
  }).join('')
}

/** 折线图：每日出口字节（峰值点单独标出来）。points = [{label, value}]。 */
function lineChart({ title, note, points, format }) {
  const list = (points ?? []).map((point) => ({ label: shortDay(point.label), value: num(point.value) }))
  if (!list.length || !list.some((point) => point.value > 0)) return emptyFigure(title, note)
  const { w, h, left, right, top, bottom } = CHART
  const max = Math.max(...list.map((point) => point.value), 1)
  const x = (i) => (list.length === 1 ? left : left + (i * (w - left - right)) / (list.length - 1))
  const y = (value) => h - bottom - (value / max) * (h - top - bottom)
  const path = list.map((point, i) => `${x(i).toFixed(1)},${y(point.value).toFixed(1)}`).join(' ')
  const peak = list.reduce((best, point, i) => (point.value > list[best].value ? i : best), 0)
  const dots = list.map((point, i) => {
    const hot = i === peak && point.value > 0
    return `<circle cx="${x(i).toFixed(1)}" cy="${y(point.value).toFixed(1)}" r="${hot ? 3 : 1.6}" `
      + `fill="${hot ? COLORS.peak : COLORS.line}"/>`
  }).join('')
  const peakAt = x(peak)
  const anchor = peakAt < left + 26 ? 'start' : peakAt > w - right - 26 ? 'end' : 'middle'
  const peakLabel = list[peak].value > 0
    ? `<text x="${peakAt.toFixed(1)}" y="${(y(list[peak].value) - 5).toFixed(1)}" class="peakLabel" text-anchor="${anchor}">${escapeHtml(format(list[peak].value))}</text>`
    : ''
  const labels = spread(list.length, 5)
    .map((i) => `<text x="${x(i).toFixed(1)}" y="${h - 9}" text-anchor="middle">${escapeHtml(list[i].label)}</text>`).join('')
  const svg = `<svg viewBox="0 0 ${w} ${h}" role="img" aria-label="${escapeHtml(title)}">`
    + gridLines(max, y, format)
    + `<polygon points="${left},${h - bottom} ${path} ${x(list.length - 1).toFixed(1)},${h - bottom}" fill="${COLORS.line}" opacity="0.12"/>`
    + `<polyline points="${path}" fill="none" stroke="${COLORS.line}" stroke-width="1.8"/>`
    + dots + peakLabel + labels + '</svg>'
  return figure(title, note, svg)
}

/** 柱状图：每日新增设备。bars = [{label, value}]。 */
function barChart({ title, note, bars, format }) {
  const list = (bars ?? []).map((bar) => ({ label: shortDay(bar.label), value: num(bar.value) }))
  if (!list.length || !list.some((bar) => bar.value > 0)) return emptyFigure(title, note)
  const { w, h, left, right, top, bottom } = CHART
  const max = Math.max(...list.map((bar) => bar.value), 1)
  const band = (w - left - right) / list.length
  const y = (value) => h - bottom - (value / max) * (h - top - bottom)
  const rects = list.map((bar, i) => {
    const bx = left + i * band + band * 0.2
    const height = Math.max(h - bottom - y(bar.value), bar.value > 0 ? 1.5 : 0)
    const tip = `<title>${escapeHtml(bar.label)}：${escapeHtml(format(bar.value))}</title>`
    return `<rect x="${bx.toFixed(1)}" y="${y(bar.value).toFixed(1)}" width="${(band * 0.6).toFixed(1)}" height="${height.toFixed(1)}" rx="1.5" fill="${COLORS.bar}">${tip}</rect>`
  }).join('')
  const labels = spread(list.length, 5)
    .map((i) => `<text x="${(left + i * band + band / 2).toFixed(1)}" y="${h - 9}" text-anchor="middle">${escapeHtml(list[i].label)}</text>`).join('')
  const svg = `<svg viewBox="0 0 ${w} ${h}" role="img" aria-label="${escapeHtml(title)}">`
    + gridLines(max, y, format) + rects + labels + '</svg>'
  return figure(title, note, svg)
}

/** 段落：`tag` 是「今日 / 最近 30 天」的彩色小标，`note` 是右侧的小字说明。 */
function section(tag, title, note, inner, cls = '') {
  const badge = `<span class="tag ${cls}">${escapeHtml(tag)}</span>`
  const hint = note ? `<span class="h2note">${escapeHtml(note)}</span>` : ''
  return `<section class="block"><h2>${badge}${escapeHtml(title)}${hint}</h2>${inner}</section>`
}

function kpis(items) {
  return `<div class="kpis">${items.map(([label, value, note]) => {
    const hint = note ? `<em>${escapeHtml(note)}</em>` : ''
    return `<div class="kpi"><span class="k">${escapeHtml(label)}</span><strong>${escapeHtml(value)}</strong>${hint}</div>`
  }).join('')}</div>`
}

function chips(items) {
  return `<div class="chips">${items.map(([label, cls = '']) =>
    `<span class="chip ${cls}">${escapeHtml(label)}</span>`).join('')}</div>`
}

/** 横向对比条：today / yesterday / 前 7 日均值。`items = [{label, value, text, color}]`。 */
function compareBars(items) {
  const max = Math.max(...items.map((item) => num(item.value)), 1)
  const rows = items.map((item) =>
    `<div class="bar"><span class="bar-k">${escapeHtml(item.label)}</span>`
    + `<span class="track"><i style="width:${((num(item.value) / max) * 100).toFixed(1)}%;background:${item.color ?? COLORS.line}"></i></span>`
    + `<span class="bar-v">${escapeHtml(item.text)}</span></div>`).join('')
  return `<div class="bars">${rows}</div>`
}

/// 清单小标题：标题 + 右侧灰色提示（手机上说明"这里只列了前几条"）。
function subheading(title, note = '') {
  const hint = note ? `<span class="h2note">${escapeHtml(note)}</span>` : ''
  return `<h3>${escapeHtml(title)}${hint}</h3>`
}

/// 涨跌幅 chip：涨用中性蓝、跌用灰——出口流量涨不等于好事，不用红绿做价值判断。
function deltaChip(label, value, base) {
  if (!base) return `<span class="chip">${escapeHtml(label)} 昨日无流量</span>`
  const diff = (num(value) - num(base)) / num(base)
  const arrow = diff > 0.0005 ? '↑' : diff < -0.0005 ? '↓' : '→'
  const cls = diff > 0.0005 ? 'up' : diff < -0.0005 ? 'down' : ''
  return `<span class="chip ${cls}">${escapeHtml(label)} ${arrow} ${(Math.abs(diff) * 100).toFixed(1)}%</span>`
}

/** columns = [{label, text(row), raw?, num?}]；cell 默认转义，raw 用于本就是 HTML 的格子。 */
function table(columns, rows, empty) {
  const head = columns.map((column) =>
    `<th class="${column.num ? 'num' : ''}">${escapeHtml(column.label)}</th>`).join('')
  const cell = (column, row) => (column.raw ? column.text(row) : escapeHtml(column.text(row)))
  const body = rows.length
    ? rows.map((row) => `<tr>${columns.map((column) =>
      `<td class="${column.num ? 'num' : ''}${column.wide ? ' name' : ''}">${cell(column, row)}</td>`).join('')}</tr>`).join('')
    : `<tr><td colspan="${columns.length}" class="empty">${escapeHtml(empty)}</td></tr>`
  return `<table><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table>`
}

/** 两行一条的清单：一行主标题 + 状态标，一行灰色细节（比七发表的手机可读性好）。 */
function rowList(rows, empty) {
  if (!rows.length) return `<p class="empty">${escapeHtml(empty)}</p>`
  const items = rows.map((row) =>
    `<li><div class="l1"><span class="t">${row.title}</span>${row.tag ?? ''}</div>`
    + `<div class="l2">${row.meta}</div></li>`).join('')
  return `<ul class="rows">${items}</ul>`
}

/** 反馈状态占比：一段堆叠条 + 图例（比环形图省一半高度，手机上更好读）。 */
function statusStack(open, replied) {
  const total = num(open) + num(replied)
  if (!total) return '<p class="empty">窗口内没有反馈线程</p>'
  const seg = [[STATUS_LABEL.open, num(open), COLORS.open], [STATUS_LABEL.replied, num(replied), COLORS.replied]]
  const bar = seg.filter(([, value]) => value > 0)
    .map(([, value, color]) => `<i style="width:${((value / total) * 100).toFixed(2)}%;background:${color}"></i>`).join('')
  const legend = seg.map(([label, value, color]) =>
    `<span class="chip"><i style="display:inline-block;width:8px;height:8px;border-radius:2px;background:${color};margin-right:4px"></i>${label} ${value}（${Math.round((value / total) * 100)}%）</span>`).join('')
  return `<div class="stack">${bar}</div><div class="chips legend">${legend}</div>`
}

/// 账号名不唯一（生产库里有好几个账号都叫「My computer」）：重名时补一段账号 id 尾号，
/// 不重名就保持干净的名字。渲染层做这件事，是因为"重不重名"取决于这一屏列了哪几行。
function accountLabeler(rows, getName = (row) => text(row.name ?? row.accountName, row.accountId)) {
  const counts = new Map()
  for (const row of rows ?? []) {
    const name = getName(row)
    counts.set(name, (counts.get(name) ?? 0) + 1)
  }
  return (row) => {
    const name = getName(row)
    if ((counts.get(name) ?? 0) < 2) return name
    return `${name} · ${String(row.accountId ?? '').slice(-6)}`
  }
}

/** 服务端漏字段时保住默认值，避免 `undefined` 渲染成表格里的空洞（只加字段、不改名）。 */
function withDefaults(value, fallback) {
  const given = Object.entries(value ?? {}).filter(([, item]) => item !== undefined)
  return { ...fallback, ...Object.fromEntries(given) }
}

export function normalize(data) {
  const source = data && typeof data === 'object' ? data : {}
  const today = source.today && typeof source.today === 'object' ? source.today : {}
  return {
    today: {
      day: num(today.day),
      dayStartAt: num(today.dayStartAt),
      usage: withDefaults(today.usage, { egressBytes: 0, connections: 0, devices: 0,
        firstSeenAt: null, lastSeenAt: null, builds: [] }),
      topAccounts: Array.isArray(today.topAccounts) ? today.topAccounts : [],
      devices: withDefaults(today.devices, { list: [], new: 0, active: 0, revoked: 0, live: 0 }),
      feedback: withDefaults(today.feedback, { new: 0, open: 0, replied: 0, threads: [] }),
      invites: withDefaults(today.invites, { used: 0, enrollments: [] }),
    },
    feedback: withDefaults(source.feedback, { new: 0, open: 0, replied: 0, medianFirstReplyHours: null, threads: [] }),
    devices: withDefaults(source.devices, { paired: 0, active7d: 0, activeWindow: 0, newInWindow: 0,
      windowDays: 0, revoked: 0, newPerDay: [], list: [] }),
    usage: withDefaults(source.usage, { perDay: [], topAccounts: [], totals: {},
      averagePerDay: 0, peakDay: null, activeDays: 0 }),
    retention: {
      scope: text(source.retention?.scope, 'external'),
      users: withDefaults(source.retention?.users, { dau: 0, wau: 0, mau: 0,
        stickiness: null, external: 0 }),
      d1: source.retention?.d1 ?? null,
      d7: source.retention?.d7 ?? null,
      activation: withDefaults(source.retention?.activation, { rate: null, cohort: 0, active: 0 }),
      weeks: Array.isArray(source.retention?.weeks) ? source.retention.weeks : [],
    },
    invites: withDefaults(source.invites, { minted: 0, used: 0, remaining: 0, enrollments: [] }),
  }
}

function sourceText(source) {
  if (!source || typeof source !== 'object') return '匿名'
  const kind = source.kind === 'device' ? text(source.deviceModel, '已配对设备') : '匿名'
  return [kind, source.appVersion].filter(Boolean).join(' · ')
}

const statusChip = (status) => `<span class="chip ${escapeHtml(status)}">${escapeHtml(STATUS_LABEL[status] ?? status)}</span>`

/// 反馈线程两行版：主题（没填就用摘要） + 状态；下行是时间、来源，未读只是灰字不做红标
/// （窗口里大多数线程本来就没被点开过，逐条标红等于没标）。
function feedbackRows(threads, limit) {
  return (threads ?? []).slice(0, limit).map((row) => ({
    title: escapeHtml(clip(text(row.subject, text(row.excerpt, '（无正文）')))),
    tag: statusChip(row.status),
    meta: escapeHtml(`${formatTime(row.createdAt)} · ${sourceText(row.source)}`
      + (num(row.ownerUnread) > 0 ? ' · 未读' : '')),
  }))
}

/// 今日设备两行版：名称 + 版本；下行是机型、连接数、时间窗（机型与名称重复就不写两遍）。
function todayDeviceRows(report) {
  const list = (report.today.devices.list ?? []).slice(0, LIMIT.todayDevices)
  const label = accountLabeler(list, (row) => text(row.accountName, row.accountId))
  return list.map((row) => {
    const name = text(row.name, row.deviceId)
    const model = text(row.model, '未知机型')
    const window = [row.firstSeenAt, row.lastSeenAt].filter(Boolean).map(clock)
    const span = window.length === 2 && window[0] !== window[1] ? `${window[0]}–${window[1]}` : window[0] ?? ''
    const bits = [text(row.accountName, '') ? label(row) : '', model === name ? '' : model,
      `连接 ${formatInt(row.connections)} 次`, span]
    return {
      title: escapeHtml(clip(name)),
      tag: row.lastBuild ? `<span class="chip">${escapeHtml(shortBuild(row.lastBuild))}</span>` : '',
      meta: escapeHtml(bits.filter(Boolean).join(' · ')),
    }
  })
}

function enrollmentRows(enrollments, limit) {
  const list = (enrollments ?? []).slice(0, limit)
  const label = accountLabeler(list, (row) => text(row.accountName, row.accountId))
  return list.map((row) => {
    const account = text(row.accountName, row.accountId)
    const agent = text(row.agentName, '未知电脑')
    return {
      title: escapeHtml(clip(label(row))),
      tag: `<span class="chip">${formatInt(row.devices)} 台</span>`,
      meta: escapeHtml([text(row.inviteNote, '（无备注）'), agent === account ? '' : agent,
        formatTime(row.usedAt)].filter(Boolean).join(' · ')),
    }
  })
}

/** 今日板块：出口流量（含对比）+ 关键计数 + 今日明细。 */
function todaySection(report, generatedAt, days) {
  const usage = report.today.usage
  const series = report.usage.perDay ?? []
  const todayEntry = report.today.day ? null : last(series)
  const egress = report.today.day ? num(usage.egressBytes) : num(todayEntry?.egressBytes)
  const connections = report.today.day ? num(usage.connections) : num(todayEntry?.connections)
  const yesterday = series.length >= 2 ? series[series.length - 2] : null
  const baseline = series.slice(-8, -1)
  const average = baseline.length
    ? baseline.reduce((sum, entry) => sum + num(entry.egressBytes), 0) / baseline.length : 0
  const devices = report.today.devices
  const feedback = report.today.feedback
  const activeWindow = [usage.firstSeenAt, usage.lastSeenAt].filter(Boolean).map(clock)
  const activeSpan = activeWindow.length === 2
    ? (activeWindow[0] === activeWindow[1] ? activeWindow[0] : `${activeWindow[0]}–${activeWindow[1]}`)
    : (activeWindow[0] ?? '—')
  const builds = (usage.builds ?? []).map((entry) => entry.build).filter(Boolean)
  const meta = [
    `连接 ${formatInt(connections)} 次`,
    `活跃设备 ${formatInt(devices.active)} 台`,
    `活跃时段 ${activeSpan}`,
    builds.length ? `在用版本 ${builds.length} 个` : '',
  ].filter(Boolean).join(' · ')

  const hero = '<section class="hero">'
    + '<span class="k">今日出口流量</span>'
    + `<span class="v">${escapeHtml(formatBytes(egress))}</span>`
    + '<div class="chips">'
    + deltaChip('较昨日', egress, yesterday?.egressBytes)
    + deltaChip('较近 7 日均值', egress, average)
    + '</div>'
    + `<p class="meta">${escapeHtml(meta)}</p>`
    + compareBars([
      { label: '今日', value: egress, text: formatBytes(egress) },
      { label: '昨日', value: num(yesterday?.egressBytes), text: formatBytes(num(yesterday?.egressBytes)), color: '#94a3b8' },
      { label: '近 7 日均值', value: average, text: formatBytes(average), color: '#94a3b8' },
    ])
    + '</section>'

  const counts = kpis([
    ['今日连接', formatInt(connections), num(yesterday?.connections) ? `昨日 ${formatInt(yesterday.connections)}` : ''],
    ['今日活跃设备', formatInt(devices.active), `在线 ${formatInt(devices.live)} 台`],
    ['今日新增设备', formatInt(devices.new), devices.revoked ? `撤销 ${formatInt(devices.revoked)}` : ''],
    ['今日新增反馈', formatInt(feedback.new), feedback.open ? `待回复 ${formatInt(feedback.open)}` : '全部已回复'],
    ['今日登记', formatInt(report.today.invites.used), `邀请码剩 ${formatInt(report.invites.remaining)}`],
    ['今日在用版本', formatInt(builds.length), builds.length ? shortBuild(builds[0]) : '无'],
  ])

  const todayAccounts = (report.today.topAccounts ?? []).slice(0, LIMIT.todayAccounts)
  const label = accountLabeler(todayAccounts)
  const accountTable = table([
    { label: '账号', text: (row) => label(row), wide: true },
    { label: '出口', text: (row) => formatBytes(row.egressBytes), num: true },
    { label: '连接', text: (row) => formatInt(row.connections), num: true },
    { label: '设备', text: (row) => formatInt(row.devices), num: true },
  ], todayAccounts, '今天还没有中转流量')

  const buildRows = (usage.builds ?? []).slice(0, LIMIT.todayBuilds)
  const buildTable = table([
    { label: '版本', text: (row) => shortBuild(row.build), wide: true },
    { label: '设备', text: (row) => formatInt(row.devices), num: true },
    { label: '账号', text: (row) => formatInt(row.accounts), num: true },
  ], buildRows, '今天还没有设备连过中转')
  const buildNote = (usage.builds ?? []).length > LIMIT.todayBuilds
    ? `按设备数前 ${LIMIT.todayBuilds} 个（共 ${formatInt(usage.builds.length)} 个）`
    : `共 ${formatInt((usage.builds ?? []).length)} 个构建`

  const detail = subheading('今日账号', `出口前 ${Math.min(LIMIT.todayAccounts, report.today.topAccounts.length)} 名`) + accountTable
    + subheading('今日版本分布', buildNote) + buildTable
    + subheading('今日设备', `出口前 ${Math.min(LIMIT.todayDevices, report.today.devices.list.length)} 台`) + rowList(todayDeviceRows(report), '今天还没有设备连过中转')
    + subheading('今日反馈', `共 ${formatInt(feedback.new)} 条`) + rowList(feedbackRows(feedback.threads, LIMIT.todayFeedback), '今天没有新反馈')
    + (report.today.invites.used
      ? subheading('今日登记', `共 ${formatInt(report.today.invites.used)} 人`) + rowList(enrollmentRows(report.today.invites.enrollments, LIMIT.todayEnrolls), '') : '')

  return section('今日', '概览', `自然日 00:00 起 · 截至 ${clock(generatedAt)}`,
    hero + counts + detail)
}

/// 百分比：服务端给的是 0..1 的比例，没有分母（None）时显示「—」。
const percent = (ratio) => (ratio === null || ratio === undefined || !Number.isFinite(Number(ratio))
  ? '—' : `${(Number(ratio) * 100).toFixed(0)}%`)

/// 留存率 + 队列人数：只给一个百分比看不出可信度，分母一起写出来。
const cohortNote = (entry) => (entry && num(entry.cohort) > 0 ? `n=${formatInt(entry.cohort)}` : '样本不足')

/** 留存板块：只算用邀请码登记的外部账号（口径与 maintainers 里的活跃/新增一致）。 */
function retentionBlock(retention) {
  const users = retention.users ?? {}
  const cards = kpis([
    ['今日活跃用户', formatInt(users.dau), `外部账号共 ${formatInt(users.external)}`],
    ['近 7 天活跃', formatInt(users.wau), `近 30 天 ${formatInt(users.mau)}`],
    ['近 30 天活跃', formatInt(users.mau), `7 日粘性 ${percent(users.stickiness)}`],
    ['次日留存', percent(retention.d1?.rate), cohortNote(retention.d1)],
    ['7 日留存', percent(retention.d7?.rate), cohortNote(retention.d7)],
    ['登记激活', percent(retention.activation?.rate), cohortNote(retention.activation)],
  ])
  const weeks = table([
    { label: '队列周', text: (row) => text(row.week) },
    { label: '新增', text: (row) => formatInt(row.size), num: true },
    { label: '次周留存', text: (row) => percent(row.rate), num: true },
  ], (retention.weeks ?? []).slice(-4), '还没有过完一整周的队列')
  return cards + weeks
}

/** 最近 N 天板块：总量与趋势 + 排名与清单。 */
function rangeSection(report, days) {
  const usage = report.usage
  const devices = report.devices
  const feedback = report.feedback
  const totals = usage.totals ?? {}
  const peak = usage.peakDay
  const cards = kpis([
    ['窗口出口', formatBytes(totals.egressBytes), `日均 ${formatBytes(usage.averagePerDay)}`],
    ['连接合计', formatInt(totals.connections), `${usage.activeDays ?? 0}/${days} 天有流量`],
    ['活跃设备', formatInt(devices.activeWindow), `已配对 ${formatInt(devices.paired)}`],
    ['新增设备', formatInt(devices.newInWindow), devices.revoked ? `累计撤销 ${formatInt(devices.revoked)}` : ''],
    ['新增反馈', formatInt(feedback.new), `待回复 ${formatInt(feedback.open)}`],
    ['邀请码', formatInt(report.invites.remaining), `${formatInt(report.invites.used)}/${formatInt(report.invites.minted)} 已用`],
  ])

  const peakNote = peak && num(peak.egressBytes) > 0
    ? `峰值 ${fullDay(peak.day)} ${formatBytes(peak.egressBytes)}` : `最近 ${days} 天`
  const charts = lineChart({
    title: '每日出口流量',
    note: peakNote,
    points: (usage.perDay ?? []).map((row) => ({ label: row.day, value: row.egressBytes })),
    format: formatBytes,
  }) + barChart({
    title: '每日新增设备',
    note: `共 ${formatInt(devices.newInWindow)} 台`,
    bars: (devices.newPerDay ?? []).map((row) => ({ label: row.day, value: row.count })),
    format: (value) => String(Math.round(value)),
  })

  const newByDay = new Map((devices.newPerDay ?? []).map((row) => [dayText(row.day), num(row.count)]))
  const recent = table([
    { label: '日期', text: (row) => fullDay(row.day) },
    { label: '出口', text: (row) => formatBytes(row.egressBytes), num: true },
    { label: '连接', text: (row) => formatInt(row.connections), num: true },
    { label: '设备', text: (row) => formatInt(row.devices), num: true },
    { label: '新增', text: (row) => formatInt(newByDay.get(dayText(row.day)) ?? 0), num: true },
  ], (usage.perDay ?? []).slice(-LIMIT.recentDays), '窗口内没有用量记录')

  const totalEgress = Math.max(num(totals.egressBytes), 1)
  const rankedAccounts = (usage.topAccounts ?? []).slice(0, LIMIT.accounts)
  const rankLabel = accountLabeler(rankedAccounts)
  const accounts = table([
    { label: '账号', text: (row) => rankLabel(row), wide: true },
    { label: '出口', text: (row) => formatBytes(row.egressBytes), num: true },
    { label: '占比', text: (row) => `${((num(row.egressBytes) / totalEgress) * 100).toFixed(1)}%`, num: true },
    { label: '连接', text: (row) => formatInt(row.connections), num: true },
  ], rankedAccounts, '窗口内没有用量记录')

  const listedDevices = (devices.list ?? []).slice(0, LIMIT.devices)
  const deviceLabel = accountLabeler(listedDevices, (row) => text(row.accountName, row.accountId))
  const deviceRows = listedDevices.map((row) => {
    const name = text(row.name, row.deviceId)
    const model = text(row.model, '未知机型')
    return {
      title: escapeHtml(clip(name)),
      tag: row.revoked ? '<span class="chip warn">已撤销</span>'
        : (row.push?.registered ? '<span class="chip replied">推送已注册</span>' : '<span class="chip open">未注册推送</span>'),
      meta: escapeHtml([text(row.accountName, '') ? deviceLabel(row) : '', model === name ? '' : model,
        shortBuild(text(row.appVersion, '未知版本')),
        `最近在线 ${shortTime(row.lastSeenAt)}`].filter(Boolean).join(' · ')),
    }
  })

  const feedbackBlock = statusStack(feedback.open, feedback.replied)
    + chips([
      [`新增 ${formatInt(feedback.new)}`],
      [`首次回复中位 ${formatHours(feedback.medianFirstReplyHours)}`],
    ])

  const inner = cards + charts
    + subheading('留存', '外部账号 · 活跃=当天有中转连接')
    + retentionBlock(report.retention)
    + subheading('最近 7 天') + recent
    + subheading('账号排名', `出口前 ${Math.min(LIMIT.accounts, rankedAccounts.length)} 名`) + accounts
    + subheading('设备', `最近在线前 ${Math.min(LIMIT.devices, devices.list.length)} 台`) + rowList(deviceRows, '窗口内没有设备')
    + subheading('反馈', `窗口内共 ${formatInt(feedback.new)} 条`
      + (num(feedback.test) > 0 ? ` · 已剔除测试提交 ${formatInt(feedback.test)} 条` : ''))
    + feedbackBlock
    + rowList(feedbackRows(feedback.threads, LIMIT.feedback), '窗口内没有反馈')
    + subheading('邀请码登记', `最近 ${Math.min(LIMIT.enrolls, report.invites.enrollments.length)} 条`)
    + rowList(enrollmentRows(report.invites.enrollments, LIMIT.enrolls), '还没有人用邀请码登记')

  return section(`最近 ${days} 天`, '趋势与明细',
    '本地日窗口（含今日）', inner, 'range')
}

/** 组装整页。`now` 只在 ops-report 没给 generatedAt 时兜底（测试用固定值）。 */
export function renderReport(data, { now = Date.now() } = {}) {
  const report = normalize(data)
  const generatedAt = num(data?.generatedAt) || now
  const days = num(data?.days) || 30
  const at = new Date(generatedAt)
  const pad = (value) => String(value).padStart(2, '0')
  const date = `${at.getFullYear()}-${pad(at.getMonth() + 1)}-${pad(at.getDate())}`
  const body = [
    todaySection(report, generatedAt, days),
    rangeSection(report, days),
  ].join('\n')
  const foot = `口径：今日为服务器本地自然日 00:00 起（截至生成时刻，白天看是部分数据）；`
    + `最近 ${days} 天为本地日窗口、含今日。流量只计中转出口字节（不含 OTA 下载与 SSH）；`
    + `调试设备（DSH- 前缀与测试台机型）已从设备、今日流量的统计里剔除。`
  return `<!DOCTYPE html>
<html lang="zh-Hans">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>DSH Mobile 运营日报 · ${escapeHtml(date)}</title>
<style>${STYLE}</style>
</head>
<body>
<div class="wrap">
<header class="page">
<h1>DSH Mobile 运营日报</h1>
<p class="sub">${escapeHtml(date)} ${escapeHtml(WEEKDAYS[at.getDay()])} · ${escapeHtml(clock(generatedAt))} 生成</p>
</header>
${body}
<p class="foot">${escapeHtml(foot)}</p>
</div>
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
