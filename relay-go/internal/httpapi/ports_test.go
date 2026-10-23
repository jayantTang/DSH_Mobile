package httpapi

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

// TestStorePortMatchesDesign 钉住 httpapi 自己的 15 个方法（DESIGN §2.5）。
//
// 它**不是** wsapi/files/feedback 的并集：三者由组合根注入各自的端口。
// 端口多一个方法就红。
func TestStorePortMatchesDesign(t *testing.T) {
	want := []string{
		"AccountState", "AgentBySecret", "ClaimInvite", "ClaimPairCode",
		"CountPairedDevices", "DeviceByID", "DeviceByToken", "DeviceHygiene",
		"ListDevices", "MintPairCode", "PutAccountStateBatch", "RefreshDevice",
		"RegeneratePairCode", "RevokeDevice", "SetPush",
	}
	port := reflect.TypeOf((*Store)(nil)).Elem()
	got := make([]string, 0, port.NumMethod())
	for index := 0; index < port.NumMethod(); index++ {
		got = append(got, port.Method(index).Name)
	}
	sort.Strings(got)
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("httpapi.Store 方法集 = %v，设计期望 %v", got, want)
	}
}

// TestHealthOnlyOptionsSurviveNilStore 钉住空 Options：没有 Store、没有 Hub、
// 没有子 handler 时 /healthz 仍然可用（DESIGN §3.2 的 nil 可用性约束）。
func TestHealthOnlyOptionsSurviveNilStore(t *testing.T) {
	handler := New(Options{})
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if recorder.Code != http.StatusOK {
		t.Fatalf("/healthz 状态码 = %d，期望 200（%s）", recorder.Code, recorder.Body.String())
	}
}

// TestSubHandlersAreMountedWhenInjected 钉住组合根的接缝：三条子路由由注入的
// handler 挂载，各自在碰仓储之前就能回自己的状态码。它防的是"main 忘了注入，
// 路由整组消失"这类装错配。
func TestSubHandlersAreMountedWhenInjected(t *testing.T) {
	api := newTestAPI(t)
	cases := []struct {
		method string
		path   string
		body   string
		code   int
	}{
		{http.MethodGet, "/link/agent", "", http.StatusUnauthorized},
		{http.MethodPut, "/files/up?sessionId=s&name=n&bid=b&bytes=1", "", http.StatusUnauthorized},
		{http.MethodPost, "/feedback/submit", `{}`, http.StatusBadRequest},
	}
	for _, testCase := range cases {
		request := httptest.NewRequest(testCase.method, testCase.path, strings.NewReader(testCase.body))
		if testCase.body != "" {
			request.Header.Set("Content-Type", "application/json")
		}
		request.RemoteAddr = "127.0.0.1:51000"
		recorder := httptest.NewRecorder()
		api.handler.ServeHTTP(recorder, request)
		if recorder.Code != testCase.code {
			t.Fatalf("%s %s 状态码 = %d，期望 %d（%s）", testCase.method,
				testCase.path, recorder.Code, testCase.code, recorder.Body.String())
		}
	}
}
