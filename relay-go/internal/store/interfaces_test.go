package store

import (
	"reflect"
	"sort"
	"strconv"
	"strings"
	"testing"
)

// 本文件钉住 DESIGN-20261023 §2.4 的领域划分：*Store 的每个导出方法要么属于
// 恰好一个领域接口，要么在生命周期白名单里。它防的是四类漂移：
//
//   - 新增 Store 方法却没有归入任何领域（测试红：无家可归）；
//   - 同一个方法被两个领域同时声明（测试红：归属不清）；
//   - 方法在领域之间搬家但没改设计表（测试红：黄金清单不符）；
//   - 接口里的签名与实现不一致（编译期已红，这里再给一条可读的消息）。

// lifecycleMethods 是四个不属于业务领域的生命周期方法（DESIGN §2.4 末段）。
//
// 它们描述的是"这个仓储对象本身"（路径、schema 版本、连通性、关闭），
// 不描述任何实体的状态，因此不进领域接口，也不许被领域接口收养。
var lifecycleMethods = []string{"Path", "Version", "Ping", "Close"}

// domainGolden 是 §2.4 表格的逐项副本：接口名 → 该方法集（排序后比较）。
//
// 它是**故意重复**的一份清单：接口本身只约束"能调用什么"，这份清单约束
// "哪个方法属于哪个领域"。设计表变了就同时改两处，测试才会通过。
var domainGolden = []struct {
	name    string
	methods []string
}{
	{"AccountStore", []string{"CreateAccount", "GetAccount", "ListAccounts"}},
	{"AgentStore", []string{
		"RegisterAgent", "SetAgentDisabled", "AgentByID", "AgentBySecret",
		"ListAgents", "TouchAgent", "SetAgentVersions",
	}},
	{"PairStore", []string{
		"MintPairCode", "RegeneratePairCode", "ClaimPairCode", "PurgeExpired",
	}},
	{"DeviceStore", []string{
		"DeviceByToken", "DeviceByID", "RevokedIDsAmong", "GoneIDsAmong",
		"ExpiredIDsOfAgent", "DeviceHygiene", "ListDevices", "RefreshDevice",
		"RevokeDevice", "SetPush", "ClearPush", "PushTargets",
		"SetDeviceAppVersion", "TouchDevice", "CountPairedDevices",
	}},
	{"AccountStateStore", []string{"AccountState", "PutAccountState", "PutAccountStateBatch"}},
	{"FeedbackStore", []string{
		"CreateFeedbackThread", "SetFeedbackSubject", "AppendFeedbackMessage",
		"CreateNotice", "FeedbackThread", "FeedbackThreadsByTickets",
		"FeedbackThreadsByDevice", "MarkThreadRead", "NoticesForAccount",
		"MarkNoticesRead", "OwnerUnreadCounts", "TouchOwnerRead",
		"ListFeedbackThreads", "DeleteFeedbackThread", "FeedbackDigest",
	}},
	{"UsageStore", []string{"AddUsage", "UsageRows", "UsageBytesOn", "UsageTotals", "TodayUsage"}},
	{"InviteStore", []string{
		"MintInvite", "InviteStatus", "ClaimInvite", "ListInvites",
		"RevokeInvite", "PurgeInvites", "InviteTotals", "ListEnrollments",
	}},
	{"MaintenanceStore", []string{
		"AgentIDsWithDevices", "DevicePurgeReport", "DeleteDoomedDevices",
		"CountDevicesOfAgents", "BackupTo",
	}},
}

// domainType 把黄金清单里的名字映射成接口类型。
func domainType(t *testing.T, name string) reflect.Type {
	t.Helper()
	switch name {
	case "AccountStore":
		return reflect.TypeOf((*AccountStore)(nil)).Elem()
	case "AgentStore":
		return reflect.TypeOf((*AgentStore)(nil)).Elem()
	case "PairStore":
		return reflect.TypeOf((*PairStore)(nil)).Elem()
	case "DeviceStore":
		return reflect.TypeOf((*DeviceStore)(nil)).Elem()
	case "AccountStateStore":
		return reflect.TypeOf((*AccountStateStore)(nil)).Elem()
	case "FeedbackStore":
		return reflect.TypeOf((*FeedbackStore)(nil)).Elem()
	case "UsageStore":
		return reflect.TypeOf((*UsageStore)(nil)).Elem()
	case "InviteStore":
		return reflect.TypeOf((*InviteStore)(nil)).Elem()
	case "MaintenanceStore":
		return reflect.TypeOf((*MaintenanceStore)(nil)).Elem()
	}
	t.Fatalf("黄金清单里的 %q 没有对应的接口类型", name)
	return nil
}

// methodNames 返回类型的方法名（排序）；接口与非接口都用它。
func methodNames(typ reflect.Type) []string {
	names := make([]string, 0, typ.NumMethod())
	for index := 0; index < typ.NumMethod(); index++ {
		names = append(names, typ.Method(index).Name)
	}
	sort.Strings(names)
	return names
}

// TestDomainInterfacesCoverEveryMethod 断言 65 个领域方法恰属一个领域接口，
// 4 个生命周期方法在白名单里，且导出方法总数正好 69（无遗漏、无重复）。
func TestDomainInterfacesCoverEveryMethod(t *testing.T) {
	storeType := reflect.TypeOf((*Store)(nil))
	exported := methodNames(storeType)

	lifecycle := map[string]bool{}
	for _, name := range lifecycleMethods {
		lifecycle[name] = true
	}

	owner := map[string][]string{}
	for _, domain := range domainGolden {
		typ := domainType(t, domain.name)
		got := methodNames(typ)
		want := append([]string(nil), domain.methods...)
		sort.Strings(want)
		if strings.Join(got, ",") != strings.Join(want, ",") {
			t.Errorf("%s 的方法集 = %v，设计与黄金清单期望 %v", domain.name, got, want)
		}
		for _, name := range got {
			owner[name] = append(owner[name], domain.name)
			if lifecycle[name] {
				t.Errorf("%s 声明了生命周期方法 %s：它不属于任何领域", domain.name, name)
			}
		}
	}

	domainCount := 0
	for _, name := range exported {
		if lifecycle[name] {
			continue
		}
		domainCount++
		switch claimed := owner[name]; len(claimed) {
		case 1:
		case 0:
			t.Errorf("%s 是导出方法但没有归入任何领域接口", name)
		default:
			t.Errorf("%s 被多个领域接口声明：%v", name, claimed)
		}
	}
	if domainCount != 65 {
		t.Errorf("领域方法数 = %d，期望 65", domainCount)
	}
	if len(exported) != 69 {
		t.Errorf("*Store 导出方法数 = %d，期望 69（65 领域 + 4 生命周期）", len(exported))
	}
	for _, name := range lifecycleMethods {
		if _, ok := storeType.MethodByName(name); !ok {
			t.Errorf("生命周期方法 %s 不在 *Store 上", name)
		}
	}
}

// TestDomainInterfaceSignaturesMatchStore 断言接口里的每个方法在 *Store 上都
// 存在且签名逐项一致（接口类型的方法签名不含 receiver，这里补上再比）。
//
// 编译期的 `var _ XStore = (*Store)(nil)` 已经能拦住不一致；这条测试的价值是
// 把"哪个方法不一致"打印出来，而不是只给一行编译错误。
func TestDomainInterfaceSignaturesMatchStore(t *testing.T) {
	storeType := reflect.TypeOf((*Store)(nil))
	for _, domain := range domainGolden {
		typ := domainType(t, domain.name)
		for index := 0; index < typ.NumMethod(); index++ {
			ifaceMethod := typ.Method(index)
			storeMethod, ok := storeType.MethodByName(ifaceMethod.Name)
			if !ok {
				t.Errorf("%s.%s 在 *Store 上不存在", domain.name, ifaceMethod.Name)
				continue
			}
			if mismatch := signatureMismatch(storeMethod, ifaceMethod); mismatch != "" {
				t.Errorf("%s.%s 签名不一致：%s", domain.name, ifaceMethod.Name, mismatch)
			}
		}
	}
}

// signatureMismatch 比较具体类型方法与接口方法（前者多一个 receiver 参数），
// 一致时返回空串，否则返回第一处差异的可读描述。
func signatureMismatch(concrete, iface reflect.Method) string {
	if concrete.Type.NumIn() != iface.Type.NumIn()+1 {
		return "参数个数不同"
	}
	receiver := reflect.TypeOf((*Store)(nil))
	if concrete.Type.In(0) != receiver {
		return "receiver 不是 *Store"
	}
	for index := 1; index < concrete.Type.NumIn(); index++ {
		if concrete.Type.In(index) != iface.Type.In(index-1) {
			return "第 " + strconv.Itoa(index) + " 个参数类型不同"
		}
	}
	if concrete.Type.NumOut() != iface.Type.NumOut() {
		return "返回值个数不同"
	}
	for index := 0; index < concrete.Type.NumOut(); index++ {
		if concrete.Type.Out(index) != iface.Type.Out(index) {
			return "第 " + strconv.Itoa(index+1) + " 个返回值类型不同"
		}
	}
	return ""
}
