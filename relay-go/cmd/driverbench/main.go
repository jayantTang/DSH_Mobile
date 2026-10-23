// driverbench 对比两种 SQLite 驱动：modernc.org/sqlite（纯 Go）与
// github.com/mattn/go-sqlite3（cgo）。
//
// 口径与正式 store 一致：同一份 schema（store.Schema）、同样的 WAL +
// busy_timeout + foreign_keys、同一个临时目录；每项指标跑 -runs 次取中位数。
// 二进制体积不在这里测（进程量不了别的构建），由 Makefile 的 size 目标给出。
//
// 用法：
//
//	make bench          # CGO_ENABLED=1，两个驱动都测，原始数据写 bin/driverbench.json
//	make bench-nocgo    # CGO_ENABLED=0，只测 modernc
package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	_ "modernc.org/sqlite" // 基准要显式注册纯 Go 驱动，不依赖 store 的构建标签

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// 各指标的规模。批量插入要足够大，才能看出事务内写入的成本；
// 单条插入走 autocommit（每次都可能 fsync），因此规模小一些。
const (
	singleInsertRows = 300
	batchInsertRows  = 20000
	readWorkers      = 16
	readsPerWorker   = 300
	rwReadWorkers    = 8
	rwWriteWorkers   = 2
	rwDuration       = 2 * time.Second
)

// driver 是 bench 需要的驱动描述：注册名 + 与 store 同口径的 DSN。
type driver struct {
	name       string
	label      string
	driverName string
	dsn        func(path string) string
}

func moderncDriver() driver {
	return driver{
		name:       "modernc",
		label:      "modernc.org/sqlite（纯 Go）",
		driverName: "sqlite",
		dsn: func(path string) string {
			// 与 store.dsn 一致。
			return fmt.Sprintf("%s?_pragma=busy_timeout(%d)&_pragma=foreign_keys(1)",
				path, store.BusyTimeoutMS)
		},
	}
}

func mattnDriver() driver {
	return driver{
		name:       "mattn",
		label:      "mattn/go-sqlite3（cgo）",
		driverName: "sqlite3",
		dsn: func(path string) string {
			// mattn 的等价参数名；语义与 modernc 的 _pragma 相同。
			return fmt.Sprintf("%s?_busy_timeout=%d&_foreign_keys=1", path, store.BusyTimeoutMS)
		},
	}
}

// availableDrivers 按构建方式返回可测驱动：没有 cgo 时只有纯 Go 那个。
func availableDrivers() []driver {
	drivers := []driver{moderncDriver()}
	if cgoAvailable {
		drivers = append(drivers, mattnDriver())
	}
	return drivers
}

// sample 是一次完整运行的全部指标。
type sample struct {
	OpenSchemaMS            float64 `json:"openSchemaMs"`
	SingleInsertUS          float64 `json:"singleInsertUs"`
	BatchInsertUS           float64 `json:"batchInsertUs"`
	SingleReadUS            float64 `json:"singleReadUs"`
	ConcurrentReadOpsPerSec float64 `json:"concurrentReadOpsPerSec"`
	ConcurrentReadP50MS     float64 `json:"concurrentReadP50Ms"`
	ConcurrentReadP99MS     float64 `json:"concurrentReadP99Ms"`
	RWReadOpsPerSec         float64 `json:"rwReadOpsPerSec"`
	RWWriteOpsPerSec        float64 `json:"rwWriteOpsPerSec"`
	RWErrors                float64 `json:"rwErrors"`
}

type driverReport struct {
	Driver string   `json:"driver"`
	Label  string   `json:"label"`
	Runs   []sample `json:"runs"`
	Median sample   `json:"median"`
}

type report struct {
	GeneratedAt string         `json:"generatedAt"`
	GoVersion   string         `json:"goVersion"`
	OS          string         `json:"os"`
	Arch        string         `json:"arch"`
	CgoEnabled  bool           `json:"cgoEnabled"`
	Runs        int            `json:"runs"`
	Drivers     []driverReport `json:"drivers"`
}

func main() {
	runs := flag.Int("runs", 3, "每项指标跑几次（取中位数）")
	driversFlag := flag.String("drivers", "modernc,mattn", "逗号分隔的驱动名：modernc,mattn")
	jsonPath := flag.String("json", "", "把原始数据写到这个 JSON 文件（空 = 不写）")
	keep := flag.Bool("keep", false, "保留临时目录（默认删除）")
	flag.Parse()

	selected, err := selectDrivers(*driversFlag)
	if err != nil {
		fmt.Fprintln(os.Stderr, "driverbench:", err)
		os.Exit(2)
	}
	if *runs < 1 {
		fmt.Fprintln(os.Stderr, "driverbench: -runs 至少为 1")
		os.Exit(2)
	}

	baseDir, err := os.MkdirTemp("", "dsh-driverbench-")
	if err != nil {
		fmt.Fprintln(os.Stderr, "driverbench: 建临时目录:", err)
		os.Exit(1)
	}
	if !*keep {
		defer os.RemoveAll(baseDir)
	}

	rep := report{
		GeneratedAt: time.Now().Format(time.RFC3339),
		GoVersion:   runtime.Version(),
		OS:          runtime.GOOS,
		Arch:        runtime.GOARCH,
		CgoEnabled:  cgoAvailable,
		Runs:        *runs,
	}

	for _, d := range selected {
		result := driverReport{Driver: d.name, Label: d.label}
		for run := 1; run <= *runs; run++ {
			fmt.Fprintf(os.Stderr, "driverbench: %s 第 %d/%d 次\n", d.name, run, *runs)
			s, err := benchmark(d, baseDir, run)
			if err != nil {
				fmt.Fprintf(os.Stderr, "driverbench: %s: %v\n", d.name, err)
				os.Exit(1)
			}
			result.Runs = append(result.Runs, s)
		}
		result.Median = medianSample(result.Runs)
		rep.Drivers = append(rep.Drivers, result)
	}

	printTable(rep)
	if *jsonPath != "" {
		writeJSON(*jsonPath, rep)
	}
}

// selectDrivers 解析 -drivers，遇到当前构建没有的驱动就明确报错，不静默跳过。
func selectDrivers(raw string) ([]driver, error) {
	wanted := map[string]driver{}
	for _, d := range availableDrivers() {
		wanted[d.name] = d
	}
	var selected []driver
	for _, name := range strings.Split(raw, ",") {
		name = strings.TrimSpace(name)
		if name == "" {
			continue
		}
		d, ok := wanted[name]
		if !ok {
			if name == "mattn" {
				return nil, fmt.Errorf("驱动 %q 需要 CGO_ENABLED=1（当前构建不含 cgo）", name)
			}
			return nil, fmt.Errorf("未知驱动 %q（可选：%s）", name, strings.Join(driverNames(), ","))
		}
		selected = append(selected, d)
	}
	if len(selected) == 0 {
		return nil, fmt.Errorf("没有选中任何驱动（可选：%s）", strings.Join(driverNames(), ","))
	}
	return selected, nil
}

func driverNames() []string {
	var names []string
	for _, d := range availableDrivers() {
		names = append(names, d.name)
	}
	return names
}

// benchmark 跑一轮全部指标；同一轮内复用同一个库，避免重复建表的噪声混进读指标。
func benchmark(d driver, baseDir string, run int) (sample, error) {
	ctx := context.Background()
	var s sample

	openPath := filepath.Join(baseDir, fmt.Sprintf("%s-open-%d.db", d.name, run))
	start := time.Now()
	db, err := openDB(ctx, d, openPath, 4)
	if err != nil {
		return s, fmt.Errorf("打开+建表: %w", err)
	}
	s.OpenSchemaMS = msSince(start)
	removeDB(openPath) // 本轮只量打开；后面的指标用新的库，避免 pool 里的连接干扰
	db.Close()

	dataPath := filepath.Join(baseDir, fmt.Sprintf("%s-data-%d.db", d.name, run))
	db, err = openDB(ctx, d, dataPath, 4)
	if err != nil {
		return s, fmt.Errorf("建数据库: %w", err)
	}
	defer func() {
		db.Close()
		removeDB(dataPath)
	}()

	if s.SingleInsertUS, err = benchSingleInsert(ctx, db); err != nil {
		return s, fmt.Errorf("单条插入: %w", err)
	}
	if s.BatchInsertUS, err = benchBatchInsert(ctx, db); err != nil {
		return s, fmt.Errorf("批量插入: %w", err)
	}
	if s.SingleReadUS, err = benchSingleRead(ctx, db); err != nil {
		return s, fmt.Errorf("单条读: %w", err)
	}

	// 并发指标要更多连接；先把池和驱动连接预热，再计时。
	db.SetMaxOpenConns(readWorkers)
	db.SetMaxIdleConns(readWorkers)
	if err := warmPool(ctx, db, readWorkers); err != nil {
		return s, fmt.Errorf("预热连接池: %w", err)
	}

	s.ConcurrentReadOpsPerSec, s.ConcurrentReadP50MS, s.ConcurrentReadP99MS, err =
		benchConcurrentReads(ctx, db)
	if err != nil {
		return s, fmt.Errorf("16 并发读: %w", err)
	}
	rwRead, rwWrite, rwErrors, err := benchConcurrentReadWrite(ctx, db)
	if err != nil {
		return s, fmt.Errorf("并发读写: %w", err)
	}
	s.RWReadOpsPerSec, s.RWWriteOpsPerSec, s.RWErrors = rwRead, rwWrite, float64(rwErrors)
	return s, nil
}

// openDB 用与 store.Open 相同的 PRAGMA 与 schema 建一个空库。
func openDB(ctx context.Context, d driver, path string, maxOpen int) (*sql.DB, error) {
	db, err := sql.Open(d.driverName, d.dsn(path))
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(maxOpen)
	db.SetMaxIdleConns(maxOpen)
	if err := db.PingContext(ctx); err != nil {
		db.Close()
		return nil, err
	}
	if _, err := db.ExecContext(ctx, "PRAGMA journal_mode=WAL"); err != nil {
		db.Close()
		return nil, fmt.Errorf("设置 WAL: %w", err)
	}
	var mode string
	if err := db.QueryRowContext(ctx, "PRAGMA journal_mode").Scan(&mode); err != nil {
		db.Close()
		return nil, fmt.Errorf("读 journal_mode: %w", err)
	}
	if !strings.EqualFold(mode, "wal") {
		db.Close()
		return nil, fmt.Errorf("journal_mode = %q, 期望 wal", mode)
	}
	if _, err := db.ExecContext(ctx, store.Schema); err != nil {
		db.Close()
		return nil, fmt.Errorf("建表: %w", err)
	}
	return db, nil
}

func benchSingleInsert(ctx context.Context, db *sql.DB) (float64, error) {
	start := time.Now()
	for i := 0; i < singleInsertRows; i++ {
		if _, err := db.ExecContext(ctx,
			"INSERT INTO accounts(accountId, name, createdAt) VALUES(?,?,?)",
			fmt.Sprintf("ins_%d", i), "single", time.Now().UnixMilli(),
		); err != nil {
			return 0, err
		}
	}
	return usPerOp(start, singleInsertRows), nil
}

func benchBatchInsert(ctx context.Context, db *sql.DB) (float64, error) {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	stmt, err := tx.PrepareContext(ctx,
		"INSERT INTO accounts(accountId, name, createdAt) VALUES(?,?,?)")
	if err != nil {
		tx.Rollback()
		return 0, err
	}
	start := time.Now()
	for i := 0; i < batchInsertRows; i++ {
		if _, err := stmt.ExecContext(ctx, fmt.Sprintf("acc_%d", i), "batch", 1700000000000); err != nil {
			stmt.Close()
			tx.Rollback()
			return 0, err
		}
	}
	if err := stmt.Close(); err != nil {
		tx.Rollback()
		return 0, err
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return usPerOp(start, batchInsertRows), nil
}

func benchSingleRead(ctx context.Context, db *sql.DB) (float64, error) {
	const reads = 5000
	start := time.Now()
	for i := 0; i < reads; i++ {
		var name string
		if err := db.QueryRowContext(ctx,
			"SELECT name FROM accounts WHERE accountId=?", fmt.Sprintf("acc_%d", i%batchInsertRows),
		).Scan(&name); err != nil {
			return 0, err
		}
	}
	return usPerOp(start, reads), nil
}

// warmPool 用 readWorkers 个并发查询把连接池填满，避免首次建连接的成本混进计时。
func warmPool(ctx context.Context, db *sql.DB, workers int) error {
	var wg sync.WaitGroup
	errCh := make(chan error, workers)
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			var name string
			if err := db.QueryRowContext(ctx,
				"SELECT name FROM accounts WHERE accountId='acc_0'").Scan(&name); err != nil {
				errCh <- err
			}
		}()
	}
	wg.Wait()
	select {
	case err := <-errCh:
		return err
	default:
		return nil
	}
}

func benchConcurrentReads(ctx context.Context, db *sql.DB) (opsPerSec, p50, p99 float64, err error) {
	latencies := make([][]time.Duration, readWorkers)
	start := time.Now()
	var wg sync.WaitGroup
	errCh := make(chan error, readWorkers)
	for w := 0; w < readWorkers; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			buf := make([]time.Duration, 0, readsPerWorker)
			for i := 0; i < readsPerWorker; i++ {
				id := (w*7919 + i*104729) % batchInsertRows
				begin := time.Now()
				var name string
				if scanErr := db.QueryRowContext(ctx,
					"SELECT name FROM accounts WHERE accountId=?",
					fmt.Sprintf("acc_%d", id),
				).Scan(&name); scanErr != nil {
					errCh <- scanErr
					return
				}
				buf = append(buf, time.Since(begin))
			}
			latencies[w] = buf
		}(w)
	}
	wg.Wait()
	select {
	case scanErr := <-errCh:
		return 0, 0, 0, scanErr
	default:
	}
	elapsed := time.Since(start)

	var all []time.Duration
	for _, buf := range latencies {
		all = append(all, buf...)
	}
	total := readWorkers * readsPerWorker
	return float64(total) / elapsed.Seconds(),
		percentileMS(all, 0.50), percentileMS(all, 0.99), nil
}

// benchConcurrentReadWrite 固定时长内让读写并发跑，统计各自吞吐与错误数。
//
// 写走 autocommit（每次都是一个事务），这是最容易撞 busy/locked 的形态；
// 读与写同时进行也正是线上最常见的负载。
func benchConcurrentReadWrite(ctx context.Context, db *sql.DB) (readOps, writeOps float64, errCount int, err error) {
	runCtx, cancel := context.WithTimeout(ctx, rwDuration)
	defer cancel()

	var reads, writes, failures atomic.Int64
	var wg sync.WaitGroup

	for w := 0; w < rwReadWorkers; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			for i := 0; ; i++ {
				if runCtx.Err() != nil {
					return
				}
				id := (w*104729 + i*7919) % batchInsertRows
				var name string
				scanErr := db.QueryRowContext(runCtx,
					"SELECT name FROM accounts WHERE accountId=?",
					fmt.Sprintf("acc_%d", id),
				).Scan(&name)
				if scanErr != nil {
					if runCtx.Err() == nil {
						failures.Add(1)
					}
					continue
				}
				reads.Add(1)
			}
		}(w)
	}
	for w := 0; w < rwWriteWorkers; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			for i := 0; ; i++ {
				if runCtx.Err() != nil {
					return
				}
				_, execErr := db.ExecContext(runCtx,
					"INSERT INTO accounts(accountId, name, createdAt) VALUES(?,?,?)",
					fmt.Sprintf("rw_%d_%d_%d", w, i, time.Now().UnixNano()),
					"rw", time.Now().UnixMilli())
				if execErr != nil {
					if runCtx.Err() == nil {
						failures.Add(1)
					}
					continue
				}
				writes.Add(1)
			}
		}(w)
	}
	wg.Wait()

	seconds := rwDuration.Seconds()
	return float64(reads.Load()) / seconds, float64(writes.Load()) / seconds,
		int(failures.Load()), nil
}

// ── 统计与输出 ────────────────────────────────────────────────────────────

func msSince(start time.Time) float64 { return float64(time.Since(start).Microseconds()) / 1000 }

func usPerOp(start time.Time, ops int) float64 {
	return float64(time.Since(start).Nanoseconds()) / float64(ops) / 1000
}

func percentileMS(values []time.Duration, p float64) float64 {
	if len(values) == 0 {
		return 0
	}
	sorted := append([]time.Duration(nil), values...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i] < sorted[j] })
	index := int(float64(len(sorted)-1) * p)
	return float64(sorted[index].Microseconds()) / 1000
}

func medianSample(runs []sample) sample {
	if len(runs) == 0 {
		return sample{}
	}
	medianOf := func(pick func(sample) float64) float64 {
		values := make([]float64, len(runs))
		for i, run := range runs {
			values[i] = pick(run)
		}
		sort.Float64s(values)
		return values[len(values)/2]
	}
	return sample{
		OpenSchemaMS:            medianOf(func(s sample) float64 { return s.OpenSchemaMS }),
		SingleInsertUS:          medianOf(func(s sample) float64 { return s.SingleInsertUS }),
		BatchInsertUS:           medianOf(func(s sample) float64 { return s.BatchInsertUS }),
		SingleReadUS:            medianOf(func(s sample) float64 { return s.SingleReadUS }),
		ConcurrentReadOpsPerSec: medianOf(func(s sample) float64 { return s.ConcurrentReadOpsPerSec }),
		ConcurrentReadP50MS:     medianOf(func(s sample) float64 { return s.ConcurrentReadP50MS }),
		ConcurrentReadP99MS:     medianOf(func(s sample) float64 { return s.ConcurrentReadP99MS }),
		RWReadOpsPerSec:         medianOf(func(s sample) float64 { return s.RWReadOpsPerSec }),
		RWWriteOpsPerSec:        medianOf(func(s sample) float64 { return s.RWWriteOpsPerSec }),
		RWErrors:                medianOf(func(s sample) float64 { return s.RWErrors }),
	}
}

func printTable(rep report) {
	fmt.Println()
	fmt.Println("SQLite 驱动基准（每项 " + fmt.Sprint(rep.Runs) + " 次取中位数）")
	for _, d := range rep.Drivers {
		m := d.Median
		fmt.Printf("\n[%s] %s\n", d.Driver, d.Label)
		fmt.Printf("  打开+建表:        %8.2f ms\n", m.OpenSchemaMS)
		fmt.Printf("  单条插入:         %8.2f us/op\n", m.SingleInsertUS)
		fmt.Printf("  批量插入事务:     %8.2f us/op\n", m.BatchInsertUS)
		fmt.Printf("  单条读:           %8.2f us/op\n", m.SingleReadUS)
		fmt.Printf("  16 并发读:        %10.0f ops/s  p50 %.3f ms  p99 %.3f ms\n",
			m.ConcurrentReadOpsPerSec, m.ConcurrentReadP50MS, m.ConcurrentReadP99MS)
		fmt.Printf("  并发读写 %0.0fs:    读 %8.0f ops/s  写 %8.0f ops/s  错误 %0.0f\n",
			rwDuration.Seconds(), m.RWReadOpsPerSec, m.RWWriteOpsPerSec, m.RWErrors)
	}
	if len(rep.Drivers) == 2 {
		base := rep.Drivers[0].Median
		other := rep.Drivers[1].Median
		fmt.Printf("\n相对差异（%s 相对 %s；延迟类负数=更快，吞吐类正数=更快）\n", rep.Drivers[1].Driver, rep.Drivers[0].Driver)
		fmt.Printf("  单条插入:      %+6.1f%%\n", pctDelta(other.SingleInsertUS, base.SingleInsertUS))
		fmt.Printf("  批量插入:      %+6.1f%%\n", pctDelta(other.BatchInsertUS, base.BatchInsertUS))
		fmt.Printf("  单条读:        %+6.1f%%\n", pctDelta(other.SingleReadUS, base.SingleReadUS))
		fmt.Printf("  16 并发读:     %+6.1f%%\n", pctDelta(other.ConcurrentReadOpsPerSec, base.ConcurrentReadOpsPerSec))
		fmt.Printf("  并发读吞吐:    %+6.1f%%\n", pctDelta(other.RWReadOpsPerSec, base.RWReadOpsPerSec))
		fmt.Printf("  并发写吞吐:    %+6.1f%%\n", pctDelta(other.RWWriteOpsPerSec, base.RWWriteOpsPerSec))
	}
}

// pctDelta 是相对基准的百分比变化；值越小越好的指标（延迟）由调用方按语义解释。
func pctDelta(value, base float64) float64 {
	if base == 0 {
		return 0
	}
	return (value - base) / base * 100
}

func writeJSON(path string, rep report) {
	body, err := json.MarshalIndent(rep, "", "  ")
	if err != nil {
		fmt.Fprintln(os.Stderr, "driverbench: 序列化结果:", err)
		os.Exit(1)
	}
	body = append(body, '\n')
	if err := os.WriteFile(path, body, 0o644); err != nil {
		fmt.Fprintln(os.Stderr, "driverbench: 写 JSON:", err)
		os.Exit(1)
	}
	fmt.Fprintf(os.Stderr, "driverbench: 原始数据已写入 %s\n", path)
}

func removeDB(path string) {
	for _, suffix := range []string{"", "-wal", "-shm"} {
		_ = os.Remove(path + suffix)
	}
}
