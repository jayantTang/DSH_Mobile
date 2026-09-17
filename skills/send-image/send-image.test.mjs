import { test } from 'node:test'
import assert from 'node:assert/strict'
import { explainCaptureFailure } from './send-image.mjs'

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
