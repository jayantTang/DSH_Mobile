/**
 * Locate the DSH installation, so this plugin can borrow modules DSH already
 * ships (`ws`) without vendoring them.
 *
 * There is no machine-specific path here: the anchors are derived, and
 * `DSH_INSTALL_DIR` overrides the whole ladder when DSH is installed somewhere
 * unusual.
 *
 *   1. `DSH_INSTALL_DIR`            explicit override
 *   2. this module                  when DSH loaded the plugin it is already
 *                                   inside DSH's dependency tree
 *   3. `$DSH_HOME/profiles/web/`    DSH's own profile directory
 *   4. `dsh` on `PATH`              walk up from the real executable to the
 *                                   package that owns it
 *   5. `npm root -g`                last resort
 *
 * The same ladder is duplicated in `plugins/mobile-link/test/` and
 * `docs/artifacts/samples/capture.mjs`: plugin packages must install standalone
 * (`package.json` ships only `lib/`), so a cross-package import is not an
 * option. Keep the three copies in step.
 */

import { execFileSync } from 'node:child_process'
import { existsSync, readFileSync, realpathSync } from 'node:fs'
import { createRequire } from 'node:module'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'

const DSH_PACKAGE = '@deepseek-ai/dsh'

function isDshPackage(dir) {
  const manifest = join(dir, 'package.json')
  if (!existsSync(manifest)) return false
  try {
    return JSON.parse(readFileSync(manifest, 'utf8')).name === DSH_PACKAGE
  } catch {
    return false
  }
}

/** Walk up from the `dsh` executable on PATH to the package that owns it. */
function anchorFromExecutable() {
  try {
    const bin = execFileSync('which', ['dsh'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim()
    if (!bin) return undefined
    let dir = dirname(realpathSync(bin))
    for (let depth = 0; depth < 6; depth += 1) {
      if (isDshPackage(dir)) return join(dir, 'package.json')
      const parent = dirname(dir)
      if (parent === dir) break
      dir = parent
    }
  } catch {
    /* not on PATH */
  }
  return undefined
}

function anchorFromNpmRoot() {
  try {
    const root = execFileSync('npm', ['root', '-g'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim()
    const dir = join(root, ...DSH_PACKAGE.split('/'))
    return isDshPackage(dir) ? join(dir, 'package.json') : undefined
  } catch {
    return undefined
  }
}

/** Anchors to hand to `createRequire`, best first. */
export function dshAnchors(selfUrl = import.meta.url) {
  const home = process.env.DSH_HOME || join(homedir(), '.dsh')
  return [
    process.env.DSH_INSTALL_DIR ? join(process.env.DSH_INSTALL_DIR, 'package.json') : undefined,
    selfUrl,
    join(home, 'profiles', 'web', 'package.json'),
    anchorFromExecutable(),
    anchorFromNpmRoot(),
  ].filter(Boolean)
}

/** Resolve `specifier` from the DSH installation, or `undefined` when absent. */
export function requireFromDsh(specifier, selfUrl) {
  for (const anchor of dshAnchors(selfUrl)) {
    try {
      return createRequire(anchor)(specifier)
    } catch {
      /* try the next anchor */
    }
  }
  return undefined
}
