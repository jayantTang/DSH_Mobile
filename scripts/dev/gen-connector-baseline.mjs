#!/usr/bin/env node
/**
 * 把 `docs/relay-contract.json` 里的连接器版本基线生成成 Swift 常量。
 *
 *   npm run gen:connector-baseline
 *
 * 为什么需要生成：App 在设备上跑，读不到仓库里的 `docs/`。手抄一份必然漂，
 * 所以两处的一致性由 `check:contracts` 的第 ⑦ 段兜着——改了契约却没重跑这个，
 * 检查会红并提示重跑。
 */

import { readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..')
const TARGET = 'ios/DSHMobile/DSHMobile/Support/ConnectorBaseline.swift'

const contract = JSON.parse(readFileSync(join(REPO_ROOT, 'docs/relay-contract.json'), 'utf8'))
const version = contract.connectorBaseline?.minVersion
if (!version) throw new Error('docs/relay-contract.json 里没有 connectorBaseline.minVersion')

const swift = `// 由 \`npm run gen:connector-baseline\` 生成，不要手改。
// 来源：docs/relay-contract.json 的 connectorBaseline.minVersion
// 一致性：npm run check:contracts（第 ⑦ 段）

import Foundation

/// 连接器（电脑端 \`dsh-plugin-mobile-link\`）的版本基线。
///
/// 比的是 \`_link/hello\` 报上来的**连接器版本**（\`serverVersion\`），**不是** DSH host 版本：
/// 两者命名空间不同，混用会让提示条永不出现（基线远低于线上连接器）或天天误报。
/// 低于它的连接器连上来时，App 给一条可关闭的提示——只提示，不阻断连接。
/// 真值与理由写在 \`docs/relay-contract.json\`。
enum ConnectorBaseline {
    /// 这个版本及以上的连接器视为满足基线。
    static let minVersion = "${version}"
}
`

writeFileSync(join(REPO_ROOT, TARGET), swift)
console.log(`已生成 ${TARGET}（minVersion = ${version}）`)
