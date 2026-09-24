#!/usr/bin/env node
/**
 * 把「自建/公司网关 + 多 key 轮换代理」接到本机 DSH 上。
 *
 * 这套东西是**本机个人的模型接入**，与 DSH Mobile 这个产品无关：
 * 它只改本机 ~/.dsh 下的配置与一个 LaunchAgent，仓库里没有任何产品路径依赖它
 * （所以它住在 sidecars/ 而不是 plugins/——plugins/ 是随产品安装的 DSH 插件）。
 *
 *   node scripts/dev/llm-router-setup.mjs keys <文件>     导入上游 key（一行一把）
 *   node scripts/dev/llm-router-setup.mjs wire            写凭据 + 建 pi-ai route（需代理在跑）
 *   node scripts/dev/llm-router-setup.mjs agent install   装 LaunchAgent（开机自起、掉线自拉）
 *   node scripts/dev/llm-router-setup.mjs agent uninstall 卸载
 *   node scripts/dev/llm-router-setup.mjs status          代理状态 + host 的模型分组
 *
 * 为什么要脚本而不是手抄：route 的模型清单要从上游 `/v1/models` 抓、思考档位要按
 * 上游实际支持的写法映射，手抄一次就会漏；而且这几步的顺序（先起代理 → 再写 route）
 * 错了，手机上会看到一条"不可用的提供方"。
 *
 * key 正文只在本机文件与内存之间流转：这个脚本从不打印它。
 */
import { execFileSync } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, writeFileSync, chmodSync, unlinkSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..')
const ROUTER_DIR = join(ROOT, 'sidecars', 'llm-key-router')
const ROUTER_HOME = join(homedir(), '.dsh', 'llm-key-router')
const CONFIG = join(ROUTER_HOME, 'config.json')
const AGENT_LABEL = 'com.jayanttang.dsh-llm-key-router'
const AGENT_PATH = join(homedir(), 'Library', 'LaunchAgents', `${AGENT_LABEL}.plist`)
const PROVIDER = 'company-gateway'

/** 上游思考档位 → 线上拼写。实测这个网关认 none/low/medium/high/max（别的模型忽略 none 也安全）。 */
const EFFORTS = { off: 'none', low: 'low', medium: 'medium', high: 'high', max: 'max' }

const [command, argument] = process.argv.slice(2)

if (command === 'keys') {
  if (!argument) fail('用法: llm-router-setup.mjs keys <装着 key 的文件>')
  const out = run(['node', join(ROUTER_DIR, 'bin', 'llm-key-router.mjs'), 'import', resolve(argument)])
  process.stdout.write(out)
  verifyKeys()
} else if (command === 'wire') {
  await wire()
} else if (command === 'agent') {
  if (argument === 'install') installAgent()
  else if (argument === 'uninstall') uninstallAgent()
  else fail('用法: llm-router-setup.mjs agent install|uninstall')
} else if (command === 'status') {
  await status()
} else {
  console.log(readFileSync(fileURLToPath(import.meta.url), 'utf8')
    .split('\n').filter((line) => line.startsWith(' *') || line.startsWith('/**')).join('\n'))
}

/// 导入之后立刻验一遍：一批 key 里可能混着上游已停用的（403），早发现比晚发现好。
function verifyKeys() {
  const keys = readFileSync(join(ROUTER_HOME, 'keys.txt'), 'utf8').split('\n').filter(Boolean)
  const config = JSON.parse(readFileSync(CONFIG, 'utf8'))
  let alive = 0
  const dead = []
  for (const key of keys) {
    const result = execFileSync('curl', [
      '-s', '-o', '/dev/null', '-w', '%{http_code}', '--max-time', '15',
      '-H', `Authorization: Bearer ${key}`,
      `${config.upstream}/v1/models`,
    ], { encoding: 'utf8' }).trim()
    if (result === '200') alive += 1
    else dead.push(`${key.slice(0, 8)}… (HTTP ${result})`)
  }
  console.log(`key 体检：${alive}/${keys.length} 可用${dead.length ? `，不可用 ${dead.join('、')}` : ''}`)
}

async function wire() {
  const config = JSON.parse(readFileSync(CONFIG, 'utf8'))
  const token = config.token
  const headers = { authorization: `Bearer ${token}` }
  let models
  try {
    const response = await fetch(`http://127.0.0.1:${config.port}/v1/models`, { headers })
    if (!response.ok) throw new Error(`HTTP ${response.status}`)
    models = (await response.json()).data.map((model) => ({
      id: model.id,
      name: model.name ?? model.id,
      reasoningEfforts: EFFORTS,
    }))
  } catch (error) {
    fail(`读不到代理的模型清单（${error.message}）——先把代理跑起来：`
      + `node sidecars/llm-key-router/bin/llm-key-router.mjs start`)
  }

  const host = await hostRPC()
  const credential = await host.call('credentials/set', { ref: 'LLM_ROUTER_TOKEN', value: token })
  if (!credential.ok) fail(`写凭据失败：${JSON.stringify(credential.error)}`)

  const patch = {
    providers: {
      [PROVIDER]: {
        displayName: '公司网关',
        api: 'openai-completions',
        baseURL: `http://127.0.0.1:${config.port}/v1`,
        apiKeyEnv: 'LLM_ROUTER_TOKEN',
        compat: { thinkingFormat: 'deepseek' },
        models,
      },
    },
  }
  const applied = await host.call('settings/update', { ns: 'llm-pi-ai', patch })
  if (!applied.ok) fail(`写 route 失败：${JSON.stringify(applied.error)}`)
  console.log(`凭据 LLM_ROUTER_TOKEN 已写入；route「公司网关」已建（${models.length} 个模型，`
    + `思考档位 ${Object.keys(EFFORTS).join('/')}）`)
  console.log('手机端：打开任一会话的「模型」选择器即可看到「公司网关」这一组；'
    + '多把 key 的轮换对手机不可见。')
}

function installAgent() {
  mkdirSync(dirname(AGENT_PATH), { recursive: true })
  const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${AGENT_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${process.execPath}</string>
    <string>${join(ROUTER_DIR, 'bin', 'llm-key-router.mjs')}</string>
    <string>start</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${join(ROUTER_HOME, 'router.log')}</string>
  <key>StandardErrorPath</key><string>${join(ROUTER_HOME, 'router.err.log')}</string>
</dict>
</plist>
`
  writeFileSync(AGENT_PATH, plist, { mode: 0o644 })
  chmodSync(AGENT_PATH, 0o644)
  const uid = process.getuid()
  // 先 bootout 再 bootstrap：第一次装的时候 bootout 会因为"没这个服务"回非零，属正常。
  try {
    execFileSync('launchctl', ['bootout', `gui/${uid}/${AGENT_LABEL}`], { stdio: 'ignore' })
  } catch { /* 还没装过 */ }
  execFileSync('launchctl', ['bootstrap', `gui/${uid}`, AGENT_PATH])
  console.log(`已装 LaunchAgent ${AGENT_LABEL}（开机自起、退出自动拉起；日志在 ${ROUTER_HOME}/router.log）`)
}

function uninstallAgent() {
  const uid = process.getuid()
  try { execFileSync('launchctl', ['bootout', `gui/${uid}/${AGENT_LABEL}`], { stdio: 'ignore' }) } catch { /* 没装过 */ }
  if (existsSync(AGENT_PATH)) unlinkSync(AGENT_PATH)
  console.log('已卸载 LaunchAgent')
}

async function status() {
  const config = JSON.parse(readFileSync(CONFIG, 'utf8'))
  try {
    const response = await fetch(`http://127.0.0.1:${config.port}/stats`, {
      headers: { authorization: `Bearer ${config.token}` },
    })
    const stats = await response.json()
    console.log(`代理 127.0.0.1:${config.port}：${stats.pool.size} 把 key（${stats.pool.healthy} 可用）`)
    console.log(`  会话粘性：${stats.affinity.sessions} 个会话，命中 ${stats.affinity.hits}，`
      + `新分配 ${stats.affinity.assigned}，迁移 ${stats.affinity.migrated}`)
    console.log(`  请求：${stats.requests}（重试 ${stats.retries}，换线路 ${stats.failovers}）`
      + `，缓存命中 ${stats.cacheHits} 次 / 缓存 token ${stats.cachedTokens}`)
    for (const key of stats.pool.keys.filter((item) => item.state !== 'healthy')) {
      console.log(`  key ${key.label} ${key.state}：${key.lastError ?? ''}`)
    }
  } catch (error) {
    console.log(`代理没在跑：${error.message}`)
  }
  const host = await hostRPC()
  const catalog = await host.call('session/modelCatalog', {})
  if (catalog.ok) {
    for (const group of catalog.value.groups ?? []) {
      console.log(`  分组 ${group.id}：${group.models.length} 个模型`)
    }
  }
}

/// 本机 DSH 的客户端会话（与探针脚本同一套：endpoint.json → 换 cookie → /api/<method>）。
async function hostRPC() {
  const endpoint = JSON.parse(readFileSync(join(homedir(), '.dsh', 'desktop-shell', 'endpoint.json'), 'utf8'))
  const token = /token=([^&]+)/.exec(endpoint.url)?.[1]
  const port = endpoint.port ?? 54499
  const exchange = await fetch(`http://127.0.0.1:${port}/?token=${token}`, { redirect: 'manual' })
  const cookie = (exchange.headers.getSetCookie?.()[0] ?? exchange.headers.get('set-cookie')).split(';')[0]
  let seq = 0
  return {
    async call(method, args) {
      const response = await fetch(`http://127.0.0.1:${port}/api/${method}`, {
        method: 'POST',
        headers: { 'content-type': 'application/json', cookie },
        body: JSON.stringify({ type: 'client-request', rpcId: `setup${++seq}`, method, payload: { args } }),
      })
      const body = await response.json()
      return body.result ?? { ok: false, error: { message: 'no result' } }
    },
  }
}

function run(args) {
  return execFileSync(args[0], args.slice(1), { encoding: 'utf8' })
}

function fail(message) {
  console.error(message)
  process.exit(1)
}
