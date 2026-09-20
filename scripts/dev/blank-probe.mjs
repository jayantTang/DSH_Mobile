#!/usr/bin/env node
// 「打字时跳白」的复现台。
//
// 不走 XCUITest：流式输出期间 App 一直在更新，XCUITest 查元素等不到静止就会超时，
// 把整轮跑废（2026-09-20 实测）。这里改成：
//
//   simctl 直接启动 App（带探针与打字驱动的启动参数）
//     → 从电脑侧发一条会长时间流式的提示词（App 只是这个会话的观察者）
//     → 探针在 App 内记录"可见带有没有被已渲染的行盖住"，异常时存整屏图
//     → 外部同时录像
//
// 用法：
//   node scripts/dev/blank-probe.mjs --session <id> [--seconds 120] [--typing 90]
//                                    [--sim <udid>] [--no-video] [--out /tmp/blank-1]
//
// 跑完把 App 容器里的 probe.log / probe-*.png 拷到 --out；配对设备在 finally 里撤销。

import { execFileSync } from 'node:child_process'
import { mkdirSync, readFileSync, rmSync, writeFileSync, copyFileSync, readdirSync, existsSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { pairDevice, revokeDevice, claimedRelayLink } from '../../test/tools/relaypair.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))
const ROOT = resolve(HERE, '../..')
const BUNDLE = 'com.jayanttang.dsh'
const APP = join(ROOT, 'ios/DSHMobile/.build/sim/Build/Products/Debug-iphonesimulator/DSHMobile.app')
const ENDPOINT = join(homedir(), '.dsh', 'desktop-shell', 'endpoint.json')

const argv = process.argv.slice(2)
const flag = (name, fallback = null) => {
  const at = argv.indexOf(`--${name}`)
  return at >= 0 && at + 1 < argv.length ? argv[at + 1] : fallback
}
const has = (name) => argv.includes(`--${name}`)

const sessionId = flag('session')
if (!sessionId) throw new Error('--session <会话 id> 必填')
const seconds = Number(flag('seconds', 150))
const typingSeconds = flag('typing', null) === null ? 0 : Number(flag('typing'))
const sim = flag('sim', '8715BBC7-9925-4F74-97CE-B87DB1A94502')
const out = resolve(flag('out', '/tmp/blank-probe'))
const prompt = flag('prompt', '请从 1 数到 60，每个数字单独占一行，每行后面加一句十个字左右的解释；不要调用任何工具，也不要搜索。')
const typingText = flag('text', '这是一段用来把输入框撑高的文字看看打字的时候会话会不会跳白')
const oscillate = has('oscillate')
const variants = flag('variants', '')
const noPrompt = has('no-prompt')

mkdirSync(out, { recursive: true })
const run = (cmd, args, options = {}) => execFileSync(cmd, args, { encoding: 'utf8', ...options })

/// 电脑侧发一条提示词：App 是这个会话的观察者，流式内容照常流进它的转写。
async function sendPrompt() {
  const raw = JSON.parse(readFileSync(ENDPOINT, 'utf8'))
  const token = /token=([^&]+)/.exec(raw.url)?.[1]
  const exchange = await fetch(`http://127.0.0.1:${raw.port}/?token=${token}`, { redirect: 'manual' })
  const cookie = (exchange.headers.getSetCookie?.() ?? [])[0]?.split(';')[0]
  const response = await fetch(`http://127.0.0.1:${raw.port}/api/session/prompt`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', cookie },
    body: JSON.stringify({
      type: 'client-request', rpcId: `blank-${Date.now()}`, method: 'session/prompt',
      payload: { args: { request: {
        requestId: `blank-${Date.now()}`, sessionId, mode: 'queue',
        clientTimeZone: 'Asia/Shanghai', content: [{ type: 'text', text: prompt }],
      } } },
    }),
  })
  const body = await response.json()
  if (body.error) throw new Error(`发提示词失败：${JSON.stringify(body.error).slice(0, 200)}`)
  return body.result?.value ?? body.result
}

function containerPath() {
  return run('xcrun', ['simctl', 'get_app_container', sim, BUNDLE, 'data']).trim()
}

function pullProbeFiles() {
  const container = containerPath()
  const documents = join(container, 'Documents')
  const wanted = existsSync(documents) ? readdirSync(documents).filter((n) => /^probe/.test(n)) : []
  const names = []
  for (const name of wanted) {
    copyFileSync(join(documents, name), join(out, name))
    names.push(name)
  }
  return { container, names }
}

const pairing = await pairDevice({ deviceName: 'DSH-BlankProbe', deviceModel: 'simulator' })
let recording = null
try {
  console.log(`>>> 配对设备 ${pairing.deviceId}`)
  if (!existsSync(APP)) throw new Error(`没有构建产物 ${APP}；先 xcodebuild -scheme DSHMobile ... build`)
  // 与测试台一致的外观：深色模式会让"墨迹"这类像素判据失去意义。
  try { run('xcrun', ['simctl', 'ui', sim, 'appearance', 'light'], { stdio: 'pipe' }) } catch { /* 老系统没有这条 */ }
  run('xcrun', ['simctl', 'install', sim, APP], { stdio: 'pipe' })
  // 没在跑的时候 terminate 会非零退出，那不是错误。
  try { run('xcrun', ['simctl', 'terminate', sim, BUNDLE], { stdio: 'pipe' }) } catch { /* 本来就没跑 */ }
  // 清掉上一轮探针产物，免得新日志和旧的混在一起
  const container = containerPath()
  for (const dir of ['Documents', 'tmp', '']) {
    const target = dir ? join(container, dir) : container
    if (!existsSync(target)) continue
    for (const name of readdirSync(target)) {
      if (/^probe/.test(name)) rmSync(join(target, name))
    }
  }

  // 录像要在**启动之前**开始：空白就出现在"键盘弹出"那一刻，而那时 App 才起来十来秒。
  if (!has('no-video')) {
    const video = join(out, 'screen.mp4')
    rmSync(video, { force: true })
    const child = execFileSync('bash', ['-c',
      `xcrun simctl io ${sim} recordVideo --codec h264 --force ${video} >/dev/null 2>&1 & echo $!`],
      { encoding: 'utf8' }).trim()
    recording = { child, video }
    console.log(`>>> 开始录像（pid ${child}）→ ${video}`)
  }

  const args = ['simctl', 'launch', sim, BUNDLE,
                '-DSHConnectURL', claimedRelayLink(pairing),
                '-DSHOpenSession', sessionId,
                '-DSHViewportProbe']
  if (typingSeconds > 0) {
    const flags = [oscillate ? 'oscillate' : '', noPrompt ? 'now' : '',
                   has('kbcycles') ? 'kbcycles' : ''].filter(Boolean).join('+')
    args.push('-DSHTypingProbe', `${typingText}@${typingSeconds}${flags ? `@${flags}` : ''}`)
  }
  if (variants) args.push('-DSHProbeVariants', variants)
  console.log(`>>> 启动 App（探针${typingSeconds > 0 ? ' + 打字驱动' : ''}）`)
  console.log(`    ${run('xcrun', args).trim()}`)

  // 等 App 连上中转、把会话打开
  await new Promise((done) => setTimeout(done, 8000))

  if (!noPrompt) {
    console.log('>>> 发一条会长流式的提示词')
    await sendPrompt()
  } else {
    console.log('>>> 不发提示词（对照组：只有键盘与打字，没有流式内容）')
  }
  writeFileSync(join(out, 'meta.json'), JSON.stringify({
    sessionId, sim, seconds, typingSeconds, oscillate, variants, noPrompt, prompt, typingText,
    deviceId: pairing.deviceId,
    at: new Date().toISOString(),
  }, null, 2))

  console.log(`>>> 观察 ${seconds} 秒`)
  await new Promise((done) => setTimeout(done, seconds * 1000))
} finally {
  if (recording) {
    try { execFileSync('kill', ['-INT', recording.child]) } catch { /* 可能已经退出 */ }
    await new Promise((done) => setTimeout(done, 2500))
  }
  try {
    const { names } = pullProbeFiles()
    console.log(`>>> 探针产物 ${names.length} 个 → ${out}`)
    for (const name of names) console.log(`    ${name}`)
  } catch (error) {
    console.error(`! 取探针产物失败：${error.message}`)
  }
  try {
    await revokeDevice(pairing)
    console.log(`>>> 已撤销配对设备 ${pairing.deviceId}`)
  } catch (error) {
    console.error(`! 撤销失败：${error.message}`)
  }
}
