/**
 * 本机连接器刷新保护的用例：用临时 home 与临时连接器目录跑 prepare/verify，
 * 不碰真实 `~/.dsh`。
 */

import assert from 'node:assert/strict'
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { spawnSync } from 'node:child_process'
import test from 'node:test'

const SCRIPT = new URL('./refresh-connector.mjs', import.meta.url).pathname

function makeFixture() {
  const root = mkdtempSync(join(tmpdir(), 'refresh-connector-test-'))
  const home = join(root, 'home')
  const connector = join(root, 'connector')
  mkdirSync(join(home, 'mobile-link'), { recursive: true })
  mkdirSync(join(connector, 'lib'), { recursive: true })
  writeFileSync(join(home, 'mobile-link', 'agent.json'),
    `${JSON.stringify({ agentId: 'agt_test', agentSecret: 'as_test' })}\n`)
  writeFileSync(join(home, 'mobile-link', 'link-events.jsonl'),
    `${JSON.stringify({ at: new Date(Date.now() - 60_000).toISOString(), kind: 'link.open', agentId: 'agt_test' })}\n`)
  writeFileSync(join(connector, 'lib', 'a.js'), 'old\n')
  writeFileSync(join(connector, 'package.json'), '{"name":"x","version":"0.0.1"}\n')
  return {
    root,
    home,
    connector,
    journal: join(home, 'mobile-link', 'link-events.jsonl'),
    identity: join(home, 'mobile-link', 'agent.json'),
    cleanup() { rmSync(root, { recursive: true, force: true }) },
  }
}

function run(args) {
  return spawnSync(process.execPath, [SCRIPT, ...args], { encoding: 'utf8' })
}

function prepare(fixture) {
  const result = run(['prepare', '--home', fixture.home, '--connector', fixture.connector])
  assert.equal(result.status, 0, result.stderr + result.stdout)
}

function append(fixture, entry) {
  writeFileSync(fixture.journal, `${JSON.stringify(entry)}\n`, { flag: 'a' })
}

test('刷新后出现新的 link.open 即判定成功', () => {
  const fixture = makeFixture()
  try {
    prepare(fixture)
    writeFileSync(join(fixture.connector, 'lib', 'a.js'), 'new\n')
    append(fixture, {
      at: new Date(Date.now() + 50).toISOString(),
      kind: 'link.open',
      agentId: 'agt_test',
    })
    const result = run(['verify', '--home', fixture.home, '--connector', fixture.connector,
      '--timeout', '5', '--settle', '0'])
    assert.equal(result.status, 0, result.stderr + result.stdout)
    assert.match(result.stdout, /刷新成功/)
    assert.equal(readFileSync(join(fixture.connector, 'lib', 'a.js'), 'utf8'), 'new\n')
  } finally {
    fixture.cleanup()
  }
})

test('链路未恢复时自动把快照放回去', () => {
  const fixture = makeFixture()
  try {
    prepare(fixture)
    writeFileSync(join(fixture.connector, 'lib', 'a.js'), 'new\n')
    const result = run(['verify', '--home', fixture.home, '--connector', fixture.connector,
      '--timeout', '1', '--settle', '0'])
    assert.equal(result.status, 3, result.stderr + result.stdout)
    assert.match(result.stderr, /自动回滚/)
    assert.equal(readFileSync(join(fixture.connector, 'lib', 'a.js'), 'utf8'), 'old\n')
  } finally {
    fixture.cleanup()
  }
})

test('身份文件变化时停止，不自动回滚源码', () => {
  const fixture = makeFixture()
  try {
    prepare(fixture)
    writeFileSync(join(fixture.connector, 'lib', 'a.js'), 'new\n')
    writeFileSync(fixture.identity, '{"agentId":"agt_other","agentSecret":"as_other"}\n')
    const result = run(['verify', '--home', fixture.home, '--connector', fixture.connector,
      '--timeout', '1'])
    assert.equal(result.status, 3, result.stderr + result.stdout)
    assert.match(result.stderr, /身份文件/)
    assert.equal(readFileSync(join(fixture.connector, 'lib', 'a.js'), 'utf8'), 'new\n')
  } finally {
    fixture.cleanup()
  }
})

test('链路本来就不健康时拒绝拍快照', () => {
  const fixture = makeFixture()
  try {
    append(fixture, { at: new Date().toISOString(), kind: 'link.close', reason: 'test' })
    const result = run(['prepare', '--home', fixture.home, '--connector', fixture.connector])
    assert.equal(result.status, 2, result.stderr + result.stdout)
    assert.match(result.stderr, /不在健康状态/)
  } finally {
    fixture.cleanup()
  }
})
