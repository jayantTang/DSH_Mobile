/**
 * 三级渠道的自检（doctor）。
 *
 * 只报告，不修改环境：不装软件、不拉镜像、不启动 VM。`available=false` 时必须给出
 * `blockedReason` 与 `nextStep`——"跑不起来"与"结论失败"必须能被分开读出来。
 */

/** @param {Record<string, {title: string, doctor: Function}>} registry */
export function runDoctor(registry, { env = process.env } = {}) {
  const lanes = Object.entries(registry).map(([id, lane]) => {
    let report
    try {
      report = lane.doctor({ env })
    } catch (error) {
      report = {
        available: false,
        checks: [{ name: 'doctor 自身', ok: false, detail: error.message, fix: '修这个脚本或它依赖的环境' }],
        blockedReason: `doctor 抛错：${error.message}`,
        nextStep: '先修 doctor 自身，再谈这一级能不能用',
      }
    }
    return { id, title: lane.title, optional: lane.optional === true, ...report }
  })
  // 可选渠道（l3 手动清单）不可用不算整体失败；否则 `lane:doctor` 会因为没装 VM 长期红，
  // 把"手动清单"误读成"必跑门禁坏了"。
  return { ok: lanes.every((lane) => lane.available || lane.optional), lanes }
}

/** 文本表格（人看）；JSON 由调用方决定。 */
export function formatDoctor(report) {
  const lines = []
  for (const lane of report.lanes) {
    const status = lane.available ? '可用  ' : lane.optional ? '可选  ' : '阻塞  '
    lines.push(`${status} ${lane.id} ${lane.title}`)
    for (const check of lane.checks) {
      lines.push(`        ${check.ok ? 'ok  ' : 'FAIL'} ${check.name} — ${check.detail}`)
      if (!check.ok && check.fix) lines.push(`             → ${check.fix}`)
    }
  }
  return lines.join('\n')
}
