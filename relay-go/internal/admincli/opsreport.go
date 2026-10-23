package admincli

import (
	"context"
	"io"
	"os/exec"
	"strings"
	"time"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/opsreport"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// ── 命令入口 ───────────────────────────────────────────────────────────────

// runOpsReport 实现 ops-report：日报的原始数据。
//
// 这里只做参数解析、journalctl 调用与输出；报告的形状与聚合在 internal/opsreport。
func runOpsReport(ctx context.Context, st *store.Store, args []string,
	stdout, stderr io.Writer) error {
	fs := newFlagSet(cmdOpsReport, stderr)
	days := fs.Int("days", 30, "窗口天数（本地日，含锚点那一天）")
	asOf := fs.String("as-of", "now", "now | yesterday | YYYY-MM-DD")
	journalUnit := fs.String("journal-unit", opsreport.DefaultJournalUnit,
		"从哪个 systemd 单元的日志重建 72 小时分布")
	if err := fs.Parse(args); err != nil {
		return newUsageError("%v", err)
	}
	generated := store.NowMS()
	stamp, err := opsreport.ResolveAsOf(*asOf, generated)
	if err != nil {
		return err
	}
	report, err := opsreport.Report(ctx, st, opsreport.Options{
		Days: *days, AsOfStamp: stamp, GeneratedAt: generated,
		JournalUnit: *journalUnit, Journal: readJournal,
	})
	if err != nil {
		return err
	}
	return emit(stdout, report)
}

// readJournal 取中转日志；取不到（没装 systemd、无权限、单元名不对）时 ok=false。
//
// 进程调用留在 CLI 层：opsreport 只接收"已取到的日志行"，不依赖本机装没装 systemd。
func readJournal(unit string, sinceMS, untilMS int64) ([]string, bool) {
	since := time.UnixMilli(sinceMS).Format("2006-01-02 15:04:05")
	until := time.UnixMilli(untilMS).Format("2006-01-02 15:04:05")
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	output, err := exec.CommandContext(ctx, "journalctl", "-u", unit,
		"--since", since, "--until", until, "--no-pager", "-o", "short-iso").Output()
	if err != nil {
		return nil, false
	}
	return strings.Split(strings.TrimRight(string(output), "\n"), "\n"), true
}
