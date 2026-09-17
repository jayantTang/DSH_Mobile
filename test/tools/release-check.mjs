#!/usr/bin/env node
// Checks that the app still builds the way the phone gets it.
//
// The simulator build is not the shipping build: `#if DEBUG` regions differ, and
// a reference outside one of them compiles all day in Debug and fails the
// archive — which is exactly how a Release-only break reached a publish attempt.
// Run this before `deploy-ota.sh`:
//
//   ./test/run.sh release

import { execFileSync } from 'node:child_process'
import { existsSync } from 'node:fs'
import { join } from 'node:path'

import { PROJECT, log, warn } from './context.mjs'

const archive = join(PROJECT, '.build/release-check.xcarchive')
const SIGNING = join(PROJECT, 'Signing.local.plist')

/**
 * The developer team, which belongs to the developer and not to the repository.
 *
 * The archive is signed exactly like the OTA publish, so this has to resolve the
 * team the same way `scripts/release/deploy-ota.sh` does — the environment
 * first, then the gitignored local file. Without it the archive dies at
 * "requires a development team", which reads like a code break but is only a
 * missing local value.
 */
function teamId() {
  if (process.env.DSH_TEAM_ID) return process.env.DSH_TEAM_ID.trim()
  if (!existsSync(SIGNING)) return ''
  try {
    return execFileSync('plutil', ['-extract', 'teamID', 'raw', '-o', '-', SIGNING],
      { encoding: 'utf8' }).trim()
  } catch {
    return ''
  }
}

export default function releaseCheck() {
  const team = teamId()
  if (!team) {
    warn(`没有开发者团队 ID：写 ${SIGNING}（形如 { teamID = XXXXXXXXXX; }）或设 DSH_TEAM_ID，`
      + '否则 Release 归档无法签名——deploy-ota.sh 也需要它。')
  }
  log('Release / 真机编译（与发布同一条路）')
  try {
    execFileSync('xcodebuild', [
      '-project', join(PROJECT, 'DSHMobile.xcodeproj'), '-scheme', 'DSHMobile',
      '-configuration', 'Release', '-destination', 'generic/platform=iOS',
      '-archivePath', archive, '-allowProvisioningUpdates',
      ...(team ? [`DEVELOPMENT_TEAM=${team}`] : []),
      'archive',
    ], { stdio: 'pipe', encoding: 'utf8' })
    console.log('    归档成功')
  } catch (error) {
    const output = `${error.stdout ?? ''}${error.stderr ?? ''}`
    const errors = output.split('\n').filter((line) => line.includes('error:')).slice(0, 10)
    warn('Release 编译失败——发布前必须修掉：')
    for (const line of errors.length ? errors : ['（没抓到 error 行，请手动跑一次 xcodebuild）']) {
      console.error(`    ${line.trim()}`)
    }
    process.exit(1)
  }
}

// Also runnable on its own: `node test/tools/release-check.mjs`.
if (import.meta.url === `file://${process.argv[1]}`) releaseCheck()
