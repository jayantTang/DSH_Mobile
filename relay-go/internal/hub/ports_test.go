package hub

import (
	"context"
	"errors"
	"reflect"
	"sort"
	"strings"
	"testing"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// 编译期断言：生产实现必须满足端口（DESIGN §2.5 要求消费者侧做一次）。
var _ Store = (*store.Store)(nil)

// TestStorePortMatchesDesign 钉住 hub 端口的方法集 = DESIGN §2.5 的 10 个方法。
//
// 端口多一个方法（把 Store 的某个查询顺手加进来）就红：hub 的仓储面是设计表
// 的一部分，扩它要先改设计，而不是让端口悄悄长成上帝接口。
func TestStorePortMatchesDesign(t *testing.T) {
	want := []string{
		"AddUsage", "ClearPush", "ExpiredIDsOfAgent", "ListDevices", "PushTargets",
		"RevokedIDsAmong", "SetAgentVersions", "SetDeviceAppVersion", "TodayUsage",
		"UsageBytesOn",
	}
	port := reflect.TypeOf((*Store)(nil)).Elem()
	got := make([]string, 0, port.NumMethod())
	for index := 0; index < port.NumMethod(); index++ {
		got = append(got, port.Method(index).Name)
	}
	sort.Strings(got)
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("hub.Store 方法集 = %v，设计期望 %v", got, want)
	}
}

// TestNilStoreIsExplicitlyEmpty 钉住"没有配库"的边界：构造函数不 panic，需要
// 仓储的入口返回 errNoStore，而不是在 nil 接口上调用方法崩掉。
func TestNilStoreIsExplicitlyEmpty(t *testing.T) {
	instance := New(Options{})
	if instance == nil {
		t.Fatal("New(Options{}) 返回 nil")
	}
	if _, err := instance.Today(context.Background()); !errors.Is(err, errNoStore) {
		t.Fatalf("Today 错误 = %v，期望 errNoStore", err)
	}
	// 空账本不需要去处：没有待冲盘的行时 FlushUsage 是 no-op（与实现一致），
	// 有行时才走 errNoStore。这条钉住"没有库也能正常收尾"。
	if err := instance.FlushUsage(context.Background()); err != nil {
		t.Fatalf("空账本 FlushUsage 错误 = %v，期望 nil", err)
	}
	// 没有在线设备时对账不查库，返回 (nil, nil) 而不是 errNoStore。
	detached, err := instance.ReconcileRevokedDevices(context.Background())
	if err != nil || detached != nil {
		t.Fatalf("ReconcileRevokedDevices = (%v, %v)，期望 (nil, nil)", detached, err)
	}
}
