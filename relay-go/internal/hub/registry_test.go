package hub

import (
	"fmt"
	"sync"
	"testing"
)

// 本文件钉住 registry 的三索引规则（DESIGN §2.3 / §5.3）：
//
//	agentShards   agentId → 当前连接
//	deviceShards  deviceId → 当前设备连接
//	AgentLink.devices / DeviceLink.agent  正向/反向关系
//
// 用例只驱动 registry 的方法，并发的组合方式照着生产的调用顺序（attach → register、
// detachFromAgent → unregisterDevice、顶替后旧的拆除）来，不构造生产里不会出现的状态。

// newTestAgentLink 造一条不启动写循环的 agent 连接（registry 不关心传输）。
func newTestAgentLink(agentID string) *AgentLink {
	return &AgentLink{
		Link: newLink(newFakeSink(), "agent "+agentID, 4, 1<<20,
			discardLogger(), linkOptions{}.withDefaults()),
		AgentID: agentID,
		devices: map[string]*DeviceLink{},
	}
}

// newTestDeviceLink 造一条不启动写循环的设备连接。
func newTestDeviceLink(agentID, deviceID string) *DeviceLink {
	return &DeviceLink{
		DeviceID: deviceID,
		AgentID:  agentID,
		Link: newLink(newFakeSink(), "device "+deviceID, 4, 1<<20,
			discardLogger(), linkOptions{}.withDefaults()),
	}
}

// assertRelationInvariants 在**静止时刻**核对三索引是否互相一致。
//
// 先分别在各分片锁下把两侧关系复制出来，再在锁外比对：测试自身也不跨片持锁。
// 允许的两种合法状态：
//   - 设备挂在电脑上（device.agent 非 nil）：设备表里它就是当前登记，且正向索引
//     恰好只有它；
//   - 电脑不在线（device.agent 为 nil）：设备仍可在设备表里（设备保留、等重连）。
func assertRelationInvariants(t *testing.T, table *registry) {
	t.Helper()
	registered := map[*AgentLink]bool{}
	forward := map[string][]*AgentLink{} // deviceId → 正向索引里挂着它的 agent
	for index := range table.agentShards {
		shard := &table.agentShards[index]
		shard.mu.RLock()
		for id, agent := range shard.agents {
			if id != agent.AgentID {
				t.Errorf("agentShards[%q] 里放着 agentId=%q 的连接", id, agent.AgentID)
			}
			registered[agent] = true
			for deviceID, device := range agent.devices {
				if device.DeviceID != deviceID {
					t.Errorf("agent %s 的正向索引键 %q 指向 deviceId=%q 的连接",
						agent.AgentID, deviceID, device.DeviceID)
				}
				forward[deviceID] = append(forward[deviceID], agent)
			}
		}
		shard.mu.RUnlock()
	}

	devices := map[string]*DeviceLink{}
	for index := range table.deviceShards {
		shard := &table.deviceShards[index]
		shard.mu.RLock()
		for id, device := range shard.devices {
			if id != device.DeviceID {
				t.Errorf("deviceShards[%q] 里放着 deviceId=%q 的连接", id, device.DeviceID)
			}
			if previous := devices[id]; previous != nil && previous != device {
				t.Errorf("deviceShards 里 %q 出现了两条不同的登记", id)
			}
			devices[id] = device
		}
		shard.mu.RUnlock()
	}

	for id, device := range devices {
		agent := device.agent.Load()
		if agent == nil {
			continue // 电脑不在线：设备保留在设备表里是合法的
		}
		if !registered[agent] {
			t.Errorf("设备 %s 指向的 agent %s 不在 agentShards 里", id, agent.AgentID)
			continue
		}
		owners := forward[id]
		if len(owners) != 1 || owners[0] != agent {
			t.Errorf("设备 %s 的 device.agent=%s，但正向索引是 %v", id, agent.AgentID, owners)
		}
	}

	for id, owners := range forward {
		if len(owners) != 1 {
			t.Errorf("设备 %s 同时挂在 %d 条 agent 连接上", id, len(owners))
			continue
		}
		device := devices[id]
		if device == nil {
			t.Errorf("agent %s 的正向索引里有 %s，但设备表里没有", owners[0].AgentID, id)
			continue
		}
		if device.agent.Load() != owners[0] {
			t.Errorf("设备 %s 的正向索引指向 %s，但 device.agent=%v",
				id, owners[0].AgentID, device.agent.Load())
		}
	}
}

// TestRegistryRelationInvariants：并发的挂接/摘除/顶替之后，三索引仍然互相一致。
func TestRegistryRelationInvariants(t *testing.T) {
	const (
		agentCount      = 6
		devicesPerAgent = 5
		rounds          = 40
	)
	table := newRegistry()
	agents := make([]*AgentLink, agentCount)
	for index := range agents {
		agents[index] = newTestAgentLink(fmt.Sprintf("agt_%02d", index))
		table.registerAgent(agents[index])
	}

	// 阶段 1：设备连接的高频 attach/detach（每个 goroutine 独占一个 deviceId，
	// 所以只会与自己的上一次登记交替，不会构造生产里没有的同 id 交叉挂接）。
	var churn sync.WaitGroup
	for agentIndex := 0; agentIndex < agentCount; agentIndex++ {
		for deviceIndex := 0; deviceIndex < devicesPerAgent; deviceIndex++ {
			churn.Add(1)
			go func(agentIndex, deviceIndex int) {
				defer churn.Done()
				agentID := agents[agentIndex].AgentID
				deviceID := fmt.Sprintf("dev_%02d_%02d", agentIndex, deviceIndex)
				for round := 0; round < rounds; round++ {
					link := newTestDeviceLink(agentID, deviceID)
					if _, err := table.attachToAgent(link, 8); err != nil {
						t.Errorf("attachToAgent(%s): %v", deviceID, err)
						return
					}
					if previous := table.registerDevice(link); previous != nil {
						// 上一次的 socket 迟到拆除：这时正向索引已经指向新连接，
						// 旧的拆除必须走"已被顶替"这条分支。
						table.detachFromAgent(previous)
						table.unregisterDevice(previous)
					}
					if agent, notified, replaced := table.detachFromAgent(link); agent == nil ||
						!notified || replaced {
						t.Errorf("设备 %s 的第 %d 次拆除：agent=%v notified=%v replaced=%v",
							deviceID, round, agent, notified, replaced)
						return
					}
					table.unregisterDevice(link)
				}
			}(agentIndex, deviceIndex)
		}
	}
	churn.Wait()
	assertRelationInvariants(t, table)

	// 阶段 2：电脑连接被顶替，新连接认领仍在线的设备（adoptDevices 的顺序）。
	// 每台电脑一条设备连接，之后不再出现同 id 的新设备连接，所以 bindDevice 与
	// 设备拆除不会互相覆盖。
	for index := 0; index < agentCount; index++ {
		device := newTestDeviceLink(agents[index].AgentID, fmt.Sprintf("dev_adopt_%02d", index))
		if _, err := table.attachToAgent(device, 8); err != nil {
			t.Fatalf("准备设备 %s: %v", device.DeviceID, err)
		}
		table.registerDevice(device)
	}

	var supersede sync.WaitGroup
	for index := 0; index < agentCount; index++ {
		supersede.Add(1)
		go func(index int) {
			defer supersede.Done()
			for round := 0; round < rounds/4; round++ {
				previous := agents[index]
				fresh := newTestAgentLink(previous.AgentID)
				table.registerAgent(fresh)

				// 旧连接的拆除不能动新连接，也不该清掉新连接认领的设备。
				if _, current := table.detachAgent(previous); current {
					t.Errorf("被顶替的旧连接仍是当前连接（agentId=%s）", previous.AgentID)
					return
				}
				for _, device := range table.devicesOfAgent(fresh.AgentID) {
					table.bindDevice(fresh, device)
				}

				if round%2 == 1 {
					// 新连接也退场：它名下的设备保留在设备表里，只清反向指针。
					bound, current := table.detachAgent(fresh)
					if !current {
						t.Errorf("当前连接被自己的拆除判成非当前（agentId=%s）", fresh.AgentID)
						return
					}
					table.releaseDevices(fresh, bound)
				}
				agents[index] = fresh
			}
		}(index)
	}
	supersede.Wait()
	assertRelationInvariants(t, table)

	// 收尾：全部连接按生产顺序退场，注册表应当回到空图。
	for _, agent := range table.agents() {
		bound, current := table.detachAgent(agent)
		if !current {
			t.Fatalf("收尾时 agent %s 已不是当前连接", agent.AgentID)
		}
		table.releaseDevices(agent, bound)
	}
	for _, device := range table.allDevices() {
		table.unregisterDevice(device)
	}
	if agentsLeft := table.agents(); len(agentsLeft) != 0 {
		t.Fatalf("收尾后还剩 %d 条 agent 连接", len(agentsLeft))
	}
	if devicesLeft := table.allDevices(); len(devicesLeft) != 0 {
		t.Fatalf("收尾后还剩 %d 条设备连接", len(devicesLeft))
	}
	assertRelationInvariants(t, table)
}

// TestRegistryLookupsAnswerFromOneGraph：六个只读入口回答的是同一张图。
func TestRegistryLookupsAnswerFromOneGraph(t *testing.T) {
	table := newRegistry()
	agent := newTestAgentLink("agt_lookup")
	other := newTestAgentLink("agt_other")
	table.registerAgent(agent)

	first := newTestDeviceLink("agt_lookup", "dev_1")
	second := newTestDeviceLink("agt_lookup", "dev_2")
	for _, device := range []*DeviceLink{second, first} {
		if attached, err := table.attachToAgent(device, 4); err != nil || attached != agent {
			t.Fatalf("attachToAgent(%s) = %v, %v", device.DeviceID, attached, err)
		}
		table.registerDevice(device)
	}

	if table.agent("agt_lookup") != agent {
		t.Fatal("agent 查找没有返回登记的连接")
	}
	if table.agent("agt_missing") != nil {
		t.Fatal("未登记的 agentId 不应有连接")
	}
	if table.device("dev_1") != first || table.device("dev_2") != second {
		t.Fatal("device 查找没有返回登记的连接")
	}
	if got := table.devices("agt_lookup"); len(got) != 2 || got[0] != "dev_1" || got[1] != "dev_2" {
		t.Fatalf("devices 应当是排序后的 [dev_1 dev_2]，得到 %v", got)
	}
	if count := table.countAgents(); count != 1 {
		t.Fatalf("countAgents = %d，期望 1", count)
	}

	views := table.agentViews()
	if len(views) != 1 || views[0].link != agent {
		t.Fatalf("agentViews = %+v", views)
	}
	if len(views[0].devices) != 2 || views[0].devices[0] != "dev_1" {
		t.Fatalf("agentViews 的设备 id = %v", views[0].devices)
	}
	if got := table.attachedDevices(agent); len(got) != 2 {
		t.Fatalf("attachedDevices = %v", got)
	}
	if got := table.devicesOfAgent("agt_lookup"); len(got) != 2 {
		t.Fatalf("devicesOfAgent = %v", got)
	}

	if got := table.deviceOfAgent(agent, []byte("dev_1")); got != first {
		t.Fatalf("deviceOfAgent(当前连接) = %v", got)
	}
	if got := table.deviceOfAgent(other, []byte("dev_1")); got != nil {
		t.Fatalf("deviceOfAgent(未登记连接) = %v，不该查到别人的设备", got)
	}
	if !table.deviceOnlineOn(agent, "dev_1") {
		t.Fatal("dev_1 应当在线")
	}
	if table.deviceOnlineOn(other, "dev_1") {
		t.Fatal("未登记连接不该被当成在线")
	}

	bound, current := table.detachAgent(agent)
	if !current || len(bound) != 2 {
		t.Fatalf("detachAgent = %v, current=%v", bound, current)
	}
	if cleared := table.releaseDevices(agent, bound); len(cleared) != 2 {
		t.Fatalf("releaseDevices = %v，期望清掉两条", cleared)
	}
	if first.agent.Load() != nil || second.agent.Load() != nil {
		t.Fatal("电脑退场后设备仍指着它")
	}
	if table.deviceOnlineOn(agent, "dev_1") {
		t.Fatal("连接已摘除，deviceOnlineOn 仍报在线")
	}
	if table.device("dev_1") != first {
		t.Fatal("电脑掉线不该把设备从设备表里摘掉")
	}
	assertRelationInvariants(t, table)
}

// TestRegistryDeviceLimitLeavesNothingRegistered：额度拒绝时正向/反向/设备表都不留痕，
// 且同一台设备重连不计新名额（与 DeviceBudgetExceeded 同一口径）。
func TestRegistryDeviceLimitLeavesNothingRegistered(t *testing.T) {
	table := newRegistry()
	agent := newTestAgentLink("agt_limit")
	table.registerAgent(agent)

	first := newTestDeviceLink("agt_limit", "dev_first")
	if _, err := table.attachToAgent(first, 1); err != nil {
		t.Fatalf("第一台设备应当被接纳：%v", err)
	}
	table.registerDevice(first)

	second := newTestDeviceLink("agt_limit", "dev_second")
	if !table.deviceBudgetExceeded("agt_limit", second.DeviceID, 1) {
		t.Fatal("第二台设备应当被判超额")
	}
	if _, err := table.attachToAgent(second, 1); err != ErrDeviceLimit {
		t.Fatalf("attachToAgent(second) = %v，期望 ErrDeviceLimit", err)
	}
	if second.agent.Load() != nil {
		t.Fatal("被拒绝的设备不该拿到 agent 指针")
	}
	if _, registered := agent.devices[second.DeviceID]; registered {
		t.Fatal("被拒绝的设备不该出现在正向索引里")
	}
	if table.device(second.DeviceID) != nil {
		t.Fatal("被拒绝的设备不该登记进设备表")
	}

	if table.deviceBudgetExceeded("agt_limit", first.DeviceID, 1) {
		t.Fatal("同一台设备重连不该计入新名额")
	}
	assertRelationInvariants(t, table)
}

// TestRegistryDetachDeviceNotifiesOnlyCurrent：被同 deviceId 新连接顶替的旧 socket
// 不发通知，新连接不受旧 socket 拆除影响（DESIGN §3.5 / §5.3）。
func TestRegistryDetachDeviceNotifiesOnlyCurrent(t *testing.T) {
	table := newRegistry()
	agent := newTestAgentLink("agt_replace")
	table.registerAgent(agent)

	oldLink := newTestDeviceLink("agt_replace", "dev_same")
	if _, err := table.attachToAgent(oldLink, 8); err != nil {
		t.Fatalf("attachToAgent(old): %v", err)
	}
	if previous := table.registerDevice(oldLink); previous != nil {
		t.Fatalf("第一次登记不该有被顶替者：%v", previous)
	}

	current := newTestDeviceLink("agt_replace", "dev_same")
	if _, err := table.attachToAgent(current, 8); err != nil {
		t.Fatalf("attachToAgent(current): %v", err)
	}
	if previous := table.registerDevice(current); previous != oldLink {
		t.Fatalf("registerDevice 返回的被顶替者 = %v，期望旧连接", previous)
	}

	owner, notified, replaced := table.detachFromAgent(oldLink)
	if owner != agent || notified || !replaced {
		t.Fatalf("旧 socket 拆除：agent=%v notified=%v replaced=%v，期望 不发通知且判为被顶替",
			owner, notified, replaced)
	}
	if oldLink.agent.Load() != nil {
		t.Fatal("旧 socket 拆除后仍指着 agent")
	}
	table.unregisterDevice(oldLink)
	if table.device("dev_same") != current {
		t.Fatal("旧 socket 的拆除摘掉了新连接的登记")
	}
	if current.agent.Load() != agent {
		t.Fatal("旧 socket 的拆除清掉了新连接的反向指针")
	}

	if _, notified, replaced := table.detachFromAgent(current); !notified || replaced {
		t.Fatalf("当前 socket 拆除：notified=%v replaced=%v，期望发通知", notified, replaced)
	}
	table.unregisterDevice(current)
	if table.device("dev_same") != nil {
		t.Fatal("当前 socket 拆除后设备表里还留着登记")
	}
	assertRelationInvariants(t, table)
}

// TestRegistryReleaseDevicesDoesNotClobberAdoptedDevices：设备在"电脑摘除"与
// "新电脑认领"之间被重新绑定后，迟到的释放不能把新关系抹掉（CAS 的唯一理由）。
func TestRegistryReleaseDevicesDoesNotClobberAdoptedDevices(t *testing.T) {
	table := newRegistry()
	oldAgent := newTestAgentLink("agt_release")
	table.registerAgent(oldAgent)
	device := newTestDeviceLink("agt_release", "dev_release")
	if _, err := table.attachToAgent(device, 8); err != nil {
		t.Fatalf("attachToAgent: %v", err)
	}
	table.registerDevice(device)

	bound, current := table.detachAgent(oldAgent)
	if !current || len(bound) != 1 {
		t.Fatalf("detachAgent = %v, current=%v", bound, current)
	}

	// 摘除之后、释放之前，新电脑已经认领了这台设备（AttachAgent 的 adoptDevices）。
	fresh := newTestAgentLink(oldAgent.AgentID)
	table.registerAgent(fresh)
	if !table.bindDevice(fresh, device) {
		t.Fatal("新连接没能认领设备")
	}
	if cleared := table.releaseDevices(oldAgent, bound); len(cleared) != 0 {
		t.Fatalf("迟到的释放清掉了 %d 条新关系", len(cleared))
	}
	if device.agent.Load() != fresh {
		t.Fatal("设备没有留在新连接上")
	}
	assertRelationInvariants(t, table)
}
