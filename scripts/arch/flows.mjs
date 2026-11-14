#!/usr/bin/env node
/**
 * 流程视图的数据层：读 `scripts/arch/flows/*.json`，并**校验每一步指向的符号真的存在**。
 *
 * 为什么这层要有校验：流程图烂掉的原因从来不是画得不好，而是代码改了没人改图。
 * 只要每一步都绑定真实文件和符号，图一失效页面就会标红，维护成本才降得下来。
 *
 * 步骤字段：
 *   id      步骤 id（edges 用它连线）
 *   label   人看的步骤名
 *   file    仓库相对路径
 *   symbol  该文件里必须存在的类型名或函数名
 *   kind    ui / logic / net / store 之一，仅用于配色
 */

import { existsSync, readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'

import { ROOT } from './parse.mjs'

const FLOW_DIR = join(ROOT, 'scripts/arch/flows')

function readJson(path) {
  try {
    return JSON.parse(readFileSync(path, 'utf8'))
  } catch (error) {
    return { __error: error.message }
  }
}

/** 符号必须真的在该文件里出现；先查声明清单，再退回整文匹配。 */
function checkSymbol(fileId, symbol, declarations) {
  const abs = join(ROOT, fileId)
  if (!existsSync(abs)) return { ok: false, reason: `文件不存在：${fileId}` }
  if (!symbol) return { ok: true }
  const declaration = declarations[fileId]
  if (declaration) {
    const names = new Set([...declaration.types.map((type) => type.name), ...declaration.funcs.map((func) => func.name)])
    if (names.has(symbol)) return { ok: true }
  }
  const text = readFileSync(abs, 'utf8')
  const escaped = symbol.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  return new RegExp(`\\b${escaped}\\b`).test(text)
    ? { ok: true }
    : { ok: false, reason: `该文件里找不到符号 ${symbol}` }
}

function validateFlow(raw, fileName, declarations) {
  if (raw.__error) {
    return { id: fileName, title: fileName, description: `解析失败：${raw.__error}`, steps: [], edges: [] }
  }
  const steps = (raw.steps ?? []).map((step) => {
    const verdict = checkSymbol(step.file ?? '', step.symbol, declarations)
    return {
      id: step.id ?? step.label,
      label: step.label ?? step.id ?? '(未命名步骤)',
      file: step.file ?? '',
      symbol: step.symbol ?? '',
      kind: step.kind ?? 'logic',
      ok: verdict.ok,
      reason: verdict.reason ?? '',
    }
  })
  const ids = new Set(steps.map((step) => step.id))
  const edges = (raw.edges ?? []).filter((edge) => Array.isArray(edge) && ids.has(edge[0]) && ids.has(edge[1]))
  return {
    id: raw.id ?? fileName.replace(/\.json$/, ''),
    title: raw.title ?? raw.id ?? fileName,
    description: raw.description ?? '',
    steps,
    edges,
  }
}

/** 读全部流程定义；目录不存在就返回空数组（不报错，流程是可选层）。 */
export function loadFlows(declarations = {}) {
  if (!existsSync(FLOW_DIR)) return []
  return readdirSync(FLOW_DIR)
    .filter((name) => name.endsWith('.json'))
    .sort()
    .map((name) => validateFlow(readJson(join(FLOW_DIR, name)), name, declarations))
}
