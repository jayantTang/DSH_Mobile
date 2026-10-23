package quota

import (
	"context"
	"testing"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// TestQuotaLedgerChargesThenRefuses：先记账再判定——把额度撑爆的那一帧本身不算送达。
func TestQuotaLedgerChargesThenRefuses(t *testing.T) {
	day := int64(20261023)
	ledger := NewLedger(nil, 100, func() int64 { return day }, discardLogger())

	if allowed, used := ledger.Charge("dev_1", 60); !allowed || used != 60 {
		t.Fatalf("第一次记账 = %v/%d", allowed, used)
	}
	if allowed, used := ledger.Charge("dev_1", 60); allowed || used != 120 {
		t.Fatalf("超限那一帧应被拒：%v/%d", allowed, used)
	}
	if remaining := ledger.Remaining("dev_1"); remaining != 0 {
		t.Fatalf("用光后剩余 = %d", remaining)
	}
	// 每台设备各有账本。
	if allowed, _ := ledger.Charge("dev_2", 60); !allowed {
		t.Fatal("另一台设备不该受牵连")
	}
}

// TestQuotaLedgerResetsOnANewDay：本地日一变，额度重新开始（与 Python DailyQuota 一致）。
func TestQuotaLedgerResetsOnANewDay(t *testing.T) {
	day := int64(20261023)
	ledger := NewLedger(nil, 100, func() int64 { return day }, discardLogger())
	ledger.Charge("dev_1", 200)
	if allowed, _ := ledger.Charge("dev_1", 1); allowed {
		t.Fatal("当天额度应当已经用光")
	}
	day = 20261024
	if allowed, used := ledger.Charge("dev_1", 50); !allowed || used != 50 {
		t.Fatalf("跨日后应重新开始：%v/%d", allowed, used)
	}
}

// TestQuotaLedgerSeedsFromStoredUsage：新进程/新连接要把库里已经用掉的算进基线。
func TestQuotaLedgerSeedsFromStoredUsage(t *testing.T) {
	st := openTestStore(t)
	day := store.LocalDay()
	if _, err := st.AddUsage(context.Background(), []store.UsageEntry{{
		Day: day, DeviceID: "dev_1", AgentID: "agt_1", AccountID: "acc_1",
		EgressBytes: 80, Connections: 1, At: store.NowMS(),
	}}); err != nil {
		t.Fatalf("AddUsage: %v", err)
	}
	ledger := NewLedger(st, 100, func() int64 { return day }, discardLogger())
	ledger.Seat(context.Background(), "dev_1")
	if used := ledger.Used("dev_1"); used != 80 {
		t.Fatalf("基线 = %d，期望 80", used)
	}
	if allowed, _ := ledger.Charge("dev_1", 30); allowed {
		t.Fatal("基线之上再记 30 就该超限")
	}
	// Seat 幂等：第二次不该把基线再加一遍。
	ledger.Seat(context.Background(), "dev_1")
	if used := ledger.Used("dev_1"); used != 110 {
		t.Fatalf("Seat 不该重复累加：%d", used)
	}
}

// TestLedgerDayRolloverAndSeat 钉住"跨日清账 + 基线每天只读一次"的组合
// （DESIGN §5.3；两条规则各自已有用例，这里钉住它们同时发生）。
func TestLedgerDayRolloverAndSeat(t *testing.T) {
	ctx := context.Background()
	st := openTestStore(t)
	dayOne := int64(1_000_000)
	dayTwo := dayOne + 1
	for day, bytes := range map[int64]int64{dayOne: 80, dayTwo: 40} {
		if _, err := st.AddUsage(ctx, []store.UsageEntry{{
			Day: day, DeviceID: "dev_1", AgentID: "agt_1", AccountID: "acc_1",
			EgressBytes: bytes, Connections: 1, At: store.NowMS(),
		}}); err != nil {
			t.Fatalf("AddUsage(day=%d): %v", day, err)
		}
	}

	day := dayOne
	ledger := NewLedger(st, 100, func() int64 { return day }, discardLogger())
	ledger.Seat(ctx, "dev_1")
	ledger.Seat(ctx, "dev_1")
	if used := ledger.Used("dev_1"); used != 80 {
		t.Fatalf("第一天基线 = %d，期望 80", used)
	}
	if allowed, used := ledger.Charge("dev_1", 30); allowed || used != 110 {
		t.Fatalf("先记账再判定：%v/%d", allowed, used)
	}

	// 跨日：账本与"已落座"一起清空，新一天重新从库里读基线。
	day = dayTwo
	if remaining := ledger.Remaining("dev_1"); remaining != 100 {
		t.Fatalf("跨日后剩余 = %d，期望 100", remaining)
	}
	ledger.Seat(ctx, "dev_1")
	if used := ledger.Used("dev_1"); used != 40 {
		t.Fatalf("第二天基线 = %d，期望 40", used)
	}
	if allowed, used := ledger.Charge("dev_1", 30); !allowed || used != 70 {
		t.Fatalf("第二天记账 = %v/%d，期望 true/70", allowed, used)
	}
}
