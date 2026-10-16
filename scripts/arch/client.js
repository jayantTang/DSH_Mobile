/* 架构快照的浏览器端：三级下钻（模块 → 文件 → 声明）与流程视图。
 *
 * 负载全部来自 index.html 里内联的 #graph-data，不发起任何请求，
 * 所以 file:// 双击打开也能用。这里只做渲染与交互，数据口径由 scripts/arch/*.mjs 决定。
 */
(function () {
  'use strict'

  const DATA = JSON.parse(document.getElementById('graph-data').textContent)
  const META = window.__ARCH_META__ || {}
  const LAYERS = META.layers || {}
  const ROLES = META.roles || {}
  const KINDS = META.kinds || {}
  const BANDS = META.bands || []
  const COLORS = META.colors || {}
  const colorOf = (node) => (node.external ? '#4b5563' : (COLORS[node.role] || '#6b7280'))
  const LINK_PREFIX = META.linkPrefix || './'
  // 模块图按部署角色分带：语言是实现细节，先分清手机侧 / 中转 / 电脑侧 DSH / 仓库工具
  const ROLE_ORDER = BANDS.length ? BANDS.map((band) => band.id) : ['ios', 'relay', 'dsh', 'repo']
  const EDGE_LABEL = { authoritative: '权威', structural: '结构', import: '导入', reference: '类型引用' }

  const $ = (id) => document.getElementById(id)
  const esc = (value) => String(value == null ? '' : value)
    .replace(/[&<>"']/g, (char) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[char]))
  const shortName = (id) => String(id).split('/').pop()
  // 模块节点只有 id，文件节点才带 label；显示名统一走这里，别在渲染里直接读 label
  const nodeLabel = (node) => node.label || shortName(node.id)
  const fmt = (value) => Number(value || 0).toLocaleString('en-US')

  /** 类型名 → 声明它的文件。多文件同名的不收，避免跳错。 */
  const typeOwners = (function buildTypeOwners() {
    const owners = new Map()
    for (const [fileId, declaration] of Object.entries(DATA.declarations || {})) {
      for (const type of declaration.types) {
        if (type.kind === 'extension') continue
        if (!owners.has(type.name)) owners.set(type.name, new Set())
        owners.get(type.name).add(fileId)
      }
    }
    const unique = new Map()
    for (const [name, files] of owners) if (files.size === 1) unique.set(name, [...files][0])
    return unique
  })()

  /** 深查询的入边索引：文件 → 谁调用了它。页面打开时建一次。 */
  const deepIncoming = (function buildDeepIncoming() {
    const map = new Map()
    for (const [from, entry] of Object.entries((DATA.deep && DATA.deep.files) || {})) {
      for (const call of entry.calls) {
        if (!map.has(call.toFile)) map.set(call.toFile, [])
        map.get(call.toFile).push({ ...call, from })
      }
    }
    return map
  })()

  const state = {
    mode: 'modules', group: null, file: null, flow: null,
    scope: 'all', showHeuristic: true, cyclesOnly: false, groupByLayer: true, onlyConnected: false,
  }

  // ---------------------------------------------------------------- 布局

  /** 最长路径分层；环内的边不参与排名，避免死循环。 */
  function rankNodes(nodes, edges) {
    const ids = new Set(nodes.map((node) => node.id))
    const rank = new Map(nodes.map((node) => [node.id, 0]))
    const forward = edges.filter((edge) => ids.has(edge.from) && ids.has(edge.to) && !edge.cyclic)
    for (let pass = 0; pass < nodes.length; pass += 1) {
      let changed = false
      for (const edge of forward) {
        const next = (rank.get(edge.from) || 0) + 1
        if (next > (rank.get(edge.to) || 0)) { rank.set(edge.to, next); changed = true }
      }
      if (!changed) break
    }
    return rank
  }

  /**
   * 把一组节点按列排开，返回 id → {x, y} 与整体宽高。
   * 一列超过 maxRows 就横向折成多列，否则文件级子图会长成一根竖条、右侧全是空白。
   */
  function placeColumns(nodes, edges, options) {
    const { nodeWidth, gapX, gapY, pad, maxRows = 99 } = options
    const rank = rankNodes(nodes, edges)
    const ranks = [...new Set([...rank.values()])].sort((a, b) => a - b)
    const byRank = new Map(ranks.map((value) => [value, []]))
    for (const node of nodes) byRank.get(rank.get(node.id) || 0).push(node)

    const chunks = []
    for (const value of ranks) {
      const items = byRank.get(value).sort((a, b) => (b.lines || 0) - (a.lines || 0) || nodeLabel(a).localeCompare(nodeLabel(b)))
      for (let index = 0; index < items.length; index += maxRows) chunks.push(items.slice(index, index + maxRows))
    }
    const positions = new Map()
    let tallest = 1
    chunks.forEach((items, slot) => {
      tallest = Math.max(tallest, items.length)
      items.forEach((node, index) => {
        positions.set(node.id, { x: pad + 20 + slot * gapX, y: pad + 20 + index * gapY })
      })
    })
    return {
      positions,
      width: pad * 2 + 40 + Math.max(0, chunks.length - 1) * gapX + nodeWidth,
      height: pad * 2 + 40 + tallest * gapY,
    }
  }

  /**
   * 模块图：两级分带，大带上下排，大带内的子块也上下排——iOS 的六个层从上往下读就是依赖方向
   * （App 壳 → Feature UI → Domain → Core/Design/Foundation → RelayKit → DSHKit）。
   */
  const SECTION_HEADER = 22

  function layoutModuleGraph(nodes, edges) {
    const positions = new Map()
    const bands = []
    let yBase = 24
    let width = 0
    const bandIds = state.groupByLayer ? ROLE_ORDER.filter((id) => nodes.some((node) => node.band === id)) : ['*']
    for (const bandId of bandIds) {
      const bandNodes = nodes.filter((node) => (state.groupByLayer ? node.band === bandId : true))
      const definition = BANDS.find((band) => band.id === bandId)
      const sectionIds = definition && definition.sections.length
        ? definition.sections.map((section) => section.id).filter((id) => bandNodes.some((node) => node.section === id))
        : [bandId]
      const bandTop = yBase + 30 // 留出大带标题

      const sections = []
      let sectionY = bandTop
      for (const sectionId of sectionIds) {
        const list = bandNodes.filter((node) => node.section === sectionId)
        if (!list.length) continue
        const header = sectionIds.length > 1 ? SECTION_HEADER : 0
        const placed = placeRows(list, edges, { nodeWidth: 210, gapX: 250, gapY: 78, pad: 24 })
        for (const [id, point] of placed.positions) positions.set(id, { x: point.x, y: point.y + sectionY + header })
        const label = definition?.sections.find((section) => section.id === sectionId)?.label || ''
        sections.push({ label, y: sectionY, height: placed.height - 48 + header })
        sectionY += placed.height - 48 + header + 10
        width = Math.max(width, placed.width)
      }
      const bandHeight = sectionY - yBase - 10
      bands.push({ label: definition ? definition.label : bandId, y: yBase, height: bandHeight, sections })
      yBase += bandHeight + 26
    }
    // 子块统一占满大带宽度（现在都是整行）
    for (const band of bands) {
      for (const section of band.sections) {
        section.x = 8
        section.width = width - 16
      }
    }
    return { positions, bands, width: width + 24, height: yBase + 10 }
  }

  /**
   * 分层行布局：rank 当「层」，rank 0 在最上行，行内节点并排。
   * 与 placeColumns（列布局，文件级子图用）相对：模块图要的是自上而下的层序感。
   */
  function placeRows(nodes, edges, options) {
    const { nodeWidth, gapX, gapY, pad } = options
    const rank = rankNodes(nodes, edges)
    const ranks = [...new Set([...rank.values()])].sort((a, b) => a - b)
    const rows = ranks.map((value) => nodes.filter((node) => (rank.get(node.id) || 0) === value)
      .sort((a, b) => (b.lines || 0) - (a.lines || 0)))
    const positions = new Map()
    rows.forEach((row, rowIndex) => {
      row.forEach((node, index) => {
        positions.set(node.id, { x: pad + 20 + index * gapX, y: pad + 20 + rowIndex * gapY })
      })
    })
    const widest = Math.max(1, ...rows.map((row) => row.length))
    return { positions, width: pad * 2 + 40 + (widest - 1) * gapX + nodeWidth, height: pad * 2 + 40 + rows.length * gapY }
  }

  function layoutFileGraph(nodes, edges) {
    const placed = placeColumns(nodes, edges, { nodeWidth: 196, gapX: 232, gapY: 62, pad: 24, maxRows: 9 })
    return { positions: placed.positions, bands: [], width: placed.width, height: placed.height }
  }

  // ---------------------------------------------------------------- 绘制

  function edgePath(a, b, nodeWidth, nodeHeight) {
    const vertical = (b.y - a.y) > nodeHeight * 0.6
    if (vertical) {
      // 上层 → 下层：从源底边中点到目标顶边中点
      const x1 = a.x + nodeWidth / 2
      const y1 = a.y + nodeHeight
      const x2 = b.x + nodeWidth / 2
      const y2 = b.y
      const bend = Math.max(26, (y2 - y1) / 2)
      return `M ${x1} ${y1} C ${x1} ${y1 + bend}, ${x2} ${y2 - bend}, ${x2} ${y2}`
    }
    const x1 = a.x + nodeWidth
    const y1 = a.y + nodeHeight / 2
    const x2 = b.x
    const y2 = b.y + nodeHeight / 2
    const bend = Math.max(40, Math.abs(x2 - x1) / 2)
    return `M ${x1} ${y1} C ${x1 + bend} ${y1}, ${x2 - bend} ${y2}, ${x2} ${y2}`
  }

  const MARKERS = '<defs>' +
    '<marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M 0 0 L 10 5 L 0 10 z" fill="#4a5568"/></marker>' +
    '<marker id="arrow-warn" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M 0 0 L 10 5 L 0 10 z" fill="#ff6b6b"/></marker>' +
    '<marker id="arrow-struct" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M 0 0 L 10 5 L 0 10 z" fill="#7dd3fc"/></marker>' +
    '</defs>'

  /** 两级分带的底衬：大带一层、子块一层。文件级图没有带，传空数组即可。 */
  function drawBands(parts, bands, width) {
    for (const band of bands) {
      if (!band.label) continue
      parts.push(`<rect class="band" x="8" y="${band.y}" width="${width - 16}" height="${band.height}" rx="12"></rect>`)
      parts.push(`<text class="band-label" x="20" y="${band.y + 19}">${esc(band.label)}</text>`)
      for (const section of band.sections) {
        if (!section.label) continue
        parts.push(`<rect class="section" x="${section.x}" y="${section.y}" width="${section.width}" height="${section.height}" rx="9" style="stroke:${section.color}55"></rect>`)
        parts.push(`<text class="section-label" x="${section.x + 12}" y="${section.y + 15}" style="fill:${section.color}">${esc(section.label)}</text>`)
      }
    }
  }

  function drawEdges(parts, edges, positions, nodeWidth, nodeHeight) {
    for (const edge of edges) {
      const a = positions.get(edge.from)
      const b = positions.get(edge.to)
      if (!a || !b) continue
      const classes = ['edge', edge.kind === 'reference' ? 'heuristic' : '', edge.cyclic ? 'cyclic' : '',
        edge.kind === 'structural' ? 'structural' : '',
        state.file && edge.from !== state.file && edge.to !== state.file ? 'dim' : ''].filter(Boolean).join(' ')
      const marker = edge.cyclic ? 'arrow-warn' : edge.kind === 'structural' ? 'arrow-struct' : 'arrow'
      const title = `${edge.from} → ${edge.to}（${EDGE_LABEL[edge.kind] || edge.kind}）` +
        `${edge.samples && edge.samples.length ? '｜' + edge.samples.join('；') : ''}`
      parts.push(`<path class="${classes}" marker-end="url(#${marker})" d="${edgePath(a, b, nodeWidth, nodeHeight)}"><title>${esc(title)}</title></path>`)
    }
  }

  function nodeSubtitle(node) {
    // 短标签放最前：插件与技能里各有一个 send-image，只看文件名分不出来
    const kind = node.external ? '模块外' : (KINDS[node.role] || '')
    if (node.external) return `${kind} · ${node.group} · ${fmt(node.lines)} 行`
    const scale = node.files != null ? `${fmt(node.files)} 文件` : `${fmt(node.typeCount)} 类型`
    return `${kind} · ${LAYERS[node.layer] || ''} · ${scale} · ${fmt(node.lines)} 行`
  }

  function drawNodes(parts, nodes, positions, nodeWidth, nodeHeight) {
    for (const node of nodes) {
      const point = positions.get(node.id)
      if (!point) continue
      const selected = state.file === node.id || state.group === node.id
      const classes = ['node', selected ? 'sel' : '', node.external ? 'external' : '',
        node.role ? `role-${node.role}` : '', node.cyclic ? 'cyclic' : ''].filter(Boolean).join(' ')
      const color = colorOf(node)
      parts.push(`<g class="${classes}" data-id="${esc(node.id)}" transform="translate(${point.x},${point.y})">` +
        `<rect width="${nodeWidth}" height="${nodeHeight}" rx="8" style="stroke:${color}"></rect>` +
        `<rect class="stripe" x="0" y="0" width="4" height="${nodeHeight}" rx="2" fill="${color}"></rect>` +
        `<text class="title" x="12" y="${nodeHeight / 2 - 2}">${esc(nodeLabel(node))}</text>` +
        `<text class="sub" x="12" y="${nodeHeight / 2 + 15}">${esc(nodeSubtitle(node))}</text></g>`)
    }
  }

  function drawGraph(target, model) {
    const { nodes, edges, positions, bands, width, height, nodeWidth, nodeHeight, onClick } = model
    target.setAttribute('width', width)
    target.setAttribute('height', height)
    const parts = [MARKERS]
    drawBands(parts, bands, width)
    drawEdges(parts, edges, positions, nodeWidth, nodeHeight)
    drawNodes(parts, nodes, positions, nodeWidth, nodeHeight)
    target.innerHTML = parts.join('')
    target.querySelectorAll('.node').forEach((element) => {
      element.addEventListener('click', () => onClick(element.dataset.id))
    })
  }

  // ---------------------------------------------------------------- 数据取用

  function visibleModuleNodes() {
    return DATA.nodes.filter((node) => state.scope === 'all' || node.band === state.scope)
  }

  function visibleModuleEdges(nodes) {
    const ids = new Set(nodes.map((node) => node.id))
    return DATA.edges.filter((edge) => {
      if (!ids.has(edge.from) || !ids.has(edge.to)) return false
      if (edge.kind === 'heuristic' && !state.showHeuristic) return false
      if (state.cyclesOnly && !edge.cyclic) return false
      return true
    })
  }

  function fileGraph(groupId) {
    const layer = DATA.files[groupId] || { nodes: [], edges: [], isolatedCount: 0 }
    const nodes = layer.nodes
    const edges = layer.edges.filter((edge) => {
      if (edge.kind === 'reference' && !state.showHeuristic) return false
      return true
    })
    return { layer, nodes, edges }
  }

  // ---------------------------------------------------------------- 面包屑与工具条

  function renderBreadcrumb() {
    const parts = [`<button data-nav="root"${state.group ? '' : ' class="cur"'}>模块图</button>`]
    if (state.group) {
      parts.push('<span>▸</span>')
      parts.push(`<button data-nav="group"${state.file ? '' : ' class="cur"'}>${esc(state.group)}</button>`)
    }
    if (state.file) {
      parts.push('<span>▸</span>')
      parts.push(`<button data-nav="file" class="cur">${esc(shortName(state.file))}</button>`)
    }
    if (state.mode === 'flows') {
      parts.push(`<button data-nav="flows"${state.flow ? '' : ' class="cur"'}>流程</button>`)
      if (state.flow) parts.push(`<span>▸</span><button data-nav="flow" class="cur">${esc(state.flow)}</button>`)
    }
    $('crumbs').innerHTML = parts.join(' ')
    $('crumbs').querySelectorAll('[data-nav]').forEach((button) => {
      button.addEventListener('click', () => {
        const nav = button.dataset.nav
        if (nav === 'root') { state.group = null; state.file = null; state.mode = 'modules'; state.flow = null }
        if (nav === 'group') { state.file = null; state.mode = 'modules' }
        if (nav === 'flows') { state.mode = 'flows'; state.flow = null; state.group = null; state.file = null }
        if (nav === 'flow') { state.flow = null }
        render()
      })
    })
  }

  function renderToolbar() {
    const html = []
    // 视图切换是另一条轴，不能和层过滤挤成同一排同款按钮：先给一组分段控件，再用竖线隔开
    html.push('<span class="segmented">')
    for (const [mode, label] of [['modules', '模块图'], ['flows', '流程']]) {
      html.push(`<button data-mode="${mode}" aria-pressed="${state.mode === mode}">${esc(label)}</button>`)
    }
    html.push('</span>')
    html.push('<span class="divider"></span>')

    if (state.mode === 'flows') {
      html.push('<span class="muted">流程按文件与符号组织，层过滤与图形选项在这里不适用</span>')
    } else {
      const bandLabels = new Map(BANDS.map((band) => [band.id, band.label]))
      for (const [value, label] of [['all', '全部']].concat(ROLE_ORDER.map((band) => [band, bandLabels.get(band) || ROLES[band] || band]))) {
        html.push(`<button data-scope="${value}" aria-pressed="${state.scope === value}">${esc(label)}</button>`)
      }
      html.push('<span class="spacer"></span>')
      html.push(`<label><input type="checkbox" id="showHeuristic"${state.showHeuristic ? ' checked' : ''}> 启发式边</label>`)
      html.push(`<label><input type="checkbox" id="cyclesOnly"${state.cyclesOnly ? ' checked' : ''}> 只看环</label>`)
      html.push(`<label><input type="checkbox" id="groupByLayer"${state.groupByLayer ? ' checked' : ''}> 按层分带</label>`)
    }

    $('toolbar').innerHTML = html.join('')
    $('toolbar').querySelectorAll('[data-scope]').forEach((button) => {
      button.addEventListener('click', () => {
        state.scope = button.dataset.scope
        state.mode = 'modules'
        state.group = null
        state.file = null
        render()
      })
    })
    $('toolbar').querySelectorAll('[data-mode]').forEach((button) => {
      button.addEventListener('click', () => {
        if (state.mode === button.dataset.mode) return
        state.mode = button.dataset.mode
        state.group = null
        state.file = null
        state.flow = null
        render()
      })
    })
    for (const [id, key] of [['showHeuristic', 'showHeuristic'], ['cyclesOnly', 'cyclesOnly'], ['groupByLayer', 'groupByLayer']]) {
      const box = $(id)
      if (box) box.addEventListener('change', () => { state[key] = box.checked; render() })
    }
  }

  // ---------------------------------------------------------------- 详情面板

  /** 真实调用列表：来自 sourcekit-lsp，不是猜的。目标符号改名后标 stale。 */
  function callList(title, calls, direction) {
    if (!calls.length) return ''
    const shown = calls.slice(0, 15)
    const items = shown.map((call) => {
      const where = direction === 'out' ? `${shortName(call.toFile)} ${call.toSymbol}` : `${shortName(call.from)} ${call.symbol}`
      const openId = direction === 'out' ? call.toFile : call.from
      return `<li><button data-open="file" data-id="${esc(openId)}">${esc(where)}</button> ` +
        `<span class="muted">:${direction === 'out' ? call.toLine : call.line}${call.stale ? ' · 目标符号已改名' : ''}</span></li>`
    })
    return `<h4>${title}（${calls.length}）</h4><ul class="edges">${items.join('')}` +
      `${calls.length > shown.length ? `<li class="muted">…另有 ${calls.length - shown.length} 条</li>` : ''}</ul>`
  }

  function edgeList(title, edges, direction) {
    if (!edges.length) return `<h4>${title}</h4><p class="muted">无</p>`
    const items = edges.map((edge) => {
      const other = direction === 'out' ? edge.to : edge.from
      const target = state.mode === 'files' || state.group ? 'file' : 'module'
      return `<li><button data-open="${target}" data-id="${esc(other)}">${esc(shortName(other))}</button> ` +
        `<span class="muted">${EDGE_LABEL[edge.kind] || edge.kind}${edge.cyclic ? ' · 环' : ''}` +
        `${edge.samples && edge.samples.length ? ' · ' + esc(edge.samples.slice(0, 2).join(', ')) : ''}</span></li>`
    })
    return `<h4>${title}（${edges.length}）</h4><ul class="edges">${items.join('')}</ul>`
  }

  function bindOpenButtons(scope) {
    scope.querySelectorAll('[data-open]').forEach((button) => {
      button.addEventListener('click', () => {
        if (button.dataset.open === 'module') { state.group = button.dataset.id; state.file = null }
        else {
          state.file = button.dataset.id
          const owner = Object.entries(DATA.files).find(([, layer]) => layer.nodes.some((node) => node.id === state.file && !node.external))
          state.group = owner ? owner[0] : state.file.split('/').slice(0, -1).join('/')
        }
        state.mode = 'modules'
        render()
      })
    })
  }

  function showModuleDetail(id) {
    const node = DATA.nodes.find((item) => item.id === id)
    const panel = $('detail')
    if (!node) { panel.innerHTML = '<p class="muted">点一个模块，进入它内部的文件级依赖。</p>'; return }
    const out = DATA.edges.filter((edge) => edge.from === id)
    const incoming = DATA.edges.filter((edge) => edge.to === id)
    const layer = DATA.files[id] || { nodes: [], edsges: [], isolatedCount: 0 }
    panel.innerHTML = `<h3>${esc(node.id)}</h3>
      <dl><dt>层</dt><dd>${esc(LAYERS[node.layer] || node.layer)}</dd>
      <dt>目录</dt><dd><code>${esc(node.dir)}</code></dd>
      <dt>规模</dt><dd>${fmt(node.files)} 文件 / ${fmt(node.lines)} 行</dd>
      <dt>声明类型</dt><dd>${fmt(node.types)}</dd>
      <dt>文件级</dt><dd>${fmt(layer.nodes.length)} 节点 / ${fmt(layer.edges.length)} 边${layer.isolatedCount ? `（另有 ${layer.isolatedCount} 个无依赖文件未画）` : ''}</dd>
      ${node.swiftImports.length ? `<dt>import</dt><dd>${esc(node.swiftImports.join(', '))}</dd>` : ''}
      ${node.pyModules.length ? `<dt>import</dt><dd>${esc(node.pyModules.slice(0, 12).join(', '))}</dd>` : ''}</dl>
      ${state.group === node.id ? '' : `<button class="primary" data-drill="${esc(node.id)}">进入文件级 →</button>`}
      ${edgeList('它依赖谁', out, 'out')}
      ${edgeList('谁依赖它', incoming, 'in')}`
    const drill = $('detail').querySelector('[data-drill]')
    if (drill) drill.addEventListener('click', () => {
      state.group = id
      state.file = null
      render()
    })
    bindOpenButtons(panel)
  }

  function showFileDetail(id) {
    const declaration = DATA.declarations[id] || { types: [], funcs: [], funcCount: 0 }
    const group = state.group
    const layer = group ? DATA.files[group] : null
    const node = layer ? layer.nodes.find((item) => item.id === id) : null
    const out = (layer ? layer.edges : []).filter((edge) => edge.from === id)
    const incoming = (layer ? layer.edges : []).filter((edge) => edge.to === id)
    const deepOut = (DATA.deep && DATA.deep.files && DATA.deep.files[id]) ? DATA.deep.files[id].calls : []
    const deepIn = deepIncoming.get(id) || []
    const typeRows = declaration.types.map((type) => {
      const parents = type.inherits.map((name) => {
        const owner = typeOwners.get(name)
        return owner
          ? `<button data-open="file" data-id="${esc(owner)}">${esc(name)}</button>`
          : `<span class="muted">${esc(name)}</span>`
      }).join(' ')
      return `<li><span class="kind">${esc(type.kind)}</span> <code>${esc(type.name)}</code> ` +
        `<span class="muted">:${type.line}</span>${parents ? ' ' + parents : ''}</li>`
    }).join('')
    const funcRows = declaration.funcs.slice(0, 12)
      .map((func) => `<li><span class="muted">:${func.line}</span> <code>${esc(func.name)}</code></li>`).join('')
    $('detail').innerHTML = `<h3>${esc(shortName(id))}</h3>
      <dl><dt>文件</dt><dd><code>${esc(id)}</code></dd>
      ${node ? `<dt>规模</dt><dd>${fmt(node.lines)} 行</dd>` : ''}
      <dt>声明</dt><dd>${declaration.types.length} 个类型 / ${fmt(declaration.funcCount)} 个函数</dd>
      ${node && node.external ? '<dt>归属</dt><dd class="muted">模块外（被本模块引用）</dd>' : ''}</dl>
      <h4>类型与继承</h4>${typeRows ? `<ul class="decls">${typeRows}</ul>` : '<p class="muted">无</p>'}
      <h4>函数${declaration.funcCount > 12 ? `（前 12 / 共 ${declaration.funcCount}）` : ''}</h4>
      ${funcRows ? `<ul class="decls">${funcRows}</ul>` : '<p class="muted">无</p>'}
      ${edgeList('它引用谁（按类型名推断）', out, 'out')}
      ${edgeList('谁引用它（按类型名推断）', incoming, 'in')}
      ${callList('真实调用 · 出（sourcekit-lsp）', deepOut, 'out')}
      ${callList('真实调用 · 入（sourcekit-lsp）', deepIn, 'in')}
      ${DATA.deep ? '' : '<p class="muted">还没有真实调用数据。跑 <code>npm run arch:deep</code> 后重新生成即可看到谁调用了谁。</p>'}`
    bindOpenButtons($('detail'))
  }

  // ---------------------------------------------------------------- 流程视图

  function renderFlows() {
    const flows = DATA.flows || []
    $('canvas').innerHTML = flows.length
      ? '<div id="flow-host"></div>'
      : '<p class="muted pad">还没有流程定义。在 <code>docs/arch/flows/</code> 下放 JSON 后重新生成。</p>'
    if (!flows.length) { $('detail').innerHTML = ''; return }
    const host = $('flow-host')
    host.innerHTML = `<div class="flow-picker">${flows.map((flow) => {
      const bad = flow.steps.filter((step) => !step.ok).length
      return `<button data-flow="${esc(flow.id)}"${state.flow === flow.id ? ' class="cur"' : ''}>${esc(flow.title)}` +
        `${bad ? ` <span class="bad">${bad} 处失效</span>` : ''}</button>`
    }).join('')}</div>` + (state.flow ? flowDetail(flows.find((flow) => flow.id === state.flow)) : '<p class="muted pad">选一条流程看步骤与符号校验结果。</p>')
    host.querySelectorAll('[data-flow]').forEach((button) => {
      button.addEventListener('click', () => { state.flow = button.dataset.flow; render() })
    })
  }

  /** 流程涉及的文件按模块归拢：点一下就跳到模块图里那个文件。 */
  function flowFilesPanel(flow) {
    if (!flow) return '<p class="muted">左边选一条流程。每一步都绑定真实文件与符号，代码改名后会在这里和步骤里标红。</p>'
    const failed = flow.steps.filter((step) => !step.ok).length
    const groups = new Map()
    for (const step of flow.steps) {
      if (!step.file) continue
      const owner = Object.entries(DATA.files).find(([, layer]) => layer.nodes.some((node) => node.id === step.file && !node.external))
      // 模块内没有依赖连线的文件不会出现在文件图里，这里如实说明，别让人以为它不属于任何模块
      const key = owner ? owner[0] : '未出现在模块文件图中（该文件在模块内没有依赖连线）'
      if (!groups.has(key)) groups.set(key, [])
      groups.get(key).push(step.file)
    }
    const rows = [...groups.entries()].map(([groupId, files]) => `<h4>${esc(groupId)}</h4><ul class="edges">` +
      files.map((file) => `<li><button data-open="file" data-id="${esc(file)}">${esc(shortName(file))}</button></li>`).join('') + '</ul>').join('')
    return `<h3>${esc(flow.title)}</h3>
      <dl><dt>步骤</dt><dd>${flow.steps.length}</dd>
      <dt>校验</dt><dd>${failed ? `<span class="bad">${failed} 处失效</span>` : '全部通过'}</dd></dl>
      <h4>涉及的文件（点开看它的调用与依赖）</h4>${rows || '<p class="muted">无</p>'}`
  }

  function flowDetail(flow) {
    if (!flow) return ''
    const byId = new Map(flow.steps.map((step) => [step.id, step]))
    const rows = flow.steps.map((step, index) => `<li class="${step.ok ? 'ok' : 'bad'}">
      <span class="step-no">${index + 1}</span>
      <div><b>${esc(step.label)}</b>
        <div class="muted">${esc(step.file || '（未指定文件）')}${step.symbol ? ` · <code>${esc(step.symbol)}</code>` : ''}</div>
        ${step.ok ? '' : `<div class="bad">校验失败：${esc(step.reason)}</div>`}
      </div></li>`).join('')
    const edges = (flow.edges || []).map((edge) => {
      const from = byId.get(edge[0])
      const to = byId.get(edge[1])
      if (!from || !to) return ''
      return `<li>${esc(from.label)} <span class="muted">${esc(edge[2] || '→')}</span> ${esc(to.label)}</li>`
    }).join('')
    return `<div class="flow-body">
      <h3>${esc(flow.title)}</h3>
      ${flow.description ? `<p class="muted">${esc(flow.description)}</p>` : ''}
      <ol class="steps">${rows}</ol>
      ${edges ? `<h4>步骤之间的关系</h4><ul class="edges">${edges}</ul>` : ''}
    </div>`
  }

  // ---------------------------------------------------------------- 主渲染

  function render() {
    renderBreadcrumb()
    renderToolbar()
    const svg = $('graph')
    if (state.mode === 'flows') {
      $('canvas').innerHTML = '<div id="flow-host"></div>'
      renderFlows()
      $('detail').innerHTML = flowFilesPanel(DATA.flows.find((flow) => flow.id === state.flow))
      bindOpenButtons($('detail'))
      return
    }
    if (!state.group) {
      $('canvas').innerHTML = '<svg id="graph"></svg>'
      const nodes = visibleModuleNodes()
      const edges = visibleModuleEdges(nodes)
      const model = layoutModuleGraph(nodes, edges)
      drawGraph($('graph'), {
        nodes, edges, positions: model.positions, bands: model.bands,
        width: model.width, height: model.height, nodeWidth: 210, nodeHeight: 56,
        onClick: (id) => { state.group = id; state.file = null; render() },
      })
      // 只有 SKILL.md / README 的单元没有代码可连，单独说明，免得看起来像漏了
      const empty = DATA.meta.emptyGroups || []
      if (empty.length && state.scope === 'all') {
        $('canvas').insertAdjacentHTML('beforeend',
          `<p class="muted pad">另有 ${empty.length} 个单元没有可扫描的代码文件，未进图：${empty.map((id) => `<code>${esc(id)}</code>`).join('、')}</p>`)
      }
      showModuleDetail(state.file)
      return
    }
    $('canvas').innerHTML = '<svg id="graph"></svg>'
    const { nodes, edges, layer } = fileGraph(state.group)
    if (!nodes.length) {
      $('detail').innerHTML = `<h3>${esc(state.group)}</h3><p class="muted">这个模块内部没有可画的依赖（只有对系统库/第三方包的引用）。</p>`
      return
    }
    const model = layoutFileGraph(nodes, edges)
    drawGraph($('graph'), {
      nodes, edges, positions: model.positions, bands: [],
      width: model.width, height: model.height, nodeWidth: 196, nodeHeight: 46,
      onClick: (id) => { state.file = state.file === id ? null : id; render() },
    })
    if (layer.isolatedCount) $('canvas').insertAdjacentHTML('beforeend', `<p class="muted pad">另有 ${layer.isolatedCount} 个文件没有依赖连线，未画。</p>`)
    if (state.file) showFileDetail(state.file)
    else showModuleDetail(state.group)
  }

  document.getElementById('graph').outerHTML = '<svg id="graph"></svg>'
  $('version').addEventListener('change', (event) => { location.href = `${LINK_PREFIX}${event.target.value}/index.html` })
  render()
})()
