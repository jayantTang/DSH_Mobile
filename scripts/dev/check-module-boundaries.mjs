#!/usr/bin/env node
// check:module-boundaries —— 模块边界契约快闸（C1/C2/C5/C6/C7，纯文本级、离线、秒级）
//
// 2026-10-21 起目录按“层 + 单元”重排，target 用显式 path:，本脚本改为**按路径判层**：
//
// 判什么：
//  C2 禁 UI：Foundation / Contracts / Core / Features/<U>/Domain / Testing/TestingSupport
//     里出现 import SwiftUI|UIKit|AppKit 即判红。
//  C1 依赖方向：解析 Package.swift 里每个 target 的 dependencies，按 path 归类到层，
//     与每层允许依赖比对；未声明 target、自依赖、跨单元依赖判红。
//  C6 声明一致：源码 import 了本包 target 却没写进 dependencies 判红
//     （Debug 靠传递依赖能过，Release 归档会挂）。
//  C7 路径覆盖：Modules/ 下每个 .swift 必须落在某个 target 的 path: 内；每个 path
//     必须存在且至少有一个 .swift。搬家后漏挂的文件不会被编译，必须由这条拦住。
//  C8 Domain 禁实现层类型：Features/<U>/Domain 的代码里不得直接出现
//     SessionPipeline / MessagePipeline / MessageStore / DSHClient / LinkCarrier；
//     这些只能出现在 DSHKit 内部或 Connection 适配器里。注释与字符串先 mask。
//  C9 生产 target 必须显式 Swift 6：包级默认是 v5，新 target 忘记写
//     swiftSettings: [.swiftLanguageMode(.v6)] 会静默退回 v5。
//  C5 例外清单：BOUNDARY-EXCEPTIONS.md 每条必须有 位置/条款/原因/收敛 四字段；
//     例外数比上次记录上升也判红（例外只减不增）。
//
// 退出码：0 = 无未豁免发现；1 = 有；2 = 工具自身错误。
import { readFileSync, readdirSync, existsSync, mkdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const modulesDir = path.join(root, 'ios/DSHMobile/Modules');
const pkgFile = path.join(modulesDir, 'Package.swift');
const exceptionsFile = path.join(modulesDir, 'BOUNDARY-EXCEPTIONS.md');
const stateFile = path.join(root, '.lanes/module-boundaries-count.json');

const issues = [];
const err = (m) => issues.push(m);

// ---------- 0. 解析 Package.swift（按括号配对取每个 target 块） ----------

function parseTargets(text) {
  const out = [];
  const re = /\.(target|testTarget)\s*\(/g;
  let m;
  while ((m = re.exec(text))) {
    const kind = m[1];
    const open = text.indexOf('(', re.lastIndex - 1);
    let depth = 0;
    let end = -1;
    for (let i = open; i < text.length; i += 1) {
      if (text[i] === '(') depth += 1;
      else if (text[i] === ')') {
        depth -= 1;
        if (depth === 0) { end = i; break; }
      }
    }
    if (end < 0) throw new Error(`Package.swift: target 块括号不配对（offset ${m.index}）`);
    const block = text.slice(open + 1, end);
    const name = block.match(/name:\s*"(\w+)"/)?.[1];
    const targetPath = block.match(/path:\s*"([^"]+)"/)?.[1];
    if (!name || !targetPath) throw new Error(`Package.swift: target 缺 name/path（${block.slice(0, 80)}）`);

    const deps = [];
    const depsAt = block.search(/dependencies:\s*\[/);
    if (depsAt >= 0) {
      const start = block.indexOf('[', depsAt);
      let d = 0;
      let depsEnd = -1;
      for (let i = start; i < block.length; i += 1) {
        if (block[i] === '[') d += 1;
        else if (block[i] === ']') {
          d -= 1;
          if (d === 0) { depsEnd = i; break; }
        }
      }
      if (depsEnd < 0) throw new Error(`Package.swift: ${name} 的 dependencies 括号不配对`);
      // 去掉 .product(...)：那是外部产品，不是本包 target。
      const cleaned = block.slice(start + 1, depsEnd).replace(/\.product\s*\([^)]*\)/gs, '');
      for (const x of cleaned.matchAll(/"(\w+)"|\b(dshKit|relayKit)\b/g)) {
        deps.push(x[1] ?? (x[2] === 'dshKit' ? 'DSHKit' : 'RelayKit'));
      }
    }
    const v6 = /swiftLanguageMode\(\.v6\)/.test(block);
    out.push({ kind, name, path: targetPath, deps, v6 });
  }
  return out;
}

const pkgText = readFileSync(pkgFile, 'utf8');
const targets = parseTargets(pkgText);
const byName = new Map(targets.map((t) => [t.name, t]));
const declared = new Set(targets.map((t) => t.name));
const knownDeps = new Set([...declared, 'DSHKit', 'RelayKit']);

// ---------- 1. 路径 → 层 ----------

const FEATURE_DOMAIN = /^Features\/([^/]+)\/Domain$/;
const FEATURE_UI = /^Features\/([^/]+)\/UI$/;

// 固定层目录：一张表，避免用 if-else 堆路径特例。
const FIXED_LAYER_BY_PATH = new Map([
  ['Foundation/Sources', 'foundation'],
  ['Design/Sources', 'design'],
  ['Contracts/Sources', 'contracts'],
  ['Core/Sources', 'core'],
  ['Testing/TestingSupport', 'testing'],
]);

// 单元层的两种子目录：单元名在路径里，层名由表给出。
const FEATURE_LAYERS = [
  [FEATURE_DOMAIN, 'feature-domain'],
  [FEATURE_UI, 'feature-ui'],
];

function layerOf(t) {
  const fixed = FIXED_LAYER_BY_PATH.get(t.path);
  if (fixed) return { layer: fixed };
  for (const [pattern, layer] of FEATURE_LAYERS) {
    const m = pattern.exec(t.path);
    if (m) return { layer, unit: m[1] };
  }
  return null;
}

const ALLOWED = {
  foundation: new Set(),
  design: new Set(['DSHFoundation']),
  contracts: new Set(['DSHKit']),
  core: new Set(['DSHConnectionAPI', 'DSHFoundation', 'DSHKit', 'RelayKit']),
  'feature-domain': new Set([
    'DSHCore', 'DSHConnectionAPI', 'DSHFoundation', 'DSHKit', 'RelayKit',
  ]),
  // UI 允许跳级到协议层（DSHKit/RelayKit 的公开类型经 Domain 外露），
  // 以及连接契约 DSHConnectionAPI（ConnectionEnv）；具体 ConnectionStore 只剩
  // 连接单元自己的 UI 与 PluginWebView 的 cookie 入口还在用。
  'feature-ui': new Set([
    'DSHDesign', 'DSHCore', 'DSHFoundation', 'DSHConnectionAPI',
    'DSHKit', 'RelayKit',
  ]),
  testing: new Set([
    'DSHCore', 'DSHConnectionAPI', 'DSHFoundation', 'DSHKit', 'RelayKit',
  ]),
};

// ---------- 2. C2 禁 UI ----------

const c2ExemptFiles = new Set();
if (existsSync(exceptionsFile)) {
  const text = readFileSync(exceptionsFile, 'utf8');
  for (const line of text.split('\n')) {
    if (!line.trim().startsWith('|')) continue;
    const first = line.split('|')[1]?.trim() ?? '';
    if (first && !/位置|----/.test(first)) {
      const m = first.match(/^(.*?\.swift)/);
      if (m) c2ExemptFiles.add(m[1]);
    }
  }
}

const UI_RE = /^\s*import\s+(SwiftUI|UIKit|AppKit)\b/m;

function walkSwift(dir, visit) {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) { walkSwift(p, visit); continue; }
    if (p.endsWith('.swift')) visit(p);
  }
}

for (const t of targets) {
  if (t.kind !== 'target') continue;
  const info = layerOf(t);
  if (!info) continue;
  if (!['foundation', 'contracts', 'core', 'feature-domain', 'testing'].includes(info.layer)) continue;
  const dir = path.join(modulesDir, t.path);
  if (!existsSync(dir)) continue;
  walkSwift(dir, (p) => {
    const rel = path.relative(root, p);
    const text = readFileSync(p, 'utf8');
    if (!UI_RE.test(text)) return;
    if ([...c2ExemptFiles].some((f) => rel.endsWith(f))) return;
    err(`[C2] ${t.name}: 禁 UI import → ${rel}`);
  });
}

// ---------- 3. C1 依赖方向 ----------

for (const t of targets) {
  for (const d of t.deps) {
    if (!knownDeps.has(d)) err(`[C1] ${t.name}: 依赖了未声明的 target「${d}」`);
  }
  if (t.kind === 'testTarget') continue;

  const info = layerOf(t);
  if (!info) { err(`[C1] ${t.name}: path「${t.path}」没有对应的层规则`); continue; }
  const allowed = ALLOWED[info.layer];
  for (const d of t.deps) {
    if (d === t.name) { err(`[C1] ${t.name}: 自依赖`); continue; }
    if (!allowed.has(d)) {
      // 同单元 UI → 同单元 Domain 是唯一的结构性配对边。
      if (info.layer === 'feature-ui' && d === `DSH${info.unit}Domain`) continue;
      err(`[C1] ${t.name} → ${d}: 禁止的依赖边（${info.layer}）`);
    }
  }
}

// ---------- 4. C6 源码 import 必须有声明 ----------

const moduleNames = new Set([...targets.map((t) => t.name), 'DSHKit', 'RelayKit']);
for (const t of targets) {
  const dir = path.join(modulesDir, t.path);
  if (!existsSync(dir)) continue;
  const seen = new Set();
  walkSwift(dir, (p) => {
    const text = readFileSync(p, 'utf8');
    for (const m of text.matchAll(/^\s*(?:@_exported\s+|@testable\s+)?import\s+(\w+)/gm)) {
      const dep = m[1];
      if (dep === t.name || !moduleNames.has(dep) || seen.has(dep)) continue;
      seen.add(dep);
      if (!t.deps.includes(dep)) {
        err(`[C6] ${t.name}: 源码 import 了「${dep}」，Package.swift 却没声明这个依赖`
          + '（Debug 靠传递依赖能过，Release 归档必挂）');
      }
    }
  });
}

// ---------- 5. C7 路径覆盖 ----------

const targetPaths = targets.map((t) => ({
  name: t.name,
  abs: path.resolve(modulesDir, t.path),
}));

for (const t of targets) {
  const dir = path.join(modulesDir, t.path);
  if (!existsSync(dir)) { err(`[C7] ${t.name}: path 不存在 → ${t.path}`); continue; }
  let count = 0;
  walkSwift(dir, () => { count += 1; });
  if (count === 0) err(`[C7] ${t.name}: path 下没有 .swift 文件 → ${t.path}`);
}

const moduleAbs = path.resolve(modulesDir);
const skipDirs = new Set(['.build', '.swiftpm']);
function walkAll(dir) {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    if (e.isDirectory()) {
      if (skipDirs.has(e.name)) continue;
      walkAll(path.join(dir, e.name));
      continue;
    }
    if (!e.name.endsWith('.swift')) continue;
    if (e.name === 'Package.swift') continue; // 包清单不是 target 源码
    const abs = path.resolve(dir, e.name);
    const rel = path.relative(root, abs);
    const owned = targetPaths.some(({ abs: base }) => abs === base || abs.startsWith(base + path.sep));
    if (!owned) err(`[C7] ${rel}: 不在任何 target 的 path 内（不会被编译）`);
  }
}
walkAll(moduleAbs);

// ---------- 5.5 C8 Domain 禁实现层类型 ----------

/** 把 Swift 注释与字符串抹成空格（保留换行与行号），只留代码做标识符匹配。 */
function maskSwift(text) {
  const blank = (segment) => segment.replace(/[^\n]/g, ' ');
  return text
    .replace(/"""[\s\S]*?"""/g, blank)
    .replace(/"(?:\\.|[^"\\\n])*"/g, blank)
    .replace(/\/\*[\s\S]*?\*\//g, blank)
    .replace(/\/\/[^\n]*/g, blank);
}

const IMPLEMENTATION_TYPES = [
  'SessionPipeline', 'MessagePipeline', 'MessageStore', 'DSHClient', 'LinkCarrier',
];

for (const t of targets) {
  if (!FEATURE_DOMAIN.test(t.path)) continue;
  // 连接单元是唯一被授权直接持实现层的适配器（LinkCarrier / DSHClient）。
  if (t.path === 'Features/Connection/Domain') continue;
  const dir = path.join(modulesDir, t.path);
  if (!existsSync(dir)) continue;
  walkSwift(dir, (p) => {
    const masked = maskSwift(readFileSync(p, 'utf8'));
    for (const name of IMPLEMENTATION_TYPES) {
      if (new RegExp(`\\b${name}\\b`).test(masked)) {
        err(`[C8] ${t.name}: Domain 直接引用实现层类型「${name}」→ ${path.relative(root, p)}`);
      }
    }
  });
}

// ---------- 5.6 C9 生产 target 必须 Swift 6 ----------

for (const t of targets) {
  if (t.kind !== 'target') continue;
  if (!t.v6) {
    err(`[C9] ${t.name}: 生产 target 未声明 swiftSettings: [.swiftLanguageMode(.v6)]`);
  }
}

// ---------- 6. C5 例外清单 ----------

let exceptionCount = 0;
if (existsSync(exceptionsFile)) {
  const text = readFileSync(exceptionsFile, 'utf8');
  if (!/位置.*条款.*原因.*收敛/.test(text.replace(/\s+/g, ''))) {
    err('[C5] BOUNDARY-EXCEPTIONS.md 缺少四字段表头（位置/条款/原因/收敛）');
  }
  exceptionCount = text.split('\n')
    .filter((l) => l.trim().startsWith('|'))
    .filter((l) => !/^\|\s*[-—|:\s]+\|\s*$/.test(l.trim()))
    .map((l) => (l.split('|')[1] ?? '').trim())
    .filter((cell) => cell && !/位置|暂无/.test(cell))
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
// `.lanes/` 是工具自己的产物目录，不入库；全新检出的目录（CI）里不存在，
// 写之前得自己建。少了这一步，检查器在公共 runner 上以 ENOENT 退出（run 40498565955）。
mkdirSync(path.dirname(stateFile), { recursive: true });
writeFileSync(stateFile, JSON.stringify({ count: exceptionCount, at: new Date().toISOString() }));

// ---------- 汇总 ----------

if (issues.length) {
  console.error(`✗ module boundaries: ${issues.length} 个问题`);
  for (const i of issues) console.error('  - ' + i);
  process.exit(1);
}
console.log(`✓ module boundaries clean（targets ${targets.length}，例外 ${exceptionCount} 条）`);
process.exit(0);
