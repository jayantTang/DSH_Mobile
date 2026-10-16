#!/usr/bin/env node
// check:module-boundaries —— 025 模块化重构的边界契约快闸（C1/C2/C5，纯文本级、离线、秒级）
//
// 判什么：
//  1. C2 禁 UI：DSHCore / DSHConnectionAPI / *Domain / DSHFoundation / DSHTestingSupport
//     的 Sources/** 出现 import SwiftUI|UIKit|AppKit 即判红。
//  2. C1 依赖方向：解析 Modules/Package.swift 中每个 target 的 dependencies，
//     与边界白名单比对；依赖了未声明的 target 名、或产生禁边（如 *Domain 依赖 *UI），判红。
//  3. C5 例外清单：BOUNDARY-EXCEPTIONS.md 每条必须有 位置/条款/原因/收敛 四字段；
//     例外数比上次记录上升也判红（例外只减不增）。
//
// 退出码：0 = 无未豁免发现；1 = 有；2 = 工具自身错误。
import { readFileSync, readdirSync, statSync, existsSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const modulesDir = path.join(root, 'ios/DSHMobile/Modules');
const pkgFile = path.join(modulesDir, 'Package.swift');
const exceptionsFile = path.join(modulesDir, 'BOUNDARY-EXCEPTIONS.md');
const stateFile = path.join(root, '.lanes/module-boundaries-count.json');

const issues = [];
const err = (m) => issues.push(m);

// C2 例外：BOUNDARY-EXCEPTIONS.md 第一列登记过的文件豁免
const c2ExemptFiles = new Set();
if (existsSync(exceptionsFile)) {
  const text = readFileSync(exceptionsFile, 'utf8');
  for (const line of text.split('\n')) {
    if (!line.trim().startsWith('|')) continue;
    const first = line.split('|')[1]?.trim() ?? '';
    if (first && !/位置|----/.test(first)) {
      // 取括号前的文件路径部分
      const m = first.match(/^(.*?\.swift)/);
      if (m) c2ExemptFiles.add(m[1]);
    }
  }
}

// ---------- 1. C2 禁 UI ----------
const noUI = new Set(['DSHCore', 'DSHConnectionAPI', 'DSHFoundation', 'DSHTestingSupport']);
// *Domain 目标（未来单元迁移后出现，规则先行）
function targetsUnder(srcDir) {
  const base = path.join(modulesDir, srcDir);
  if (!existsSync(base)) return [];
  return readdirSync(base, { withFileTypes: true }).filter(d => d.isDirectory()).map(d => d.name);
}
for (const t of targetsUnder('Sources')) if (/Domain$/.test(t)) noUI.add(t);

const UI_RE = /^\s*import\s+(SwiftUI|UIKit|AppKit)\b/m;
function scanDir(dir, label) {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) { scanDir(p, label); continue; }
    if (!p.endsWith('.swift')) continue;
    const text = readFileSync(p, 'utf8');
    if (UI_RE.test(text)) {
      const rel = path.relative(root, p);
      if (!c2ExemptFiles.has(path.resolve(rel)) && ![...c2ExemptFiles].some(f => rel.endsWith(f))) {
        err(`[C2] ${label}: 禁 UI import → ${rel}`);
      }
    }
  }
}
for (const t of noUI) {
  const d = path.join(modulesDir, 'Sources', t);
  if (existsSync(d)) scanDir(d, t);
}

// ---------- 2. C1 依赖白名单 ----------
// 允许的依赖边（from → 允许依赖集合；未匹配即判红）
const allow = [
  [/^DSHDesign$/, new Set(['DSHFoundation'])],
  [/^DSHCore$/, new Set(['DSHConnectionAPI', 'DSHFoundation', 'DSHKit', 'RelayKit'])],
  [/^(\w+)API$/, new Set(['DSHKit'])],
  [/^DSHFoundation$/, new Set()],
  [/^DSHTestingSupport$/, new Set(['DSHCore', 'DSHConnectionAPI', 'DSHKit', 'RelayKit', 'DSHFoundation'])],
  // Domain 层只许经 DSHConnectionAPI 协议拿连接能力；具体实现 ConnectionStore 只在
  // DSHConnectionDomain 自身与 App 装配层出现（026 FR-006 收紧）。
  [/^(\w+)Domain$/, new Set(['DSHCore', 'DSHConnectionAPI', 'DSHFoundation', 'DSHKit', 'RelayKit'])],
  // UI 允许跳级到 L3 协议层（DSHKit/RelayKit 的公开类型经 Domain 外露时 UI 直接引用）
  [/^(\w+)UI$/, new Set(['DSHDesign', 'DSHCore', 'DSHFoundation', 'DSHConnectionDomain', 'DSHKit', 'RelayKit'])],
  // 测试 target 自由依赖被测目标 + 辅助
  [/Tests$/, null],
];

const pkgText = readFileSync(pkgFile, 'utf8');
const depRe = /\.target\(\s*name:\s*"(\w+)"/g;
const declared = new Set();
let m;
while ((m = depRe.exec(pkgText))) declared.add(m[1]);

// 抓每个 target 块的 dependencies 列表（按括号配对粗解析）
const targetRe = /\.target\(\s*name:\s*"(\w+)",\s*dependencies:\s*\[([^\]]*)\]/gs;
const knownDeps = new Set([...declared, 'DSHKit', 'RelayKit']);
while ((m = targetRe.exec(pkgText))) {
  const [, name, depsRaw] = m;
  const deps = [...depsRaw.matchAll(/"(\w+)"/g)].map(x => x[1]);
  for (const d of deps) {
    if (!knownDeps.has(d)) err(`[C1] ${name}: 依赖了未声明的 target「${d}」`);
  }
  if (/Tests$/.test(name)) continue;
  const rule = allow.find(([re]) => re.test(name));
  if (!rule) { err(`[C1] ${name}: 该 target 没有边界白名单规则`); continue; }
  if (rule[1] === null) continue;
  for (const d of deps) {
    if (d === name) { err(`[C1] ${name}: 自依赖`); continue; }
    // 同单元 UI → 同单元 Domain：架构允许的配对边
    if (/UI$/.test(name) && d === name.replace(/UI$/, 'Domain')) continue;
    if (!rule[1].has(d)) err(`[C1] ${name} → ${d}: 禁止的依赖边`);
  }
}

// ---------- 2.5 C1 源码级：Sources/<Target> 里 import 了白名单外的本包 target 即判红 ----------
// （声明级检查拦不住「import 了但没声明」的越层，025 曾被这条漏过：Domain import 了 DSHDesign）
{
  const moduleTargets = targetsUnder('Sources');
  for (const t of moduleTargets) {
    const d = path.join(modulesDir, 'Sources', t);
    const rule = allow.find(([re]) => re.test(t));
    const allowed = rule?.[1] ?? null;
    for (const e of readdirSync(d, { withFileTypes: true })) {
      if (!e.isFile() || !e.name.endsWith('.swift')) continue;
      const p = path.join(d, e.name);
      const text = readFileSync(p, 'utf8');
      for (const m2 of text.matchAll(/^\s*(?:@_exported\s+)?import\s+(\w+)/gm)) {
        const dep = m2[1];
        if (!moduleTargets.includes(dep) && dep !== 'DSHKit' && dep !== 'RelayKit') continue;
        if (dep === t) continue;
        if (/UI$/.test(t) && dep === t.replace(/UI$/, 'Domain')) continue;
        if (allowed === null) continue;
        if (allowed && !allowed.has(dep)) err(`[C1] ${t}: 源码 import 白名单外模块「${dep}」→ ${path.relative(root, p)}`);
      }
    }
  }
}

// ---------- 2.6 C6 声明级：import 了谁就必须声明谁 ----------
// 源码 import 了本包的 target、而 `.target(dependencies:)` 里没有它，Debug 构建靠
// **传递依赖**照样能编过，Release 归档却会以 `Unable to find module dependency` 或
// `cannot find type` 失败——2026-10-16 实测：12 个 target 是这种状态，下一次发版必挂。
{
  const allTargets = [...targetsUnder('Sources'), ...targetsUnder('Tests')];
  const moduleNames = new Set([...allTargets, 'DSHKit', 'RelayKit']);
  const alias = { dshKit: 'DSHKit', relayKit: 'RelayKit' };
  const declaredDeps = new Map();
  const declRe = /\.(?:target|testTarget)\(\s*name:\s*"(\w+)"/g;
  while ((m = declRe.exec(pkgText))) {
    const name = m[1];
    const deps = new Set();
    const declEnd = m.index + m[0].length;
    const head = pkgText.slice(declEnd, declEnd + 400);
    const dm = /^\s*,\s*dependencies:\s*\[/.exec(head);
    if (dm) {
      const start = declEnd + dm[0].length - 1;
      let depth = 0;
      let end = -1;
      for (let i = start; i < pkgText.length; i += 1) {
        if (pkgText[i] === '[') depth += 1;
        else if (pkgText[i] === ']') { depth -= 1; if (depth === 0) { end = i; break; } }
      }
      if (end > start) {
        for (const t of pkgText.slice(start + 1, end)
          .matchAll(/"(\w+)"|\b(dshKit|relayKit)\b/g)) {
          const value = t[1] || alias[t[2]];
          if (value) deps.add(value);
        }
      }
    }
    declaredDeps.set(name, deps);
  }
  for (const t of allTargets) {
    const deps = declaredDeps.get(t);
    if (!deps) continue;
    const seen = new Set();
    const walk = (dir) => {
      for (const e of readdirSync(dir, { withFileTypes: true })) {
        const p = path.join(dir, e.name);
        if (e.isDirectory()) { walk(p); continue; }
        if (!e.name.endsWith('.swift')) continue;
        for (const m2 of readFileSync(p, 'utf8')
          .matchAll(/^\s*(?:@_exported\s+)?import\s+(\w+)/gm)) {
          const dep = m2[1];
          if (dep === t || !moduleNames.has(dep) || seen.has(dep)) continue;
          seen.add(dep);
          if (!deps.has(dep)) {
            err(`[C6] ${t}: 源码 import 了「${dep}」，Package.swift 却没声明这个依赖`
              + '（Debug 靠传递依赖能过，Release 归档必挂）');
          }
        }
      }
    };
    for (const dir of [path.join(modulesDir, 'Sources', t), path.join(modulesDir, 'Tests', t)]) {
      if (existsSync(dir)) walk(dir);
    }
  }
}

// ---------- 3. C5 例外清单 ----------
let exceptionCount = 0;
if (existsSync(exceptionsFile)) {
  const text = readFileSync(exceptionsFile, 'utf8');
  if (!/位置.*条款.*原因.*收敛/.test(text.replace(/\s+/g, ''))) {
    err('[C5] BOUNDARY-EXCEPTIONS.md 缺少四字段表头（位置/条款/原因/收敛）');
  }
  exceptionCount = text.split('\n')
    .filter(l => l.trim().startsWith('|'))
    .filter(l => !/^\|\s*[-—|:\s]+\|\s*$/.test(l.trim()))
    .map(l => (l.split('|')[1] ?? '').trim())
    .filter(cell => cell && !/位置|暂无/.test(cell))
    .length;
} else {
  err('[C5] 缺少 BOUNDARY-EXCEPTIONS.md');
}
try {
  if (existsSync(stateFile)) {
    const prev = JSON.parse(readFileSync(stateFile, 'utf8')).count ?? 0;
    if (exceptionCount > prev) err(`[C5] 例外数上升：${prev} → ${exceptionCount}（例外只减不增）`);
  }
} catch { /* 状态文件损坏不判红，下次重写 */ }
writeFileSync(stateFile, JSON.stringify({ count: exceptionCount, at: new Date().toISOString() }));

// ---------- 汇总 ----------
if (issues.length) {
  console.error(`✗ module boundaries: ${issues.length} 个问题`);
  for (const i of issues) console.error('  - ' + i);
  process.exit(1);
}
console.log(`✓ module boundaries clean（例外 ${exceptionCount} 条）`);
process.exit(0);
