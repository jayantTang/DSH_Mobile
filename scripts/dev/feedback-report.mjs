#!/usr/bin/env node
// 把 `admin.py ops-report --days N` 的 JSON 渲染成一页自带图表的 HTML（014 运营日报）。
//
// 版面分三块，各回答一个问题（2026-10-17 owner 要求精简后重排）：
//   【关注】    今天要处理什么——只留要 owner 动作的四类：待回复反馈、激活码余量、
//               7 日留存越线、推送注册率不足。数据没问题就是一句「没有要处理的事」。
//   【今日/全天】今天有没有事——头牌是**活跃账号**（有设备用量行的账号，owner 2026-10-17 定），
//               下面四张卡：出口流量（含环比）、连接次数、新增设备、近 7 天活跃账号；
//               一行状态给出同一天的活跃设备数、在册设备数与活跃时段。
//   【最近 N 天】趋势与谁在用——每日活跃账号与每日出口流量两张折线、近 7 天表、
//               外部账号留存漏斗、账号排名、设备清单，以及反馈的**计数**（不列具体线程）。
//
// 2026-10-17 精简掉的内容（小字与重复数字太多，owner 说"搞得很混乱"）：窗口六张 KPI 卡、
// 每日新增设备柱状图、今日账号/版本/设备/反馈四张明细表、激活码登记清单、分周队列表、
// 反馈状态栈与占比 chips、留存卡片与目标/上周小字，以及 info 级的自动观察告警。
// 2026-10-19 再精简：反馈不再列线程明细，只给新增/待回复/已回复/首次回复中位四个数；
// GitHub 的 star/fork/关注者并进激活码那一排（两者都是"外部进来多少人"）。
//
// 单位只用三个词（2026-10-17 owner 对齐）：**账号** = 自然人（一次激活码兑换建立一个）；
// **主机** = 装了连接器的一台电脑（agent）；**设备** = 一次配对产生的客户端（手机/平板/网页，
// 一台设备一行）。**活跃账号**按账号算（同一账号的多台设备只算一个），与设备行数的「活跃设备」是两个
// 口径，页面底部那行写明了两者的关系。
//
// 为什么在本机画：服务器只出原始数据、不装图形依赖，改样式不必重新部署（plan.md 12）。
// 为什么手写 SVG：`package.json` 的 dependencies 是空的，不新增第三方依赖（宪法 VII.4）。
// 为什么图表的 viewBox 只有 360 宽：这份报告主要在手机上看，卡片内宽就是 330–360pt。
// 旧版按 720 宽画、再被 CSS 压到一半，12px 的轴标签实际渲染成 6px，等于看不见。
//
//   node scripts/dev/feedback-report.mjs report.json > report.html
//   node scripts/dev/feedback-report.mjs < report.json > report.html
//
// 正文一律过 escapeHtml——反馈摘要、手机名、邀请码备注都是外部可控字符串。

import { readFileSync } from 'node:fs'
import { pathToFileURL } from 'node:url'

/// 图表配色与画布尺寸：viewBox 固定，实际宽度交给 CSS（窄屏能整页缩放）。
const COLORS = { line: '#2563eb', open: '#f59e0b', replied: '#10b981',
  peak: '#dc2626', grid: '#eef2f7' }
/// 72 小时热度图用的五档色阶（浅 → 深）。分档边界是**绝对活跃账号数**：
/// 1–2 / 3–4 / 5–6 / 7–8 / 9+。见 `hourlyHeatmap` 里为什么不用相对色阶。
/// 边界按"有设备在线的账号"这个口径定的（常态每小时 1–10 个）；换成电脑连接口径
/// （峰值 26）就只剩最浅两档，图会失去分辨力。
const HEAT_STEPS = ['#dbe9ff', '#a9c7ff', '#6f9df8', '#3f79ee', '#2563eb']
const HEAT_LEGEND = ['1–2', '3–4', '5–6', '7–8', '9+']
const heatStep = (accounts) => {
  const value = num(accounts)
  if (value <= 2) return 0
  if (value <= 4) return 1
  if (value <= 6) return 2
  if (value <= 8) return 3
  return 4
}
const CHART = { w: 360, h: 168, left: 46, right: 10, top: 16, bottom: 24 }
const WEEKDAYS = ['周日', '周一', '周二', '周三', '周四', '周五', '周六']

/// 一张清单最多列几条：手机上要一屏能扫完，剩下的用「共 N 条」交代。
const LIMIT = { accounts: 6, devices: 6, recentDays: 7 }

/// 「关注」板块的报警阈值（2026-10-13 运营评审定的第一版，按周报复盘再调）。
/// 只有 warn 级要求 owner 动作；`info` 级的自动观察（背离/波动/突增/版本分裂/目标缺口）
/// 2026-10-17 全部删掉——那些数字在趋势图与表里已经有了，写进「关注」只是把一屏塞满。
const THRESHOLDS = {
  inviteLow: 10,        // 邀请码余量 ≤ 这个数提醒补铸
  d7Low: 0.2,           // 7 日留存警戒线
  d7MinCohort: 10,      // 留存样本太小不报警（百分比没意义）
  pushLow: 0.5,         // 推送注册率低于一半要提醒（「待你回应」到不了）
  pushMinDevices: 5,    // 手机太少不算率
  feedbackSlaHours: 24, // 反馈首次回复的承诺时长；超了告警升级
  alertEscalateDays: 3, // 同一条待办连续挂了几天开始写「已连续 N 天」
}

/// 经营目标（2026-10-13 owner 拍的第一版，按周报复盘调）：只在留存板块当对照线用。
const TARGETS = {
  d7: 0.3,              // 7 日留存
  activation: 0.75,     // 登记激活
}

/// 机型代码转人话：`iPhone15,4` → `iPhone 15`。只放出现过的主流型号，
/// 查不到的（新型号、非 iPhone）原样显示，宁保守不乱猜。
const IPHONE_MODELS = {
  'iPhone10,1': '8', 'iPhone10,4': '8', 'iPhone10,2': '8 Plus', 'iPhone10,5': '8 Plus',
  'iPhone10,3': 'X', 'iPhone10,6': 'X',
  'iPhone11,2': 'XS', 'iPhone11,4': 'XS Max', 'iPhone11,6': 'XS Max', 'iPhone11,8': 'XR',
  'iPhone12,1': '11', 'iPhone12,3': '11 Pro', 'iPhone12,5': '11 Pro Max',
  'iPhone12,8': 'SE 2',
  'iPhone13,1': '12 mini', 'iPhone13,2': '12', 'iPhone13,3': '12 Pro', 'iPhone13,4': '12 Pro Max',
  'iPhone14,2': '13 Pro', 'iPhone14,3': '13 Pro Max', 'iPhone14,4': '13 mini',
  'iPhone14,5': '13', 'iPhone14,6': 'SE 3',
  'iPhone14,7': '14', 'iPhone14,8': '14 Plus',
  'iPhone15,2': '14 Pro', 'iPhone15,3': '14 Pro Max',
  'iPhone15,4': '15', 'iPhone15,5': '15 Plus',
  'iPhone16,1': '15 Pro', 'iPhone16,2': '15 Pro Max',
  'iPhone17,1': '16 Pro', 'iPhone17,2': '16 Pro Max', 'iPhone17,3': '16',
  'iPhone17,4': '16 Plus', 'iPhone17,5': '16e',
  'iPhone18,1': '17 Pro', 'iPhone18,2': '17 Pro Max', 'iPhone18,3': '17', 'iPhone18,4': 'Air',
}

/** 机型代码转人话；查不到的原样返回（名字已经是人话的也原样通过）。 */
export function humanModel(raw) {
  const value = String(raw ?? '')
  const name = IPHONE_MODELS[value]
  return name ? `iPhone ${name}` : value
}

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
figure.chart { margin: 0 0 10px; padding: 10px 12px 4px; background: #fff; border-radius: 11px;
  border: 1px solid #eef1f5; }
figure.chart figcaption { display: flex; align-items: baseline; justify-content: space-between;
  gap: 8px; font-size: 12.5px; }
figure.chart .note { color: #94a3b8; font-size: 11px; text-align: right; }
figure.chart svg { display: block; width: 100%; max-width: 540px; height: auto; margin: 2px auto 0; }
svg text { font-family: "PingFang SC", Arial, sans-serif; font-size: 9.5px; fill: #94a3b8; }
svg text.peakLabel { fill: ${COLORS.peak}; font-weight: 600; }
/* 72 小时热度图的图例：色块 + 账号数区间，与 SVG 同一套五档。 */
.heat-legend { display: flex; align-items: center; flex-wrap: wrap; gap: 3px 5px;
  margin: 2px auto 6px; max-width: 540px; color: #94a3b8; font-size: 10px; }
.heat-legend span { margin-right: 2px; }
.heat-legend i { width: 12px; height: 9px; border-radius: 2px; }
.heat-legend em { margin-right: 4px; font-style: normal; color: #64748b; }
.gap8 { height: 8px; }
p.empty { margin: 0; padding: 11px 12px; border: 1px dashed #d7dde5; border-radius: 11px;
  background: #fff; color: #94a3b8; font-size: 12.5px; }
p.foot { margin: 18px 2px 0; color: #94a3b8; font-size: 11px; line-height: 1.6; }
/* 「关注」板块：warn 红边 = 要 owner 动作，info 蓝边 = 值得看一眼。 */
h2 .tag.focus { background: #7c3aed; }
ul.alerts { margin: 0; padding: 0; list-style: none; }
ul.alerts li.alert { display: flex; align-items: baseline; gap: 8px; margin-top: 6px;
  padding: 9px 11px; background: #fff; border: 1px solid #e8ecf1; border-left-width: 3px;
  border-radius: 11px; }
ul.alerts li.alert:first-child { margin-top: 0; }
ul.alerts li.alert.warn { border-left-color: ${COLORS.peak}; }
ul.alerts li.alert.info { border-left-color: ${COLORS.line}; }
ul.alerts .at { font-size: 12.5px; color: #334155; }
/* 转化漏斗：登记 → 激活 → 次日 → 7 日。各段是各自的队列率，棒长只表达率本身。 */
.funnel { margin-top: 10px; padding: 10px 12px 12px; background: #fff;
  border: 1px solid #e8ecf1; border-radius: 11px; }
.frow { display: flex; align-items: center; gap: 8px; margin-top: 7px; font-size: 12.5px; }
.frow:first-child { margin-top: 0; }
.frow .fk { flex: 0 0 74px; color: #64748b; }
.frow .track { flex: 1 1 auto; height: 8px; border-radius: 999px; background: #eff2f6; }
.frow .track i { display: block; height: 100%; border-radius: 999px; }
.frow .fv { flex: 0 0 auto; min-width: 96px; display: flex; flex-direction: column;
  align-items: flex-end; gap: 1px; text-align: right; color: #334155;
  font-variant-numeric: tabular-nums; }
@media (min-width: 600px) {
  .kpis { grid-template-columns: repeat(4, minmax(0, 1fr)); }
  .hero .v { font-size: 34px; }
}
`

/** HTML 转义。反馈摘要、手机名、备注都可能带标签或引号。 */
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

/// 时间戳夹到 `end` 之内（`end` 为 0 表示不夹）。
///
/// 覆盖的是已经过完的那一天时，中转会把跨零点的连接记在前一天的行上
/// （2026-10-11 的行里 lastSeenAt 是 10-12 00:00:13），不夹的话「活跃时段 00:01–00:00」
/// 在日报上看起来像算错了。
const clampTo = (ms, end) => {
  const value = num(ms)
  return end && value > end ? end : value
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

/** 折线图：每日出口字节（峰值点单独标出来）。points = [{label, value}]。
    markers = [{index, label}]：在指定点位画一条竖虚线 + 小字（发版日这类事件标注）。 */
function lineChart({ title, note, points, format, markers = [] }) {
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
  const marks = markers.filter((marker) => marker.index >= 0 && marker.index < list.length)
    .map((marker) => {
      const at = x(marker.index)
      const anchor = at < left + 14 ? 'start' : at > w - right - 14 ? 'end' : 'middle'
      return `<line x1="${at.toFixed(1)}" x2="${at.toFixed(1)}" y1="${top}" y2="${h - bottom}" `
        + `stroke="${COLORS.peak}" stroke-width="1" stroke-dasharray="2,3" opacity="0.55"/>`
        + `<text x="${at.toFixed(1)}" y="${top - 4}" text-anchor="${anchor}" fill="${COLORS.peak}" `
        + `font-size="8.5">${escapeHtml(marker.label)}</text>`
    }).join('')
  const svg = `<svg viewBox="0 0 ${w} ${h}" role="img" aria-label="${escapeHtml(title)}">`
    + gridLines(max, y, format)
    + `<polygon points="${left},${h - bottom} ${path} ${x(list.length - 1).toFixed(1)},${h - bottom}" fill="${COLORS.line}" opacity="0.12"/>`
    + `<polyline points="${path}" fill="none" stroke="${COLORS.line}" stroke-width="1.8"/>`
    + dots + peakLabel + labels + marks + '</svg>'
  return figure(title, note, svg)
}

/** 24 小时 × N 天的热度图：格子越深，那一小时在线的账号越多。

为什么用热度图而不是折线：72 小时如果画成一条 72 点的折线，横向会被压扁，凌晨的
低谷与工作时间的双峰全糊在一起；按「日 × 小时」摆成三行，作息形状一眼可读。

`buckets` = [{hourStartAt, accounts, agents}]（服务端从 systemd 日志重建）。
缺的那一小时画成浅灰空格，不插值——没数据与 0 个账号是两件事。
*/
function hourlyHeatmap({ title, note, buckets }) {
  if (buckets === null || buckets === undefined) {
    return emptyFigure(title, '服务端读不到中转日志，这一块跳过')
  }
  const list = (buckets ?? [])
    .map((bucket) => ({ at: num(bucket.hourStartAt), accounts: num(bucket.accounts),
      devices: num(bucket.devices) }))
    .filter((bucket) => bucket.at > 0)
    .sort((a, b) => a.at - b.at)
  if (!list.length) return emptyFigure(title, note)

  // 按本地日分行；小时取本地 0–23（report 在本机渲染，与服务器同为 Asia/Shanghai）。
  const days = []
  const grid = new Map()
  for (const bucket of list) {
    const at = new Date(bucket.at)
    const day = `${at.getFullYear()}-${String(at.getMonth() + 1).padStart(2, '0')}-${String(at.getDate()).padStart(2, '0')}`
    if (!days.includes(day)) days.push(day)
    grid.set(`${day}#${at.getHours()}`, bucket)
  }
  const max = Math.max(...list.map((bucket) => bucket.accounts), 1)
  const peak = list.reduce((best, bucket) => (bucket.accounts > best.accounts ? bucket : best), list[0])

  const width = 540
  const cell = 17
  const gap = 2.5
  const left = 34
  const top = 6
  const labelY = top + days.length * (cell + gap) + 9
  const cells = days.map((day, row) => [...Array(24).keys()].map((hour) => {
    const bucket = grid.get(`${day}#${hour}`)
    const x = left + hour * (cell + gap)
    const y = top + row * (cell + gap)
    if (!bucket) {
      return `<rect x="${x}" y="${y}" width="${cell}" height="${cell}" rx="3" fill="#f1f5f9"/>`
    }
    // 按**绝对账号数**分档，不按当前峰值做相对色阶：相对色阶下，平淡的一天也能画成
    // 满屏深蓝，看不出"今天其实比昨天闲"。分档边界与图例一致（见 figure 下的 legend）。
    const fill = HEAT_STEPS[heatStep(bucket.accounts)]
    return `<rect x="${x}" y="${y}" width="${cell}" height="${cell}" rx="3" fill="${fill}">`
      + `<title>${escapeHtml(`${day.slice(5)} ${String(hour).padStart(2, '0')}:00 · ${bucket.accounts} 个活跃账号 · ${bucket.devices} 台设备在线`)}</title></rect>`
  }).join('')).join('')
  const rowLabels = days.map((day, row) => `<text x="${left - 6}" `
    + `y="${(top + row * (cell + gap) + cell / 2 + 3.2).toFixed(1)}" text-anchor="end">`
    + `${escapeHtml(day.slice(5))}</text>`).join('')
  const hourLabels = [0, 6, 12, 18, 23].map((hour) => {
    const x = left + hour * (cell + gap) + cell / 2
    const anchor = hour === 0 ? 'start' : hour === 23 ? 'end' : 'middle'
    return `<text x="${x.toFixed(1)}" y="${labelY}" text-anchor="${anchor}">${hour}时</text>`
  }).join('')
  const peakAt = new Date(peak.at)
  const peakWhen = `${String(peakAt.getMonth() + 1).padStart(2, '0')}-${String(peakAt.getDate()).padStart(2, '0')} `
    + `${String(peakAt.getHours()).padStart(2, '0')}时`
  const peakLabel = `<text x="${left}" y="${labelY + 13}" class="peakLabel" `
    + `text-anchor="start">峰值 ${formatInt(peak.accounts)} 个账号在线 · ${escapeHtml(peakWhen)}</text>`
  const svg = `<svg viewBox="0 0 ${width} ${labelY + 20}" role="img" aria-label="${escapeHtml(title)}">`
    + rowLabels + cells + hourLabels + peakLabel + '</svg>'
  const legend = '<div class="heat-legend"><span>在线账号</span>'
    + HEAT_STEPS.map((color, index) => `<i style="background:${color}"></i>`
      + `<em>${HEAT_LEGEND[index]}</em>`).join('')
    + '</div>'
  return figure(title, note, svg + legend)
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

/// 清单小标题：标题 + 右侧灰色提示（手机上说明"这里只列了前几条"）。
function subheading(title, note = '') {
  const hint = note ? `<span class="h2note">${escapeHtml(note)}</span>` : ''
  return `<h3>${escapeHtml(title)}${hint}</h3>`
}

/// 涨跌幅 chip：涨用中性蓝、跌用灰——出口流量涨不等于好事，不用红绿做价值判断。
/// base 缺失（窗口不够长）时不渲染这枚 chip；base 为 0 时没有百分比可谈。
function deltaChip(label, value, base) {
  if (base === null || base === undefined || !Number.isFinite(Number(base))) return ''
  if (!num(base)) return `<span class="chip">${escapeHtml(label)} 前期为 0</span>`
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
/// 账号名不唯一（生产库里有几十个都叫「My computer」，那是连接器的默认名）：重名时补一段
/// 账号 id 尾号，不重名就保持干净的名字。渲染层做这件事，是因为"重不重名"取决于这一屏列了哪几行。
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
  // GitHub 计数是本机取的外部数据，没取到（老服务端 / 断网）时为 null，页面整块省略。
  const github = source.github && typeof source.github === 'object'
    && ['stars', 'forks', 'followers'].every((key) => Number.isFinite(Number(source.github[key])))
    ? {
        repo: text(source.github.repo, '仓库'),
        stars: num(source.github.stars),
        forks: num(source.github.forks),
        followers: num(source.github.followers),
        fetchedAt: num(source.github.fetchedAt),
      }
    : null
  return {
    github,
    today: {
      day: num(today.day),
      dayStartAt: num(today.dayStartAt),
      usage: withDefaults(today.usage, { egressBytes: 0, connections: 0, devices: 0, accounts: 0,
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
      averagePerDay: 0, peakDay: null, activeDays: 0, activeAccounts: 0, activeAccounts7d: 0 }),
    // 版本分布（服务端 `versions`）与过去 72 小时的活性（`hourlyActivity`）。
    // 两个字段都是 2026-10-17 新增：老服务端没有它们，页面照常渲染，只是少这两块。
    versions: Array.isArray(source.versions) ? source.versions : [],
    versionsWindowHours: num(source.versionsWindowHours) || 48,
    hourlyActivity: withDefaults(source.hourlyActivity, { windowHours: 72, buckets: null }),
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

/** 「关注」板块的报警。返回 [{key, level, text, streak}]，按重要度排序。

只留**要 owner 动作**的四类（2026-10-17 精简）：待回复反馈、激活码余量、7 日留存越线、
推送注册率不足。此前的 info 级自动观察（连接/流量背离、单日波动、新增突增、版本分裂、
周目标缺口）已删除——那些数字在趋势图与表里已经能看到，堆在最上面只会把小字弄乱。

history（.ops-history.json 的内容）提供告警的连续天数：同一条 warn 连续挂了
THRESHOLDS.alertEscalateDays 天还没处理，文案升级为「已连续 N 天未处理」。 */
function attentionItems(report, { completed = false, generatedAt = 0, history = null } = {}) {
  const items = []
  const push = (level, text_, key = '') => items.push({ level, text: text_, key })
  const dayStartAt = num(report.today.dayStartAt)

  // 待回复反馈：全窗口的开口线程（不止今天新增的），这是日报里唯一有时效的事。
  const open = num(report.feedback.open)
  if (open > 0) {
    const opened = (report.feedback.threads ?? [])
      .filter((thread) => thread.status === 'open' && num(thread.createdAt) > 0)
    const oldest = opened.length ? Math.min(...opened.map((thread) => num(thread.createdAt))) : 0
    const waitedHours = oldest && generatedAt && generatedAt > oldest
      ? (generatedAt - oldest) / 3_600_000 : 0
    const waited = waitedHours ? `，最早一条已等 ${waitedHours.toFixed(1)} h` : ''
    const sla = waitedHours > THRESHOLDS.feedbackSlaHours
      ? `，超过 ${THRESHOLDS.feedbackSlaHours}h 响应 SLA` : ''
    push('warn', `反馈待回复 ${formatInt(open)} 条${waited}${sla}`, 'feedback-open')
  }
  // 激活码余量：码发完了新用户进不来，剩 10 张以内就提醒。
  // 口径优先用 `usable`（未用且未过期）；老服务端没有这个字段时退回 `remaining`。
  const inviteLeft = num(report.invites.usable ?? report.invites.remaining)
  if (num(report.invites.minted) > 0 && inviteLeft <= THRESHOLDS.inviteLow) {
    push('warn', `激活码只剩 ${formatInt(inviteLeft)} 张`
      + `（${formatInt(report.invites.used)}/${formatInt(report.invites.minted)} 已用），该补铸一批`,
      'invites-low')
  }
  // 7 日留存越线：样本够才判。
  const d7 = report.retention.d7
  if (d7 && Number.isFinite(Number(d7.rate)) && num(d7.cohort) >= THRESHOLDS.d7MinCohort
    && Number(d7.rate) < THRESHOLDS.d7Low) {
    push('warn', `7 日留存 ${percent(d7.rate)}（n=${formatInt(d7.cohort)}）低于 `
      + `${Math.round(THRESHOLDS.d7Low * 100)}% 警戒线，该查首日体验`, 'd7-low')
  }
  // 推送注册率：没注册的设备收不到「待你回应」，直接影响活跃。分母只算**近 7 天活跃**的
  // 设备（owner 2026-10-17 定）：在册设备里躺着大量早已不用的旧行，全算进来这条告警就没有
  // 指向（2026-10-17 实测 78/89 未注册，其中多数是废弃设备）。
  const windowEnd = dayStartAt ? dayStartAt + 86_400_000 - 1 : generatedAt
  const windowStart = windowEnd - 7 * 86_400_000
  const phones = (report.devices.list ?? []).filter((row) => !row.revoked
    && num(row.lastSeenAt) >= windowStart && num(row.lastSeenAt) <= windowEnd)
  if (phones.length >= THRESHOLDS.pushMinDevices) {
    const registered = phones.filter((row) => row.push?.registered).length
    const rate = registered / phones.length
    if (rate < THRESHOLDS.pushLow) {
      push('warn', `近 7 天活跃的 ${formatInt(phones.length)} 台设备里 ${formatInt(phones.length - registered)} 台`
        + `没注册推送（${Math.round((1 - rate) * 100)}%），「待你回应」提醒到不了这些设备`, 'push-low')
    }
  }
  // 连续天数：history.alerts[key] = { lastStart, count }。与上一次覆盖日相邻则 +1，
  // 同一天重复渲染不重复计数（00:02 的定时任务一天只跑这一次）。
  for (const item of items) {
    const prev = item.key ? history?.alerts?.[item.key] : null
    const diff = prev && dayStartAt ? dayStartAt - num(prev.lastStart) : null
    item.streak = diff === 86_400_000 ? num(prev.count) + 1 : diff === 0 ? num(prev.count) : 1
    if (item.level === 'warn' && item.streak >= THRESHOLDS.alertEscalateDays) {
      item.text += `（已连续 ${formatInt(item.streak)} 天未处理）`
    }
  }
  return items
}

/** 「关注」板块：整页最上面。没有事项时给一句明确的"没事"，不留空。 */
function attentionSection(items) {
  if (!items.length) {
    return section('关注', '要处理的事', '',
      '<p class="empty">没有待回复反馈，余量与指标都在常态区间内。</p>', 'focus')
  }
  const warns = items.filter((item) => item.level === 'warn').length
  const rows = items.map((item) => {
    const badge = item.level === 'warn'
      ? '<span class="chip warn">待办</span>' : '<span class="chip up">提示</span>'
    return `<li class="alert ${item.level}">${badge}<span class="at">${escapeHtml(item.text)}</span></li>`
  }).join('')
  return section('关注', '要处理的事',
    warns ? `${warns} 件待办 · ${items.length - warns} 条提示` : `${items.length} 条提示`,
    `<ul class="alerts">${rows}</ul>`, 'focus')
}


/// 反馈只给数字（owner 2026-10-19 定）：哪几条、谁提的都不进日报，要看去 App 的反馈页。
/// 四枚 chip：窗口内新增、待回复、已回复、首次回复中位时长；没有分母的指标不显示。
function feedbackStats(feedback = {}) {
  const median = feedback.medianFirstReplyHours
  const chips = [
    `<span class="chip">窗口内新增 ${formatInt(num(feedback.new))} 条</span>`,
    `<span class="chip${num(feedback.open) > 0 ? ' open' : ''}">待回复 ${formatInt(num(feedback.open))} 条</span>`,
    `<span class="chip">已回复 ${formatInt(num(feedback.replied))} 条</span>`,
    median === null || median === undefined || !Number.isFinite(Number(median))
      ? '' : `<span class="chip">首次回复中位 ${Number(median).toFixed(1)} h</span>`,
  ].filter(Boolean).join('')
  return `<div class="chips">${chips}</div>`
}

/// 版本号的展示口径：构建号（`20261013.2233`）单独拿出来当版本名，其余（网页端 0.1.0、
/// 模拟器 1.0 1、空值）按类别写清楚——把 `0.1.0` 与 App 构建混在一列里，会让
/// 「还有多少人在旧版」这个问题没法回答。
const versionKey = (raw) => {
  const value = String(raw ?? '').trim()
  const build = value.match(/\d{8}\.\d{4}/)
  if (build) return build[0]
  if (!value) return '未知'
  if (value === '1.0 1' || value.includes('test-harness')) return '模拟器'
  return '网页端'
}

const versionKind = (key) => (key === '网页端' ? '网页端'
  : key === '模拟器' ? '模拟器' : key === '未知' ? '未知' : 'App')

/** 版本分布：只看最近 48 小时有设备连接的用户（owner 2026-10-17 定）。

为什么不再给「全量在册」：库里的设备行有一半是几周没上线的历史记录，混进来会让
「还有多少人在旧版」显得很严重；owner 要的是**现在还在用的人**装在哪个版本。
账号按 `accountId` 去重、设备按行，两者不等是常态（重装/换机会多一行）。
*/
function versionBlock(report, { limit = 6 } = {}) {
  const windowHours = num(report.versionsWindowHours) || 48
  const fleet = new Map()
  for (const row of [...(report.versions ?? [])].sort((a, b) => num(b.lastSeenAt) - num(a.lastSeenAt))) {
    const key = versionKey(row.appVersion)
    const entry = fleet.get(key) ?? { devices: 0, accounts: 0, lastSeenAt: 0 }
    entry.devices += num(row.devices)
    entry.accounts += num(row.accounts)
    entry.lastSeenAt = Math.max(entry.lastSeenAt, num(row.lastSeenAt))
    fleet.set(key, entry)
  }
  if (!fleet.size) {
    return subheading(`版本分布（近 ${windowHours} 小时活跃）`)
      + '<p class="empty">窗口内没有活跃设备</p>'
  }
  const rows = [...fleet.entries()].map(([key, entry]) => ({
    key,
    kind: versionKind(key),
    devices: entry.devices,
    accounts: entry.accounts,
    lastSeenAt: entry.lastSeenAt,
  })).sort((a, b) => (b.devices - a.devices) || (b.accounts - a.accounts)
    || a.key.localeCompare(b.key))
  const shown = rows.slice(0, limit)
  const rest = rows.slice(limit)
  if (rest.length) {
    shown.push({
      key: `其他 ${rest.length} 个版本`, kind: '合并',
      devices: rest.reduce((sum, row) => sum + row.devices, 0),
      accounts: rest.reduce((sum, row) => sum + row.accounts, 0),
      lastSeenAt: Math.max(...rest.map((row) => row.lastSeenAt)),
    })
  }
  const total = rows.reduce((sum, row) => sum + row.devices, 0)
  const body = table([
    { label: '版本', text: (row) => (row.kind === 'App' || row.kind === '合并' || row.kind === row.key
      ? row.key : `${row.key} · ${row.kind}`) },
    { label: '活跃账号', text: (row) => formatInt(row.accounts), num: true },
    { label: '活跃设备', text: (row) => formatInt(row.devices), num: true },
    { label: '设备占比', text: (row) => (total ? `${((row.devices / total) * 100).toFixed(0)}%` : '—'), num: true },
    { label: '最近在线', text: (row) => (row.lastSeenAt ? shortTime(row.lastSeenAt) : '—'), num: true },
  ], shown, '窗口内没有活跃设备')
  return subheading(`版本分布（近 ${windowHours} 小时活跃）`, '与活跃账号同口径 · 设备按行') + body
}

/** 激活码情况：还剩几张能用、哪些快到期、最近谁激活了。

为什么单列一块：激活码是这个产品唯一的获客入口，而它有三本账容易混在一起——
铸了多少（`minted`）、已经激活多少（`used`）、还剩多少**能用**的（`usable`）。
老口径的 `remaining` 把过期未用的也算了进去，光看它会高估余量。
*/
function inviteBlock(report, { generatedAt = 0, limit = 6 } = {}) {
  const invites = report.invites ?? {}
  const used = num(invites.used)
  const minted = num(invites.minted)
  const usable = num(invites.usable ?? invites.remaining)
  const expiring = num(invites.expiringSoon)
  const expired = num(invites.expiredUnused)
  const enrollments = [...(invites.enrollments ?? [])]
    .filter((row) => num(row.usedAt) > 0 && num(row.usedAt) <= num(generatedAt))
    .sort((a, b) => num(b.usedAt) - num(a.usedAt))
  const weekAgo = num(generatedAt) - 7 * 86_400_000
  const activated7d = enrollments.filter((row) => num(row.usedAt) >= weekAgo).length

  // 消耗趋势：近 14 天每日新增激活。未使用码的明细不再列——owner 2026-10-17 定：
  // 日报要回答"每天进来多少人"，而不是把还没发出去的码抄一遍。
  const trendDays = 14
  const dayCounts = new Map()
  for (const row of enrollments) {
    const day = localDayOf(row.usedAt)
    if (day) dayCounts.set(day, (dayCounts.get(day) ?? 0) + 1)
  }
  const today = localDayOf(generatedAt)
  const points = [...Array(trendDays).keys()].map((offset) => {
    const day = localDayOf(num(generatedAt) - (trendDays - 1 - offset) * 86_400_000)
    return { label: String(day), value: dayCounts.get(day) ?? 0 }
  })
  const activatedToday = dayCounts.get(today) ?? 0
  const activated30d = enrollments
    .filter((row) => num(row.usedAt) >= num(generatedAt) - 30 * 86_400_000).length
  const chips = [
    `<span class="chip">已激活 ${formatInt(used)}/${formatInt(minted)}</span>`,
    `<span class="chip${usable <= THRESHOLDS.inviteLow ? ' warn' : ''}">可用 ${formatInt(usable)} 张</span>`,
    expiring > 0 ? `<span class="chip open">7 天内到期 ${formatInt(expiring)} 张</span>` : '',
    expired > 0 ? `<span class="chip down">已过期未用 ${formatInt(expired)} 张</span>` : '',
    `<span class="chip">今日激活 ${formatInt(activatedToday)}</span>`,
    `<span class="chip">近 7 天激活 ${formatInt(activated7d)}</span>`,
    `<span class="chip">近 30 天激活 ${formatInt(activated30d)}</span>`,
    // GitHub 的三个计数并进激活码这一排（owner 2026-10-19 定）：两者都是"外部进来多少人"，
    // 单独占一行没有信息增量。取不到时就不显示，不占位。
    ...githubChips(report.github),
  ].filter(Boolean).join('')

  const recent = enrollments.slice(0, limit).map((row) => ({
    account: text(row.accountName, row.accountId),
    agent: text(row.agentName, row.agentId),
    at: row.usedAt ? shortTime(row.usedAt) : '—',
    note: text(row.inviteNote, '—'),
  }))
  const recentTable = table([
    { label: '账号', text: (row) => row.account, wide: true },
    { label: '主机', text: (row) => row.agent },
    { label: '激活时间', text: (row) => row.at, num: true },
    { label: '备注', text: (row) => row.note },
  ], recent, '还没有激活记录')
  const chart = lineChart({
    title: '每日激活',
    note: `近 ${trendDays} 天`,
    points,
    format: (value) => String(Math.round(value)),
  })

  return subheading('激活码', '激活码的账 · 只看能用的余量；GitHub 计数取生成时刻')
    + `<div class="chips">${chips}</div>`
    + (githubChips(report.github).length
      ? '<p class="meta">GitHub 的 star / fork / 关注者取生成时刻（接口无历史快照），与覆盖日无关</p>'
      : '')
    + `<div class="gap8"></div>${chart}`
    + `<div class="gap8"></div>${recentTable}`
}

/// GitHub 的三枚计数 chip（仓库 star、fork、账号关注者）。没有数据时返回空数组：
/// 外部接口取不到不该在页面上留一个「0」。
function githubChips(github) {
  const stars = num(github?.stars)
  const forks = num(github?.forks)
  const followers = num(github?.followers)
  if (!github || !Number.isFinite(stars) || !Number.isFinite(forks) || !Number.isFinite(followers)) {
    return []
  }
  return [
    `<span class="chip">${escapeHtml(text(github.repo, '仓库'))} ★ ${formatInt(stars)}</span>`,
    `<span class="chip">Fork ${formatInt(forks)}</span>`,
    `<span class="chip">账号关注者 ${formatInt(followers)}</span>`,
  ]
}

/** 时间戳 → 本地日序号（`YYYYMMDD`），与 `dayText` 的取值域一致。 */
function localDayOf(ms) {
  const at = new Date(num(ms))
  const pad = (n) => String(n).padStart(2, '0')
  return Number(`${at.getFullYear()}${pad(at.getMonth() + 1)}${pad(at.getDate())}`)
}

/** 概览板块：头牌 = 活跃账号（有设备用量行的账号），配四张计数卡与一行状态。

`completed` = 这一板块覆盖的是已经过完的一整天（00:00 跑的自动日报，`--as-of yesterday`）：
标签从「今日」改成「全天」、对比基准说「前一日」，免得 10-13 生成的页面上把 10-12 写成"今日"。

口径（owner 2026-10-17 定）：**活跃账号按账号算**——当天有设备用量行的账号数，同一账号的
多台设备只算一个。头牌旁边那行状态里给出同一天的**活跃设备**（设备行数），两者不等是常态：
同一台设备重装会多一行。每天的账号数不能用设备数代替，也不能相加求并集，故由服务端算好
（`usage.accounts` / `usage.activeAccounts` / `usage.activeAccounts7d`）。
*/
function todaySection(report, generatedAt, days, completed = false) {
  const word = completed ? '全天' : '今日'
  const previous = completed ? '前一日' : '昨日'
  const dayEnd = completed ? report.today.dayStartAt + 86_400_000 - 1 : 0
  const usage = report.today.usage
  const series = report.usage.perDay ?? []
  const todayEntry = report.today.day ? null : last(series)
  const egress = report.today.day ? num(usage.egressBytes) : num(todayEntry?.egressBytes)
  const connections = report.today.day ? num(usage.connections) : num(todayEntry?.connections)
  const activeUsers = report.today.day ? num(usage.accounts) : num(todayEntry?.accounts)
  const activePhones = report.today.day ? num(usage.devices) : num(todayEntry?.devices)
  const yesterday = series.length >= 2 ? series[series.length - 2] : null
  const baseline = series.slice(-8, -1)
  const devices = report.today.devices
  const activeWindow = [usage.firstSeenAt, usage.lastSeenAt].filter(Boolean)
    .map((ms) => clock(clampTo(ms, dayEnd)))
  // 跨度接近一整天时写「全天有连接」：「00:00–23:59」是占地方没信息的废话。
  const fullSpan = usage.firstSeenAt && usage.lastSeenAt
    && (clampTo(usage.lastSeenAt, dayEnd) - clampTo(usage.firstSeenAt, dayEnd)) >= 23.5 * 3_600_000
  const activeSpan = fullSpan ? '全天有连接'
    : activeWindow.length === 2
      ? (activeWindow[0] === activeWindow[1] ? activeWindow[0] : `${activeWindow[0]}–${activeWindow[1]}`)
      : (activeWindow[0] ?? '—')
  const meta = [
    `活跃设备 ${formatInt(activePhones)} 台`,
    `在册设备 ${formatInt(devices.live)} 台`,
    fullSpan ? '全天有连接' : `活跃时段 ${activeSpan}`,
  ].filter(Boolean).join(' · ')

  // 头牌是价值指标（活跃账号）；出口流量是成本，留在下面那张卡里。
  // 口径用「当天有中转用量记录的账号」（usage.accounts / perDay.accounts），**不用**
  // devices.active：那是"在册且 lastSeenAt 恰好落在覆盖日"——设备次日再一连，昨天的活跃数
  // 就会缩（10-13 实测从 20 缩到 12），日报的数字必须生成后不再变。
  const yesterdayActive = yesterday ? num(yesterday.accounts) : null
  // 上周同期 = 序列倒数第 8 行（同日曜日）；窗口不够长就没有这枚对照。
  const weekAgoActive = series.length >= 8 ? num(series[series.length - 8].accounts) : null
  const hero = '<section class="hero">'
    + `<span class="k">${word}活跃账号</span>`
    + `<span class="v">${escapeHtml(formatInt(activeUsers))} 个</span>`
    + '<div class="chips">'
    + deltaChip(`较${previous}`, activeUsers, yesterdayActive)
    + deltaChip('较上周同期', activeUsers, weekAgoActive)
    + '</div>'
    + `<p class="meta">${escapeHtml(meta)}</p>`
    + '</section>'

  // 出口（成本口径）只给一个环比，不判好坏：它是护栏指标。
  const egressDelta = (() => {
    const base = num(yesterday?.egressBytes)
    if (!base) return ''
    const diff = (egress - base) / base
    const arrow = diff > 0.0005 ? '↑' : diff < -0.0005 ? '↓' : '→'
    return `较${previous} ${arrow} ${(Math.abs(diff) * 100).toFixed(1)}%`
  })()
  const counts = kpis([
    [`${word}出口流量`, formatBytes(egress), egressDelta],
    [`${word}连接`, formatInt(connections), ''],
    [`${word}新增设备`, formatInt(devices.new), ''],
    ['近 7 天活跃账号', formatInt(report.usage.activeAccounts7d),
      `近 ${formatInt(days)} 天 ${formatInt(report.usage.activeAccounts)} 个`],
  ])

  return section(word, '概览', completed
    ? `${shortDay(report.today.day)} 自然日 00:00–23:59（已过完）`
    : `自然日 00:00 起 · 截至 ${clock(generatedAt)}`,
    hero + counts + versionBlock(report)
    + inviteBlock(report, { generatedAt: completed ? dayEnd : generatedAt }))
}


/// 百分比：服务端给的是 0..1 的比例，没有分母（None）时显示「—」。
const percent = (ratio) => (ratio === null || ratio === undefined || !Number.isFinite(Number(ratio))
  ? '—' : `${(Number(ratio) * 100).toFixed(0)}%`)

/// 留存率 + 队列人数：只给一个百分比看不出可信度，分母一起写出来。
const cohortNote = (entry) => (entry && num(entry.cohort) > 0 ? `n=${formatInt(entry.cohort)}` : '样本不足')

/** 留存板块：只算用激活码登记的外部账号（口径与头牌的活跃账号一致）。
    布局只有一段 登记→激活→次日→7 日 的漏斗。各段是各自的队列率（服务端按各自 cohort 算），
    棒长只表达率本身，不做"占上一段的百分之几"的连环换算——那样是把不同分母的率硬接在一起。
    2026-10-17 精简：删掉活跃量三张卡（与头牌重复）与分周队列表、以及每段右侧的目标／上周小字。 */
function retentionBlock(retention) {
  const users = retention.users ?? {}
  const funnelRow = (label, entry, { warnBelow = null } = {}) => {
    const ratio = entry?.rate
    if (ratio === null || ratio === undefined || !Number.isFinite(Number(ratio))) {
      return `<div class="frow"><span class="fk">${escapeHtml(label)}</span>`
        + '<span class="track"></span><span class="fv">样本不足</span></div>'
    }
    // 越过警戒线的段标红，与「关注」板块同一阈值。
    const low = warnBelow !== null && Number(ratio) < warnBelow
    return `<div class="frow"><span class="fk">${escapeHtml(label)}</span>`
      + `<span class="track"><i style="width:${(Number(ratio) * 100).toFixed(1)}%;`
      + `background:${low ? COLORS.peak : COLORS.line}"></i></span>`
      + `<span class="fv"><span>${percent(ratio)} · ${cohortNote(entry)}</span></span></div>`
  }
  return '<div class="funnel">'
    + '<div class="frow"><span class="fk">登记</span><span class="track">'
    + '<i style="width:100%;background:#cbd5e1"></i></span>'
    + `<span class="fv"><span>${formatInt(users.external)} 个账号</span></span></div>`
    + funnelRow('登记激活', retention.activation)
    + funnelRow('次日留存', retention.d1)
    + funnelRow('7 日留存', retention.d7, { warnBelow: THRESHOLDS.d7Low })
    + '</div>'
}

/** 最近 N 天板块：趋势图 + 近 7 天表 + 留存漏斗 + 三张清单（账号 / 设备 / 反馈）。
    `completed` 见 `renderReport`；`history`（.ops-history.json）只用来给流量图标发版日。

    2026-10-17 精简：删掉窗口六张 KPI 卡（数字与概览、表重复）、每日新增设备柱状图、
    激活码登记清单、反馈状态栈与占比 chips、以及各段右侧的"前 N 条"小字。 */
function rangeSection(report, days, completed = false, { history = null } = {}) {
  const usage = report.usage
  const devices = report.devices
  const feedback = report.feedback
  const totals = usage.totals ?? {}
  const peak = usage.peakDay

  const peakNote = peak && num(peak.egressBytes) > 0
    ? `峰值 ${fullDay(peak.day)} ${formatBytes(peak.egressBytes)}` : `最近 ${days} 天`
  const userPoints = (usage.perDay ?? []).map((row) => ({ label: row.day, value: row.accounts }))
  const egressPoints = (usage.perDay ?? []).map((row) => ({ label: row.day, value: row.egressBytes }))
  // 发版标注：历史快照里每个构建号第一次出现的那一天，在流量图上画一条竖线——
  // 「10-12 发版后流量翻倍」这类因果不用翻日历对。没有历史文件就没有标注。
  const releaseMarkers = (() => {
    if (!history?.days) return []
    const firstSeen = new Set()
    const entries = Object.values(history.days)
      .filter((entry) => entry && num(entry.dayStartAt))
      .sort((a, b) => num(a.dayStartAt) - num(b.dayStartAt))
    for (const entry of entries) {
      for (const build of entry.builds ?? []) {
        if (!firstSeen.has(build)) firstSeen.add(String(entry.day))
      }
    }
    if (!firstSeen.size) return []
    return egressPoints
      .map((point, index) => ({ index, day: dayText(point.label) }))
      .filter((marker) => marker.day && firstSeen.has(marker.day))
      .map((marker) => ({ index: marker.index, label: '发版' }))
  })()
  const charts = lineChart({
    title: '每日活跃账号',
    note: `近 7 天 ${formatInt(usage.activeAccounts7d)} 个`,
    points: userPoints,
    format: (value) => String(Math.round(value)),
  }) + lineChart({
    title: '每日出口流量',
    note: peakNote,
    points: egressPoints,
    format: formatBytes,
    markers: releaseMarkers,
  }) + hourlyHeatmap({
    title: `过去 ${num(report.hourlyActivity.windowHours) || 72} 小时活跃分布`,
    note: '按小时 · 连接口径（日志） · 越深越多',
    buckets: report.hourlyActivity.buckets,
  })

  const newByDay = new Map((devices.newPerDay ?? []).map((row) => [dayText(row.day), num(row.count)]))
  const recent = table([
    { label: '日期', text: (row) => fullDay(row.day) },
    { label: '活跃账号', text: (row) => formatInt(row.accounts), num: true },
    { label: '出口', text: (row) => formatBytes(row.egressBytes), num: true },
    { label: '连接', text: (row) => formatInt(row.connections), num: true },
    { label: '新增设备', text: (row) => formatInt(newByDay.get(dayText(row.day)) ?? 0), num: true },
  ], (usage.perDay ?? []).slice(-LIMIT.recentDays), '窗口内没有用量记录')

  const rankedAccounts = (usage.topAccounts ?? []).slice(0, LIMIT.accounts)
  const rankLabel = accountLabeler(rankedAccounts)
  const accounts = table([
    { label: '账号', text: (row) => rankLabel(row), wide: true },
    { label: '出口', text: (row) => formatBytes(row.egressBytes), num: true },
    { label: '连接', text: (row) => formatInt(row.connections), num: true },
    { label: '设备', text: (row) => formatInt(row.devices), num: true },
  ], rankedAccounts, '窗口内没有用量记录')

  const listedDevices = (devices.list ?? []).slice(0, LIMIT.devices)
  const deviceLabel = accountLabeler(listedDevices, (row) => text(row.accountName, row.accountId))
  const deviceRows = listedDevices.map((row) => {
    const name = text(row.name, row.deviceId)
    const model = humanModel(text(row.model, '未知机型'))
    return {
      title: escapeHtml(clip(name)),
      tag: row.revoked ? '<span class="chip warn">已撤销</span>'
        : (row.push?.registered ? '<span class="chip replied">推送已注册</span>' : '<span class="chip open">未注册推送</span>'),
      meta: escapeHtml([text(row.accountName, '') ? deviceLabel(row) : '', model === name ? '' : model,
        shortBuild(text(row.appVersion, '未知版本')),
        `最近在线 ${shortTime(row.lastSeenAt)}`].filter(Boolean).join(' · ')),
    }
  })

  const inner = subheading('趋势') + charts
    + subheading('近 7 天') + recent
    + subheading('外部账号留存', '激活码登记的外部账号 · 活跃=当天有设备连接') + retentionBlock(report.retention)
    + subheading('账号排名') + accounts
    + subheading('设备', `${formatInt(devices.paired)} 台在册 · 最近在线前 ${Math.min(LIMIT.devices, (devices.list ?? []).length)} 台`) + rowList(deviceRows, '窗口内没有设备')
    // 反馈只给数字（owner 2026-10-19 定）：哪几条、谁提的都不进日报，要看去 App 的反馈页。
    + subheading('反馈', '窗口内新增与回复情况 · 明细见 App 反馈页'
      + (num(feedback.test) > 0 ? ` · 已剔除测试提交 ${formatInt(feedback.test)} 条` : ''))
    + feedbackStats(feedback)

  return section(`最近 ${days} 天`, completed ? '趋势与留存' : '趋势与留存',
    completed ? `本地日窗口（含 ${shortDay(report.today.day)}）` : '本地日窗口（含今日）',
    inner, 'range')
}

/** 组装整页。`now` 只在 ops-report 没给 generatedAt 时兜底（测试用固定值）。
    `history` 是 `.ops-history.json` 的内容（{ days, alerts }），提供告警连续天数与
    流量图上的发版标注；没有这份文件时整页照常渲染，只是没有这两样。 */
export function renderReport(data, { now = Date.now(), history = null } = {}) {
  const report = normalize(data)
  const generatedAt = num(data?.generatedAt) || now
  const days = num(data?.days) || 30
  // 覆盖日：`today` 板块那一天。锚点在过去（00:00 跑的自动日报，`--as-of yesterday`）时，
  // 这一天已经过完 —— 页面的日期、周几、标题与「全天」标签都按**覆盖日**写，不按生成时刻。
  const covered = report.today.day
  const completed = Boolean(covered) && report.today.dayStartAt + 86_400_000 <= generatedAt
  const at = completed ? new Date(report.today.dayStartAt) : new Date(generatedAt)
  const pad = (value) => String(value).padStart(2, '0')
  const date = `${at.getFullYear()}-${pad(at.getMonth() + 1)}-${pad(at.getDate())}`
  const body = [
    attentionSection(attentionItems(report, { completed, generatedAt, history })),
    todaySection(report, generatedAt, days, completed),
    rangeSection(report, days, completed, { history }),
  ].join('\n')
  // 口径说明只留会让人误读数字的几条：活跃账号/活跃设备的区别、流量与调试设备的边界、
  // 72 小时图与版本分布的窗口。逐项细账不写在页面底部。
  const foot = `口径：活跃账号 = 当天有设备用量行的账号（同一账号多台设备只算一个，网页端也计入设备）；`
    + `活跃设备 = 当天的设备行数（重装/换版本会多一行，故可能大于活跃账号）。`
    + ` 出口流量只计中转出口字节（不含 OTA 下载与 SSH）；调试设备（DSH- 前缀与测试台机型）不计。`
    + ` 72 小时分布是连接口径（从日志重建，含只连着、没有流量的设备；取不到日志时该图跳过）；`
    + `版本分布与活跃账号同口径，窗口 48 小时（按用量行的 lastSeenAt 卡）。`
    + ` GitHub 的 star / fork / 关注者取自公开 API（未认证），是**生成时刻**的值（接口没有历史快照），`
    + `本机缓存 6 小时；取不到时这一行省略。`
    + ` 其余板块按覆盖日结算：覆盖日之后才配对的设备、才铸或用掉的邀请码、才激活的账号都不进这份报告。`
  const stampNote = completed
    ? `全天 · ${escapeHtml(clock(generatedAt))} 生成`
    : `${escapeHtml(clock(generatedAt))} 生成`
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
<p class="sub">${escapeHtml(date)} ${escapeHtml(WEEKDAYS[at.getDay()])} · ${stampNote}</p>
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

/** 渲染完一份「已过完一整天」的报告后，把当天的摘要并进历史（`.ops-history.json`）。
    返回新的 history 对象；不该记历史时（半天数据、老服务端没有 today.day）返回 null。
    只有 full-day 报告才记：午间的部分数据写进去会污染 WoW 对照。一天最多记一次
    （定时任务在 00:02 跑），同一天重复渲染以最后一次为准。 */
export function updateHistory(data, prevHistory = null) {
  const report = normalize(data)
  const covered = dayText(report.today.day)
  const dayStartAt = num(report.today.dayStartAt)
  const generatedAt = num(data?.generatedAt)
  if (!covered || !dayStartAt || !(dayStartAt + 86_400_000 <= generatedAt)) return null
  const items = attentionItems(report, { completed: true, generatedAt, history: prevHistory })
  const alerts = {}
  for (const item of items) {
    if (item.key) alerts[item.key] = { lastStart: dayStartAt, count: item.streak ?? 1 }
  }
  const snapshot = {
    day: num(covered),
    dayStartAt,
    // 活跃账号按账号口径（与头牌、perDay 的 accounts 一致）；devicesActive 保留设备行
    // 口径备查（老历史文件里也还有这个字段）。
    usersActive: num(report.today.usage.accounts),
    devicesActive: num(report.today.usage.devices),
    egressBytes: num(report.today.usage.egressBytes),
    connections: num(report.today.usage.connections),
    newDevices: num(report.today.devices.new),
    feedbackOpen: num(report.feedback.open),
    dau: num(report.retention.users.dau),
    wau: num(report.retention.users.wau),
    mau: num(report.retention.users.mau),
    d1: report.retention.d1?.rate ?? null,
    d7: report.retention.d7?.rate ?? null,
    activation: report.retention.activation?.rate ?? null,
    builds: (report.today.usage.builds ?? []).map((entry) => shortBuild(entry.build)).filter(Boolean),
  }
  const days = { ...(prevHistory?.days ?? {}), [covered]: snapshot }
  // 历史只留最近 90 天：WoW 用 7 天前的，发版标注的"第一次出现"也不需要更老的。
  const keys = Object.keys(days).sort()
  const trimmed = keys.length > 90
    ? Object.fromEntries(keys.slice(-90).map((key) => [key, days[key]])) : days
  return { version: 1, days: trimmed, alerts }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exit(main(process.argv.slice(2)))
}
