#!/usr/bin/env node
// 中转设备清单与清扫：调试配对留下的 `DSH-*` 设备，不该堆在用户的设备列表里。
//
// 为什么不是「记得手动撤销」：配对码是一次性的，谁 claim 谁才知道 device id，
// 所以只有跑它的那一方能撤销自己。历史上每次仿真器运行都在中转上留一行
// `DSH-Test`（见 test/tools/relaypair.mjs 的文件头），用户最后要自己去手机上删。
// 这里把「清扫」做成一条命令，并挂进跑用例的前置步骤：谁留下谁负责，留不下就没人要清。
//
// 撤销要凭一个同属该 agent 的设备 token，所以本脚本先配一个一次性的 `DSH-Sweep`，
// 用完（无论成败）在 finally 里把它自己也撤掉——清扫器本身不许变成新的垃圾。
//
// 用法:
//   node scripts/dev/relay-devices.mjs list            # 列这台电脑的 agent 下的设备
//   node scripts/dev/relay-devices.mjs sweep           # 撤销所有 `DSH-*` 设备
//   node scripts/dev/relay-devices.mjs sweep --dry-run # 只说会撤哪些
//
// 判定「调试设备」的口径是**设备名以 `DSH-` 开头**：真实手机的名字是 iPhone 之类，
// 而仿真器/探针/用例都按 dsh 侧的名字登记（DSH-Test / DSH-Probe / DSH-ListCheck …）。
// 真实设备因此不会被误撤。

import { pairDevice, listDevices, revokeDevice, identity } from '../../test/tools/relaypair.mjs'

const SWEEP_NAME = 'DSH-Sweep'
const DEBUG_NAME = /^DSH-/
const USAGE = '用法: node scripts/dev/relay-devices.mjs list | sweep [--dry-run]'

/// 一次「借一个临时设备身份 → 办事 → 把它自己撤掉」的会话。
async function withSweeper(work) {
  const relayUrl = identity().relayUrl
  const sweeper = await pairDevice({ deviceName: SWEEP_NAME, deviceModel: 'simulator', appVersion: 'test-harness' })
  try {
    return await work({ relayUrl, deviceToken: sweeper.deviceToken, deviceId: sweeper.deviceId })
  } finally {
    // 撤不掉也要喊出来：这正是「用户得自己清」的老问题。
    await revokeDevice({ relayUrl, deviceToken: sweeper.deviceToken, deviceId: sweeper.deviceId })
      .then(() => console.log(`清扫器 ${sweeper.deviceId} 已自行撤销`))
      .catch((error) => console.error(`警告: 清扫器 ${sweeper.deviceId} 没能撤销：${error.message}`))
  }
}

function stamp(ms) {
  return ms ? new Date(ms).toISOString().replace('T', ' ').slice(0, 16) : '-'
}

function describe(device) {
  return `${device.deviceId}  ${device.name}  ${device.model}  ${device.appVersion}`
    + `  建于 ${stamp(device.createdAt)}  最后在线 ${stamp(device.lastSeenAt)}`
}

/// 该被清扫的设备：名字是调试名，且还没被撤销。
export function isStaleDebugDevice(device) {
  return !device.revokedAt && DEBUG_NAME.test(device.name ?? '')
}

async function main() {
  const [command, ...flags] = process.argv.slice(2)
  if (command === 'list') {
    await withSweeper(async ({ relayUrl, deviceToken }) => {
      const { devices = [] } = await listDevices({ relayUrl, deviceToken })
      const live = devices.filter((device) => !device.revokedAt)
      console.log(`${live.length} 台在用（含临时清扫器 ${SWEEP_NAME}）：`)
      for (const device of live) console.log(`  ${describe(device)}`)
    })
    return
  }

  if (command === 'sweep') {
    const dryRun = flags.includes('--dry-run')
    await withSweeper(async ({ relayUrl, deviceToken, deviceId }) => {
      const { devices = [] } = await listDevices({ relayUrl, deviceToken })
      const stale = devices.filter((device) => device.deviceId !== deviceId && isStaleDebugDevice(device))
      if (stale.length === 0) {
        console.log('没有遗留的调试设备')
        return
      }
      for (const device of stale) {
        if (dryRun) {
          console.log(`会撤销  ${describe(device)}`)
          continue
        }
        await revokeDevice({ relayUrl, deviceToken, deviceId: device.deviceId })
        console.log(`已撤销  ${describe(device)}`)
      }
      if (dryRun) console.log(`（--dry-run：以上 ${stale.length} 台没有真的撤销）`)
      else console.log(`共撤销 ${stale.length} 台调试设备`)
    })
    return
  }

  console.error(USAGE)
  process.exit(2)
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((error) => {
    console.error(`失败: ${error.message}`)
    process.exit(1)
  })
}
