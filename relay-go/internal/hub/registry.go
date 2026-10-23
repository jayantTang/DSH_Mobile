package hub

import (
	"errors"
	"hash/fnv"
	"sort"
	"sync"
)

// shardCount 是注册表的分片数（DESIGN §5.2：默认 64 片）。
//
// 分片的意义是**没有全局大锁**：查找、挂接、摘除只锁一片，1000 台设备同时上线时
// 不会在一条 RWMutex 上排队。
const shardCount = 64

// ErrDeviceLimit 表示这台电脑的在线设备数已达上限（调用方回 4012）。
var ErrDeviceLimit = errors.New("relay: device limit reached")

// agentShard 是 agentId 哈希到的一片 agent 注册表。
type agentShard struct {
	mu     sync.RWMutex
	agents map[string]*AgentLink
}

// deviceShard 是 deviceId 哈希到的一片设备注册表（含未挂上电脑的设备）。
type deviceShard struct {
	mu      sync.RWMutex
	devices map[string]*DeviceLink
}

// registry 是连接图（三份索引）的唯一写者。
//
// 三份索引回答同一个事实的不同方向，所以写入必须只经过这里：
//
//	agentShards   agentId → 当前那条连接（谁在线）
//	deviceShards  deviceId → 当前那条设备连接（含电脑不在线的设备）
//	AgentLink.devices / DeviceLink.agent  正向/反向关系（谁挂在谁身上）
//
// 规则（由 registry_test.go 的不变量测试守住）：
//
//   - 关系只由本类型的方法在**分片写锁**下修改；Hub 只能调这些方法。
//   - `DeviceLink.agent` 是热路径只读缓存（每帧原子 Load），写入也只允许这里。
//   - `AgentLink.devices` 是反向索引，写入同样只允许这里。
//   - **不同时持有两把分片锁**：跨两个平面的操作分两步、各自加解锁。
//
// 本类型不做帧编码、发送、日志策略与额度记账（DESIGN §2.3）：那些都是编排层的事，
// 这里只回答“关系是什么、改完之后是什么”。
type registry struct {
	agentShards  [shardCount]agentShard
	deviceShards [shardCount]deviceShard
}

// newRegistry 建一个空的连接图。
func newRegistry() *registry {
	table := &registry{}
	for index := range table.agentShards {
		table.agentShards[index].agents = map[string]*AgentLink{}
		table.deviceShards[index].devices = map[string]*DeviceLink{}
	}
	return table
}

// shardIndex 把 id 映射到分片。
func shardIndex(id string) uint32 {
	hasher := fnv.New32a()
	_, _ = hasher.Write([]byte(id))
	return hasher.Sum32() % shardCount
}

// ── 查找 ─────────────────────────────────────────────────────────────────────

// agent 返回 agentId 当前登记的那条连接（没有时 nil）。
func (r *registry) agent(agentID string) *AgentLink {
	shard := &r.agentShards[shardIndex(agentID)]
	shard.mu.RLock()
	defer shard.mu.RUnlock()
	return shard.agents[agentID]
}

// device 返回 deviceId 当前登记的那条连接（没有时 nil）。
func (r *registry) device(deviceID string) *DeviceLink {
	shard := &r.deviceShards[shardIndex(deviceID)]
	shard.mu.RLock()
	defer shard.mu.RUnlock()
	return shard.devices[deviceID]
}

// devices 返回某个 agent 当前挂着的设备 id（按 id 排序，供诊断与测试）。
func (r *registry) devices(agentID string) []string {
	shard := &r.agentShards[shardIndex(agentID)]
	shard.mu.RLock()
	defer shard.mu.RUnlock()
	agent := shard.agents[agentID]
	if agent == nil {
		return nil
	}
	return sortedDeviceIDs(agent)
}

// countAgents 返回在线的 agent 连接数（/stats 的 load.agents）。
func (r *registry) countAgents() int {
	agents := 0
	for index := range r.agentShards {
		shard := &r.agentShards[index]
		shard.mu.RLock()
		agents += len(shard.agents)
		shard.mu.RUnlock()
	}
	return agents
}

// agents 取全部在线 agent 连接的快照（不持锁返回）。
//
// 逐分片读锁、不跨片持锁：连接风暴时它不会把转发卡住。返回的是指针副本，
// 连接的存活由 Link 自己的原子状态回答，不由注册表代答。
func (r *registry) agents() []*AgentLink {
	var agents []*AgentLink
	for index := range r.agentShards {
		shard := &r.agentShards[index]
		shard.mu.RLock()
		for _, agent := range shard.agents {
			agents = append(agents, agent)
		}
		shard.mu.RUnlock()
	}
	return agents
}

// agentView 是一个 agent 与它当前挂着的设备 id 的一致性快照。
type agentView struct {
	link    *AgentLink
	devices []string
}

// agentViews 取全部在线 agent 与各自设备 id 的快照。
//
// 设备 id 与 agent 在**同一把分片读锁**下复制，所以一行之内“谁挂着谁”是自洽的；
// 行与行之间不保证同一时刻（与旧实现逐分片遍历一致）。
func (r *registry) agentViews() []agentView {
	var views []agentView
	for index := range r.agentShards {
		shard := &r.agentShards[index]
		shard.mu.RLock()
		for _, agent := range shard.agents {
			views = append(views, agentView{link: agent, devices: sortedDeviceIDs(agent)})
		}
		shard.mu.RUnlock()
	}
	return views
}

// allDevices 取全部在线设备（跨分片快照，不持锁返回）。
func (r *registry) allDevices() []*DeviceLink {
	var devices []*DeviceLink
	for index := range r.deviceShards {
		shard := &r.deviceShards[index]
		shard.mu.RLock()
		for _, device := range shard.devices {
			devices = append(devices, device)
		}
		shard.mu.RUnlock()
	}
	return devices
}

// devicesOfAgent 从设备注册表里取某台电脑名下的活设备（不持锁返回）。
func (r *registry) devicesOfAgent(agentID string) []*DeviceLink {
	var found []*DeviceLink
	for index := range r.deviceShards {
		shard := &r.deviceShards[index]
		shard.mu.RLock()
		for _, device := range shard.devices {
			if device.AgentID == agentID && !device.Closed() {
				found = append(found, device)
			}
		}
		shard.mu.RUnlock()
	}
	return found
}

// attachedDevices 取这台电脑当前挂着的设备（不持锁返回）。
func (r *registry) attachedDevices(link *AgentLink) []*DeviceLink {
	shard := &r.agentShards[shardIndex(link.AgentID)]
	shard.mu.RLock()
	defer shard.mu.RUnlock()
	devices := make([]*DeviceLink, 0, len(link.devices))
	for _, device := range link.devices {
		devices = append(devices, device)
	}
	return devices
}

// deviceOfAgent 只在这台电脑自己名下的设备里找。
//
// 不能查全局设备表：一枚设备令牌只该寻址自己那台电脑的设备，否则任意连接器都能
// 往别人的手机上投帧。
func (r *registry) deviceOfAgent(link *AgentLink, deviceID []byte) *DeviceLink {
	shard := &r.agentShards[shardIndex(link.AgentID)]
	shard.mu.RLock()
	defer shard.mu.RUnlock()
	if shard.agents[link.AgentID] != link {
		return nil
	}
	return link.devices[string(deviceID)]
}

// deviceOnlineOn 报告这台设备是否挂在**这一条**（且仍是当前）的 agent 连接上。
//
// 只查 map 不够：被顶替的旧连接还留着 devices 时，答案会从"在线"漂成"离线"或
// 反过来。所以先确认这条连接仍是注册表里的那一条。
func (r *registry) deviceOnlineOn(link *AgentLink, deviceID string) bool {
	shard := &r.agentShards[shardIndex(link.AgentID)]
	shard.mu.RLock()
	defer shard.mu.RUnlock()
	current := shard.agents[link.AgentID]
	if current == nil || current != link {
		return false
	}
	_, online := current.devices[deviceID]
	return online
}

// deviceBudgetExceeded 判断再接入 deviceID 是否会超过这台电脑的设备上限。
//
// "设备上限"只有这一处定义：升级前的预检查（能在握手前干净地拒绝）与
// attachToAgent（最后一道防线）都问它，两条路径不可能给出不同答案。
//
// 重连的设备不算**新**设备：手机可能在新连接到达时还没清掉旧 socket，把自己算进
// 名额里会把一台手机锁在自己的中转外面。
func (r *registry) deviceBudgetExceeded(agentID, deviceID string, limit int) bool {
	shard := &r.agentShards[shardIndex(agentID)]
	shard.mu.RLock()
	defer shard.mu.RUnlock()
	agent := shard.agents[agentID]
	if agent == nil {
		return false
	}
	return budgetExceededLocked(agent, deviceID, limit)
}

// budgetExceededLocked 是设备上限规则的唯一实现；调用方持有对应分片的锁。
func budgetExceededLocked(agent *AgentLink, deviceID string, limit int) bool {
	if limit <= 0 {
		return false
	}
	live := 0
	for id, device := range agent.devices {
		if id == deviceID || device.Closed() {
			continue
		}
		live++
	}
	return live >= limit
}

// sortedDeviceIDs 复制某个 agent 的设备 id 并排序；调用方持有对应分片的锁。
func sortedDeviceIDs(agent *AgentLink) []string {
	ids := make([]string, 0, len(agent.devices))
	for id := range agent.devices {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	return ids
}

// ── 写入 ─────────────────────────────────────────────────────────────────────

// registerAgent 把一条已经通过准入的连接登记为当前连接。
//
// 旧连接必须先由编排层按「标记 → 关闭 → 等退出」的顺序退场（DESIGN §3.5）；
// 这里的覆盖只是登记新连接这一步。
func (r *registry) registerAgent(link *AgentLink) {
	shard := &r.agentShards[shardIndex(link.AgentID)]
	shard.mu.Lock()
	shard.agents[link.AgentID] = link
	shard.mu.Unlock()
}

// attachToAgent 在 agent 分片写锁下做**判定 + 挂接**，两者必须原子。
//
// 返回 ErrDeviceLimit 时什么都没登记。设备上限规则与 deviceBudgetExceeded 共用
// budgetExceededLocked，所以握手前的预检与这里的兜底不可能给出不同答案。
func (r *registry) attachToAgent(link *DeviceLink, limit int) (*AgentLink, error) {
	shard := &r.agentShards[shardIndex(link.AgentID)]
	shard.mu.Lock()
	defer shard.mu.Unlock()
	agent := shard.agents[link.AgentID]
	if agent == nil {
		return nil, nil // 电脑不在线：设备照样能连，只是收不到帧
	}
	if budgetExceededLocked(agent, link.DeviceID, limit) {
		return nil, ErrDeviceLimit
	}
	agent.devices[link.DeviceID] = link
	link.agent.Store(agent)
	return agent, nil
}

// bindDevice 在 agent 分片写锁下把设备挂到链路上；返回 false 表示本次不该挂。
func (r *registry) bindDevice(link *AgentLink, device *DeviceLink) bool {
	shard := &r.agentShards[shardIndex(link.AgentID)]
	shard.mu.Lock()
	defer shard.mu.Unlock()
	if shard.agents[link.AgentID] != link {
		return false // 已经被新连接顶替
	}
	if device.Closed() {
		return false
	}
	device.agent.Store(link)
	link.devices[device.DeviceID] = device
	return true
}

// registerDevice 把设备登记进注册表，返回被顶替的那条（可能为 nil）。
func (r *registry) registerDevice(link *DeviceLink) *DeviceLink {
	shard := &r.deviceShards[shardIndex(link.DeviceID)]
	shard.mu.Lock()
	defer shard.mu.Unlock()
	previous := shard.devices[link.DeviceID]
	shard.devices[link.DeviceID] = link
	return previous
}

// detachFromAgent 从所属 agent 的反向索引里摘除设备，返回"要不要通知"。
//
// 返回的 agent 是这次摘除前该设备挂着的连接（可能已被顶替）；调用方据此发
// deviceDetach。判定与旧实现逐条一致：
//
//   - 没登记过：没有可发的通知；
//   - 仍是当前那条：摘除并发 deviceDetach；
//   - 已被同 deviceId 的新连接顶替：**不发** deviceDetach（连接器那边设备没走）。
//
// link.agent 在这里清零；它只在 registry 方法里写。
func (r *registry) detachFromAgent(link *DeviceLink) (agent *AgentLink, notified, replaced bool) {
	agent = link.agent.Load()
	if agent == nil {
		return nil, false, false
	}
	// `closed` 已经置位，接下来读 agent 并摘除必须和 bindDevice **同一把锁**：
	// 电脑重连认领设备的那个瞬间如果不互斥，拆除会漏掉刚挂上的那条登记。
	shard := &r.agentShards[shardIndex(agent.AgentID)]
	shard.mu.Lock()
	current, registered := agent.devices[link.DeviceID]
	switch {
	case !registered:
		// 已经被摘掉了：没有可发的通知。
	case current == link:
		delete(agent.devices, link.DeviceID)
		notified = true
	default:
		// 这条 socket 已经被同 deviceId 的新连接顶替过。连接器会认为那台设备
		// 还在（新连接也是它），所以**没有** deviceDetach 可发。
		replaced = true
	}
	link.agent.Store(nil)
	shard.mu.Unlock()
	return agent, notified, replaced
}

// unregisterDevice 把设备从全局设备表摘掉（只摘仍是自己的那条登记）。
func (r *registry) unregisterDevice(link *DeviceLink) {
	shard := &r.deviceShards[shardIndex(link.DeviceID)]
	shard.mu.Lock()
	if shard.devices[link.DeviceID] == link {
		delete(shard.devices, link.DeviceID)
	}
	shard.mu.Unlock()
}

// detachAgent 摘除一条 agent 连接，返回它当时挂着的设备与"是否仍是当前连接"。
//
// 不是当前连接时什么都不做：摘除与通知都归新连接（调用方只收尾旧 socket 自己的桥）。
// 设备只是从反向索引里摘下来，`DeviceLink.agent` 由 releaseDevices 在编排层原来的
// 位置清（保持事件顺序不变）。
func (r *registry) detachAgent(link *AgentLink) ([]*DeviceLink, bool) {
	shard := &r.agentShards[shardIndex(link.AgentID)]
	shard.mu.Lock()
	defer shard.mu.Unlock()
	if shard.agents[link.AgentID] != link {
		return nil, false
	}
	delete(shard.agents, link.AgentID)
	devices := make([]*DeviceLink, 0, len(link.devices))
	for _, device := range link.devices {
		devices = append(devices, device)
	}
	link.devices = map[string]*DeviceLink{}
	return devices, true
}

// releaseDevices 清掉仍指向这条 agent 的设备反向指针，返回真正清掉的那几条。
//
// 用 CompareAndSwap 而不是无条件 Store：设备可能已经被新连接认领，迟到的拆除
// 不能把新连接的关系抹掉。
func (r *registry) releaseDevices(link *AgentLink, devices []*DeviceLink) []*DeviceLink {
	cleared := make([]*DeviceLink, 0, len(devices))
	for _, device := range devices {
		if device.agent.CompareAndSwap(link, nil) {
			cleared = append(cleared, device)
		}
	}
	return cleared
}
