#!/usr/bin/env node
// check:project —— App 工程是否按相对路径引用了每个源文件。
//
// App 工程由 XcodeGen 从 project.yml 生成。这里用 plutil 把 pbxproj 转成 JSON，
// 按 PBXGroup 的 path 递归拼出每个 PBXFileReference 的相对路径，再与磁盘比对：
//   - 磁盘有、工程没有：新增文件忘了 xcodegen；
//   - 工程有、磁盘没有：stale 引用。
// 没有 plutil 的环境（CI 文本任务）退回 basename 粗筛，并明确打印 fallback。
//
// 退出码：0 = 一致；1 = 有差异；2 = 工具自身错误。
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { basename, join, relative } from 'node:path';

const root = new URL('../..', import.meta.url).pathname;
const projectDir = join(root, 'ios/DSHMobile');
const pbxPath = join(projectDir, 'DSHMobile.xcodeproj/project.pbxproj');
const sourceRoots = ['DSHMobile', 'DSHMobileTests', 'DSHMobileUITests'];

if (!existsSync(pbxPath)) {
  console.error(`✗ 找不到 ${relative(root, pbxPath)}`);
  process.exit(2);
}

const actual = new Set();
for (const dir of sourceRoots) {
  const full = join(projectDir, dir);
  if (!existsSync(full)) continue;
  walk(full, (path) => {
    if (path.endsWith('.swift')) actual.add(relative(projectDir, path));
  });
}

function walk(dir, visit) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name === '.build' || entry.name === 'DerivedData') continue;
      walk(full, visit);
    } else {
      visit(full);
    }
  }
}

function collectFromPBX() {
  const converted = spawnSync('plutil', ['-convert', 'json', '-o', '-', pbxPath], { encoding: 'utf8' });
  if (converted.status !== 0) return null;
  const parsed = JSON.parse(converted.stdout);
  const objects = parsed.objects;
  const mainGroup = objects[parsed.rootObject]?.mainGroup;
  if (!mainGroup || !objects[mainGroup]) return null;

  const referenced = new Set();
  const visit = (id, prefix) => {
    const object = objects[id];
    if (!object) return;
    if (object.isa === 'PBXGroup' || object.isa === 'PBXVariantGroup') {
      const segment = object.path || object.name || '';
      const next = segment ? join(prefix, segment) : prefix;
      for (const child of object.children || []) visit(child, next);
      return;
    }
    if (object.isa !== 'PBXFileReference' || !object.path || !object.path.endsWith('.swift')) return;
    const path = object.sourceTree === 'SOURCE_ROOT' ? object.path : join(prefix, object.path);
    if (sourceRoots.some((rootName) => path === rootName || path.startsWith(`${rootName}/`))) {
      referenced.add(path);
    }
  };
  visit(mainGroup, '');
  return referenced;
}

const referenced = collectFromPBX();
if (!referenced) {
  // 无 plutil：退回 basename 粗筛，避免 CI 文本任务因缺工具直接红。
  const pbx = readFileSync(pbxPath, 'utf8');
  const missing = [...actual].filter((path) => !pbx.includes(`/* ${basename(path)} */`));
  if (missing.length) {
    console.error(`✗ project 缺少 ${missing.length} 个源文件引用（basename fallback）：`);
    for (const file of missing) console.error(`  - ${relative(root, join(projectDir, file))}`);
    console.error('\n修法：cd ios/DSHMobile && xcodegen generate');
    process.exit(1);
  }
  console.log(`✓ project references all ${actual.size} app/test sources (basename fallback)`);
  process.exit(0);
}

const missing = [...actual].filter((path) => !referenced.has(path));
const stale = [...referenced].filter((path) => !actual.has(path));
if (missing.length || stale.length) {
  if (missing.length) {
    console.error(`✗ project 缺少 ${missing.length} 个源文件引用：`);
    for (const file of missing) console.error(`  - ${relative(root, join(projectDir, file))}`);
  }
  if (stale.length) {
    console.error(`✗ project 有 ${stale.length} 个 stale 源文件引用：`);
    for (const file of stale) console.error(`  - ${relative(root, join(projectDir, file))}`);
  }
  console.error('\n修法：cd ios/DSHMobile && xcodegen generate');
  process.exit(1);
}

console.log(`✓ project references all ${actual.size} app/test sources by relative path`);
