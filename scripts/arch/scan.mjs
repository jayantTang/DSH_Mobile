#!/usr/bin/env node
/**
 * 架构快照扫描器：**只读**，不改仓库、不加依赖。
 *
 *   node scripts/arch/scan.mjs           # 打印模块清单
 *   node scripts/arch/scan.mjs --json    # 打印完整结果（调试用）
 *
 * 产出统一的 { meta, nodes, edges, externals, cycles }，交给 render.mjs 渲染。
 * 边分三档，页面上要能看出差别：
 *   - authoritative：SPM target 依赖、Swift `import` 自有模块、JS/Python 的相对 import
 *   - heuristic    ：Swift 跨目录的类型引用（靠类型名匹配，会漏会误）
 *   - external     ：系统框架与第三方包，只统计不画图
 *
 * 解析函数在 parse.mjs，本文只负责"怎么分组、怎么连边"。
 */

import { existsSync, readFileSync } from 'node:fs'
import { extname, join } from 'node:path'

import { buildFileLayer } from './files.mjs'
import {
  ROOT, walk, dirsIn, rel, countLines, parseSwift, parseJs, parsePy,
  swiftUsesType, swiftShadowsName, SWIFT_TYPE_STOPLIST, swiftPackageTargets,
  resolveJsSpecifier, groupOfFile, tarjan, gitCommit, gitBranch, gitDirty,
} from './parse.mjs'

export { ROOT }

/**
 * 部署角色：模块图按这个分带，而不是按语言。
 * 语言（Swift / JS / Python）是实现细节，看架构时要先能分清
 * 「手机侧 / 中转 / 电脑侧 DSH / 仓库自身工具」这四块。
 */
const BANDS = [
  {
    id: 'ios',
    label: 'iOS 侧（iPhone App）',
    match: (id) => id.startsWith('ios/'),
    // 子块顺序就是纵向层序：上面的依赖下面的，读图自上而下即依赖方向
    sections: [
      { id: 'ios-shell', label: 'App 壳与装配（组合根）', match: (id) => id.startsWith('ios/app/') },
      { id: 'ios-ui', label: 'Feature UI 层', match: (id) => id.startsWith('ios/mod/') && /UI$/.test(id) },
      { id: 'ios-domain', label: 'Domain 层（业务规则，禁 UI）', match: (id) => id.startsWith('ios/mod/') && /Domain|API$/.test(id) },
      { id: 'ios-shared', label: 'Core / Design / Foundation / 测试支撑', match: (id) => id.startsWith('ios/mod/') },
      { id: 'ios-relaykit', label: '中转客户端（RelayKit）', match: (id) => id === 'ios/kit/RelayKit' },
      { id: 'ios-protocol', label: '协议与数据层（DSHKit）', match: (id) => id === 'ios/kit/DSHKit' },
    ],
  },
  {
    id: 'dsh',
    label: '电脑侧 DSH',
    match: (id) => id.startsWith('plugin/') || id.startsWith('skill/') || id.startsWith('sidecar/'),
    sections: [
      { id: 'connector', label: '连接器', match: (id) => id === 'plugin/mobile-link' },
      { id: 'plugin', label: '其它插件', match: (id) => id.startsWith('plugin/') },
      { id: 'skill', label: '技能', match: (id) => id.startsWith('skill/') },
      { id: 'sidecar', label: 'sidecar 服务（独立进程）', match: (id) => id.startsWith('sidecar/') },
    ],
  },
  { id: 'repo', label: '仓库工程（不进产品链路）', match: () => true, sections: [] },
]

/** 一个模块属于哪个大带、带内哪个子块；子块匹配不上时归到带本身。 */
function bandOf(groupId) {
  const band = BANDS.find((item) => item.match(groupId))
  if (!band) return { band: 'repo', section: 'repo', role: 'repo' }
  const section = band.sections.find((item) => item.match(groupId))
  // role 就是子块 id：页面按它上色、标短标签，同一大带里的不同子块要有区别
  const role = section ? section.id : band.id
  return { band: band.id, section: role, role }
}

/** 定义分组：每个分组是一个人能叫出名字的架构单元。 */
function defineGroups() {
  const groups = []
  const add = (id, layer, absDir, note) => {
    if (existsSync(absDir)) groups.push({ id, layer, dir: rel(absDir), abs: absDir, note })
  }

  // iOS App target：Features 下逐个子目录分组，其余顶层目录各自成组
  const appRoot = join(ROOT, 'ios/DSHMobile/DSHMobile')
  const NOT_A_UNIT = new Set(['Features', 'Assets.xcassets', 'zh-Hans.lproj', 'en.lproj'])
  for (const name of dirsIn(appRoot)) {
    if (name === 'Features') {
      for (const feature of dirsIn(join(appRoot, 'Features'))) {
        add(`ios/app/Features/${feature}`, 'ios-app', join(appRoot, 'Features', feature))
      }
    } else if (!NOT_A_UNIT.has(name)) {
      add(`ios/app/${name}`, 'ios-app', join(appRoot, name))
    }
  }

  // iOS SPM 包：按 target 目录分组（权威边界）
  const kitRoot = join(ROOT, 'ios/DSHMobile/DSHKit/Sources')
  for (const target of dirsIn(kitRoot)) add(`ios/kit/${target}`, 'ios-kit', join(kitRoot, target))

  // Modules 本地包（2026-10 层/单元目录重排）：target 用显式 path:，
  // 分组名仍取 target 名（import 名），路径从 Package.swift 读，不能再假设 Sources/<Target>。
  const modulesRoot = join(ROOT, 'ios/DSHMobile/Modules')
  const modulesPkg = readFileSync(join(modulesRoot, 'Package.swift'), 'utf8')
  for (const m of modulesPkg.matchAll(/\.target\(\s*name:\s*"(\w+)"[\s\S]*?path:\s*"([^"]+)"/g)) {
    add(`ios/mod/${m[1]}`, 'ios-mod', join(modulesRoot, m[2]))
  }

  for (const name of dirsIn(join(ROOT, 'plugins'))) add(`plugin/${name}`, 'js', join(ROOT, 'plugins', name))
  for (const name of dirsIn(join(ROOT, 'scripts'))) add(`scripts/${name}`, 'js', join(ROOT, 'scripts', name))

  for (const name of dirsIn(join(ROOT, 'sidecars'))) add(`sidecar/${name}`, 'py', join(ROOT, 'sidecars', name))
  for (const name of dirsIn(join(ROOT, 'skills'))) add(`skill/${name}`, 'py', join(ROOT, 'skills', name))
  add('test/tools', 'py', join(ROOT, 'test/tools'))

  return groups
}

/**
 * 建"类型名 → 唯一声明它的分组"索引。
 * 多处分组同名的一律放弃，避免把泛用名当依赖；只认真正声明过的名字，
 * 不认 `extension UIColor` 这种对外部类型的扩展。
 */
function buildSwiftTypeIndex(groups) {
  const owners = new Map()
  for (const group of groups) {
    if (group.layer !== 'ios-app' && group.layer !== 'ios-kit') continue
    group.types = new Set()
    group.declared = new Set()
    for (const abs of walk(group.abs)) {
      if (extname(abs) !== '.swift') continue
      const parsed = parseSwift(abs)
      for (const [target, names] of [[group.types, parsed.types], [group.declared, parsed.declared]]) {
        for (const name of names) {
          if (!SWIFT_TYPE_STOPLIST.has(name) && name.length >= 4) target.add(name)
        }
      }
    }
    for (const name of group.declared) {
      if (!owners.has(name)) owners.set(name, new Set())
      owners.get(name).add(group.id)
    }
  }
  const unique = new Map()
  for (const [name, ids] of owners) if (ids.size === 1) unique.set(name, [...ids][0])
  return unique
}

/** 边集合：同一条边重复出现时合并计数、保留样例，权威边优先于启发式边。 */
class EdgeBag {
  constructor() {
    this.map = new Map()
  }

  add(from, to, kind, detail) {
    if (!from || !to || from === to) return
    const key = `${from}->${to}`
    const edge = this.map.get(key) ?? { from, to, kind, count: 0, samples: new Set() }
    if (kind === 'authoritative') edge.kind = kind
    edge.count += 1
    if (detail) edge.samples.add(detail)
    this.map.set(key, edge)
  }

  delete(key) {
    this.map.delete(key)
  }

  entries() {
    return [...this.map.entries()]
  }

  values() {
    return [...this.map.values()]
  }
}

/** 每个分组的规模与 import 清单。 */
function collectNodes(groups, nodes) {
  for (const group of groups) {
    const files = walk(group.abs)
    let lines = 0
    const swiftImports = new Set()
    const pyModules = new Set()
    for (const abs of files) {
      lines += countLines(abs)
      const ext = extname(abs)
      if (ext === '.swift') for (const name of parseSwift(abs).imports) swiftImports.add(name)
      else if (ext === '.py') for (const name of parsePy(abs).modules) pyModules.add(name)
    }
    nodes.set(group.id, {
      id: group.id,
      ...bandOf(group.id),
      layer: group.layer,
      dir: group.dir,
      note: group.note ?? '',
      files: files.length,
      lines,
      types: group.types ? group.types.size : 0,
      swiftImports: [...swiftImports].sort(),
      pyModules: [...pyModules].sort(),
    })
  }
  // 空目录（只有 SKILL.md / README 之类的）没有代码可连，不进图，但要如实记下来，
  // 否则"技能是不是漏了"这种问题只能靠人猜。
  const empty = []
  for (const [id, node] of [...nodes]) {
    if (node.files === 0) { empty.push(id); nodes.delete(id) }
  }
  return empty
}

function dropEmpty(groups, nodes) {
  for (let i = groups.length - 1; i >= 0; i -= 1) if (!nodes.has(groups[i].id)) groups.splice(i, 1)
}

/**
 * 空目录（只有 markdown 之类的）不构成架构单元
 * @deprecated 见 collectNodes 返回值
 */
function unusedLegacy() {
  for (const [, node] of []) void node
  for (let i = groups.length - 1; i >= 0; i -= 1) if (!nodes.has(groups[i].id)) groups.splice(i, 1)
}

/** iOS App → kit 模块：`import DSHKit` 是权威边界，其余 import 记进外部依赖。 */
function addSwiftImportEdges(groups, nodes, edges, externals) {
  // SPM target 名（Modules 包 + DSHKit 包）到分组的映射：import 名就是 target 名
  const byModule = new Map()
  for (const group of groups) {
    if (group.layer === 'ios-mod' || group.layer === 'ios-kit') {
      byModule.set(group.id.split('/').pop(), group.id)
    }
  }
  for (const group of groups) {
    if (group.layer !== 'ios-app' && group.layer !== 'ios-mod') continue
    for (const name of nodes.get(group.id).swiftImports) {
      const target = byModule.get(name)
      if (target) edges.add(group.id, target, 'authoritative', `import ${name}`)
      else externals.set(`ios-app|${name}`, (externals.get(`ios-app|${name}`) ?? 0) + 1)
    }
  }
}

/** Swift App / kit 内部的跨目录类型引用：启发式，样例里带上具体类型名供人工判断。 */
function addHeuristicEdges(groups, edges, typeIndex) {
  for (const group of groups) {
    if (group.layer !== 'ios-app' && group.layer !== 'ios-kit') continue
    const referenced = new Map()
    for (const abs of walk(group.abs)) {
      if (extname(abs) !== '.swift') continue
      const { code } = parseSwift(abs)
      for (const [typeName, ownerId] of typeIndex) {
        if (ownerId === group.id || swiftShadowsName(code, typeName)) continue
        if (!swiftUsesType(code, typeName)) continue
        if (!referenced.has(ownerId)) referenced.set(ownerId, new Set())
        referenced.get(ownerId).add(typeName)
      }
    }
    for (const [ownerId, names] of referenced) {
      const list = [...names].sort()
      edges.add(group.id, ownerId, 'heuristic', `${list.length} 个类型：${list.slice(0, 5).join(', ')}${list.length > 5 ? ' …' : ''}`)
    }
  }
}

/** SPM target 依赖：权威，来自 `swift package describe`。 */
function addSpmEdges(nodes, edges, spm) {
  for (const target of spm.targets) {
    if (target.isTest) continue
    for (const dep of target.deps) {
      const from = `ios/kit/${target.name}`
      const to = `ios/kit/${dep}`
      if (nodes.has(from) && nodes.has(to)) edges.add(from, to, 'authoritative', 'SPM target 依赖')
    }
  }
}

/** JS：解析相对 import 落到哪个分组；裸说明符记成外部依赖。 */
function addJsEdges(groups, edges, externals) {
  for (const group of groups) {
    if (group.layer !== 'js') continue
    for (const abs of walk(group.abs)) {
      if (!['.js', '.mjs', '.cjs'].includes(extname(abs))) continue
      for (const specifier of parseJs(abs).specifiers) {
        const resolved = resolveJsSpecifier(specifier, abs)
        if (!resolved) {
          if (!specifier.startsWith('.')) {
            const name = specifier.replace(/^node:/, '')
            externals.set(`js|${name}`, (externals.get(`js|${name}`) ?? 0) + 1)
          }
          continue
        }
        const target = groupOfFile(resolved, groups)
        if (target && target.id !== group.id) edges.add(group.id, target.id, 'authoritative', specifier)
      }
    }
  }
}

/** Python：按模块名映射到分组（relay 是扁平模块布局，够用）。 */
function addPyEdges(groups, edges, nodes, externals) {
  const pyByModule = new Map()
  for (const group of groups) {
    if (group.layer !== 'py') continue
    for (const abs of walk(group.abs)) {
      if (extname(abs) !== '.py') continue
      const name = abs.endsWith('__init__.py') ? abs.split('/').slice(-2)[0] : abs.split('/').pop().replace(/\.py$/, '')
      pyByModule.set(name, group.id)
    }
  }
  for (const group of groups) {
    if (group.layer !== 'py') continue
    for (const moduleName of nodes.get(group.id).pyModules) {
      const target = pyByModule.get(moduleName)
      if (target && target !== group.id) edges.add(group.id, target, 'authoritative', `import ${moduleName}`)
      else if (!target && moduleName !== '__future__') {
        externals.set(`py|${moduleName}`, (externals.get(`py|${moduleName}`) ?? 0) + 1)
      }
    }
  }
}

/** 结构性不可能：SPM 库不可能反向依赖 App target。命中说明启发式在猜，丢弃并计数。 */
function dropImpossible(edges, nodes) {
  const dropped = []
  for (const [key, edge] of edges.entries()) {
    if (nodes.get(edge.from)?.layer === 'ios-kit' && nodes.get(edge.to)?.layer === 'ios-app') {
      dropped.push(`${edge.from} -> ${edge.to}`)
      edges.delete(key)
    }
  }
  return dropped
}

function finalize(nodes, edges, externals, spm, dropped, fileLayer, emptyGroups) {
  const edgeList = edges.values()
    .map((edge) => ({ ...edge, samples: [...edge.samples].slice(0, 4) }))
    .sort((a, b) => (a.from === b.from ? a.to.localeCompare(b.to) : a.from.localeCompare(b.from)))
  const nodeList = [...nodes.values()].sort((a, b) => a.id.localeCompare(b.id))
  const cycles = tarjan(nodeList, edgeList)
  const cycleEdges = new Set()
  for (const component of cycles) {
    const members = new Set(component)
    for (const edge of edgeList) if (members.has(edge.from) && members.has(edge.to)) cycleEdges.add(`${edge.from}->${edge.to}`)
  }
  const externalList = [...externals.entries()]
    .map(([key, count]) => {
      const [layer, name] = key.split('|')
      return { layer, name, count }
    })
    .sort((a, b) => b.count - a.count)

  return {
    meta: {
      generatedAt: new Date().toISOString(),
      commit: gitCommit(),
      branch: gitBranch(),
      dirty: gitDirty(),
      swiftDescribe: spm.source,
      groupCount: nodeList.length,
      edgeCount: edgeList.length,
      heuristicEdgeCount: edgeList.filter((edge) => edge.kind === 'heuristic').length,
      cycleCount: cycles.length,
      droppedEdges: dropped,
      fileCount: nodeList.reduce((sum, node) => sum + node.files, 0),
      lineCount: nodeList.reduce((sum, node) => sum + node.lines, 0),
      fileEdgeCount: Object.values(fileLayer.byGroup).reduce((sum, group) => sum + group.edges.length, 0),
      declarationCount: Object.values(fileLayer.declarations).reduce((sum, file) => sum + file.types.length, 0),
      emptyGroups,
      bands: BANDS.map((band) => ({
        id: band.id,
        label: band.label,
        sections: band.sections.map((section) => ({ id: section.id, label: section.label })),
      })),
    },
    nodes: nodeList,
    edges: edgeList.map((edge) => ({ ...edge, cyclic: cycleEdges.has(`${edge.from}->${edge.to}`) })),
    cycles: cycles.map((component) => ({ members: component, size: component.length })).sort((a, b) => b.size - a.size),
    externals: externalList.slice(0, 60),
    files: fileLayer.byGroup,
    declarations: fileLayer.declarations,
  }
}

export function buildGraph() {
  const groups = defineGroups()
  // 先建类型索引：节点上的"声明类型"数和启发式边都依赖它
  const typeIndex = buildSwiftTypeIndex(groups)
  const nodes = new Map()
  const externals = new Map()
  const edges = new EdgeBag()
  const spm = swiftPackageTargets()

  const emptyGroups = collectNodes(groups, nodes)
  dropEmpty(groups, nodes)
  addSwiftImportEdges(groups, nodes, edges, externals)
  addHeuristicEdges(groups, edges, typeIndex)
  addSpmEdges(nodes, edges, spm)
  addJsEdges(groups, edges, externals)
  addPyEdges(groups, edges, nodes, externals)
  const dropped = dropImpossible(edges, nodes)
  const fileLayer = buildFileLayer(groups)

  return finalize(nodes, edges, externals, spm, dropped, fileLayer, emptyGroups)
}

if (process.argv[1] && process.argv[1].endsWith('scan.mjs')) {
  const graph = buildGraph()
  if (process.argv.includes('--json')) {
    process.stdout.write(`${JSON.stringify(graph, null, 2)}\n`)
  } else {
    console.log(`节点 ${graph.meta.groupCount}｜边 ${graph.meta.edgeCount}（启发式 ${graph.meta.heuristicEdgeCount}）｜环 ${graph.meta.cycleCount}`)
    for (const node of graph.nodes) {
      console.log(`  ${node.id.padEnd(30)} ${String(node.files).padStart(3)} 文件 ${String(node.lines).padStart(6)} 行`)
    }
  }
}
