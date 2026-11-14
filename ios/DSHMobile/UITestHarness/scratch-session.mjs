// Stable lifecycle for temporary host sessions used by device and simulator tests.
//
// A test may create a session only in its own scratch directory; cleanup deletes
// every session whose cwd is that directory (both raw and canonical spelling) and
// removes the workspace registration the app made for it. Reused by the UI runner
// and the physical performance driver.

import { readdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

/// Signs in to the host the way the app does, for calls outside the app.
export async function hostSession(live) {
  const exchange = await fetch(`http://127.0.0.1:${live.port}/?token=${live.token}`, { redirect: 'manual' })
  const cookie = (exchange.headers.getSetCookie?.() ?? [])[0]?.split(';')[0]
  const call = async (method, args) => {
    const response = await fetch(`http://127.0.0.1:${live.port}/api/${method}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', cookie },
      body: JSON.stringify({ type: 'client-request', rpcId: `run${Date.now()}`,
                             method, payload: { args } }),
    })
    const body = await response.json()
    if (!body.result?.ok) throw new Error(`${method}: ${JSON.stringify(body.result?.error)}`)
    return body.result.value
  }
  return { call }
}

export async function createScratchSession(live, directory) {
  const { call } = await hostSession(live)
  const created = await call('session/create', { request: { cwd: directory, agentPreset: 'standard' } })
  return created?.sessionId ?? null
}

export async function cleanupScratch(live, directory, sessionIds = []) {
  const canonical = canonicalPath(directory)
  const wanted = new Set([directory, canonical])
  const ids = new Set(sessionIds)
  let call = null
  try {
    call = (await hostSession(live)).call
    const list = await call('session/list', { _request: {} })
    for (const item of list.items ?? []) {
      if (wanted.has(item.cwd ?? '')) ids.add(item.sessionId)
    }
  } catch (error) {
    // The host can die between the test and cleanup. Do not leave a session
    // behind: remove the known ids on disk and take back the registration below.
    console.error(`    host 不可用，改用文件清理：${error.message}`)
  }

  const projcache = join(homedir(), '.dsh', 'storages', 'session_projcache', 'sessions')
  for (const id of ids) {
    if (call) {
      await call('workspace/archiveSession', { request: { sessionId: id, archived: false } }).catch(() => {})
    }
    for (const dir of readdirSync(join(homedir(), '.dsh', 'sessions'))) {
      rmSync(join(homedir(), '.dsh', 'sessions', dir, id), { recursive: true, force: true })
    }
    rmSync(join(projcache, `${id}.json`), { force: true })
  }
  console.log(`    清理了 ${ids.size} 个临时会话`)
  if (call) {
    await deleteWorkspacesAt(call, canonical)
  } else {
    removeWorkspacesAt(wanted)
  }
}

function removeWorkspacesAt(paths) {
  const file = join(homedir(), '.dsh', 'storages', 'workspace.json')
  try {
    const doc = JSON.parse(readFileSync(file, 'utf8'))
    const table = doc.tables?.workspaces ?? {}
    let removed = 0
    for (const [id, record] of Object.entries(table)) {
      if (paths.has(record.path)) {
        delete table[id]
        removed += 1
      }
    }
    if (removed) {
      writeFileSync(file, JSON.stringify(doc, null, 2))
      console.log(`    清理了 ${removed} 个临时工作区登记（离线）`)
    }
  } catch (error) {
    console.error(`    离线清理工作区失败：${error.message}`)
  }
}

async function deleteWorkspacesAt(call, path) {
  let deleted = 0
  for (const id of workspacesAt(path)) {
    await call('workspace/delete', { request: { workspaceId: id } })
      .then(() => { deleted += 1 })
      .catch(() => {})
  }
  if (deleted) console.log(`    清理了 ${deleted} 个临时工作区登记`)
}

function workspacesAt(path) {
  const file = join(homedir(), '.dsh', 'storages', 'workspace.json')
  try {
    const doc = JSON.parse(readFileSync(file, 'utf8'))
    return Object.entries(doc.tables?.workspaces ?? {})
      .filter(([, record]) => record.path === path)
      .map(([id]) => id)
  } catch {
    return []
  }
}

function canonicalPath(path) {
  try { return realpathSync(path) } catch { return path }
}
