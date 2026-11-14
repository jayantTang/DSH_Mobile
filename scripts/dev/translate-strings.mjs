#!/usr/bin/env node
// Offline-first translation helper for the local DSH LLM router.
//
//   node scripts/dev/translate-strings.mjs --languages ja,ko --file ios/DSHMobile/DSHMobile/en.lproj/Localizable.strings
//
// It translates the VALUES of an English .strings file into each language and
// writes <lang>.lproj/Localizable.strings. Keys stay unchanged. Placeholders are
// validated after every batch; a mismatch aborts instead of silently shipping a
// broken format string. Output is machine translated and must be reviewed before
// release; the generated header says so.

import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs'
import { dirname, join } from 'node:path'

const ROOT = process.cwd()
const CONFIG = JSON.parse(readFileSync(join(process.env.HOME, '.dsh/llm-key-router/config.json'), 'utf8'))
const args = process.argv.slice(2)
const getArg = (name, fallback) => {
  const i = args.indexOf(name)
  return i >= 0 ? args[i + 1] : fallback
}
const languages = String(getArg('--languages', 'ja')).split(',').map((s) => s.trim()).filter(Boolean)
const file = getArg('--file', 'ios/DSHMobile/DSHMobile/en.lproj/Localizable.strings')
const batchSize = Number(getArg('--batch', '60'))
const concurrency = Number(getArg('--concurrency', '3'))
const model = getArg('--model', 'deepseek-v4-flash')
const names = { 'zh-Hant': 'Traditional Chinese', ja: 'Japanese', ko: 'Korean', es: 'Spanish', 'pt-BR': 'Brazilian Portuguese', fr: 'French', de: 'German' }
const placeholders = (s) => [...s.matchAll(/%(?:\d+\$)?(?:@|lld|d|f|%)/g)].map((m) => m[0]).sort()
const escape = (s) => s.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n')

function parseStrings(path) {
  const text = readFileSync(path, 'utf8')
  const rows = []
  for (const line of text.split('\n')) {
    const m = line.match(/^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";\s*$/)
    if (m) rows.push({ key: m[1], value: m[2] })
  }
  return rows
}

async function callLLM(language, items) {
  const live = items.filter((item) => item.value.trim())
  if (live.length === 0) return items.map(() => '')
  const prompt = {
    instruction: `Translate these UI strings from English to ${language}. Keep placeholders exactly, keep product names DSH/DSH Mobile/TestFlight, keep punctuation natural. Return only a JSON object with the same numeric keys and translated string values; no markdown.`,
    strings: Object.fromEntries(live.map((item, i) => [String(i), item.value])),
  }
  let last
  for (let attempt = 0; attempt < 4; attempt += 1) {
    const response = await fetch(`http://127.0.0.1:${CONFIG.port}/v1/chat/completions`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${CONFIG.token}` },
      body: JSON.stringify({
        model,
        temperature: 0,
        max_tokens: 12000,
        messages: [
          { role: 'system', content: 'You are a precise software UI translator. Output JSON only.' },
          { role: 'user', content: JSON.stringify(prompt) },
        ],
      }),
    })
    if (!response.ok) throw new Error(`LLM HTTP ${response.status}: ${(await response.text()).slice(0, 200)}`)
    const body = await response.json()
    let content = body.choices?.[0]?.message?.content ?? ''
    content = content.replace(/^```(?:json)?\s*/i, '').replace(/\s*```$/, '').trim()
    try {
      const parsed = JSON.parse(content)
      const translated = live.map((item, i) => {
        const value = parsed[String(i)]
        if (typeof value !== 'string' || !value.trim()) throw new Error(`missing item ${i}`)
        if (placeholders(item.value).join('\0') !== placeholders(value).join('\0')) {
          throw new Error(`placeholder mismatch item ${i}: ${item.value} -> ${value}`)
        }
        return value
      })
      let cursor = 0
      return items.map((item) => item.value.trim() ? translated[cursor++] : '')
    } catch (error) {
      last = error
      console.error(`  retry ${language} batch ${items[0].index}: ${error.message}`)
    }
  }
  throw last
}

function writeLocale(language, rows, translated) {
  const path = join(dirname(file), '..', `${language}.lproj`, 'Localizable.strings')
  mkdirSync(dirname(path), { recursive: true })
  const lines = [
    `/* DSH Mobile — machine-translated from English to ${names[language] ?? language}. Review before release. */`,
    '',
    ...rows.map((row, i) => `"${escape(row.key)}" = "${escape(translated[i])}";`),
    '',
  ]
  writeFileSync(path, lines.join('\n'))
  console.log(`wrote ${path} (${rows.length})`)
}

const source = parseStrings(file)
console.log(`source ${file}: ${source.length} strings; languages ${languages.join(', ')}`)
for (const language of languages) {
  if (!names[language]) throw new Error(`unknown language ${language}`)
  const batches = []
  for (let i = 0; i < source.length; i += batchSize) {
    batches.push(source.slice(i, i + batchSize).map((row, j) => ({ ...row, index: i + j })))
  }
  const translated = new Array(source.length)
  let cursor = 0
  await Promise.all(Array.from({ length: concurrency }, async () => {
    while (cursor < batches.length) {
      const index = cursor++
      const batch = batches[index]
      const values = await callLLM(language, batch)
      values.forEach((value, i) => { translated[batch[i].index] = value })
      console.log(`  ${language} ${index + 1}/${batches.length}`)
    }
  }))
  writeLocale(language, source, translated)
}
