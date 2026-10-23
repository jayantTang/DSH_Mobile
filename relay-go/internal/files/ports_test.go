package files

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
