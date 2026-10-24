/**
 * L1 同机隔离渠道：同一台 Mac、同一份二进制，靠临时 `HOME`/`DSH_HOME` 把
 * 会话、凭据、配对设备全部隔开。
 *
 * 为什么需要它：有些结论在本机"已经装好、已有身份"的状态下永远验不准
 * （例如"新装一个插件要不要重启宿主"），而用虚拟机验又太贵。临时 HOME 拿到的是
 * 同一份二进制，保真度高于容器。
 *
 * 纪律（宪法 III）：只**读**真实 `~/.dsh` 当作档案模板，绝不写；跑完要能证明
 * 真实数据没被动过（hash + mtime 对照），这条证明写进证据包的 `isolation.proof`。
 *
 * 层次：本文件只放渠道定义与自检；隔离运行时在 `l1-runtime.mjs`，场景在 `l1-scenarios.mjs`。
 */

import { existsSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import { realDshHome, whichBinary } from './l1-runtime.mjs'
import {
  desktopInstance, freshInstall, iosLinkCarrierLifecycle, linkDiagnostics, mailTests,
  pluginInstallHot, relayGoTests, relayTests, smoke,
} from './l1-scenarios.mjs'

export const lane = {
  id: 'l1',
  title: '同机隔离',
  isolation: '同一台 Mac、同一份二进制与代码；临时 HOME/DSH_HOME + 一次性档案',
  requiresCopyIn: false,
  doctor: doctorL1,
  scenarios: {
    smoke: { title: '隔离宿主能起来、连接器加载并发现宿主', run: smoke },
    'relay-tests': {
      title: '中转单测（含真 Caddy 的端到端那半）在本机跑一遍，且不动真实数据',
      run: relayTests,
    },
    'relay-go-tests': {
      title: 'Go 中转单测（make test）在本机跑一遍，且不动真实数据',
      run: relayGoTests,
    },
    'mail-tests': {
      title: '信件服务单测（含真 Caddy 的切换演练）在本机跑一遍，且不动真实数据',
      run: mailTests,
    },
    'plugin-install-hot': { title: '新装一个插件是否需要重启宿主', run: pluginInstallHot },
    'desktop-instance': { title: '官方桌面版能否在隔离 HOME 下起第二个实例', run: desktopInstance },
    'fresh-install': { title: '空 DSH_HOME 下从零起得来（新用户第一次跑 dsh web）', run: freshInstall },
    'ios-link-carrier-lifecycle': {
      title: 'iOS 协议层：relay socket 断开/替换必须 cancel（单测 + 仿真器经中转用例）',
      run: iosLinkCarrierLifecycle,
    },
    'link-diagnostics': {
      title: '三侧诊断：隔离宿主里真的写出有界、词表内的生命周期流水（spec 020）',
      run: linkDiagnostics,
    },
  },
}

/** 自检：只查"现在能不能跑"，不装东西、不改环境。 */
export function doctorL1({ env = process.env } = {}) {
  const checks = []
  const dsh = whichBinary('dsh')
  checks.push({
    name: 'dsh 可执行',
    ok: Boolean(dsh),
    detail: dsh ?? 'PATH 上找不到 dsh',
    fix: dsh ? undefined : '装 DSH（`npm i -g @deepseek-ai/dsh`）或把它放进 PATH',
  })
  const realProfile = join(realDshHome(env), 'profiles', 'web')
  checks.push({
    name: '真实 web 档案可读（只当模板）',
    ok: existsSync(realProfile),
    detail: realProfile,
    fix: existsSync(realProfile) ? undefined : '先跑一次 `dsh web`，让它初始化档案',
  })
  const nodeMajor = Number(process.versions.node.split('.')[0])
  checks.push({
    name: 'Node ≥ 22',
    ok: nodeMajor >= 22,
    detail: process.versions.node,
    fix: nodeMajor >= 22 ? undefined : '用 Node 22 以上跑这个工具',
  })
  let tempOk = false
  let tempDetail = tmpdir()
  try {
    const probe = mkdtempSync(join(tmpdir(), 'lane-l1-doctor-'))
    writeFileSync(join(probe, 'probe'), 'ok')
    rmSync(probe, { recursive: true, force: true })
    tempOk = true
  } catch (error) {
    tempDetail = `${tmpdir()}: ${error.message}`
  }
  checks.push({
    name: '临时目录可写',
    ok: tempOk,
    detail: tempDetail,
    fix: tempOk ? undefined : '清一下临时目录或换个 TMPDIR',
  })
  const failed = checks.filter((check) => !check.ok)
  return {
    available: failed.length === 0,
    checks,
    blockedReason: failed.length > 0 ? failed.map((check) => check.name).join('、') : undefined,
    nextStep: failed.length > 0 ? failed.map((check) => check.fix).filter(Boolean).join('；') : undefined,
  }
}
