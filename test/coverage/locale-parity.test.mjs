import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { join } from 'node:path'
import test from 'node:test'

const app = 'ios/DSHMobile/DSHMobile'
const locales = ['en', 'zh-Hans', 'zh-Hant', 'ja', 'ko', 'es', 'pt-BR', 'fr', 'de']
const parse = (path) => {
  const rows = []
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    const m = line.match(/^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";\s*$/)
    if (m) rows.push({ key: m[1], value: m[2] })
  }
  return rows
}
const placeholders = (s) => [...s.matchAll(/%(?:\d+\$)?(?:@|lld|d|f|%)/g)].map((m) => m[0]).sort()

test('all shipped locales have the same Localizable key set and placeholders', () => {
  const base = parse(join(app, 'en.lproj/Localizable.strings'))
  const baseKeys = new Set(base.map((row) => row.key))
  for (const locale of locales) {
    const rows = parse(join(app, `${locale}.lproj/Localizable.strings`))
    assert.equal(rows.length, base.length, `${locale} count`)
    assert.equal(new Set(rows.map((row) => row.key)).size, baseKeys.size, `${locale} duplicate/missing keys`)
    for (const row of rows) {
      assert.ok(baseKeys.has(row.key), `${locale} unexpected key ${row.key}`)
      const baseValue = base.find((item) => item.key === row.key).value
      if (baseValue.trim()) assert.ok(row.value.trim(), `${locale} empty value ${row.key}`)
      assert.deepEqual(placeholders(row.value), placeholders(base.find((item) => item.key === row.key).value), `${locale} placeholder ${row.key}`)
    }
  }
})

test('all shipped locales have the same InfoPlist permission keys', () => {
  const keys = ['NSLocalNetworkUsageDescription', 'NSPhotoLibraryAddUsageDescription', 'NSCameraUsageDescription']
  for (const locale of locales) {
    const text = readFileSync(join(app, `${locale}.lproj/InfoPlist.strings`), 'utf8')
    for (const key of keys) assert.match(text, new RegExp(`"${key}"\\s*=`), `${locale} ${key}`)
  }
})

test('CFBundleLocalizations matches the shipped lproj set', () => {
  const plist = readFileSync(join(app, '..', 'DSHMobile-Info.plist'), 'utf8')
  const listed = [...plist.matchAll(/<string>([a-z]{2}(?:-[A-Za-z]+)?)<\/string>/g)].map((m) => m[1])
  for (const locale of locales) assert.ok(listed.includes(locale), `CFBundleLocalizations missing ${locale}`)
})
