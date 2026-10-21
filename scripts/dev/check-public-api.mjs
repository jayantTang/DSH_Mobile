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
const budgets = {
  symbols: 2200,
  declarations: 1665,
  types: 283,
};

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

const useSymbolGraph = spawnSync('swift', ['--version'], { encoding: 'utf8' }).status === 0;
if (useSymbolGraph) {
  const dump = spawnSync('swift', ['package', 'dump-symbol-graph', '--minimum-access-level', 'public'], {
    cwd: dshkit,
    encoding: 'utf8',
    timeout: 180_000,
  });
  if (dump.status === 0 && existsSync(out)) {
    const graph = JSON.parse(readFileSync(out, 'utf8'));
    const count = graph.symbols?.length ?? 0;
    if (count > budgets.symbols) {
      console.error(`✗ DSHKit 导出面超预算：${count} 个 symbol / 预算 ${budgets.symbols}`);
      process.exit(1);
    }
    console.log(`✓ DSHKit symbol surface ${count}/${budgets.symbols} exported symbols`);
    process.exit(0);
  }
}

const raw = rawCount();
if (raw.declarations > budgets.declarations || raw.types > budgets.types) {
  console.error(`✗ DSHKit 公开面超预算：${raw.declarations} 声明 / ${raw.types} 类型`);
  console.error(`  预算：${budgets.declarations} 声明 / ${budgets.types} 类型`);
  process.exit(1);
}
console.log(`✓ DSHKit public surface ${raw.declarations}/${budgets.declarations} declarations, ${raw.types}/${budgets.types} types (raw fallback)`);
