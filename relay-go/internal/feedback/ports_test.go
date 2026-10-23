package feedback

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

// TestStorePortMatchesDesign 钉住用户侧四端点的 9 个方法（DESIGN §2.5）。
//
// 它**不含** owner 侧方法：CreateNotice 之类只由 admin 命令使用，用户侧端点
// 不该拿得到；多一个就红。
func TestStorePortMatchesDesign(t *testing.T) {
	want := []string{
		"AppendFeedbackMessage", "CreateFeedbackThread", "DeviceByToken",
		"FeedbackThread", "FeedbackThreadsByDevice", "FeedbackThreadsByTickets",
		"MarkNoticesRead", "MarkThreadRead", "NoticesForAccount",
	}
	port := reflect.TypeOf((*Store)(nil)).Elem()
	got := make([]string, 0, port.NumMethod())
	for index := 0; index < port.NumMethod(); index++ {
		got = append(got, port.Method(index).Name)
	}
	sort.Strings(got)
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("feedback.Store 方法集 = %v，设计期望 %v", got, want)
	}
}

// TestBadBodyIsRejectedWithoutStore 钉住空 Options 的边界：请求体在碰仓储之前
// 就被校验挡住，所以 nil Store 不会 panic。
func TestBadBodyIsRejectedWithoutStore(t *testing.T) {
	handlers := New(Options{})
	mux := http.NewServeMux()
	handlers.Register(mux, "")
	request := httptest.NewRequest(http.MethodPost, "/feedback/submit",
		strings.NewReader(`{}`))
	request.Header.Set("Content-Type", "application/json")
	recorder := httptest.NewRecorder()
	mux.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("空提交状态码 = %d，期望 400（%s）", recorder.Code, recorder.Body.String())
	}
}
