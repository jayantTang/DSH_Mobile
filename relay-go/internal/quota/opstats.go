package quota

import (
	"sync"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// Op 是设备操作的种类。它只用于用量账本，不是协议类型。
type Op uint8

const (
	// OpPrompt 是一条 session/prompt 请求。
	OpPrompt Op = iota + 1
	// OpAnswer 是一次 eventResult 作答提交。
	OpAnswer
)

// seenSlots 是每台设备、每种操作保留的最近指纹数。
//
// 重发风暴的特征是同一小批键反复出现，而不是无限新键；512 槽足以让同一请求的
// 重试全部命中，同时把每设备内存钉在 2 × 512 × 8 字节。槽满后覆盖最旧的一条：
// 两次重发之间插入超过 512 条不同消息时，迟到重发可能多计一次，这是有界误差。
const seenSlots = 512

// seenRing 是零分配的固定容量指纹环。
//
// 不用 map：map 在风暴下会持续增长，且每次插入可能分配。线性扫描在 512 槽、
// 人类操作频率下只有几百次比较，远低于一次 JSON 解析。
type seenRing struct {
	slots [seenSlots]uint64
	next  uint16
	used  uint16
}

// add 返回 true 表示这是第一次见到该指纹；false 表示重复。
func (r *seenRing) add(fingerprint uint64) bool {
	for index := 0; index < int(r.used); index++ {
		if r.slots[index] == fingerprint {
			return false
		}
	}
	if int(r.used) < len(r.slots) {
		r.slots[r.used] = fingerprint
		r.used++
		return true
	}
	r.slots[r.next] = fingerprint
	r.next = (r.next + 1) % seenSlots
	return true
}

// deviceSeen 是一台设备的两种操作指纹表。分开保存，避免消息风暴把作答键挤出。
type deviceSeen struct {
	prompts seenRing
	answers seenRing
	lastAt  int64
}

// seenStore 是按设备隔离的最近操作指纹。
//
// 它有自己的锁：环形扫描不应阻塞 NoteEgress 的字节账本锁。两把锁从不嵌套，
// NoteOpOnce 先通过去重检查，再短暂持有账本锁累加计数。
type seenStore struct {
	mu      sync.Mutex
	devices map[string]*deviceSeen
}

// add 记录一次操作；true 表示第一次见到。
func (s *seenStore) add(deviceID string, op Op, fingerprint uint64) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.devices == nil {
		s.devices = map[string]*deviceSeen{}
	}
	device := s.devices[deviceID]
	if device == nil {
		device = &deviceSeen{}
		s.devices[deviceID] = device
	}
	device.lastAt = store.NowMS()
	switch op {
	case OpPrompt:
		return device.prompts.add(fingerprint)
	case OpAnswer:
		return device.answers.add(fingerprint)
	default:
		return false
	}
}

// seenMaxAgeMS 是空闲设备指纹表的保留时长。超过它的设备通常早已过期/撤销，
// 继续占着 8 KiB 只会让内存随历史设备数增长。
const seenMaxAgeMS = 7 * 24 * 60 * 60 * 1000

// prune 丢掉超过 maxAgeMS 没有操作的设备指纹表，返回删除数量。
func (s *seenStore) prune(nowMS, maxAgeMS int64) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	removed := 0
	for deviceID, device := range s.devices {
		if nowMS-device.lastAt > maxAgeMS {
			delete(s.devices, deviceID)
			removed++
		}
	}
	return removed
}

// forget 丢掉一台设备的指纹表（设备撤销或清理时调用）。
func (s *seenStore) forget(deviceID string) {
	s.mu.Lock()
	delete(s.devices, deviceID)
	s.mu.Unlock()
}

// deviceCount 只给单测断言用：确认清理后不留下空表。
func (s *seenStore) deviceCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.devices)
}
