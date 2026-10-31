/**
 * `check:lanes` 与矩阵守卫的用例——重点是**反例**：一个只会打印绿灯的守卫等于没有
 * （003 的教训：静态检查必须自带能判红的用例）。
 */

import assert from 'node:assert/strict'
import { mkdtempSync, readFileSync, rmSync, utimesSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'

import { gate } from './check-lanes.mjs'
import { runScenario } from '../verify/lane.mjs'
import { readEvidence, runId, validateVerdict, writeEvidence } from '../verify/evidence.mjs'
import { globToRegExp, loadMatrix, matchSubjects, requiredLanes, validateLaneEntries, validateMatrix } from '../verify/matrix.mjs'

const REPO = new URL('../../', import.meta.url).pathname
const CONNECTOR_FILE = 'plugins/mobile-link/lib/link.js'
const INSTALL_FILE = 'scripts/install/install-all.sh'
const APP_FILE = 'ios/DSHMobile/DSHMobile/Features/Connection/ConnectionView.swift'

function tempDir(prefix = 'lanes-test-') {
  return mkdtempSync(join(tmpdir(), prefix))
}

/** 造一份最小可用矩阵，只动被测试的那一处。 */
function matrixWith(mutate) {
  const base = structuredClone(loadMatrix())
  mutate(base)
  return base
}

function passVerdict(lane, overrides = {}) {
  return {
    lane,
    runId: runId(new Date(), 'test'),
    scenario: 'test',
    status: 'pass',
    startedAt: new Date().toISOString(),
    finishedAt: new Date().toISOString(),
    commands: [{ argv: ['true'], exitCode: 0 }],
    isolation: { dshHome: '/tmp/x', realHomeUntouched: true, proof: 'sha256 对照' },
    ...overrides,
  }
}

test('矩阵守卫：缺格判红', () => {
  const matrix = matrixWith((m) => {
    m.matrix = m.matrix.filter((entry) => !(entry.subject === 'plugin' && entry.lane === 'l2'))
  })
  assert.ok(validateMatrix(matrix).some((issue) => issue.includes('plugin×l2') && issue.includes('缺格')))
})

test('矩阵守卫：重复格判红', () => {
  const matrix = matrixWith((m) => {
    m.matrix.push({ subject: 'plugin', lane: 'l1', value: 'required', reason: '重复一条应当判红' })
  })
  assert.ok(validateMatrix(matrix).some((issue) => issue.includes('plugin×l1') && issue.includes('重复')))
})

test('矩阵守卫：取值越界与理由过短判红', () => {
  const matrix = matrixWith((m) => {
    const entry = m.matrix.find((item) => item.subject === 'relay-go' && item.lane === 'l2')
    entry.value = 'maybe'
    entry.reason = '短'
  })
  const issues = validateMatrix(matrix)
  assert.ok(issues.some((issue) => issue.includes('value 必须是')))
  assert.ok(issues.some((issue) => issue.includes('reason 太短')))
})

test('矩阵守卫：globs 为空的被测对象判红（那一行永远不会被触发）', () => {
  const matrix = matrixWith((m) => {
    m.subjects.find((subject) => subject.id === 'e2e').globs = []
  })
  assert.ok(validateMatrix(matrix).some((issue) => issue.includes('e2e') && issue.includes('globs')))
})

test('入口漂移守卫：矩阵写的 npm 脚本不存在时判红', () => {
  const matrix = matrixWith((m) => {
    m.lanes.l1.entry = 'npm run lane:nope'
  })
  const issues = validateLaneEntries(matrix, { 'lane:l1': 'x', 'lane:l2': 'x' })
  assert.ok(issues.some((issue) => issue.includes('lane:nope')))
  assert.deepEqual(validateLaneEntries(loadMatrix(), { 'lane:l1': 'x', 'lane:l2': 'x' }), [])
})

test('glob：** 跨目录、* 不跨段', () => {
  assert.ok(globToRegExp('plugins/**').test('plugins/mobile-link/lib/link.js'))
  assert.ok(globToRegExp('plugins/**').test('plugins/mobile-link/package.json'))
  assert.ok(!globToRegExp('plugins/*').test('plugins/mobile-link/lib/link.js'))
  assert.ok(globToRegExp('docs/ONBOARDING.md').test('docs/ONBOARDING.md'))
})

test('改动 → 被测对象：多命中取并集', () => {
  const matrix = loadMatrix()
  assert.deepEqual(matchSubjects(matrix, ['plugins/mobile-link/lib/index.js']).sort(), ['host-desktop', 'plugin'])
  assert.deepEqual(matchSubjects(matrix, [CONNECTOR_FILE]), ['plugin'])
})

test('改动 → 必跑集合：连接器只要 L1，宿主 web 要 L1+L2，安装路径没有自动渠道', () => {
  const matrix = loadMatrix()
  assert.deepEqual(requiredLanes(matrix, [CONNECTOR_FILE]).required, ['l1'])
  assert.deepEqual(requiredLanes(matrix, [INSTALL_FILE]).required, [])
  assert.deepEqual(requiredLanes(matrix, [APP_FILE]).required, ['l1'])
  assert.deepEqual(requiredLanes(matrix, ['docs/PRIVACY.md']).required, [])
  // host-web 的 L2 必须绑定具体场景：同渠道其它场景的证据不能顶账。
  const hostWeb = requiredLanes(matrix, ['plugins/mobile-link/lib/dsh-client.js'])
  assert.deepEqual(hostWeb.required, ['l1', 'l2'])
  assert.deepEqual(hostWeb.scenarios, {
    l1: ['plugin-install-hot', 'smoke', 'fresh-install'],
    l2: ['plugin-install-hot'],
  })
})

test('矩阵守卫：scenarios 必须是非空字符串数组', () => {
  const matrix = matrixWith((m) => {
    m.matrix.find((entry) => entry.subject === 'host-web' && entry.lane === 'l2').scenarios = []
  })
  assert.ok(validateMatrix(matrix).some((issue) => issue.includes('scenarios')))
})

test('证据包：blocked 缺 reason/nextStep 判不合法；realHomeUntouched 缺 proof 判不合法', () => {
  const blocked = passVerdict('l1', { status: 'blocked' })
  assert.ok(validateVerdict(blocked).some((issue) => issue.includes('blockedReason')))
  const noProof = passVerdict('l1', { isolation: { dshHome: '/tmp/x', realHomeUntouched: true } })
  assert.ok(validateVerdict(noProof).some((issue) => issue.includes('proof')))
  assert.deepEqual(validateVerdict(passVerdict('l1')), [])
})

test('拦截：缺证据 → 退出码 1；补齐新鲜证据 → 0', () => {
  const root = tempDir()
  try {
    const first = gate({ changed: [CONNECTOR_FILE], evidenceRoot: root })
    assert.equal(first.exitCode, 1)
    assert.deepEqual(first.missing, ['l1'])

    writeEvidence({ root, verdict: passVerdict('l1', { scenario: 'plugin-install-hot' }) })
    const second = gate({ changed: [CONNECTOR_FILE], evidenceRoot: root })
    assert.equal(second.exitCode, 0)
    assert.deepEqual(second.satisfied, ['l1'])
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('拦截：证据场景不匹配时不顶账（host-web×l2 只认 plugin-install-hot）', () => {
  const root = tempDir()
  const hostWebFile = 'plugins/mobile-link/lib/dsh-client.js'
  try {
    writeEvidence({ root, verdict: passVerdict('l1', { scenario: 'smoke' }) })
    writeEvidence({ root, verdict: passVerdict('l2', { scenario: 'mail-tests' }) })
    const wrong = gate({ changed: [hostWebFile], evidenceRoot: root })
    assert.equal(wrong.exitCode, 1)
    assert.deepEqual(wrong.missing, ['l2'])

    writeEvidence({ root, verdict: passVerdict('l2', { scenario: 'plugin-install-hot' }) })
    const right = gate({ changed: [hostWebFile], evidenceRoot: root })
    assert.equal(right.exitCode, 0)
    assert.deepEqual(right.satisfied, ['l1', 'l2'])
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('拦截：比改动旧的证据算缺（不许拿旧结论顶账）', () => {
  const root = tempDir()
  const newer = join(tempDir(), 'changed.js')
  try {
    writeEvidence({ root, verdict: passVerdict('l1', { scenario: 'plugin-install-hot' }) })
    const old = new Date(Date.now() - 60_000)
    for (const entry of readEvidence(root)) utimesSync(entry.path, old, old)
    writeFileSync(newer, 'x')
    const result = gate({ changed: [CONNECTOR_FILE, newer], evidenceRoot: root })
    assert.equal(result.toolError, undefined)
    // 被改文件的 mtime 是现在，旧证据算缺
    assert.deepEqual(result.missing, ['l1'])
    assert.ok(result.stale.l1.includes('比改动旧'))
  } finally {
    rmSync(root, { recursive: true, force: true })
    rmSync(join(newer, '..'), { recursive: true, force: true })
  }
})

test('拦截：blocked 证据不算通过，且要带下一步', () => {
  const root = tempDir()
  try {
    writeEvidence({ root, verdict: passVerdict('l1', { status: 'blocked', scenario: 'plugin-install-hot', blockedReason: '没装 colima', nextStep: 'brew install colima' }) })
    const result = gate({ changed: [CONNECTOR_FILE], evidenceRoot: root })
    assert.equal(result.exitCode, 1)
    assert.ok(result.missing.includes('l1'))
    assert.equal(result.blocked[0].reason, '没装 colima')
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('拦截：矩阵坏掉按工具错误退出 2', () => {
  const dir = tempDir()
  const matrixPath = join(dir, 'lanes.json')
  try {
    const broken = matrixWith((m) => {
      m.matrix = m.matrix.filter((entry) => !(entry.subject === 'relay-go' && entry.lane === 'l2'))
    })
    writeFileSync(matrixPath, JSON.stringify(broken, null, 2))
    const result = gate({ changed: [CONNECTOR_FILE], matrixPath })
    assert.equal(result.exitCode, 2)
    assert.ok(result.toolError.some((issue) => issue.includes('relay-go×l2')))
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
})

test('渠道入口：没有的场景写 blocked（不是静默跳过）', async () => {
  const root = tempDir()
  try {
    const registry = { l1: { title: '假渠道', doctor: () => ({ available: true, checks: [] }), scenarios: {} } }
    const verdict = await runScenario({ registry, laneId: 'l1', scenario: 'nope', evidenceRoot: root, log: () => {} })
    assert.equal(verdict.status, 'blocked')
    assert.ok(verdict.blockedReason.includes('没有场景'))
    assert.ok(readEvidence(root).length === 1)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('渠道入口：自检不过时先 blocked，不执行场景', async () => {
  const root = tempDir()
  let ran = false
  try {
    const registry = {
      l1: {
        title: '假渠道',
        doctor: () => ({ available: false, checks: [], blockedReason: '缺工具', nextStep: '装它' }),
        scenarios: { smoke: { run: () => { ran = true; return { status: 'pass' } } } },
      },
    }
    const verdict = await runScenario({ registry, laneId: 'l1', scenario: 'smoke', evidenceRoot: root, log: () => {} })
    assert.equal(verdict.status, 'blocked')
    assert.equal(ran, false)
    assert.equal(verdict.nextStep, '装它')
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('渠道入口：正常场景写出四态证据且能读回', async () => {
  const root = tempDir()
  try {
    const registry = {
      l1: {
        title: '假渠道',
        doctor: () => ({ available: true, checks: [] }),
        scenarios: {
          smoke: {
            run: () => ({
              status: 'pass',
              observations: [{ step: 'x', fact: 'y' }],
              commands: [{ argv: ['echo', 'ok'], exitCode: 0 }],
              isolation: { dshHome: '/tmp/x', realHomeUntouched: true, proof: 'sha256 对照' },
            }),
          },
        },
      },
    }
    const verdict = await runScenario({ registry, laneId: 'l1', scenario: 'smoke', evidenceRoot: root, log: () => {} })
    assert.equal(verdict.status, 'pass')
    const read = readEvidence(root)
    assert.equal(read.length, 1)
    assert.deepEqual(read[0].issues, [])
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('CI 模式：L1/L2 由作业覆盖', () => {
  const root = tempDir()
  try {
    const ci = gate({ changed: [CONNECTOR_FILE], evidenceRoot: root, ci: true })
    assert.deepEqual(ci.required, ['l1'])
    assert.deepEqual(ci.covered, ['l1'])
    assert.equal(ci.exitCode, 0)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('缺证据时带出那一级的 doctor 原因（T031）', () => {
  const root = tempDir()
  try {
    const registry = {
      l2: {
        title: '假渠道',
        doctor: () => ({ available: false, checks: [], blockedReason: '没装 colima', nextStep: 'brew install colima' }),
        scenarios: {},
      },
    }
    const result = gate({ changed: ['plugins/mobile-link/lib/dsh-client.js'], evidenceRoot: root, registry })
    assert.equal(result.exitCode, 1)
    assert.deepEqual(result.missing, ['l1', 'l2'])
    assert.equal(result.hints.l2.blockedReason, '没装 colima')
    assert.ok(result.hints.l2.nextStep.includes('colima'))
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('矩阵自己能被加载且合法（真实仓库这一份）', () => {
  const matrix = loadMatrix()
  assert.deepEqual(validateMatrix(matrix), [])
  const pkg = JSON.parse(readFileSync(`${REPO}package.json`, 'utf8'))
  assert.deepEqual(validateLaneEntries(matrix, pkg.scripts), [])
  // 所有 required 格必须绑定具体场景，否则 evidence 又会退化成"同渠道任意 pass 都算"。
  for (const entry of matrix.matrix.filter((item) => item.value === 'required')) {
    assert.ok(Array.isArray(entry.scenarios) && entry.scenarios.length > 0,
      `${entry.subject}×${entry.lane} required 未绑定 scenarios`)
  }
})
