#!/usr/bin/env node
// check:project —— App 工程是否引用了 DSHMobile/ 与测试目录下的每个 .swift。
//
// 背景：App 工程由 XcodeGen 从 project.yml 生成（project.yml 是唯一事实来源）。
// 新增源文件后忘记跑 `xcodegen generate` 时，xcodebuild 会以
// "cannot find type ... in scope" 失败；这条在提交前先拦住。
//
// 只看文件引用是否齐全，不比较 UUID/顺序（生成器每次都会重排）。
//
// 退出码：0 = 齐全；1 = 有遗漏；2 = 工具自身错误。
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { basename, join, relative } from 'node:path';

const root = new URL('../..', import.meta.url).pathname;
const projectDir = join(root, 'ios/DSHMobile');
const pbxPath = join(projectDir, 'DSHMobile.xcodeproj/project.pbxproj');

if (!existsSync(pbxPath)) {
  console.error(`✗ 找不到 ${relative(root, pbxPath)}`);
  process.exit(2);
}

const pbx = readFileSync(pbxPath, 'utf8');
const sourceRoots = ['DSHMobile', 'DSHMobileTests', 'DSHMobileUITests'];
const missing = [];
let count = 0;

function walk(dir) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name === '.build' || entry.name === 'DerivedData') continue;
      walk(full);
      continue;
    }
    if (!entry.name.endsWith('.swift')) continue;
    count += 1;
    // XcodeGen 的 PBXFileReference 注释是 `/* File.swift */`，按 basename 判引用。
    if (!pbx.includes(`/* ${basename(full)} */`)) {
      missing.push(relative(root, full));
    }
  }
}

for (const dir of sourceRoots) {
  const full = join(projectDir, dir);
  if (existsSync(full)) walk(full);
}

if (missing.length) {
  console.error(`✗ project 缺少 ${missing.length} 个源文件引用：`);
  for (const file of missing) console.error(`  - ${file}`);
  console.error('\n修法：cd ios/DSHMobile && xcodegen generate');
  process.exit(1);
}

console.log(`✓ project references all ${count} app/test sources`);
