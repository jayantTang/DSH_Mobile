#!/usr/bin/env node
/**
 * 把 `docs/relay-contract.json` 里的 host 版本基线生成成 Swift 常量。
 *
 *   npm run gen:host-baseline
 *
 * 为什么需要生成：App 在设备上跑，读不到仓库里的 `docs/`。手抄一份必然漂，
 * 所以两处的一致性由 `check:contracts` 的第 ⑦ 段兜着——改了契约却没重跑这个，
 * 检查会红并提示重跑。
 */

import { readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..')
const TARGET = 'ios/DSHMobile/DSHMobile/Support/HostBaseline.swift'

const contract = JSON.parse(readFileSync(join(REPO_ROOT, 'docs/relay-contract.json'), 'utf8'))
const version = contract.hostBaseline?.dshVersion
if (!version) throw new Error('docs/relay-contract.json 里没有 hostBaseline.dshVersion')

const swift = `// 由 \`npm run gen:host-baseline\` 生成，不要手改。
// 来源：docs/relay-contract.json 的 hostBaseline.dshVersion
// 一致性：npm run check:contracts（第 ⑦ 段）

import Foundation

/// 主机（电脑端 DSH）的版本基线。
///
/// 低于它的主机连上来时，App 给一条可关闭的提示——**只提示，不阻断连接**。
/// 基线的真值与理由写在 \`docs/relay-contract.json\`。
enum HostBaseline {
    /// 这个版本及以上的主机视为满足基线。
    static let dshVersion = "${version}"
}
`

writeFileSync(join(REPO_ROOT, TARGET), swift)
console.log(`已生成 ${TARGET}（dshVersion = ${version}）`)
