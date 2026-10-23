package opsreport

import (
	"reflect"
	"sort"
	"testing"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// Source 的实现就是 *store.Store（编译期断言：签名一旦漂移，这里先红）。
var _ Source = (*store.Store)(nil)

// TestSourcePortIsExactlyTheTenReportMethods 钉住取数面：端口只能包含报告实际
// 用到的方法，不能被顺手扩成"换个名字的 Store"。
func TestSourcePortIsExactlyTheTenReportMethods(t *testing.T) {
	port := reflect.TypeOf((*Source)(nil)).Elem()
	want := []string{
		"FeedbackDigest", "ListAccounts", "ListAgents", "ListDevices",
		"ListEnrollments", "ListFeedbackThreads", "ListInvites", "OwnerUnreadCounts",
		"UsageRows", "UsageTotals",
	}
	got := make([]string, 0, port.NumMethod())
	for index := 0; index < port.NumMethod(); index++ {
		got = append(got, port.Method(index).Name)
	}
	sort.Strings(got)
	sort.Strings(want)
	if len(got) != len(want) {
		t.Fatalf("Source 有 %d 个方法，期望 %d：%v", len(got), len(want), got)
	}
	for index := range want {
		if got[index] != want[index] {
			t.Fatalf("Source 方法集不匹配：got %v want %v", got, want)
		}
	}
}
