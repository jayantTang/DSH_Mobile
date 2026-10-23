package hub

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/dlp"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// remoteFakeSink 是带对端地址的假连接（生产里由 wsapi 提供地址）。
type remoteFakeSink struct {
	*fakeSink
	addr string
}

func (s *remoteFakeSink) RemoteAddr() string { return s.addr }

func TestDebugConnsReportsEachLiveConnection(t *testing.T) {
	f := newFixture(t, Options{})
	owner := f.newTenant("debug-mac")

	agentSink := &remoteFakeSink{fakeSink: newFakeSink(), addr: "203.0.113.9:5555"}
	agentLink := f.hub.AttachAgent(context.Background(), owner.agent, agentSink,
		f.admitAgent(owner))
	f.hub.noteAgentVersions(agentLink, dlp.Frame{"t": "hostStatus",
		"info": map[string]any{"version": "0.6.6", "hostVersion": "1.2.3"}})
	agentLink.NoteInbound()
	agentLink.NoteError(errors.New("write boom"))
	agentLink.noteControlDrop("pong")

	deviceSink := &remoteFakeSink{fakeSink: newFakeSink(), addr: "198.51.100.7:6000"}
	device := store.Device{
		DeviceID: "dev_debug_phone", AgentID: owner.agent.AgentID,
		AccountID: owner.account.AccountID, Name: "iPhone",
	}
	deviceLink, err := f.hub.AttachDevice(context.Background(), device, deviceSink)
	if err != nil {
		t.Fatalf("AttachDevice: %v", err)
	}
	deviceLink.NoteError(errors.New("read reset"))

	snapshot := f.hub.DebugConns()
	if snapshot.Now <= 0 {
		t.Fatalf("now = %d", snapshot.Now)
	}
	if len(snapshot.Agents) != 1 || len(snapshot.Devices) != 1 {
		t.Fatalf("快照 = %+v", snapshot)
	}

	agent := snapshot.Agents[0]
	if agent.Kind != "agent" || agent.AgentID != owner.agent.AgentID {
		t.Fatalf("agent 行 = %+v", agent)
	}
	if agent.Remote != "203.0.113.9:5555" {
		t.Fatalf("remote = %q", agent.Remote)
	}
	if agent.ConnectedAt <= 0 || agent.LastInbound <= 0 {
		t.Fatalf("时间字段 = %+v", agent)
	}
	if agent.ControlDrops != 1 {
		t.Fatalf("controlDrops = %d", agent.ControlDrops)
	}
	if agent.ConnectorVersion != "0.6.6" || agent.HostVersion != "1.2.3" {
		t.Fatalf("版本 = %q/%q", agent.ConnectorVersion, agent.HostVersion)
	}
	if agent.LastError != "write boom" {
		t.Fatalf("lastError = %q", agent.LastError)
	}
	if agent.Generation == 0 || agent.Closing {
		t.Fatalf("generation/closing = %d/%v", agent.Generation, agent.Closing)
	}

	deviceRow := snapshot.Devices[0]
	if deviceRow.Kind != "device" || deviceRow.DeviceID != device.DeviceID ||
		deviceRow.AgentID != owner.agent.AgentID {
		t.Fatalf("device 行 = %+v", deviceRow)
	}
	if deviceRow.Remote != "198.51.100.7:6000" || deviceRow.LastError != "read reset" {
		t.Fatalf("device remote/lastError = %+v", deviceRow)
	}

	// 快照里没有任何凭据：hub 从不持有明文令牌，这里再钉一次字段形状。
	payload, err := json.Marshal(snapshot)
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	for _, forbidden := range []string{"secret", "token", "authorization"} {
		if strings.Contains(strings.ToLower(string(payload)), forbidden) {
			t.Fatalf("快照里出现了 %q：%s", forbidden, payload)
		}
	}
}
