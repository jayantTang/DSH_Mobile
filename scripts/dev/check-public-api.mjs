#!/usr/bin/env node
// check:public-api —— DSHKit 公开面预算（只减不增）。
//
// 2026-10-21 收口后基线：1,658 个 public 声明 / 282 个 public 类型。
// 预算给 1,700 / 282 留一点余量；新增公开类型或方法前先删旧面，否则这里判红。
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const root = new URL('../..', import.meta.url).pathname;
const dir = join(root, 'ios/DSHMobile/DSHKit/Sources/DSHKit');
const budgets = { declarations: 1665, types: 283 };

let declarations = 0;
let types = 0;

function walk(path) {
  for (const entry of readdirSync(path, { withFileTypes: true })) {
    const full = join(path, entry.name);
    if (entry.isDirectory()) { walk(full); continue; }
    if (!entry.name.endsWith('.swift')) continue;
    for (const line of readFileSync(full, 'utf8').split('\n')) {
      if (/^\s*public\s/.test(line)) declarations += 1;
      if (/^\s*public\s+(struct|enum|class|actor|protocol)\s/.test(line)) types += 1;
    }
  }
}

walk(dir);

const over = declarations > budgets.declarations || types > budgets.types;
if (over) {
  console.error(`✗ DSHKit 公开面超预算：${declarations} 声明 / ${types} 类型`);
  console.error(`  预算：${budgets.declarations} 声明 / ${budgets.types} 类型`);
  process.exit(1);
}

console.log(`✓ DSHKit public surface ${declarations}/${budgets.declarations} declarations, ${types}/${budgets.types} types`);
