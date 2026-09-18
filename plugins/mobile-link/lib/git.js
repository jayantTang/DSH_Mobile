/**
 * Git status, diffs and history, answered on the computer itself.
 *
 * The Host has no git endpoint — nothing in its 47 RPC methods runs a command —
 * but the connector is already a process on the machine that holds the work
 * tree, and the `_link/file*` upload path proved the shape: a reserved method
 * name answered here instead of being forwarded. So git runs here, in the
 * session's own directory, and the phone gets what a person wants to check
 * before approving an agent's work: which files changed, what changed in them,
 * and what the recent commits were.
 *
 * **Read-only by construction.** The command whitelist below is the entire
 * surface: status, diff, log, show, rev-parse, numstat. There is no way to
 * commit, stage, checkout or clean through this path, and every command runs
 * with `GIT_OPTIONAL_LOCKS=0` so merely looking at a repository can never leave
 * an `index.lock` behind for the agent to trip over.
 */

import { execFile } from 'node:child_process'
import { statSync } from 'node:fs'
import { isAbsolute, resolve } from 'node:path'

/** Reserved method names this module answers; never forwarded to the Host. */
export const GIT_STATUS = '_link/gitStatus'
export const GIT_DIFF = '_link/gitDiff'
export const GIT_LOG = '_link/gitLog'
export const GIT_SHOW = '_link/gitShow'
export const GIT_FILE = '_link/gitFile'

const METHODS = new Set([GIT_STATUS, GIT_DIFF, GIT_LOG, GIT_SHOW, GIT_FILE])

export function isGitMethod(method) {
  return METHODS.has(method)
}

/** Output ceilings: a phone review, not a `git log | less`. */
export const LIMITS = {
  statusBytes: 1024 * 1024,
  diffBytes: 256 * 1024,
  logBytes: 512 * 1024,
  fileBytes: 8 * 1024 * 1024,
  logPage: 20,
  statusTimeoutMs: 15_000,
  readTimeoutMs: 15_000,
}

/** The environment every git call runs in. */
function gitEnv() {
  return {
    ...process.env,
    // Never wait for a credential prompt or open an editor: a phone review
    // must not be able to wedge a process on the computer.
    GIT_TERMINAL_PROMPT: '0',
    GIT_PAGER: 'cat',
    GIT_EDITOR: 'true',
    // Looking at a repository must not take its locks — the agent may be
    // working in it at the same moment.
    GIT_OPTIONAL_LOCKS: '0',
    // Stable field order and dates; the parsers below depend on it.
    LC_ALL: 'C',
  }
}

/** A refusal the phone can branch on, rather than a string to match. */
export class GitError extends Error {
  constructor(code, message, details = {}) {
    super(message)
    this.code = code
    this.details = details
  }
}

/**
 * Runs one git command in `cwd`.
 *
 * `okCodes` exists because `git diff` answers 1 when it found differences —
 * which is the normal case here, not a failure.
 */
function runGit(cwd, argv, { timeoutMs, maxBytes, okCodes = [0] } = {}) {
  return new Promise((resolvePromise, reject) => {
    execFile(
      'git',
      ['-C', cwd, '--no-pager', '-c', 'core.quotepath=false', ...argv],
      {
        timeout: timeoutMs ?? LIMITS.readTimeoutMs,
        maxBuffer: (maxBytes ?? LIMITS.diffBytes) + 1024,
        env: gitEnv(),
        encoding: 'buffer',
      },
      (error, stdout, stderr) => {
        const out = Buffer.isBuffer(stdout) ? stdout : Buffer.from(stdout ?? '')
        if (error) {
          // `execFile` reports a spawn failure (no git installed) as ENOENT.
          if (error.code === 'ENOENT') {
            reject(new GitError('git/unavailable', '这台电脑上没有找到 git'))
            return
          }
          if (error.killed || error.signal) {
            reject(new GitError('git/timed-out', 'git 命令超过时限，已中止'))
            return
          }
          if (error.code === 'ERR_CHILD_PROCESS_STDIO_MAXBUFFER') {
            reject(new GitError('git/too-large', '命令输出超过上限，请缩小范围'))
            return
          }
          const code = typeof error.code === 'number' ? error.code : 1
          if (okCodes.includes(code)) {
            resolvePromise(out)
            return
          }
          const text = (Buffer.isBuffer(stderr) ? stderr : Buffer.from(stderr ?? '')).toString('utf8')
          reject(new GitError('git/failed', text.trim().split('\n').slice(-1)[0] || 'git 命令失败', {
            exitCode: code,
          }))
          return
        }
        resolvePromise(out)
      }
    )
  })
}

/** Resolves a directory that is inside a work tree, and that tree's root. */
async function repository(cwd) {
  const directory = String(cwd ?? '')
  if (!directory || !isAbsolute(directory)) {
    throw new GitError('git/bad-request', '需要一个绝对路径的工作目录')
  }
  let stats
  try {
    stats = statSync(resolve(directory))
  } catch {
    throw new GitError('git/not-found', `目录不在了：${directory}`)
  }
  if (!stats.isDirectory()) {
    throw new GitError('git/bad-request', `不是一个目录：${directory}`)
  }
  let root
  try {
    root = (await runGit(directory, ['rev-parse', '--show-toplevel'], {
      timeoutMs: LIMITS.statusTimeoutMs,
    }))
      .toString('utf8')
      .trim()
  } catch (error) {
    // `rev-parse` exits 128 outside a work tree; that is a state to report, not
    // a failure of the command.
    if (error instanceof GitError && error.code === 'git/failed') {
      throw new GitError('git/not-a-repo', '这个目录不在 git 仓库里', { path: directory })
    }
    throw error
  }
  if (!root) throw new GitError('git/not-a-repo', '这个目录不在 git 仓库里', { path: directory })
  return { directory, root }
}

/** One repository-relative path, as the phone sends it. */
function safePath(value, { required = true } = {}) {
  const path = String(value ?? '').trim()
  if (!path) {
    if (!required) return ''
    throw new GitError('git/bad-request', '缺少文件路径')
  }
  if (isAbsolute(path) || path.split('/').includes('..')) {
    throw new GitError('git/bad-request', `路径必须是仓库内的相对路径：${path}`)
  }
  return path
}

/** Whether this revision exists at all (a fresh repository has no HEAD). */
async function headExists(root) {
  try {
    await runGit(root, ['rev-parse', '--verify', 'HEAD'])
    return true
  } catch {
    return false
  }
}

// ── status ─────────────────────────────────────────────────────────────────

/**
 * `git status --porcelain=v2 -z --branch`.
 *
 * Version 2 with NUL separators, not the human format: it names the index and
 * worktree sides separately (so "staged" and "not staged" are facts, not
 * guesses), reports renames with both paths, and survives newlines in file
 * names — which the line-based format does not.
 */
export function parseStatus(buffer) {
  const records = buffer.toString('utf8').split('\0')
  const files = []
  let branch = { head: null, oid: null, upstream: null, ahead: 0, behind: 0, detached: false }

  for (let index = 0; index < records.length; index += 1) {
    const record = records[index]
    if (!record) continue
    if (record.startsWith('# branch.oid ')) {
      branch.oid = record.slice('# branch.oid '.length).trim()
      if (branch.oid === '(initial)') branch.oid = null
      continue
    }
    if (record.startsWith('# branch.head ')) {
      const head = record.slice('# branch.head '.length).trim()
      branch.detached = head === '(detached)'
      branch.head = branch.detached ? null : head
      continue
    }
    if (record.startsWith('# branch.upstream ')) {
      branch.upstream = record.slice('# branch.upstream '.length).trim()
      continue
    }
    if (record.startsWith('# branch.ab ')) {
      // `# branch.ab +2 -1`: the counters are the third and fourth fields.
      const parts = record.split(/\s+/)
      branch.ahead = Number(String(parts[2] ?? '').replace('+', '')) || 0
      branch.behind = Number(String(parts[3] ?? '').replace('-', '')) || 0
      continue
    }
    if (record.startsWith('1 ')) {
      const parts = record.split(' ')
      // 1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
      files.push(entry(parts[1], parts.slice(8).join(' '), null))
      continue
    }
    if (record.startsWith('2 ')) {
      const parts = record.split(' ')
      // 2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path>
      const path = parts.slice(9).join(' ')
      // The original path is the next NUL-separated field.
      const original = records[index + 1] ?? ''
      index += 1
      files.push(entry(parts[1], path, original))
      continue
    }
    if (record.startsWith('u ')) {
      const parts = record.split(' ')
      // u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>
      files.push({ ...entry(parts[1], parts.slice(10).join(' '), null), conflicted: true })
      continue
    }
    if (record.startsWith('? ')) {
      files.push({ path: record.slice(2), originalPath: null, index: '.', worktree: '?', kind: 'untracked', staged: false, unstaged: true, conflicted: false })
      continue
    }
  }
  return { branch, files }
}

function entry(xy, path, originalPath) {
  const index = xy?.[0] ?? '.'
  const worktree = xy?.[1] ?? '.'
  return {
    path,
    originalPath: originalPath || null,
    index,
    worktree,
    kind: kindOf(index, worktree),
    staged: index !== '.' && index !== '?',
    unstaged: worktree !== '.' && worktree !== '?',
    conflicted: false,
  }
}

function kindOf(index, worktree) {
  const code = worktree !== '.' ? worktree : index
  switch (code) {
    case 'A': return 'added'
    case 'D': return 'deleted'
    case 'R': return 'renamed'
    case 'C': return 'copied'
    case 'T': return 'typechange'
    case 'M': return 'modified'
    default: return 'modified'
  }
}

// ── log ────────────────────────────────────────────────────────────────────

const LOG_FORMAT = '%H%x1f%h%x1f%an%x1f%aI%x1f%s%x1f%D'

/** `git log -z --format=…`: one NUL-separated record per commit. */
export function parseLog(buffer) {
  return buffer
    .toString('utf8')
    .split('\0')
    .map((record) => record.replace(/^\n+/, ''))
    .filter((record) => record.trim())
    .map((record) => {
      const [sha, short, author, date, subject, refs] = record.split('\u001f')
      return {
        sha,
        short,
        author,
        date,
        subject,
        refs: refs ? refs.split(', ').filter(Boolean) : [],
      }
    })
}

// ── show ───────────────────────────────────────────────────────────────────

/**
 * `--numstat`: additions, deletions and path per file; `-` means binary.
 *
 * Called with `-z`, so records are NUL-separated and a path may contain
 * anything — including a newline. The `\n` fallback keeps the parser usable on
 * captured output that was not produced with `-z`.
 */
export function parseNumstat(buffer) {
  const text = buffer.toString('utf8')
  return text
    .split(text.includes('\0') ? '\0' : '\n')
    .filter((line) => line.trim())
    .map((line) => {
      const [added, deleted, ...rest] = line.split('\t')
      let path = rest.join('\t')
      // A rename shows as `old => new` (or `dir/{old => new}/file`).
      let originalPath = null
      const brace = /\{(.*?) => (.*?)\}/.exec(path)
      if (brace) {
        originalPath = path.replace(/\{(.*?) => (.*?)\}/, '$1')
        path = path.replace(/\{(.*?) => (.*?)\}/, '$2')
      } else if (path.includes(' => ')) {
        const [from, to] = path.split(' => ')
        originalPath = from
        path = to
      }
      return {
        path,
        originalPath,
        additions: added === '-' ? null : Number(added),
        deletions: deleted === '-' ? null : Number(deleted),
        binary: added === '-' && deleted === '-',
      }
    })
}

// ── the bridge ─────────────────────────────────────────────────────────────

export class GitBridge {
  #logger

  constructor(logger) {
    this.#logger = logger
  }

  /** Answers one reserved call. Throws `GitError` for the router to report. */
  async handle(method, args = {}) {
    switch (method) {
      case GIT_STATUS: return this.#status(args)
      case GIT_DIFF: return this.#diff(args)
      case GIT_LOG: return this.#log(args)
      case GIT_SHOW: return this.#show(args)
      case GIT_FILE: return this.#file(args)
      default: throw new GitError('git/bad-request', `未知的 git 调用：${method}`)
    }
  }

  async #status(args) {
    const { directory, root } = await repository(args.cwd)
    const buffer = await runGit(
      directory,
      ['status', '--porcelain=v2', '-z', '--branch', '--untracked-files=all'],
      { timeoutMs: LIMITS.statusTimeoutMs, maxBytes: LIMITS.statusBytes }
    )
    const parsed = parseStatus(buffer)
    this.#logger?.debug?.(`mobile-link: git status ${root} — ${parsed.files.length} 处改动`)
    return {
      root,
      insideWorkTree: true,
      hasHead: await headExists(root),
      branch: parsed.branch,
      files: parsed.files,
      truncated: buffer.length >= LIMITS.statusBytes,
    }
  }

  async #diff(args) {
    const { directory, root } = await repository(args.cwd)
    const path = safePath(args.path)
    const staged = args.staged === true
    // An untracked file has no baseline to diff against: `--no-index` against
    // /dev/null renders it as the pure addition it is. Exit code 1 is "there
    // were differences", which is the normal answer here.
    const untracked = await this.#isUntracked(directory, path)
    const argv = untracked
      ? ['diff', '--no-color', '--no-index', `--unified=${clampContext(args.context)}`, '--', '/dev/null', path]
      : ['diff', '--no-color', `--unified=${clampContext(args.context)}`, ...(staged ? ['--cached'] : []), '--', path]
    const buffer = await runGit(directory, argv, {
      maxBytes: LIMITS.diffBytes + 1024,
      okCodes: [0, 1],
    })
    const text = buffer.toString('utf8')
    const binary = /^Binary files .* differ$/m.test(text) || /^GIT binary patch$/m.test(text)
    return {
      root,
      path,
      staged,
      untracked,
      binary,
      text: binary ? '' : text.slice(0, LIMITS.diffBytes),
      truncated: !binary && buffer.length > LIMITS.diffBytes,
    }
  }

  async #isUntracked(directory, path) {
    const buffer = await runGit(directory, ['status', '--porcelain=v1', '-z', '--', path], {
      timeoutMs: LIMITS.statusTimeoutMs,
    })
    return buffer.toString('utf8').startsWith('?? ')
  }

  async #log(args) {
    const { directory, root } = await repository(args.cwd)
    if (!(await headExists(root))) {
      throw new GitError('git/no-commits', '这个仓库还没有任何提交', { root })
    }
    const page = Math.min(Math.max(Number(args.limit) || LIMITS.logPage, 1), 50)
    const skip = Math.max(Number(args.skip) || 0, 0)
    const buffer = await runGit(
      directory,
      ['log', '-z', `--max-count=${page + 1}`, `--skip=${skip}`, `--format=${LOG_FORMAT}`],
      { maxBytes: LIMITS.logBytes }
    )
    const all = parseLog(buffer)
    const hasMore = all.length > page
    return { root, commits: all.slice(0, page), hasMore, skip }
  }

  async #show(args) {
    const { directory, root } = await repository(args.cwd)
    const sha = String(args.sha ?? '').trim()
    if (!/^[0-9a-fA-F]{4,40}$/.test(sha)) {
      throw new GitError('git/bad-request', '需要一个提交号')
    }
    const path = safePath(args.path, { required: false })

    if (path) {
      const buffer = await runGit(
        directory,
        ['show', '--no-color', `--unified=${clampContext(args.context)}`, '--format=', sha, '--', path],
        { maxBytes: LIMITS.diffBytes + 1024, okCodes: [0, 1] }
      )
      const text = buffer.toString('utf8')
      const binary = /^Binary files .* differ$/m.test(text) || /^GIT binary patch$/m.test(text)
      return {
        root,
        sha,
        path,
        binary,
        text: binary ? '' : text.slice(0, LIMITS.diffBytes),
        truncated: !binary && buffer.length > LIMITS.diffBytes,
      }
    }

    const meta = parseLog(
      await runGit(directory, ['show', '-s', '-z', `--format=${LOG_FORMAT}`, sha], { okCodes: [0, 1] })
    )[0] ?? { sha }
    const files = parseNumstat(
      await runGit(directory, ['show', '--numstat', '--format=', '-z', sha], {
        maxBytes: LIMITS.statusBytes,
        okCodes: [0, 1],
      })
    )
    return { root, commit: meta, files }
  }

  async #file(args) {
    const { directory, root } = await repository(args.cwd)
    const sha = String(args.rev ?? args.sha ?? '').trim()
    if (!sha || !/^[0-9a-zA-Z._/^~-]{1,80}$/.test(sha)) {
      throw new GitError('git/bad-request', '需要一个版本号')
    }
    const path = safePath(args.path)
    const size = Number(
      (await runGit(directory, ['cat-file', '-s', `${sha}:${path}`], { okCodes: [0, 1] }))
        .toString('utf8')
        .trim()
    )
    if (Number.isFinite(size) && size > LIMITS.fileBytes) {
      throw new GitError('git/too-large', `这个版本的文件有 ${size} 字节，超过手机上直接打开的上限`, {
        bytes: size,
        limit: LIMITS.fileBytes,
      })
    }
    const buffer = await runGit(directory, ['show', `${sha}:${path}`], {
      maxBytes: LIMITS.fileBytes + 1024,
      okCodes: [0, 1],
    })
    return {
      root,
      rev: sha,
      path,
      bytes: buffer.length,
      data: buffer.toString('base64'),
    }
  }
}

function clampContext(value) {
  const context = Number(value)
  if (!Number.isFinite(context)) return 3
  return Math.min(Math.max(Math.trunc(context), 0), 10)
}
