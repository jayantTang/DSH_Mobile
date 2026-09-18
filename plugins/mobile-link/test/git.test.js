import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { mkdtempSync, mkdirSync, realpathSync, rmSync, writeFileSync, appendFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  GitBridge, GitError, GIT_STATUS, GIT_DIFF, GIT_LOG, GIT_SHOW, GIT_FILE, isGitMethod,
  parseStatus, parseLog, parseNumstat,
} from '../lib/git.js'

/** Runs git in a fixture repository, the way the bridge does. */
function git(cwd, argv) {
  return execFileSync('git', ['-C', cwd, '-c', 'core.quotepath=false', ...argv], {
    encoding: 'utf8',
    env: { ...process.env, GIT_TERMINAL_PROMPT: '0', GIT_OPTIONAL_LOCKS: '0', LC_ALL: 'C' },
  })
}

/** A throwaway repository with one commit and a mix of changes on top. */
function fixture() {
  const root = mkdtempSync(join(tmpdir(), 'dsh-git-'))
  git(root, ['init', '-q', '-b', 'main'])
  git(root, ['config', 'user.email', 'fixture@example.com'])
  git(root, ['config', 'user.name', 'Fixture'])
  writeFileSync(join(root, 'README.md'), '# fixture\n\n一句话。\n')
  mkdirSync(join(root, 'src'))
  writeFileSync(join(root, 'src', 'app.js'), 'export const one = 1\n')
  // A name with a space and a CJK character: the parsing has to survive both.
  writeFileSync(join(root, '说明 文档.md'), '原始内容\n')
  git(root, ['add', '-A'])
  git(root, ['commit', '-q', '-m', '初始提交'])
  return root
}

async function withFixture(body) {
  const root = fixture()
  try {
    // Awaited: dropping the directory in `finally` before an async body finished
    // deleted the repository out from under the assertions.
    return await body(root)
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
}

const bridge = () => new GitBridge({ debug() {}, info() {} })

test('isGitMethod claims only the reserved names', () => {
  for (const method of [GIT_STATUS, GIT_DIFF, GIT_LOG, GIT_SHOW, GIT_FILE]) {
    assert.ok(isGitMethod(method))
  }
  // Everything else must keep going to the Host as an ordinary RPC.
  assert.equal(isGitMethod('workspaceFiles/list'), false)
  assert.equal(isGitMethod('_link/fileBegin'), false)
  assert.equal(isGitMethod('_link/gitBlame'), false)
})

test('status reports branch, staged, unstaged, untracked and renames', async () => {
  await withFixture(async (root) => {
    appendFileSync(join(root, 'README.md'), '未暂存的改动\n')
    appendFileSync(join(root, 'src', 'app.js'), 'export const two = 2\n')
    git(root, ['add', 'src/app.js'])
    writeFileSync(join(root, '新文件 名.txt'), '未跟踪\n')
    git(root, ['mv', '说明 文档.md', '改名 文档.md'])

    const value = await bridge().handle(GIT_STATUS, { cwd: root })
    assert.equal(value.root, realpathSync(root))
    assert.equal(value.branch.head, 'main')
    assert.equal(value.hasHead, true)

    const byPath = new Map(value.files.map((file) => [file.path, file]))
    assert.equal(byPath.get('README.md').kind, 'modified')
    assert.equal(byPath.get('README.md').staged, false)
    assert.equal(byPath.get('src/app.js').staged, true, 'git add 之后应当算已暂存')
    assert.equal(byPath.get('新文件 名.txt').kind, 'untracked')
    const renamed = value.files.find((file) => file.kind === 'renamed')
    assert.ok(renamed, '重命名应当被识别')
    assert.equal(renamed.originalPath, '说明 文档.md')
    assert.equal(renamed.path, '改名 文档.md')
  })
})

test('status of a clean repository is empty, not an error', async () => {
  await withFixture(async (root) => {
    const value = await bridge().handle(GIT_STATUS, { cwd: root })
    assert.deepEqual(value.files, [])
    assert.equal(value.branch.head, 'main')
  })
})

test('a directory that is not a repository is refused with a code', async () => {
  const plain = mkdtempSync(join(tmpdir(), 'dsh-plain-'))
  try {
    await assert.rejects(
      () => bridge().handle(GIT_STATUS, { cwd: plain }),
      (error) => error instanceof GitError && error.code === 'git/not-a-repo'
    )
  } finally {
    rmSync(plain, { recursive: true, force: true })
  }
})

test('a subdirectory works and still reports repository-relative paths', async () => {
  await withFixture(async (root) => {
    appendFileSync(join(root, 'src', 'app.js'), '// 改一下\n')
    const value = await bridge().handle(GIT_STATUS, { cwd: join(root, 'src') })
    // `realpathSync`: on macOS /var is a symlink to /private/var and git reports
    // the resolved path.
    assert.equal(value.root, realpathSync(root))
    assert.deepEqual(value.files.map((file) => file.path), ['src/app.js'])
  })
})

test('a relative or missing working directory is refused', async () => {
  await assert.rejects(
    () => bridge().handle(GIT_STATUS, { cwd: 'relative/path' }),
    (error) => error.code === 'git/bad-request'
  )
  await assert.rejects(
    () => bridge().handle(GIT_STATUS, { cwd: '/definitely/not/here' }),
    (error) => error.code === 'git/not-found'
  )
})

test('diff shows the change, and an untracked file as an addition', async () => {
  await withFixture(async (root) => {
    appendFileSync(join(root, 'README.md'), '新增的一行\n')
    const tracked = await bridge().handle(GIT_DIFF, { cwd: root, path: 'README.md' })
    assert.equal(tracked.untracked, false)
    assert.match(tracked.text, /\+新增的一行/)
    assert.match(tracked.text, /^@@/m)
    assert.equal(tracked.truncated, false)

    writeFileSync(join(root, 'notes.txt'), '第一行\n第二行\n')
    const untracked = await bridge().handle(GIT_DIFF, { cwd: root, path: 'notes.txt' })
    assert.equal(untracked.untracked, true)
    assert.match(untracked.text, /\+第一行/)
  })
})

test('diff of a staged file can be asked for separately', async () => {
  await withFixture(async (root) => {
    appendFileSync(join(root, 'README.md'), '暂存的内容\n')
    git(root, ['add', 'README.md'])
    const unstaged = await bridge().handle(GIT_DIFF, { cwd: root, path: 'README.md' })
    assert.equal(unstaged.text.trim(), '', '已暂存的改动不该出现在未暂存差异里')
    const staged = await bridge().handle(GIT_DIFF, { cwd: root, path: 'README.md', staged: true })
    assert.match(staged.text, /\+暂存的内容/)
  })
})

test('diff refuses a path outside the repository', async () => {
  await withFixture(async (root) => {
    for (const path of ['/etc/hosts', '../outside.txt']) {
      await assert.rejects(
        () => bridge().handle(GIT_DIFF, { cwd: root, path }),
        (error) => error.code === 'git/bad-request',
        `${path} 应当被拒绝`
      )
    }
  })
})

test('a binary change is reported as binary, not as mojibake', async () => {
  await withFixture(async (root) => {
    writeFileSync(join(root, 'blob.bin'), Buffer.from([0, 1, 2, 3, 0, 255]))
    git(root, ['add', 'blob.bin'])
    git(root, ['commit', '-q', '-m', '加一个二进制文件'])
    writeFileSync(join(root, 'blob.bin'), Buffer.from([0, 9, 9, 9, 0, 254]))
    const value = await bridge().handle(GIT_DIFF, { cwd: root, path: 'blob.bin' })
    assert.equal(value.binary, true)
    assert.equal(value.text, '')
  })
})

test('log pages backwards, newest first, and says when there is more', async () => {
  await withFixture(async (root) => {
    for (let index = 1; index <= 4; index += 1) {
      appendFileSync(join(root, 'README.md'), `第 ${index} 次\n`)
      git(root, ['add', '-A'])
      git(root, ['commit', '-q', '-m', `提交 ${index}`])
    }

    const first = await bridge().handle(GIT_LOG, { cwd: root, limit: 2 })
    assert.deepEqual(first.commits.map((commit) => commit.subject), ['提交 4', '提交 3'])
    assert.equal(first.hasMore, true)
    assert.equal(first.commits[0].sha.length, 40)
    assert.equal(first.commits[0].author, 'Fixture')
    assert.match(first.commits[0].date, /^\d{4}-\d{2}-\d{2}T/)

    const second = await bridge().handle(GIT_LOG, { cwd: root, limit: 2, skip: 2 })
    assert.deepEqual(second.commits.map((commit) => commit.subject), ['提交 2', '提交 1'])
    assert.equal(second.hasMore, true, '后面还有「初始提交」')

    const third = await bridge().handle(GIT_LOG, { cwd: root, limit: 2, skip: 4 })
    assert.deepEqual(third.commits.map((commit) => commit.subject), ['初始提交'])
    assert.equal(third.hasMore, false)
  })
})

test('a repository without commits answers with a code, not a stack trace', async () => {
  const root = mkdtempSync(join(tmpdir(), 'dsh-empty-'))
  try {
    git(root, ['init', '-q', '-b', 'main'])
    await assert.rejects(
      () => bridge().handle(GIT_LOG, { cwd: root }),
      (error) => error.code === 'git/no-commits'
    )
    // Status still works: an empty repository is a legitimate thing to look at.
    const value = await bridge().handle(GIT_STATUS, { cwd: root })
    assert.equal(value.hasHead, false)
    assert.equal(value.branch.head, 'main')
  } finally {
    rmSync(root, { recursive: true, force: true })
  }
})

test('show returns one commit with its file list', async () => {
  await withFixture(async (root) => {
    appendFileSync(join(root, 'README.md'), '第二次提交的内容\n')
    git(root, ['add', '-A'])
    git(root, ['commit', '-q', '-m', '第二次提交'])
    const head = git(root, ['rev-parse', 'HEAD']).trim()

    const detail = await bridge().handle(GIT_SHOW, { cwd: root, sha: head.slice(0, 7) })
    assert.equal(detail.commit.subject, '第二次提交')
    assert.equal(detail.files.length, 1)
    assert.equal(detail.files[0].path, 'README.md')
    assert.equal(detail.files[0].additions, 1)
    assert.equal(detail.files[0].deletions, 0)

    const patch = await bridge().handle(GIT_SHOW, { cwd: root, sha: head, path: 'README.md' })
    assert.match(patch.text, /\+第二次提交的内容/)
  })
})

test('a file at an older revision is readable byte for byte', async () => {
  await withFixture(async (root) => {
    const first = git(root, ['rev-parse', 'HEAD']).trim()
    appendFileSync(join(root, 'README.md'), '之后加的\n')
    git(root, ['add', '-A'])
    git(root, ['commit', '-q', '-m', '再加一行'])

    const value = await bridge().handle(GIT_FILE, { cwd: root, rev: first.slice(0, 7), path: 'README.md' })
    const text = Buffer.from(value.data, 'base64').toString('utf8')
    assert.equal(text, '# fixture\n\n一句话。\n')
    assert.equal(value.bytes, Buffer.byteLength(text))
    assert.equal(value.rev, first.slice(0, 7))
  })
})

test('parsers survive NUL records, unicode paths and renames in numstat', () => {
  const status = Buffer.from(
    '# branch.oid abc\0# branch.head main\0# branch.ab +2 -1\0' +
    '1 M. N... 100644 100644 100644 aaa bbb src/app.js\0' +
    '2 R. N... 100644 100644 100644 aaa bbb R100 改名 文档.md\0说明 文档.md\0' +
    '? 未跟踪.txt\0',
    'utf8'
  )
  const parsed = parseStatus(status)
  assert.deepEqual(parsed.branch, { head: 'main', oid: 'abc', upstream: null, ahead: 2, behind: 1, detached: false })
  assert.equal(parsed.files.length, 3)
  assert.equal(parsed.files[0].path, 'src/app.js')
  assert.equal(parsed.files[0].staged, true)
  assert.equal(parsed.files[0].unstaged, false)
  assert.equal(parsed.files[1].originalPath, '说明 文档.md')
  assert.equal(parsed.files[2].kind, 'untracked')

  const log = parseLog(Buffer.from('sha1\u001fabc1234\u001f张三\u001f2026-09-18T10:00:00+08:00\u001f第一个提交\u001fHEAD -> main\0', 'utf8'))
  assert.deepEqual(log[0], {
    sha: 'sha1', short: 'abc1234', author: '张三',
    date: '2026-09-18T10:00:00+08:00', subject: '第一个提交', refs: ['HEAD -> main'],
  })

  const numstat = parseNumstat(Buffer.from('3\t1\tsrc/app.js\n-\t-\t图片.png\n2\t0\tdir/{old => new}/file.js\n', 'utf8'))
  assert.deepEqual(numstat[0], { path: 'src/app.js', originalPath: null, additions: 3, deletions: 1, binary: false })
  assert.equal(numstat[1].binary, true)
  assert.equal(numstat[2].path, 'dir/new/file.js')
  assert.equal(numstat[2].originalPath, 'dir/old/file.js')
})
