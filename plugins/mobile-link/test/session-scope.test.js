import assert from 'node:assert/strict'
import test from 'node:test'

import { createSessionScope } from '../lib/session-scope.js'

/** 宿主 `Session.header` 的最小形状；`origin` 只有子会话才有。 */
function session(id, { origin, parentSession } = {}) {
  return {
    id,
    header: { id, ...(origin === undefined ? {} : { origin }), ...(parentSession === undefined ? {} : { parentSession }) },
  }
}

function services({ sessions, workspaces }) {
  return {
    sessions: {
      get: (id) => sessions.find((entry) => entry.header.id === id),
      list: () => sessions,
    },
    workspaces: {
      archivedSessionIds: workspaces.archived ?? [],
      list: () => workspaces.items ?? [],
    },
  }
}

test('工作区里的普通会话是正式会话', () => {
  const scope = createSessionScope(services({
    sessions: [session('s1')],
    workspaces: { items: [{ sessionIds: ['s1'] }] },
  }))
  assert.equal(scope.isFormal('s1'), true)
})

test('未分组会话不是正式会话', () => {
  const scope = createSessionScope(services({
    sessions: [session('loose')],
    workspaces: { items: [{ sessionIds: ['s1'] }] },
  }))
  assert.equal(scope.isFormal('loose'), false)
})

test('子会话不是正式会话，即使它的 id 被工作区记账', () => {
  const scope = createSessionScope(services({
    sessions: [session('child', { origin: 'subagent', parentSession: 's1' })],
    workspaces: { items: [{ sessionIds: ['s1', 'child'] }] },
  }))
  assert.equal(scope.isFormal('child'), false)
})

test('已归档会话不是正式会话，归档后仍可能保留工作区记账', () => {
  const scope = createSessionScope(services({
    sessions: [session('archived')],
    workspaces: { items: [{ sessionIds: ['archived'] }], archived: ['archived'] },
  }))
  assert.equal(scope.isFormal('archived'), false)
})

test('读不到的会话不当作正式会话', () => {
  const scope = createSessionScope(services({ sessions: [], workspaces: { items: [{ sessionIds: ['s1'] }] } }))
  assert.equal(scope.isFormal('missing'), false)
  assert.equal(scope.isFormal(''), false)
})

test('宿主服务未绑上时维持旧行为（全报）', () => {
  assert.equal(createSessionScope().isFormal('s1'), true)
  assert.equal(createSessionScope({ sessions: { list: () => [] } }).isFormal('s1'), true)
})

test('只给 list 也能判定（宿主不提供 get 时）', () => {
  const scope = createSessionScope({
    sessions: { list: () => [session('s1')] },
    workspaces: { list: () => [{ sessionIds: ['s1'] }], archivedSessionIds: [] },
  })
  assert.equal(scope.isFormal('s1'), true)
})

test('归档账本读失败时不吞掉正式会话的提醒', () => {
  const scope = createSessionScope({
    sessions: { get: () => session('s1') },
    workspaces: {
      get archivedSessionIds() { throw new Error('registry not ready') },
      list: () => [{ sessionIds: ['s1'] }],
    },
  })
  assert.equal(scope.isFormal('s1'), true)
})

test('工作区账本读失败时也无法判定，维持旧行为', () => {
  const scope = createSessionScope({
    sessions: { get: () => session('s1') },
    workspaces: {
      archivedSessionIds: [],
      list: () => { throw new Error('registry not ready') },
    },
  })
  assert.equal(scope.isFormal('s1'), true)
})
