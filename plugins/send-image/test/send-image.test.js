import { test } from 'node:test'
import assert from 'node:assert/strict'
import { apply, buildArgs, inject, name, renderResult, resolveSource, scriptPath } from '../lib/index.js'

/** A tool definition as the host would receive it. */
function register() {
  let tool = null
  apply({ tools: { register: (definition) => { tool = definition } } })
  assert.ok(tool, 'apply() registered nothing')
  return tool
}

test('exports a Cordis plugin shape', () => {
  assert.equal(name, 'tool-send-image')
  assert.deepEqual(inject, ['tools'])
})

test('registers the send_image tool with every documented parameter', () => {
  const tool = register()
  assert.equal(tool.name, 'send_image')
  assert.equal(tool.parameters.type, 'object')
  assert.deepEqual(Object.keys(tool.parameters.properties).sort(), ['caption', 'clipboard', 'file', 'screenshot'])
  assert.equal(typeof tool.execute, 'function')
  // The description is what the model reads; an empty one makes the tool
  // undiscoverable even though it is registered.
  assert.ok(tool.description.length > 30)
})

test('declares an output schema, which the registry refuses to load without', () => {
  // Boot fails hard on a tool with no `output`, and a failed boot takes the
  // whole harness down — the desktop app then cannot start at all.
  const tool = register()
  assert.equal(tool.output.schema.type, 'object')
  assert.deepEqual(tool.output.schema.required, ['ok'])
  assert.deepEqual(
    Object.keys(tool.output.schema.properties).sort(),
    ['detail', 'error', 'ok', 'sessionId'],
  )
  assert.equal(typeof tool.output.render, 'function')
})

test('render turns a result into model-facing text parts', () => {
  const tool = register()
  assert.deepEqual(tool.output.render({}, { ok: true, sessionId: 's', detail: '已发送 3.4 KB' }), [
    { type: 'text', text: '已发送 3.4 KB' },
  ])
  assert.deepEqual(tool.output.render({}, { ok: false, error: '需要 file、screenshot 或 clipboard 之一' }), [
    { type: 'text', text: '发送失败：需要 file、screenshot 或 clipboard 之一' },
  ])
  // A bare success still has to say something: an empty part reads as no result.
  assert.equal(renderResult({ ok: true }), '图片已发送。')
  assert.equal(renderResult({ ok: false }), '发送失败：未知原因')
})

test('resolveSource accepts exactly one source', () => {
  assert.deepEqual(resolveSource({ file: '/tmp/a.png' }), { ok: true, source: 'file' })
  assert.deepEqual(resolveSource({ screenshot: true }), { ok: true, source: 'screenshot' })
  assert.deepEqual(resolveSource({ clipboard: true }), { ok: true, source: 'clipboard' })
})

test('resolveSource refuses none', () => {
  const result = resolveSource({})
  assert.equal(result.ok, false)
  assert.match(result.error, /file.*screenshot.*clipboard/)
})

test('resolveSource refuses more than one', () => {
  // Silently picking one would send something the caller did not ask for.
  const result = resolveSource({ file: '/tmp/a.png', screenshot: true })
  assert.equal(result.ok, false)
  assert.match(result.error, /一次只能用一个来源/)
  assert.match(result.error, /file/)
  assert.match(result.error, /screenshot/)
})

test('resolveSource treats a blank file path as missing', () => {
  const result = resolveSource({ file: '   ' })
  assert.equal(result.ok, false)
})

test('buildArgs maps each source to its flag', () => {
  assert.deepEqual(buildArgs({ file: '/tmp/a.png' }, 'S'), ['S', '--file', '/tmp/a.png'])
  assert.deepEqual(buildArgs({ screenshot: true }, 'S'), ['S', '--screenshot'])
  assert.deepEqual(buildArgs({ clipboard: true }, 'S'), ['S', '--clipboard'])
})

test('buildArgs keeps a caption and drops an empty one', () => {
  assert.deepEqual(
    buildArgs({ file: 'a.png', caption: '渲染结果' }, 'S'),
    ['S', '--file', 'a.png', '--caption', '渲染结果'],
  )
  assert.deepEqual(buildArgs({ file: 'a.png', caption: '   ' }, 'S'), ['S', '--file', 'a.png'])
})

test('scriptPath finds the installed skill', () => {
  // The plugin deliberately reuses the skill's script rather than keeping a
  // second copy: two implementations of the same wire call would drift.
  const path = scriptPath()
  assert.ok(path, 'the send-image script was not found')
  assert.match(path, /send-image\.mjs$/)
})

test('execute refuses without a session id', async () => {
  // The env var is the last-resort carrier, so it has to be absent for this
  // test to mean anything. Without clearing it the assertion silently depends
  // on the ambient shell — it passed for months and then failed the moment a
  // session id happened to be exported.
  const saved = process.env.DSH_SESSION_ID
  delete process.env.DSH_SESSION_ID
  try {
    const tool = register()
    const result = await tool.execute({ screenshot: true }, {})
    assert.equal(result.ok, false)
    assert.match(result.error, /会话 id/)
  } finally {
    if (saved === undefined) delete process.env.DSH_SESSION_ID
    else process.env.DSH_SESSION_ID = saved
  }
})

test('execute finds the session id on the live session object', async () => {
  // The host moved this from `agent.sessionId` to `agent.session.id`; the env
  // var does not cover it, because the server process has no DSH_SESSION_ID.
  const saved = process.env.DSH_SESSION_ID
  delete process.env.DSH_SESSION_ID
  try {
    const tool = register()
    // A blank path fails validation, but only AFTER the session id is resolved —
    // so a "需要 file" error proves the id was found.
    const result = await tool.execute({ file: '  ' }, { agent: { session: { id: 'session-live' } } })
    assert.equal(result.ok, false)
    assert.match(result.error, /file/)
    assert.doesNotMatch(result.error, /会话 id/)
  } finally {
    if (saved === undefined) delete process.env.DSH_SESSION_ID
    else process.env.DSH_SESSION_ID = saved
  }
})

test('execute refuses without a source before touching the script', async () => {
  const tool = register()
  const result = await tool.execute({}, { agent: { sessionId: 'session-x' } })
  assert.equal(result.ok, false)
  assert.match(result.error, /需要 file/)
})
