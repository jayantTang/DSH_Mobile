#!/usr/bin/env node
// Turns a case's execution instructions into the JSON plan the UI engine runs.
//
// Two files per case, on purpose:
//
//   <name>.md      the case itself — numbered natural-language steps, nothing
//                  mechanical, readable by whoever reviews the test plan
//   <name>.steps   what the machine does for each of those steps
//
// The case is the source of truth for *what* is being tested; the steps file is
// the translation of it into actions. Keeping them apart is what stops the case
// from turning into code, and it keeps the mapping checkable: step N of one
// lines up with step N of the other, and the run reports a mismatch.
//
// A steps file is one line per case step, fields separated by `|`:
//
//   1  do: 连接本机 DSH  |  shot: sessions check=texts,amber
//   2  do: 什么都不做    |  want: label:连接管理 | label:设置
//
// `do` is written in Chinese because that is what a person editing it reads;
// the action words are listed in ACTIONS below.

/// Front matter: `---` delimited, `键: 值` per line.
export function caseMeta(text) {
  const match = /^---\n([\s\S]*?)\n---/.exec(text)
  if (!match) return {}
  const fields = {}
  for (const line of match[1].split('\n')) {
    const at = line.indexOf(':')
    if (at > 0) fields[line.slice(0, at).trim()] = line.slice(at + 1).trim()
  }
  return fields
}

/// The case's numbered steps, as prose. Used for the titles the report shows.
export function caseSteps(text) {
  const lines = text.split('\n')
  const start = lines.findIndex((line) => /^#{2,}[ \t]*步骤/.test(line))
  if (start < 0) return []
  const steps = []
  for (const line of lines.slice(start + 1)) {
    if (/^#{2,}[ \t]/.test(line)) break
    const numbered = /^\s*(\d+)[.、)]\s+(.*)$/.exec(line)
    if (numbered) { steps.push(numbered[2].trim()); continue }
    if (steps.length && line.trim()) steps[steps.length - 1] += ` ${line.trim()}`
  }
  return steps
}

/// `key: value` pairs of one steps-file line.
///
/// A chunk with a `:` starts a field; a chunk without one continues the field
/// before it. That is what lets `want: label:连接管理 | label:设置` list two
/// checks while the value's own colon stays part of the value.
function fields(line) {
  const body = line.replace(/^\s*\d+\s+/, '')
  const found = {}
  let key = null
  for (const chunk of body.split('|')) {
    const text = chunk.trim()
    if (!text) continue
    const at = text.indexOf(':')
    if (at > 0 && /^[a-zA-Z]+$/.test(text.slice(0, at).trim())) {
      key = text.slice(0, at).trim()
      found[key] = text.slice(at + 1).trim()
    } else if (key) {
      found[key] = `${found[key]} | ${text}`
    }
  }
  return found
}

/// The action vocabulary. Written here once so a case's steps file can stay in
/// Chinese while the engine keeps its mechanical directives.
const ACTIONS = [
  { match: /^连接本机 DSH$/, to: () => ['launch connect=auto'] },
  { match: /^不连接 DSH$/, to: () => ['launch connect=none'] },
  { match: /^打开页面\s+(\S+)$/, to: (page) => [`launch screen=${page}`] },
  // A workspace file: the report itself, opened in whichever viewer the app
  // picks for its type. The path is relative to the session's workspace.
  { match: /^打开报告\s+([^\s（(]+)(?:\s*[（(](.+)[）)])?$/, to: (file, anchor) =>
      [`launch file=${file} root=${quote((anchor ?? '').trim())}`] },
  // Same, but the viewer opens in its source mode — the path that used to hang.
  { match: /^打开源码\s+([^\s（(]+)(?:\s*[（(](.+)[）)])?$/, to: (file, anchor) =>
      [`launch file=${file} root=${quote((anchor ?? '').trim())} filemode=source`] },
  // The positional form comes first: `点击 X 的右` would otherwise be read as
  // "tap an element whose name is `X 的右`".
  { match: /^点击\s+(.+?)\s+的(左|右|中间)$/, to: (target, side) =>
      [`tap_at ${quote(target)} at=${{ 左: 'left', 右: 'right', 中间: 'center' }[side]}`] },
  { match: /^点击\s+(.+)$/, to: (target) => [`tap ${quote(target)}`] },
  // `点击屏幕 60%,4%`: a fraction of the screen, for a control with no stable
  // hit target of its own.
  { match: /^点击屏幕\s+(\d+(?:\.\d+)?)%\s*,\s*(\d+(?:\.\d+)?)%$/, to: (x, y) =>
      [`tap_where at=${Number(x) / 100},${Number(y) / 100}`] },
  { match: /^输入\s+(.+)$/, to: (text) => [`type text=${quote(text)}`] },
  // Order matters: `滚动到 X` is its own action, and the generic `滚动` below
  // would otherwise swallow it as "scroll towards an element named 到 X".
  { match: /^滚动到\s+(.+)$/, to: (target) => [`scroll_to ${quote(target)}`] },
  { match: /^等待消失\s+(.+?)(?:\s+timeout=(\d+))?$/, to: (target, timeout) =>
      [`wait_gone ${quote(target)}${timeout ? ` timeout=${timeout}` : ''}`] },
  // `滚动 left id:session.row.x` — a direction, then optionally what to drag.
  { match: /^滚动\s*(up|down|left|right)?\s*(.*)$/, to: (direction, target) => [
      target ? `swipe ${quote(target.trim())} direction=${direction ?? 'up'}`
             : `swipe direction=${direction ?? 'up'}`,
    ] },
  // The timeout is part of the vocabulary, not part of the target: without its
  // own group the whole line — `id:x timeout=15` — becomes one quoted selector,
  // and the step fails with "缺少目标" as if no target had been written at all.
  { match: /^等待\s+(.+?)(?:\s+timeout=(\d+))?$/, to: (target, timeout) =>
      [`wait ${quote(target)}${timeout ? ` timeout=${timeout}` : ''}`] },
  { match: /^核对\s+(.+)$/, to: (target) => [`assert ${quote(target)}`] },
  { match: /^探查$/, to: () => ['probe'] },
  { match: /^切到后台\s*(\d+)?\s*秒?$/, to: (seconds) => [`background seconds=${seconds ?? 3}`] },
  { match: /^切回前台$/, to: () => ['foreground'] },
  // A second opinion from the system browser.
  { match: /^用浏览器打开\s+(\S+)$/, to: (url) => [`open_url ${url}`] },
  { match: /^渲染 HTML\s+(.+)$/, to: (html) => [`open_html '${html}'`] },
  { match: /^什么都不做$/, to: () => [] },
]

/// Keeps a target with spaces in it one argument.
function quote(value) {
  return /\s/.test(value) && !value.startsWith('"') ? `"${value}"` : value
}

function directivesFor(action) {
  const entry = ACTIONS.find((candidate) => candidate.match.test(action))
  if (!entry) throw new Error(`不认识的动作用语「${action}」——见 test/README.md 的动作表`)
  const groups = entry.match.exec(action).slice(1)
  return entry.to(...groups)
}

/// A comma-separated list of checks, targets or pictures.
function splitList(value) {
  // Comma only. A space must not split, because a shot's fields are
  // space-separated inside the item: `sessions check=texts,amber`.
  return String(value ?? '').split(',').map((item) => item.trim()).filter(Boolean)
}

/// Splits a `shot` field into one item per picture.
///
/// A picture is a name plus the modifiers that follow it: `check=texts,amber`
/// (a value with a comma in it) and the bare flag `after`. Whitespace separates
/// pictures, keys and flags apart.
function splitShots(value) {
  const items = []
  for (const token of String(value ?? '').trim().split(/\s+/).filter(Boolean)) {
    const isField = token.includes('=') || token === 'after'
    if (!isField) { items.push({ name: token, fields: [] }); continue }
    if (!items.length) items.push({ name: null, fields: [] })
    items.at(-1).fields.push(token)
  }
  return items
    .map((item) => [item.name, ...item.fields].filter(Boolean).join(' '))
    .filter((item) => item.split(' ')[0])
}

/// Reads the execution instructions, one case step per line.
export function readStepsFile(text) {
  const steps = []
  for (const raw of text.split('\n')) {
    const line = raw.trim()
    if (!line || line.startsWith('#')) continue
    const numbered = /^(\d+)\s+(.*)$/.exec(line)
    if (!numbered) continue
    const [, index, rest] = numbered
    const found = fields(line)
    // `want` and `shot` are recognised keys; anything else is the action, which
    // lets a line read `do: 打开页面 files` without ceremony.
    const action = (found.do ?? '').trim()
    // Several checks are separated by commas: `want: label:a, label:b`. A `|`
    // cannot separate them, because it is what separates the fields themselves.
    const wants = splitList(found.want)
    // Shots split on whitespace, not commas, because a shot carries
    // `check=texts,amber` and that comma belongs to the value.
    const shots = splitShots(found.shot)
    steps.push({ index: Number(index), action, wants, shots, rest })
  }
  return steps
}

export function buildPlan({ casePath, caseText, stepsText, runId, bundleId, sessionId,
                            pickedSession, connectUrl, screens }) {
  const meta = caseMeta(caseText)
  const prose = caseSteps(caseText)
  const rows = readStepsFile(stepsText)
  if (!rows.length) throw new Error(`${casePath} 对应的 .steps 文件里没有可执行的步骤`)
  if (prose.length && prose.length !== rows.length) {
    throw new Error(`用例有 ${prose.length} 个步骤，指令文件有 ${rows.length} 条——两者必须一一对应`)
  }

  // A case refers to the session it may work on as `{{session}}`; the runner
  // decides which session that is (usually a scratch one it created and will
  // delete), so a case never hard-codes an id and never touches real history.
  const substitute = (value) => {
    if (typeof value !== 'string') return value
    // `{{session}}` is the session this run works on (a scratch one when the
    // case asks for it); `{{pick}}` is the real session the runner picked,
    // which is what a "the list is still there" check needs.
    return value
      .split('{{session}}').join(sessionId ?? '')
      .split('{{pick}}').join(pickedSession ?? sessionId ?? '')
  }

  const planned = []
  let current = null
  let seq = 0
  /// Set by a directive that knows better than the page table what proves the
  /// page arrived — a report names its own title.
  let pendingRoot = null

  for (const row of rows) {
    const title = prose[row.index - 1] ?? row.action
    const directives = directivesFor(row.action)
    let shots = row.shots.map((item) => {
      const tokens = item.split(/\s+/)
      const after = tokens.includes('after')
      const values = {}
      for (const token of tokens) {
        const at = token.indexOf('=')
        if (at > 0) values[token.slice(0, at)] = token.slice(at + 1)
      }
      const name = tokens.find((token) => !token.includes('=') && token !== 'after') ?? 'shot'
      return { name, note: title, ...(after ? { after: true } : {}), ...(values.check ? { check: values.check } : {}) }
    })
    const wants = row.wants

    const nextStep = (action) => {
      seq += 1
      const step = { seq, row: row.index, id: `s${String(seq).padStart(2, '0')}`,
                     title, do: action }
      current.steps.push(step)
      return step
    }
    let anchor = null

    for (const directive of directives) {
      // Single quotes hold a value with spaces and double quotes in it — an
      // inline HTML document, for instance.
      const [action, ...tokens] = (directive.match(/'[^']*'|"[^"]*"|\S+/g) ?? [])
        .map((token) => token.replace(/^["']|["']$/g, ''))
      const values = {}
      for (const token of tokens) {
        const at = token.indexOf('=')
        if (at > 0) values[token.slice(0, at)] = token.slice(at + 1)
        else values[token] = true
      }

      if (action === 'launch') {
        const args = []
        if (values.connect !== 'none') args.push('-DSHConnectURL', connectUrl)
        if (values.root && String(values.root).trim()) {
          // What proves this page arrived, when the default anchor does not fit
          // — a different report, for instance. A bare phrase means "this text
          // is on screen".
          const anchor = String(values.root).trim()
          pendingRoot = anchor.includes(':') ? anchor : `text:${anchor}`
        }
        if (values.file) {
          // Opening a file needs a session to resolve the workspace, and the
          // runner already picked one.
          if (sessionId) args.push('-DSHOpenSession', sessionId)
          args.push('-DSHOpenFile', String(values.file))
          if (values.filemode) args.push('-DSHFileMode', String(values.filemode))
        }
        const keys = values.screen ? String(values.screen).split(',') : []
        for (const key of keys) {
          const entry = screens[key]
          if (!entry) throw new Error(`未知页面「${key}」：先在 test/screens.md 与 context.mjs 的 screens 表里登记`)
          args.push(...entry.args(sessionId))
        }
        current = { id: keys[0] ?? (values.file ? 'report' : (values.connect === 'none' ? 'onboarding' : 'sessions')),
                    note: title, launch: args, steps: [], root: pendingRoot }
        pendingRoot = null
        planned.push(current)
        continue
      }

      if (!current) throw new Error(`${casePath} 的第 ${row.index} 步之前没有「连接本机 DSH」或「打开页面」`)

      const positional = tokens.filter((token) => !token.includes('='))
      switch (action) {
        case 'tap':
        case 'tap_at':
        case 'tap_where':
        case 'background':
        case 'foreground':
        case 'scroll_to':
        case 'wait_gone':
        case 'type':
        case 'swipe':
        case 'wait':
        case 'probe':
          anchor = nextStep(action)
          anchor.target = positional[0]
          if (action === 'swipe') anchor.value = values.direction ?? positional[1] ?? 'up'
          if (action === 'wait') anchor.timeout = Number(values.timeout ?? positional[1] ?? 15)
          // `等待消失 x timeout=90`: a wait that outlasts a live turn needs its
          // own number, and dropping it here silently held the step to 20s.
          if (action === 'wait_gone') anchor.timeout = Number(values.timeout ?? positional[1] ?? 20)
          // `输入 文字` types into whatever is focused; `type <field> text=…`
          // names the field instead.
          if (action === 'type') {
            anchor.target = values.text === undefined ? positional[0] : undefined
            anchor.value = values.text ?? positional[1] ?? ''
          }
          if (action === 'tap_at') anchor.value = values.at ?? 'center'
          if (action === 'tap_where') anchor.value = values.at ?? '0.5,0.5'
          if (action === 'background') anchor.timeout = Number(values.seconds ?? positional[0] ?? 3)
          break
        case 'open_url':
        case 'open_html':
          // A URL or a document is a value, not a target selector: both carry
          // `:` and `/`.
          anchor = nextStep(action)
          anchor.value = positional[0]
          break
        case 'assert':
          // An explicit assertion is already one of the checks; recording it
          // again through `want` would run it twice.
          nextStep('assert').target = positional[0]
          anchor = nextStep('snapshot')
          break
        default:
          throw new Error(`无法识别的动作「${action}」（${casePath}）`)
      }
    }

    // The row's own step is the one that acts or photographs; a row that only
    // checks has no such step, so its first check becomes the row's step and the
    // rest follow.
    const acted = anchor
    const checks = shots.flatMap((shot) => shot.check?.split(/[,\s]+/) ?? [])
    if (acted) {
      if (checks.length) acted.checks = [...new Set([...(acted.checks ?? []), ...checks])]
      if (shots.length) acted.shots = shots
      if (wants.length) acted.expect = wants
    }
    wants.forEach((want, index) => {
      // `X, absent` reads as "X must not be there" — the only way to assert that
      // something is missing, which is how a failure banner is checked.
      // The modifier follows a `;`, not a `,` — a comma already separates one
      // check from the next.
      const [value, modifier] = want.split(';').map((part) => part.trim())
      const step = nextStep('assert')
      step.target = value
      if (modifier === 'absent') step.value = 'absent'
      if (!acted && index === 0) {
        step.expect = wants
        // `do: 什么都不做 | want: … | shot: …` is a legitimate row — "photograph
        // what is here, and check it". Dropping the picture because the row has
        // no action left a claimed screenshot that never existed.
        if (shots.length) step.shots = shots
        if (checks.length) step.checks = [...new Set(checks)]
      }
    })
    // A row that only photographs still gets a step of its own.
    if (!acted && !wants.length && shots.length) {
      const step = nextStep('snapshot')
      if (checks.length) step.checks = checks
      step.shots = shots
    }
  }

  for (const screen of planned) {
    for (const step of screen.steps) {
      step.target = substitute(step.target)
      step.value = substitute(step.value)
    }
  }

  return {
    run: runId,
    case: meta.id ?? casePath,
    caseTitle: meta.title ?? '',
    caseVersion: meta['用例版本'] ?? '',
    caseFile: casePath,
    // The case's own definition of done, copied into the plan so the report can
    // print it from the machine-readable record instead of re-reading the case.
    criteria: String(meta['通过判据'] ?? '').split(/[／|;]/).map((part) => part.trim()).filter(Boolean),
    bundleId,
    screens: planned,
  }
}
