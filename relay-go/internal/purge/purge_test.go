package purge

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// seed 建一套「一台在用 + 一台已撤销 + 一台已过期」的设备行，返回库路径与 agent。
func seed(t *testing.T) (dbPath, agentID string, liveID, revokedID, expiredID string) {
	t.Helper()
	dir := t.TempDir()
	dbPath = filepath.Join(dir, "state.db")
	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatalf("打开临时库: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })
	ctx := context.Background()
	account, err := st.CreateAccount(ctx, "purge-owner")
	if err != nil {
		t.Fatalf("CreateAccount: %v", err)
	}
	agent, _, err := st.RegisterAgent(ctx, account.AccountID, "purge-mac", nil)
	if err != nil {
		t.Fatalf("RegisterAgent: %v", err)
	}
	agentID = agent.AgentID
	claim := func(name string, ttl time.Duration) string {
		minted, err := st.MintPairCode(ctx, agentID, nil)
		if err != nil {
			t.Fatalf("MintPairCode: %v", err)
		}
		result, err := st.ClaimPairCode(ctx, minted.Code, store.ClaimParams{
			DeviceName: name, TTLMS: ttl.Milliseconds(), MaxPairedDevices: 8,
		})
		if err != nil {
			t.Fatalf("ClaimPairCode(%s): %v", name, err)
		}
		return result.DeviceID
	}
	liveID = claim("PURGE-live", 365*24*time.Hour)
	revokedID = claim("PURGE-revoked", 365*24*time.Hour)
	expiredID = claim("PURGE-expired", -1000*time.Millisecond)
	if err := st.RevokeDevice(ctx, revokedID); err != nil {
		t.Fatalf("RevokeDevice: %v", err)
	}
	return dbPath, agentID, liveID, revokedID, expiredID
}

func TestDryRunChangesNothingAndWritesNoBackup(t *testing.T) {
	dbPath, agentID, _, _, _ := seed(t)
	before, err := store.Open(dbPath)
	if err != nil {
		t.Fatalf("打开库: %v", err)
	}
	beforeCounts, err := before.CountDevicesOfAgents(context.Background(), []string{agentID})
	if err != nil {
		t.Fatalf("统计: %v", err)
	}
	_ = before.Close()

	report, err := Run(context.Background(), Options{DBPath: dbPath, AgentID: agentID})
	if err != nil {
		t.Fatalf("预演: %v", err)
	}
	if report.Applied || report.Removed != 0 {
		t.Fatalf("预演报告 = %+v", report)
	}
	if len(report.Agents) != 1 || report.Agents[0].Total != 3 ||
		report.Agents[0].Doomed != 2 || report.Agents[0].Live != 1 {
		t.Fatalf("预演明细 = %+v", report.Agents)
	}
	after, err := store.Open(dbPath)
	if err != nil {
		t.Fatalf("重新打开库: %v", err)
	}
	defer after.Close()
	afterCounts, err := after.CountDevicesOfAgents(context.Background(), []string{agentID})
	if err != nil {
		t.Fatalf("重新统计: %v", err)
	}
	if afterCounts[agentID] != beforeCounts[agentID] {
		t.Fatalf("预演改了库：%d -> %d", beforeCounts[agentID], afterCounts[agentID])
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(dbPath), "backups")); !os.IsNotExist(err) {
		t.Fatalf("预演不该创建备份目录（err=%v）", err)
	}
}

func TestApplyDeletesOnlyDoomedAndWritesBackups(t *testing.T) {
	dbPath, agentID, liveID, revokedID, expiredID := seed(t)
	backupDir := filepath.Join(t.TempDir(), "backups")
	report, err := Run(context.Background(), Options{
		DBPath: dbPath, AllAgents: true, Apply: true, BackupDir: backupDir,
	})
	if err != nil {
		t.Fatalf("清理: %v", err)
	}
	if report.Removed != 2 {
		t.Fatalf("删除行数 = %d，期望 2", report.Removed)
	}
	if report.Backup == "" || report.Dump == "" {
		t.Fatalf("没有写备份/导出：%+v", report)
	}
	if _, err := os.Stat(report.Backup); err != nil {
		t.Fatalf("备份文件不存在: %v", err)
	}
	dump, err := os.ReadFile(report.Dump)
	if err != nil {
		t.Fatalf("读导出: %v", err)
	}
	var rows []store.Device
	if err := json.Unmarshal(dump, &rows); err != nil {
		t.Fatalf("导出不是 JSON: %v", err)
	}
	if len(rows) != 2 {
		t.Fatalf("导出行数 = %d，期望 2", len(rows))
	}
	// 备份必须是完整库：三行都在。
	backupCounts, err := store.CountDevicesInBackup(context.Background(), report.Backup, []string{agentID})
	if err != nil {
		t.Fatalf("核对备份: %v", err)
	}
	if backupCounts[agentID] != 3 {
		t.Fatalf("备份里 %d 行，期望 3", backupCounts[agentID])
	}

	// 在用设备一行不少；两行死记录已删。
	st, err := store.Open(dbPath)
	if err != nil {
		t.Fatalf("重新打开库: %v", err)
	}
	defer st.Close()
	ctx := context.Background()
	counts, err := st.CountDevicesOfAgents(ctx, []string{agentID})
	if err != nil {
		t.Fatalf("统计: %v", err)
	}
	if counts[agentID] != 1 {
		t.Fatalf("清理后 %d 行，期望只剩 1 行在用设备", counts[agentID])
	}
	for _, id := range []string{liveID} {
		if _, found, err := st.DeviceByID(ctx, id); err != nil || !found {
			t.Fatalf("在用设备 %s 被误删（found=%v err=%v）", id, found, err)
		}
	}
	for _, id := range []string{revokedID, expiredID} {
		if _, found, err := st.DeviceByID(ctx, id); err != nil || found {
			t.Fatalf("死记录 %s 没删掉（found=%v err=%v）", id, found, err)
		}
	}
}

func TestApplyWithNothingToDoWritesNoBackup(t *testing.T) {
	dbPath, agentID, _, _, _ := seed(t)
	// 先把两条死记录清掉。
	if _, err := Run(context.Background(), Options{
		DBPath: dbPath, AgentID: agentID, Apply: true,
	}); err != nil {
		t.Fatalf("第一次清理: %v", err)
	}
	backupDir := filepath.Join(t.TempDir(), "backups")
	report, err := Run(context.Background(), Options{
		DBPath: dbPath, AgentID: agentID, Apply: true, BackupDir: backupDir,
	})
	if err != nil {
		t.Fatalf("第二次清理: %v", err)
	}
	if report.Removed != 0 || report.Backup != "" {
		t.Fatalf("没有待删行时 = %+v，期望不写备份", report)
	}
	entries, err := os.ReadDir(backupDir)
	if err != nil && !os.IsNotExist(err) {
		t.Fatalf("读备份目录: %v", err)
	}
	if len(entries) != 0 {
		t.Fatalf("没有待删行却写了备份：%v", entries)
	}
}

func TestKeepPrunesOnlyItsOwnBackups(t *testing.T) {
	dbPath, agentID, _, _, _ := seed(t)
	// 先把死记录清掉，第二次清理就没有新备份，备份目录里只剩用例造的旧文件。
	if _, err := Run(context.Background(), Options{
		DBPath: dbPath, AgentID: agentID, Apply: true,
	}); err != nil {
		t.Fatalf("预清理: %v", err)
	}
	dir := t.TempDir()
	for _, stamp := range []string{"20200101-000000", "20210101-000000", "20220101-000000"} {
		for _, name := range []string{
			"state-" + stamp + ".db", "purged-devices-all-" + stamp + ".json",
		} {
			if err := os.WriteFile(filepath.Join(dir, name), []byte("{}"), 0o600); err != nil {
				t.Fatalf("造旧备份: %v", err)
			}
		}
	}
	foreign := filepath.Join(dir, "notes.txt")
	if err := os.WriteFile(foreign, []byte("keep me"), 0o600); err != nil {
		t.Fatalf("造外来文件: %v", err)
	}
	report, err := Run(context.Background(), Options{
		DBPath: dbPath, AgentID: agentID, Apply: true, BackupDir: dir, Keep: 2,
	})
	if err != nil {
		t.Fatalf("清理: %v", err)
	}
	if len(report.BackupsRemoved) != 2 {
		t.Fatalf("清理旧备份 = %v，期望删掉最老一组的两个文件", report.BackupsRemoved)
	}
	for _, name := range []string{
		"state-20200101-000000.db", "purged-devices-all-20200101-000000.json",
	} {
		if _, err := os.Stat(filepath.Join(dir, name)); !os.IsNotExist(err) {
			t.Fatalf("最老一组没删：%s", name)
		}
	}
	if _, err := os.Stat(foreign); err != nil {
		t.Fatalf("外来文件被误删: %v", err)
	}
}

func TestMainRejectsBadArguments(t *testing.T) {
	var out, errOut discardWriter
	if code := Main([]string{"--db", filepath.Join(t.TempDir(), "missing.db"),
		"--all-agents", "--apply"}, nil, &out, &errOut); code != 1 {
		t.Fatalf("库不存在时退出码 = %d，期望 1", code)
	}
	if code := Main([]string{"--all-agents"}, nil, &out, &errOut); code != 2 {
		t.Fatalf("缺 --db 时退出码 = %d，期望 2", code)
	}
	if code := Main([]string{"--db", "x.db", "--agent", "a", "--all-agents"},
		nil, &out, &errOut); code != 2 {
		t.Fatalf("--agent 与 --all-agents 同时给时退出码 = %d，期望 2", code)
	}
}

// discardWriter 吞掉命令输出（CLI 退出码用例不关心正文）。
type discardWriter struct{}

func (discardWriter) Write(payload []byte) (int, error) { return len(payload), nil }
