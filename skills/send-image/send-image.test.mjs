import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { promisify } from 'node:util'
import { fileURLToPath } from 'node:url'
import { explainCaptureFailure } from './send-image.mjs'

const run = promisify(execFile)
const script = fileURLToPath(new URL('./send-image.mjs', import.meta.url))

test('a denied capture points at the permission and the restart, not at stderr', () => {
  // This exact stderr is what macOS returns when the Screen Recording grant
  // does not cover the running process.
  const message = explainCaptureFailure({
    stderr: Buffer.from('could not create image from display\n'),
  })
  assert.match(message, /屏幕录制/)
  assert.match(message, /重新打开 DSH\.app/)
  // The original text stays, so a different cause is still diagnosable.
  assert.match(message, /could not create image from display/)
})

test('another failure keeps its own reason', () => {
  const message = explainCaptureFailure({ stderr: Buffer.from('screencapture: no display\n') })
  assert.match(message, /截屏失败/)
  assert.match(message, /no display/)
  assert.doesNotMatch(message, /重新打开/)
})

test('a failure with no stderr still says something usable', () => {
  const message = explainCaptureFailure(new Error('spawn screencapture ENOENT'))
  assert.match(message, /spawn screencapture ENOENT/)
})

// ── prepare mode ────────────────────────────────────────────────────────────

test('--file prepares a descriptor instead of sending anything', async () => {
  // The default mode must not touch the session: the tool turns this descriptor
  // into an attachment that rides on its own result. A prompt would show up as a
  // user message and start another turn — the bug this replaced.
  const directory = mkdtempSync(join(tmpdir(), 'dsh-send-image-script-'))
  const path = join(directory, 'pixel.png')
  writeFileSync(path, Buffer.from(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
    'base64'
  ))
  try {
    // No DSH_SESSION_ID: preparing must not need one, and must not call the API.
    const env = { ...process.env }
    delete env.DSH_SESSION_ID
    const { stdout } = await run(process.execPath, [script, '--file', path], { env, encoding: 'utf8' })
    const descriptor = JSON.parse(stdout.trim())
    assert.equal(descriptor.path, path)
    assert.equal(descriptor.mediaType, 'image/png')
    assert.equal(descriptor.name, 'pixel.png')
    assert.ok(descriptor.bytes > 0)
    assert.equal(descriptor.temporary, false)
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
})

test('--via-prompt still insists on a session id', async () => {
  // The fallback path is the one that needs the session, and it says so rather
  // than failing deeper in with a confusing error.
  const directory = mkdtempSync(join(tmpdir(), 'dsh-send-image-script-'))
  const path = join(directory, 'pixel.png')
  writeFileSync(path, Buffer.from(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
    'base64'
  ))
  try {
    const env = { ...process.env }
    delete env.DSH_SESSION_ID
    await assert.rejects(
      () => run(process.execPath, [script, '--file', path, '--via-prompt'], { env, encoding: 'utf8' }),
      (error) => /DSH_SESSION_ID/.test(String(error.stderr) + String(error.message))
    )
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
})
