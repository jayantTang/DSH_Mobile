import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import test from 'node:test'

const matrix = readFileSync('handbook/requirements/details/internationalization.md', 'utf8')
const info = readFileSync('ios/DSHMobile/DSHMobile-Info.plist', 'utf8')
const enPlist = readFileSync('ios/DSHMobile/DSHMobile/en.lproj/InfoPlist.strings', 'utf8')
const zhPlist = readFileSync('ios/DSHMobile/DSHMobile/zh-Hans.lproj/InfoPlist.strings', 'utf8')
const enStrings = readFileSync('ios/DSHMobile/DSHMobile/en.lproj/Localizable.strings', 'utf8')

test('language matrix keeps English as fallback and lists the first-wave locales', () => {
  for (const code of ['en', 'zh-Hans', 'zh-Hant', 'ja', 'ko', 'es', 'pt-BR', 'fr', 'de']) {
    assert.match(matrix, new RegExp('`' + code + '`'), `matrix missing ${code}`)
  }
  assert.match(matrix, /英语是回退语言/)
})

test('permission descriptions exist in both shipped languages', () => {
  for (const key of ['NSLocalNetworkUsageDescription', 'NSCameraUsageDescription', 'NSPhotoLibraryAddUsageDescription']) {
    assert.match(info, new RegExp(key))
    assert.match(enPlist, new RegExp(key))
    assert.match(zhPlist, new RegExp(key))
  }
})

test('English UI values contain no Chinese characters', () => {
  const values = [...enStrings.matchAll(/^"[^"]+"\s*=\s*"((?:[^"\\]|\\.)*)";/gm)]
    .map((match) => match[1])
  assert.ok(values.length > 800)
  const untranslated = values.filter((value) => /[\u4e00-\u9fff]/.test(value))
  assert.deepEqual(untranslated, [])
})

test('the support matrix and fallback are documented for every surface', () => {
  for (const surface of ['iOS App', '连接器面板', '连接器 CLI', '通知与权限说明']) {
    assert.match(matrix, new RegExp(surface), `matrix missing ${surface}`)
  }
})
