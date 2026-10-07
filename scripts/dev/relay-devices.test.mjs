// 清扫白名单：`DSH-Test` 是 owner 常驻的仿真器设备，sweep 不许碰它。
//
// 为什么单独立一个文件测：这段判定决定"下次跑用例前会不会把用户的常驻设备撤了"，
// 而它又是纯函数——没有理由只能靠真的连中转去验证。

import { test } from 'node:test'
import assert from 'node:assert/strict'

import { isStaleDebugDevice, keptNames } from './relay-devices.mjs'

const device = (name, { revokedAt = null, deviceId = 'dev_x' } = {}) =>
  ({ deviceId, name, model: 'simulator', appVersion: 'test-harness', revokedAt })

test('DSH-Test is exempt from the sweep', () => {
  assert.equal(isStaleDebugDevice(device('DSH-Test')), false)
})

test('every other DSH-* device is still swept', () => {
  // 豁免必须**精确到名字**。前缀式放宽会让 `DSH-Test-2` 这类一次性的名字
  // 一起活下来，那正是这条例外不该长成的样子。
  for (const name of ['DSH-Probe', 'DSH-Sweep', 'DSH-ListCheck', 'DSH-Test-2',
                      'DSH-TestProbe', 'DSH-test', 'DSH-Test ']) {
    assert.equal(isStaleDebugDevice(device(name)), true, `${name} 该被撤`)
  }
})

test('real phones are never swept, whatever else is in the list', () => {
  // 真实手机不是调试设备，与豁免名单无关。
  for (const name of ['iPhone', 'Jayant 的 iPhone', 'iPad Pro', '', null, undefined]) {
    assert.equal(isStaleDebugDevice(device(name)), false, `${name} 不该被撤`)
  }
})

test('an already-revoked device is not swept again', () => {
  // 否则每次 sweep 都会对同一行重复调 revoke。
  assert.equal(isStaleDebugDevice(device('DSH-Probe', { revokedAt: 1 })), false)
  assert.equal(isStaleDebugDevice(device('DSH-Test', { revokedAt: 1 })), false)
})

test('the exemption is a set membership test, not a prefix test', () => {
  // 直接钉住实现形态：换成 `name.startsWith(...)` 之类的写法必须红。
  const keep = keptNames()
  assert.ok(keep.has('DSH-Test'))
  assert.ok(!keep.has('DSH-Test-2'))
  assert.ok(!keep.has('DSH-TestProbe'))
})

test('DSH_SWEEP_KEEP adds names to the exemption, exactly', () => {
  const before = process.env.DSH_SWEEP_KEEP
  process.env.DSH_SWEEP_KEEP = 'DSH-Probe, DSH-Extra'
  try {
    assert.equal(isStaleDebugDevice(device('DSH-Probe')), false)
    assert.equal(isStaleDebugDevice(device('DSH-Extra')), false)
    // …and only exactly.
    assert.equal(isStaleDebugDevice(device('DSH-Extra-2')), true)
    assert.equal(isStaleDebugDevice(device('DSH-ExtraProbe')), true)
    // The built-in exemption is not replaced by the variable.
    assert.equal(isStaleDebugDevice(device('DSH-Test')), false)
  } finally {
    if (before === undefined) delete process.env.DSH_SWEEP_KEEP
    else process.env.DSH_SWEEP_KEEP = before
  }
})

test('an explicit keep set overrides the environment', () => {
  // `isStaleDebugDevice` 的第二个参数是给调用方（以及测试）显式指定名单用的。
  assert.equal(isStaleDebugDevice(device('DSH-Test'), new Set()), true)
  assert.equal(isStaleDebugDevice(device('DSH-Probe'), new Set(['DSH-Probe'])), false)
})
