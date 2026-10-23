package wsapi

import (
	"net/http"
	"net/http/httptest"
	"reflect"
	"sort"
	"strings"
	"testing"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// 编译期断言：生产实现必须满足端口（DESIGN §2.5 要求消费者侧做一次）。
var _ Store = (*store.Store)(nil)

// TestStorePortMatchesDesign 钉住握手端口的 4 个方法（DESIGN §2.5）。
func TestStorePortMatchesDesign(t *testing.T) {
	want := []string{"AgentBySecret", "DeviceByToken", "TouchAgent", "TouchDevice"}
	port := reflect.TypeOf((*Store)(nil)).Elem()
	got := make([]string, 0, port.NumMethod())
	for index := 0; index < port.NumMethod(); index++ {
		got = append(got, port.Method(index).Name)
	}
	sort.Strings(got)
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("wsapi.Store 方法集 = %v，设计期望 %v", got, want)
	}
}

// TestMissingTokenIsRejectedWithoutStore 钉住空 Options 的边界：没有令牌的握手
// 在碰仓储之前就回 401，所以 nil Store 不会 panic。
func TestMissingTokenIsRejectedWithoutStore(t *testing.T) {
	handlers := New(Options{})
	mux := http.NewServeMux()
	handlers.Register(mux, "")
	for _, path := range []string{"/link/agent", "/link/device"} {
		recorder := httptest.NewRecorder()
		mux.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, path, nil))
		if recorder.Code != http.StatusUnauthorized {
			t.Fatalf("%s 状态码 = %d，期望 401", path, recorder.Code)
		}
	}
}
