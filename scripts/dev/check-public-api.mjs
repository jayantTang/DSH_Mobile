#!/usr/bin/env node
// check:public-api —— DSHKit 导出面预算（只减不增）。
//
// 优先用 SwiftPM 的 symbol graph（真实可 import 的符号，不含 internal 类型里的
// public 成员）；本机没有 Swift 工具链时退回 public 关键字粗筛，保证 CI 文本任务
// 仍能跑。symbol graph 基线见下方 budgets.symbols。
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

const root = new URL('../..', import.meta.url).pathname;
const dshkit = join(root, 'ios/DSHMobile/DSHKit');
const out = join(dshkit, '.build/out/symbolgraph/DSHKit.symbols.json');
// 2026-10-27 按实测更新（原 2200 / 1665 / 283）。本轮先把"上游零引用且不泄露给
// public 签名"的类型降级，公开面从 2425/1827/301 收到 2360/1785/286；剩下那批被
// public 协议签名或测试直接引用，降级要改签名，属单独的重构任务。
// 口径不变：只减不增，下次加公开面前先迁旧。
//
// 2026-11-15 owner 批准的唯一一次上调：图片原图变体（SR-02.11 / SR-02.07）新增
// `ImageOriginalMetadata` / `ImageOriginalLookup` / `ImageOriginalChunk` /
// `ImageCommitValue` / `ImageVariantUpload` 与 3 个 `ChatHosting` 方法，公开面
// 从 2360 增至 2412（+52）。这几件都是 `ChatHosting` 的签名依赖，迁不走；换成
// JSONValue 会破坏这一层的类型契约。`declarations` / `types` 两项未动，口径仍是
// 只减不增：下一次要加公开面，先迁出等价的旧 API。
const budgets = {
  symbols: 2412,
  declarations: 1785,
  types: 286,
};

/// 在 .build 下找 symbol graph：SwiftPM 的输出目录随版本变化，不能只看一个路径。
function findSymbolGraph(dir, name) {
  if (!existsSync(dir)) return null;
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      const found = findSymbolGraph(full, name);
      if (found) return found;
    } else if (entry.name === name) {
      return full;
    }
  }
  return null;
}

function rawCount() {
  const dir = join(dshkit, 'Sources/DSHKit');
  let declarations = 0;
  let types = 0;
  const walk = (path) => {
    for (const entry of readdirSync(path, { withFileTypes: true })) {
      const full = join(path, entry.name);
      if (entry.isDirectory()) { walk(full); continue; }
      if (!entry.name.endsWith('.swift')) continue;
      for (const line of readFileSync(full, 'utf8').split('\n')) {
        if (/^\s*public\s/.test(line)) declarations += 1;
        if (/^\s*public\s+(struct|enum|class|actor|protocol)\s/.test(line)) types += 1;
      }
    }
  };
  walk(dir);
  return { declarations, types };
}

const hasSwift = spawnSync('swift', ['--version'], { encoding: 'utf8' }).status === 0;
if (hasSwift) {
  const dump = spawnSync('swift', ['package', 'dump-symbol-graph', '--minimum-access-level', 'public'], {
    cwd: dshkit,
    encoding: 'utf8',
    timeout: 180_000,
  });
  // 有 Swift 就必须用 symbol graph：这条口径与真实可 import 的符号一致。
  // 生成失败时不再悄悄退回关键字粗筛——那会把口径问题伪装成预算超支。
  const graphPath = existsSync(out) ? out : findSymbolGraph(join(dshkit, '.build'), 'DSHKit.symbols.json');
  if (dump.status !== 0 || !graphPath) {
    console.error(`✗ 无法生成 symbol graph（exit ${dump.status}）`);
    console.error((dump.stderr || dump.error?.message || '').trim().slice(0, 2000));
    console.error('  先确认 `swift package dump-symbol-graph --minimum-access-level public` 能在本机跑通。');
    process.exit(1);
  }
  const graph = JSON.parse(readFileSync(graphPath, 'utf8'));
  const count = graph.symbols?.length ?? 0;
  if (count > budgets.symbols) {
    console.error(`✗ DSHKit 导出面超预算：${count} 个 symbol / 预算 ${budgets.symbols}`);
    console.error('  先迁出等价旧 API，再考虑调高预算；不要只为本需求加公开面。');
    process.exit(1);
  }
  console.log(`✓ DSHKit symbol surface ${count}/${budgets.symbols} exported symbols`);
  process.exit(0);
}

const raw = rawCount();
if (raw.declarations > budgets.declarations || raw.types > budgets.types) {
  console.error(`✗ DSHKit 公开面超预算：${raw.declarations} 声明 / ${raw.types} 类型`);
  console.error(`  预算：${budgets.declarations} 声明 / ${budgets.types} 类型`);
  process.exit(1);
}
console.log(`✓ DSHKit public surface ${raw.declarations}/${budgets.declarations} declarations, ${raw.types}/${budgets.types} types (raw fallback)`);
