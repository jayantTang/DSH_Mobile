package hub

import (
	"context"
	"strings"
	"time"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/dlp"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/push"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/quota"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// 通知与客户端上报记录（DESIGN-20261023 §3.6 的 notify 单元）。
//
// 连接器的一条 notify 变成对需要提醒的设备的 APNs 推送；同账户的状态变更通知
// 也在这里。客户端上报的构建号与连接器版本只做记账，不参与路由决策。

// ── APNs 推送（notify → 提醒）──────────────────────────────────────────────

// deliverNotify 把连接器的一条 `notify` 变成对"需要提醒的手机"的 APNs 推送。
//
// 四个条件都成立才推（Python hub._should_push）：
//
//	① 此刻不在线——在线的手机自己会弹本地通知，再推就是重复；
//	② 有推送登记（令牌与环境都有效，store 已把撤销/过期滤掉）；
//	③ 用户开着这一类提醒。
//
// 投递放在 goroutine 里：路由路径绝不等 Apple，推送失败只是一行日志。
func (h *Hub) deliverNotify(link *AgentLink, frame dlp.Frame) {
	sender := h.push
	if sender == nil || !sender.Enabled() {
		return
	}
	kind, _ := frame["kind"].(string)
	sid, _ := frame["sid"].(string)
	if (kind != "turnEnd" && kind != "attention") || sid == "" {
		h.log.Debug("relay: ignoring malformed notify from agent", "agentId", link.AgentID)
		return
	}
	var eid *string
	if value, ok := frame["eid"].(string); ok && value != "" {
		eid = &value
	}
	if h.store == nil {
		return
	}
	go h.sendReminders(link, kind, sid, eid)
}

// sendReminders 读推送目标、筛出该推的那几台、投递并按结果清理失效登记。
func (h *Hub) sendReminders(link *AgentLink, kind, sid string, eid *string) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	rows, err := h.store.PushTargets(ctx, link.AgentID)
	if err != nil {
		h.log.Warn("relay: could not read push targets",
			"agentId", link.AgentID, "error", err)
		return
	}
	wanted := make([]store.Device, 0, len(rows))
	for _, row := range rows {
		if h.shouldPush(link, row, kind) {
			wanted = append(wanted, row)
		}
	}
	if len(wanted) == 0 {
		return
	}
	targets := make([]push.Target, 0, len(wanted))
	for _, row := range wanted {
		targets = append(targets, push.Target{
			DeviceID: row.DeviceID, Token: stringValue(row.APNSToken), Env: row.APNSEnv,
		})
	}
	results := h.push.SendMany(ctx, targets, kind, sid, eid, false)
	for index, row := range wanted {
		if index >= len(results) {
			break
		}
		result := results[index]
		if result.OK {
			h.log.Info("relay: pushed a reminder",
				"kind", kind, "deviceId", row.DeviceID)
			continue
		}
		if result.DeadToken {
			// Apple 的判定是这套系统唯一的自动清理：App 没了或重装了，登记就是
			// 陈旧记录，等它回来重新登记。
			h.log.Info("relay: device push token is dead; clearing it",
				"deviceId", row.DeviceID, "kind", kind,
				"status", statusValue(result.Status), "reason", stringValue(result.Reason))
			if err := h.store.ClearPush(ctx, row.DeviceID); err != nil {
				h.log.Warn("relay: could not clear push",
					"deviceId", row.DeviceID, "error", err)
			}
			continue
		}
		if result.Skipped != nil {
			h.log.Info("relay: push skipped", "deviceId", row.DeviceID,
				"kind", kind, "skipped", stringValue(result.Skipped))
			continue
		}
		h.log.Warn("relay: push failed",
			"deviceId", row.DeviceID, "kind", kind,
			"status", statusValue(result.Status),
			"reason", stringValue(result.Reason))
	}
}

// shouldPush 判断一台设备要不要收这条提醒。
func (h *Hub) shouldPush(link *AgentLink, row store.Device, kind string) bool {
	// ① 此刻不在线。在线的手机自己会弹本地通知（$events → App），再推就是重复。
	if h.registry.deviceOnlineOn(link, row.DeviceID) {
		return false
	}
	// ② 有推送登记（令牌与环境都有效；store 已把撤销/过期滤掉）。
	if row.APNSToken == nil || row.APNSEnv == nil {
		return false
	}
	// ③ 用户开着这一类提醒。
	if kind == "turnEnd" {
		return row.PushTurnEnd != 0
	}
	return row.PushAttention != 0
}

// ── 记账 ─────────────────────────────────────────────────────────────────────

// noteClientBuild 记录手机上报的构建号（只在值变化时写库）。
func (h *Hub) noteClientBuild(link *DeviceLink, wire dlp.Wire) {
	frame, err := wire.Decode()
	if err != nil {
		// 帧到了但解不开：说明握手调用存在、只是结构不对（不该发生，出现即查协议）。
		h.log.Warn("relay: device handshake could not be decoded",
			"deviceId", link.DeviceID, "error", err)
		return
	}
	args, ok := frame["args"].(map[string]any)
	if !ok {
		// 2026-10-29 排查用：设备行里的构建号一直不刷新，先分清是"帧没到"还是
		// "到了但没带字段"。这条只在解不出 args 时出现，平时不会刷日志。
		h.log.Warn("relay: device handshake carried no args",
			"deviceId", link.DeviceID)
		return
	}
	var parts []string
	for _, key := range []string{"clientVersion", "clientBuild"} {
		if text, ok := args[key].(string); ok && text != "" {
			parts = append(parts, text)
		}
	}
	if len(parts) == 0 {
		h.log.Warn("relay: device handshake carried no client build",
			"deviceId", link.DeviceID, "clientVersion", args["clientVersion"],
			"clientBuild", args["clientBuild"])
		return
	}
	reported := strings.Join(parts, " ")
	// 记进当天那行要在"和上次一样就跳过"之前：重连时设备行里已经是这个构建号，
	// 早退的话当天那行的 lastBuild 永远是空的。
	h.usage.NoteBuild(link.ref(), reported)
	if current := link.appVersion.Load(); current != nil && *current == reported {
		return
	}
	link.appVersion.Store(&reported)
	if h.store == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := h.store.SetDeviceAppVersion(ctx, link.DeviceID, reported); err != nil {
		h.log.Warn("relay: could not record the client build",
			"deviceId", link.DeviceID, "error", err)
		return
	}
	h.log.Info("relay: device reports its build",
		"deviceId", link.DeviceID, "build", reported)
}

// noteAgentVersions 记下这台电脑跑的是哪套版本（只认控制帧 hostStatus）。
//
// 用户报问题时我们手里只有中转：设备行里有手机的构建号，但电脑上是哪版连接器、
// 哪版 DSH 只有这里能留下。写库只在值变化时发生，一次连接最多一行。
func (h *Hub) noteAgentVersions(link *AgentLink, frame dlp.Frame) {
	info, ok := frame["info"].(map[string]any)
	if !ok {
		return
	}
	text := func(key string) string {
		value, ok := info[key].(string)
		if !ok {
			return ""
		}
		return strings.TrimSpace(value)
	}
	connector, host := text("version"), text("hostVersion")
	if connector == "" && host == "" {
		return
	}
	link.versionMu.Lock()
	if connector == link.connectorVersion && host == link.hostVersion {
		link.versionMu.Unlock()
		return
	}
	link.connectorVersion, link.hostVersion = connector, host
	link.versionMu.Unlock()

	// 这条连接完成了初始化：解除该 agent 的 unverified 标记与重连退避。
	// 只认当前代（迟到的旧连接上报不能给新连接背书）。
	if h.presence.Verified(link.AgentID, link.generation, time.Now()) {
		h.log.Info("relay: agent cleared its unverified state",
			"agentId", link.AgentID, "connector", connector, "host", host)
	}

	if h.store == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := h.store.SetAgentVersions(ctx, link.AgentID,
		quota.OptionalString(connector), quota.OptionalString(host), 0); err != nil {
		h.log.Warn("relay: could not record the agent versions",
			"agentId", link.AgentID, "error", err)
		return
	}
	h.log.Info("relay: agent reports its versions",
		"agentId", link.AgentID, "connector", connector, "host", host)
}

// ── 账户级通知 ───────────────────────────────────────────────────────────────

// NotifyAccountState 给同账户的在线设备各发一帧 accountState，返回送达数。
//
// **尽力而为**：入队失败（对端太慢）就当没发，不重试、不入队、不阻断写入方——
// 这条通道的意义是"两三秒内其他设备跟上"，最终一致性靠客户端前台拉取兜底。
// 排除写入者：它自己刚写完，本机已经改了。
func (h *Hub) NotifyAccountState(accountID string, keys []string, excludeDeviceID string) int {
	if accountID == "" || len(keys) == 0 {
		return 0
	}
	payload, err := dlp.Encode(dlp.AccountStateFrame(keys))
	if err != nil {
		h.log.Warn("relay: could not encode an accountState frame", "error", err)
		return 0
	}
	sent := 0
	for _, device := range h.registry.allDevices() {
		if device.AccountID != accountID || device.Closed() {
			continue
		}
		if excludeDeviceID != "" && device.DeviceID == excludeDeviceID {
			continue
		}
		if device.EnqueueControl(payload, "accountState", true) == Enqueued {
			sent++
		}
	}
	return sent
}
