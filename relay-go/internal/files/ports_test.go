package files

import (
	"net/http"
	"net/http/httptest"
	"reflect"
	"sort"
	"strings"
	"testing"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/hub"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// 编译期断言：生产实现必须满足端口（DESIGN §2.5 要求消费者侧做一次）。
var _ Store = (*store.Store)(nil)

// 文件通道的 hub 门面同样在消费者侧固定（DESIGN §3.6）。
var _ Hub = (*hub.Hub)(nil)

// TestStorePortMatchesDesign 钉住文件端点只需要 1 个仓储方法（DESIGN §2.5）。
func TestStorePortMatchesDesign(t *testing.T) {
	want := []string{"DeviceByToken"}
	port := reflect.TypeOf((*Store)(nil)).Elem()
	got := make([]string, 0, port.NumMethod())
	for index := 0; index < port.NumMethod(); index++ {
		got = append(got, port.Method(index).Name)
	}
	sort.Strings(got)
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("files.Store 方法集 = %v，设计期望 %v", got, want)
	}
}

// TestHubPortMatchesDesign 钉住文件通道只需要这 11 个 hub 方法。
//
// 端口多一个方法就红：文件端点不能借机重新拿到 registry、分片 map 或其他
// 内部状态；少一个方法则编译不过（var _ Hub = (*hub.Hub)(nil)）。
func TestHubPortMatchesDesign(t *testing.T) {
	want := []string{
		"Agent", "CancelFetch", "ChargeDeviceQuota", "CloseBridge", "Device",
		"DeviceQuotaRemaining", "OpenFetchBridge", "OpenPutBridge",
		"SeatDeviceQuota", "SendBridgeChunk", "SendControl",
	}
	port := reflect.TypeOf((*Hub)(nil)).Elem()
	got := make([]string, 0, port.NumMethod())
	for index := 0; index < port.NumMethod(); index++ {
		got = append(got, port.Method(index).Name)
	}
	sort.Strings(got)
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("files.Hub 方法集 = %v，设计期望 %v", got, want)
	}
}

// TestMissingTokenIsRejectedWithoutStore 钉住空 Options 的边界：两条端点在缺
// 令牌时直接回 401，不会去碰 nil Store。
func TestMissingTokenIsRejectedWithoutStore(t *testing.T) {
	handlers := New(Options{})
	mux := http.NewServeMux()
	handlers.Register(mux, "")
	cases := []struct {
		method string
		path   string
	}{
		{http.MethodPut, "/files/up?sessionId=s&name=n&bid=b&bytes=1"},
		{http.MethodGet, "/files/down?scopeId=s&path=p"},
	}
	for _, testCase := range cases {
		recorder := httptest.NewRecorder()
		mux.ServeHTTP(recorder, httptest.NewRequest(testCase.method, testCase.path, nil))
		if recorder.Code != http.StatusUnauthorized {
			t.Fatalf("%s %s 状态码 = %d，期望 401",
				testCase.method, testCase.path, recorder.Code)
		}
	}
}
