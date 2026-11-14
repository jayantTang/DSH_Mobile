import assert from 'node:assert/strict'
import test from 'node:test'
import { T, setLanguage, resolveLanguage, currentLanguage } from '../lib/i18n.js'

test('the CLI/status catalog covers every shipped locale', () => {
  for (const locale of ['zh-Hans', 'zh-Hant', 'ja', 'ko', 'es', 'pt-BR', 'fr', 'de']) {
    assert.equal(setLanguage(locale), locale)
    assert.equal(currentLanguage(), locale)
    assert.equal(T('cli.registered').length > 0, true, locale)
    assert.equal(T('status.unregistered').length > 0, true, locale)
    assert.match(T('cli.code', { code: 'ABCD', minutes: 10 }), /ABCD/)
  }
  setLanguage('zh-Hans')
})

test('language tags resolve to the supported catalogs', () => {
  assert.equal(resolveLanguage('zh-TW'), 'zh-Hant')
  assert.equal(resolveLanguage('pt_BR'), 'pt-BR')
  assert.equal(resolveLanguage('de-DE'), 'de')
  assert.equal(resolveLanguage('nl-NL'), null)
})
