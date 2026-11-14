import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import test from 'node:test'

const settings = readFileSync('ios/DSHMobile/Modules/Features/Settings/UI/SettingsView.swift', 'utf8')

test('user-facing docs offer TestFlight, not an OTA address', () => {
  for (const file of ['README.md', 'docs/ONBOARDING.md']) {
    const text = readFileSync(file, 'utf8')
    assert.match(text, /TestFlight/i, `${file} lacks TestFlight`)
    assert.doesNotMatch(text, /https?:\/\/[^\s)]+\/ios\//, `${file} exposes an OTA install page`)
  }
})

test('TestFlight submission is the default and --no-submit is the explicit exception', () => {
  const script = readFileSync('scripts/release/deploy-testflight.sh', 'utf8')
  assert.match(script, /SUBMIT=1/)
  assert.match(script, /--no-submit\) SUBMIT=0/)
  assert.match(script, /--beta-only/)
})

test('the settings clear-cache button clears all three local caches', () => {
  assert.match(settings, /settings\.clear-cache/)
  assert.match(settings, /SessionListSnapshotStore\(\)\.clearAll\(\)/)
  assert.match(settings, /MessageLayer\.clearTranscriptCache\(\)/)
  assert.match(settings, /AttachmentDiskCache\(\)\.clearAll\(\)/)
})
