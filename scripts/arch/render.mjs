#!/usr/bin/env node
/**
 * 架构快照的页面外壳：样式 + 头部 + 内联数据 + 引入 client.js。
 *
 * 交互逻辑全在 client.js（原样拷进版本目录，不参与模板拼接），
 * 这样既避免了在模板字符串里转义 JS，也让每个文件都留在仓库自己的行数门禁内。
 */

/**
 * 每个子块一个色相：同一大带里用相近色系，不同大带拉开。
 * 键是子块 id（= 节点上的 role），没有子块时就是大带 id。
 */
const SECTION_COLOR = {
  'ios-shell': '#4f8ff7', 'ios-features': '#38bdf8', 'ios-support': '#6f7ff0',
  'ios-design': '#22d3ee', 'ios-debug': '#94a3b8', 'ios-protocol': '#7dd3fc', 'ios-relaykit': '#a78bfa',
  relay: '#d98cf0',
  connector: '#46c9a0', plugin: '#2f9e7a', skill: '#a3b36a', sidecar: '#c08a5e',
  repo: '#6b7280',
}

/** 节点副标题前的短标签：同名文件（如插件与技能各有一个 send-image）靠它区分。 */
const KIND_LABEL = {
  'ios-shell': 'App 壳', 'ios-features': 'Feature', 'ios-support': 'Support',
  'ios-design': 'Design', 'ios-debug': '调试', 'ios-protocol': 'DSHKit', 'ios-relaykit': 'RelayKit',
  relay: '中转服务',
  connector: '连接器', plugin: '插件', skill: '技能', sidecar: 'sidecar',
  repo: '工程',
}

const LAYER_LABEL = {
  'ios-app': 'iOS App',
  'ios-kit': 'iOS Kit（SPM）',
  js: 'JS / Node',
  py: 'Python',
}

const esc = (value) =>
  String(value ?? '').replace(/[&<>"']/g, (char) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[char]))

const badge = (text, kind = '') => `<span class="badge ${kind}">${esc(text)}</span>`

const STYLE = `
  :root {
    --bg: #0f1115; --panel: #171a21; --line: #262b36; --ink: #e6e9ef; --muted: #8b93a3;
    --accent: #6ea8fe; --warn: #ff6b6b; --ok: #4ade80; --heur: #f0b849; --struct: #7dd3fc;
  }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--bg); color: var(--ink);
    font: 14px/1.6 -apple-system, "PingFang SC", "Helvetica Neue", Arial, sans-serif; }
  header { padding: 14px 20px 10px; border-bottom: 1px solid var(--line); position: sticky; top: 0;
    background: rgba(15,17,21,.95); backdrop-filter: blur(8px); z-index: 10; }
  h1 { font-size: 17px; margin: 0 0 6px; font-weight: 600; }
  .meta { color: var(--muted); font-size: 12px; display: flex; flex-wrap: wrap; gap: 6px 14px; align-items: center; }
  .badge { display: inline-block; padding: 1px 7px; border: 1px solid var(--line); border-radius: 99px; font-size: 11px; color: var(--muted); }
  .badge.warn { color: var(--warn); border-color: #4a2626; }
  .badge.ok { color: var(--ok); border-color: #1f3d2a; }
  #crumbs { margin-top: 8px; font-size: 13px; display: flex; gap: 6px; align-items: center; color: var(--muted); }
  #crumbs button { background: none; border: 0; color: var(--accent); cursor: pointer; padding: 0; font-size: 13px; }
  #crumbs button.cur { color: var(--ink); cursor: default; }
  .toolbar { display: flex; flex-wrap: wrap; gap: 8px 14px; align-items: center; margin-top: 8px; font-size: 13px; }
  .toolbar button { background: var(--panel); color: var(--ink); border: 1px solid var(--line);
    border-radius: 7px; padding: 3px 11px; cursor: pointer; font-size: 13px; }
  .toolbar button[aria-pressed="true"] { border-color: var(--accent); color: var(--accent); }
  .toolbar label { display: inline-flex; align-items: center; gap: 5px; color: var(--muted); }
  .toolbar .spacer { flex: 1; }
  .toolbar .segmented { display: inline-flex; border: 1px solid var(--line); border-radius: 8px; overflow: hidden; }
  .toolbar .segmented button { border: 0; border-radius: 0; padding: 4px 14px; background: transparent; color: var(--muted); }
  .toolbar .segmented button[aria-pressed="true"] { background: #1d2433; color: var(--accent); }
  .toolbar .divider { width: 1px; height: 18px; background: var(--line); }
  select { background: var(--panel); color: var(--ink); border: 1px solid var(--line); border-radius: 7px; padding: 3px 8px; }
  main { display: grid; grid-template-columns: minmax(0, 1fr) 330px; align-items: start; }
  @media (max-width: 1100px) { main { grid-template-columns: 1fr; } }
  #canvas { overflow: auto; padding: 14px; min-height: 420px; }
  #detail { border-left: 1px solid var(--line); padding: 16px; position: sticky; top: 128px;
    max-height: calc(100vh - 144px); overflow: auto; }
  @media (max-width: 1100px) { #detail { position: static; max-height: none; border-left: 0; border-top: 1px solid var(--line); } }
  #detail h3 { margin: 0 0 8px; font-size: 14px; }
  #detail h4 { margin: 14px 0 4px; font-size: 12.5px; color: var(--muted); font-weight: 500; }
  #detail dl { margin: 0 0 12px; display: grid; grid-template-columns: 76px 1fr; gap: 4px 10px; font-size: 13px; }
  #detail dt { color: var(--muted); }
  #detail dd { margin: 0; word-break: break-word; }
  #detail code { color: var(--accent); }
  #detail ul { margin: 4px 0 12px; padding-left: 0; list-style: none; font-size: 13px; }
  #detail ul.decls li, #detail ul.edges li { padding: 2px 0; border-bottom: 1px solid rgba(38,43,54,.5); }
  #detail button { background: none; border: 0; color: var(--accent); cursor: pointer; padding: 0; font: inherit; }
  #detail button.primary { border: 1px solid var(--accent); border-radius: 7px; padding: 5px 12px; margin: 4px 0 10px; }
  .kind { color: var(--muted); font-size: 11px; border: 1px solid var(--line); border-radius: 5px; padding: 0 5px; }
  .muted { color: var(--muted); }
  .pad { padding: 12px; }
  .bad { color: var(--warn); }
  section.block { border-top: 1px solid var(--line); padding: 16px 20px; }
  section.block h2 { font-size: 14px; margin: 0 0 10px; font-weight: 600; }
  .diff { list-style: none; padding: 0; margin: 0; font-size: 13px; }
  .diff li { padding: 2px 0; }
  .diff .add { color: var(--ok); }
  .diff .del { color: var(--warn); }
  .diff em { color: var(--muted); font-style: normal; }
  .cycle { margin-bottom: 10px; }
  .chain { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; font-size: 12px; color: var(--muted); }
  .chain code { color: var(--ink); background: var(--panel); padding: 1px 6px; border-radius: 5px; }
  .ext-group { margin-bottom: 12px; }
  .ext-group h4 { margin: 0 0 4px; font-size: 12px; color: var(--muted); font-weight: 500; }
  .ext-list { display: flex; flex-wrap: wrap; gap: 6px; }
  .ext-list code { background: var(--panel); border: 1px solid var(--line); border-radius: 6px; padding: 1px 7px; font-size: 12px; }
  .ext-list .count { color: var(--muted); font-size: 11px; }
  .legend { display: flex; flex-direction: column; gap: 4px; font-size: 12.5px; color: var(--muted); }
  .legend b { color: var(--ink); font-weight: 500; }
  .flow-picker { display: flex; flex-wrap: wrap; gap: 8px; margin-bottom: 14px; }
  .flow-picker button { background: var(--panel); color: var(--ink); border: 1px solid var(--line);
    border-radius: 8px; padding: 5px 12px; cursor: pointer; font-size: 13px; }
  .flow-picker button.cur { border-color: var(--accent); color: var(--accent); }
  .flow-body h3 { margin: 0 0 6px; font-size: 15px; }
  .steps { list-style: none; padding: 0; margin: 10px 0 0; }
  .steps li { display: flex; gap: 10px; padding: 8px 10px; border: 1px solid var(--line); border-radius: 8px; margin-bottom: 6px; }
  .steps li.bad { border-color: #4a2626; }
  .steps .step-no { color: var(--muted); font-variant-numeric: tabular-nums; min-width: 16px; }
  .steps li.ok .step-no { color: var(--ok); }
  .steps li.bad .step-no { color: var(--warn); }
  svg { display: block; }
  .node rect { fill: var(--panel); stroke: var(--line); }
  .node .title { fill: var(--ink); font-size: 12.5px; font-weight: 600; }
  .node .sub { fill: var(--muted); font-size: 10.5px; }
  .node { cursor: pointer; }
  .node.sel rect { stroke: var(--accent); stroke-width: 2; }
  .node.external rect { stroke-dasharray: 3 3; fill: #14161b; }
  .section { fill: rgba(255,255,255,.016); stroke: var(--line); }
  .node.external .title { fill: var(--muted); font-weight: 500; }
  .node .tag { fill: #46c9a0; font-size: 10px; }
  .node .title { fill: var(--ink); }
  .node .stripe { stroke: none; }
  .edge { fill: none; stroke: #4a5568; stroke-width: 1.3; }
  .edge.heuristic { stroke: var(--heur); stroke-dasharray: 4 3; stroke-width: 1.1; }
  .edge.structural { stroke: var(--struct); stroke-width: 1.4; }
  .edge.cyclic { stroke: var(--warn); stroke-width: 1.8; stroke-dasharray: 6 3; }
  .edge.dim { opacity: .1; }
  .band { fill: rgba(255,255,255,.014); stroke: var(--line); stroke-dasharray: 5 4; }
  .band-label { fill: var(--ink); font-size: 12px; letter-spacing: .04em; font-weight: 600; }
  .section-label { font-size: 11px; }
`

function diffSection(diff) {
  if (!diff) return '<p class="muted">这是第一版快照，没有可对比的上一版。下一版起这里会列出新增与消失的依赖边。</p>'
  const rows = []
  for (const edge of diff.addedEdges) rows.push(`<li class="add">＋ ${esc(edge.from)} → ${esc(edge.to)} <em>${esc(edge.kind)}</em></li>`)
  for (const edge of diff.removedEdges) rows.push(`<li class="del">－ ${esc(edge.from)} → ${esc(edge.to)}</li>`)
  for (const id of diff.addedNodes) rows.push(`<li class="add">＋ 新模块 ${esc(id)}</li>`)
  for (const id of diff.removedNodes) rows.push(`<li class="del">－ 模块消失 ${esc(id)}</li>`)
  if (!rows.length) return `<p class="muted">与 ${esc(diff.previous)} 相比：依赖结构没有变化（节点、边均一致）。</p>`
  return `<ul class="diff">${rows.join('')}</ul>`
}

function cycleSection(graph) {
  if (!graph.cycles.length) return '<p class="muted">没有检测到循环依赖。</p>'
  return graph.cycles.map((cycle) => `<div class="cycle"><b>${cycle.size} 个模块互相依赖</b>` +
    `<div class="chain">${cycle.members.map((id) => `<code>${esc(id)}</code>`).join('<span>→</span>')}</div></div>`).join('')
}

function externalSection(graph) {
  const byLayer = new Map()
  for (const item of graph.externals) {
    if (!byLayer.has(item.layer)) byLayer.set(item.layer, [])
    byLayer.get(item.layer).push(item)
  }
  return [...byLayer.entries()].map(([layer, items]) => `<div class="ext-group"><h4>${esc(LAYER_LABEL[layer] ?? layer)}</h4>` +
    `<div class="ext-list">${items.slice(0, 10).map((item) => `<code>${esc(item.name)}</code><span class="count">${item.count}</span>`).join('')}</div></div>`).join('')
}

export function renderPage({ graph, versions, current, diff, linkPrefix = './', assetPrefix = './' }) {
  const meta = graph.meta
  const options = versions
    .map((version) => `<option value="${esc(version)}"${version === current ? ' selected' : ''}>${esc(version)}</option>`)
    .join('')
  const clientMeta = {
    version: current, layers: LAYER_LABEL, kinds: KIND_LABEL, colors: SECTION_COLOR,
    bands: meta.bands || [], linkPrefix, generatedAt: meta.generatedAt,
  }

  return `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>架构快照 ${esc(current)} · DSH Mobile</title>
<style>${STYLE}</style>
</head>
<body>
<header>
  <h1>DSH Mobile 架构快照</h1>
  <div class="meta">
    ${badge(current, 'ok')}
    <span>commit <code>${esc(meta.commit)}</code>${meta.dirty ? ` ${badge(`工作区有 ${meta.dirty} 处未提交改动`, 'warn')}` : ''}</span>
    <span>分支 <code>${esc(meta.branch)}</code></span>
    <span>生成于 ${esc(meta.generatedAt.replace('T', ' ').slice(0, 19))} UTC</span>
    <span>${meta.groupCount} 模块 · ${meta.edgeCount} 模块边 · ${meta.fileEdgeCount ?? 0} 文件边 · ${meta.fileCount} 文件 · ${meta.lineCount.toLocaleString('en-US')} 行</span>
    ${meta.deepCallCount ? badge(`${meta.deepCallCount} 条真实调用`, 'ok') : badge('无真实调用数据（跑 npm run arch:deep）')}
    ${meta.cycleCount ? badge(`${meta.cycleCount} 处循环`, 'warn') : badge('无循环', 'ok')}
    <label>版本 <select id="version">${options}</select></label>
  </div>
  <div id="crumbs"></div>
  <div class="toolbar" id="toolbar"></div>
</header>
<main>
  <div id="canvas"><svg id="graph"></svg></div>
  <div id="detail"><p class="muted">点一个模块，进入它内部的文件级依赖；再点文件，看它的类型、继承与函数。</p></div>
</main>
<section class="block">
  <h2>循环依赖</h2>
  ${cycleSection(graph)}
</section>
<section class="block">
  <h2>与上一版相比</h2>
  ${diffSection(diff)}
</section>
<section class="block">
  <h2>外部依赖（只在统计里，不画进图）</h2>
  ${externalSection(graph)}
</section>
<section class="block">
  <h2>这张图的口径</h2>
  <div class="legend">
    <span><b>实线灰</b>：权威边界。Swift <code>import</code> 自有模块、SPM target 依赖、JS/Python 相对 import。</span>
    <span><b>蓝实线</b>：继承与协议实现。语法明确，可信。</span>
    <span><b>黄虚线</b>：启发式。Swift 跨文件/跨目录的<b>类型引用</b>，靠类型名匹配得出，会漏也会误，可关掉。</span>
    <span><b>红虚线</b>：循环依赖。虚线边框的节点是模块外被引用的文件。</span>
  </div>
  <p class="muted" style="margin-top:10px">
    扫描口径：SPM 目标依赖来自 <code>swift package describe</code>（${esc(meta.swiftDescribe)}）。
    启发式边已剔除注释与字符串，并要求类型出现在标注、泛型、构造调用等语法位置；
    库模块反向依赖 App 这类结构性不可能的边被直接丢弃${meta.droppedEdges?.length ? `（本次丢弃 ${meta.droppedEdges.length} 条）` : ''}。
    模块内没有依赖连线的文件不画，只计数。
  </p>
</section>
<script id="graph-data" type="application/json">${JSON.stringify(graph).replace(/</g, '\\u003c')}</script>
<script>window.__ARCH_META__ = ${JSON.stringify(clientMeta)}</script>
<script src="${esc(assetPrefix)}client.js"></script>
</body>
</html>
`
}

export { LAYER_LABEL }
