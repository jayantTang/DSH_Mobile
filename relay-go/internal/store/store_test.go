package store

import (
	"context"
	"database/sql"
	"path/filepath"
	"strings"
	"testing"
)

// wantTables 是 schema 建出的全部业务表。
var wantTables = []string{
	"accountState", "accounts", "agents", "devices", "feedbackMessages",
	"feedbackThreads", "invites", "noticeDeliveries", "notices", "pairCodes",
	"usageDaily",
}

func tableNames(t *testing.T, db *sql.DB) []string {
	t.Helper()
	rows, err := db.Query("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
	if err != nil {
		t.Fatalf("查表清单: %v", err)
	}
	defer rows.Close()
	var names []string
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			t.Fatalf("读表名: %v", err)
		}
		names = append(names, name)
	}
	return names
}

func columnNames(t *testing.T, db *sql.DB, table string) []string {
	t.Helper()
	rows, err := db.Query("PRAGMA table_info(" + table + ")")
	if err != nil {
		t.Fatalf("查 %s 列: %v", table, err)
	}
	defer rows.Close()
	var names []string
	for rows.Next() {
		var (
			cid        int
			name       string
			kind       string
			notNull    int
			dflt       any
			primaryKey int
		)
		if err := rows.Scan(&cid, &name, &kind, &notNull, &dflt, &primaryKey); err != nil {
			t.Fatalf("读 %s 列: %v", table, err)
		}
		names = append(names, name)
	}
	return names
}

func hasColumn(t *testing.T, db *sql.DB, table, column string) bool {
	t.Helper()
	for _, name := range columnNames(t, db, table) {
		if name == column {
			return true
		}
	}
	return false
}

func pragmaInt(t *testing.T, db *sql.DB, sqlText string) int {
	t.Helper()
	var value int
	if err := db.QueryRow(sqlText).Scan(&value); err != nil {
		t.Fatalf("%s: %v", sqlText, err)
	}
	return value
}

// TestSelectedDriver 钉住构建选择：cgo 构建用 mattn，纯 Go 构建用 modernc。
func TestSelectedDriver(t *testing.T) {
	want := "sqlite"
	if cgoDriver {
		want = "sqlite3"
	}
	if driverName != want {
		t.Fatalf("driverName = %q, 期望 %q（cgoDriver=%v）", driverName, want, cgoDriver)
	}
}

func TestOpenCreatesSchema(t *testing.T) {
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "state.db")

	s, err := Open(dbPath)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer s.Close()

	if s.Path() != dbPath {
		t.Fatalf("Path = %q, 期望 %q", s.Path(), dbPath)
	}
	if s.Version() != SchemaVersion {
		t.Fatalf("Version = %d, 期望 %d", s.Version(), SchemaVersion)
	}

	if got := tableNames(t, s.db.DB); strings.Join(got, ",") != strings.Join(wantTables, ",") {
		t.Fatalf("表清单 = %v\n期望 %v", got, wantTables)
	}

	if got := pragmaInt(t, s.db.DB, "PRAGMA user_version"); got != SchemaVersion {
		t.Fatalf("user_version = %d, 期望 %d", got, SchemaVersion)
	}

	var journal string
	if err := s.db.QueryRow("PRAGMA journal_mode").Scan(&journal); err != nil {
		t.Fatalf("读 journal_mode: %v", err)
	}
	if !strings.EqualFold(journal, "wal") {
		t.Fatalf("journal_mode = %q, 期望 wal", journal)
	}
	if got := pragmaInt(t, s.db.DB, "PRAGMA foreign_keys"); got != 1 {
		t.Fatalf("foreign_keys = %d, 期望 1", got)
	}
	if got := pragmaInt(t, s.db.DB, "PRAGMA busy_timeout"); got != BusyTimeoutMS {
		t.Fatalf("busy_timeout = %d, 期望 %d", got, BusyTimeoutMS)
	}

	// 新库的列必须与 Python 版一致（抽查末尾几列：它们靠 ALTER TABLE 追加）。
	if !hasColumn(t, s.db.DB, "agents", "versionsAt") {
		t.Fatal("agents 缺 versionsAt")
	}
	if !hasColumn(t, s.db.DB, "devices", "deviceKey") {
		t.Fatal("devices 缺 deviceKey")
	}
	if !hasColumn(t, s.db.DB, "pairCodes", "useCount") {
		t.Fatal("pairCodes 缺 useCount")
	}
	if !hasColumn(t, s.db.DB, "usageDaily", "prompts") ||
		!hasColumn(t, s.db.DB, "usageDaily", "answers") {
		t.Fatal("usageDaily 缺操作计数列")
	}
}

func TestOpenCreatesParentDirectories(t *testing.T) {
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "nested", "deeper", "state.db")
	s, err := Open(dbPath)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer s.Close()
	if s.Path() != dbPath {
		t.Fatalf("Path = %q", s.Path())
	}
}

func TestOpenPathWithSpaces(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "with space")
	s, err := Open(filepath.Join(dir, "state.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer s.Close()
	if got := len(tableNames(t, s.db.DB)); got != len(wantTables) {
		t.Fatalf("表数量 = %d", got)
	}
}

func TestOpenRejectsEmptyPath(t *testing.T) {
	if _, err := Open("   "); err == nil {
		t.Fatal("空路径没有报错")
	}
}

func TestReopenIsIdempotent(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "state.db")

	first, err := Open(dbPath)
	if err != nil {
		t.Fatalf("首次 Open: %v", err)
	}
	if _, err := first.db.Exec(
		"INSERT INTO accounts(accountId, name, createdAt) VALUES(?,?,?)",
		"acc_1", "测试账户", 1700000000000,
	); err != nil {
		t.Fatalf("写入账户: %v", err)
	}
	if err := first.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	if err := first.Close(); err != nil {
		t.Fatalf("重复 Close: %v", err)
	}

	second, err := Open(dbPath)
	if err != nil {
		t.Fatalf("再次 Open: %v", err)
	}
	defer second.Close()

	if second.Version() != SchemaVersion {
		t.Fatalf("再次打开 Version = %d", second.Version())
	}
	var name string
	if err := second.db.QueryRow("SELECT name FROM accounts WHERE accountId=?", "acc_1").Scan(&name); err != nil {
		t.Fatalf("读回账户: %v", err)
	}
	if name != "测试账户" {
		t.Fatalf("账户名 = %q", name)
	}
	if got := len(tableNames(t, second.db.DB)); got != len(wantTables) {
		t.Fatalf("重复打开后表数量 = %d", got)
	}
}

func TestSecondOpenWhileFirstOpen(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "state.db")
	first, err := Open(dbPath)
	if err != nil {
		t.Fatalf("首次 Open: %v", err)
	}
	defer first.Close()

	second, err := Open(dbPath)
	if err != nil {
		t.Fatalf("并发 Open: %v", err)
	}
	defer second.Close()

	if second.Version() != SchemaVersion {
		t.Fatalf("并发打开 Version = %d", second.Version())
	}
	if _, err := first.db.Exec(
		"INSERT INTO accounts(accountId, name, createdAt) VALUES(?,?,?)",
		"acc_2", "第二个", 1700000000001,
	); err != nil {
		t.Fatalf("写入: %v", err)
	}
	var name string
	if err := second.db.QueryRow("SELECT name FROM accounts WHERE accountId=?", "acc_2").Scan(&name); err != nil {
		t.Fatalf("另一句柄读回: %v", err)
	}
	if name != "第二个" {
		t.Fatalf("账户名 = %q", name)
	}
}

// TestMigratesOlderDatabase 造一个 v1 的老库（缺后续版本加的列、pairCodes 老约束），
// 再确认 Open 把它补到当前版本，且旧数据一条不少。
func TestMigratesOlderDatabase(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "old.db")

	raw, err := sql.Open(driverName, dbPath)
	if err != nil {
		t.Fatalf("打开老库: %v", err)
	}
	oldDDL := []string{
		"CREATE TABLE accounts (accountId TEXT PRIMARY KEY, name TEXT NOT NULL, createdAt INTEGER NOT NULL)",
		"CREATE TABLE agents (agentId TEXT PRIMARY KEY, accountId TEXT NOT NULL, name TEXT NOT NULL," +
			" secretHash TEXT NOT NULL, createdAt INTEGER NOT NULL, updatedAt INTEGER NOT NULL," +
			" disabled INTEGER NOT NULL DEFAULT 0, lastSeenAt INTEGER)",
		"CREATE TABLE devices (deviceId TEXT PRIMARY KEY, deviceTokenHash TEXT NOT NULL UNIQUE," +
			" agentId TEXT NOT NULL, accountId TEXT NOT NULL, name TEXT NOT NULL, model TEXT," +
			" appVersion TEXT, createdAt INTEGER NOT NULL, expiresAt INTEGER NOT NULL," +
			" lastSeenAt INTEGER, revokedAt INTEGER)",
		"CREATE TABLE pairCodes (codeHash TEXT PRIMARY KEY, agentId TEXT NOT NULL," +
			" accountId TEXT NOT NULL, createdAt INTEGER NOT NULL, expiresAt INTEGER NOT NULL," +
			" usedAt INTEGER, deviceId TEXT)",
		"CREATE TABLE accountState (accountId TEXT NOT NULL, key TEXT NOT NULL, value TEXT NOT NULL," +
			" updatedAt INTEGER NOT NULL, updatedByDeviceId TEXT, PRIMARY KEY (accountId, key))",
		"CREATE TABLE usageDaily (day INTEGER NOT NULL, deviceId TEXT NOT NULL, agentId TEXT NOT NULL," +
			" accountId TEXT NOT NULL, egressBytes INTEGER NOT NULL DEFAULT 0," +
			" connections INTEGER NOT NULL DEFAULT 0, firstSeenAt INTEGER NOT NULL," +
			" lastSeenAt INTEGER NOT NULL, lastBuild TEXT, PRIMARY KEY (day, deviceId))",
		"CREATE TABLE invites (codeHash TEXT PRIMARY KEY, createdAt INTEGER NOT NULL," +
			" expiresAt INTEGER NOT NULL, usedAt INTEGER, usedByAgentId TEXT, note TEXT)",
		"CREATE TABLE feedbackThreads (threadId TEXT PRIMARY KEY, ticketHash TEXT NOT NULL UNIQUE," +
			" accountId TEXT, deviceId TEXT, appVersion TEXT, deviceModel TEXT, systemVersion TEXT," +
			" createdAt INTEGER NOT NULL, lastMessageAt INTEGER NOT NULL, ownerReadAt INTEGER," +
			" userReadAt INTEGER, status TEXT NOT NULL DEFAULT 'open', clientRef TEXT UNIQUE)",
		"CREATE TABLE feedbackMessages (messageId TEXT PRIMARY KEY, threadId TEXT NOT NULL," +
			" author TEXT NOT NULL, body TEXT NOT NULL, createdAt INTEGER NOT NULL, clientRef TEXT UNIQUE)",
		"CREATE TABLE notices (noticeId TEXT PRIMARY KEY, subject TEXT, body TEXT NOT NULL," +
			" createdAt INTEGER NOT NULL, createdBy TEXT)",
		"CREATE TABLE noticeDeliveries (noticeId TEXT NOT NULL, deviceId TEXT NOT NULL," +
			" createdAt INTEGER NOT NULL, readAt INTEGER, PRIMARY KEY (noticeId, deviceId))",
		"INSERT INTO accounts VALUES ('acc_old', '老账户', 1700000000000)",
		"INSERT INTO devices (deviceId, deviceTokenHash, agentId, accountId, name, createdAt, expiresAt)" +
			" VALUES ('dev_old', 'hash_old', 'agt_old', 'acc_old', '旧手机', 1700000000001, 1800000000000)",
		"INSERT INTO noticeDeliveries VALUES ('notice_1', 'dev_old', 1700000000002, NULL)",
		"INSERT INTO usageDaily (day, deviceId, agentId, accountId, egressBytes, connections," +
			" firstSeenAt, lastSeenAt, lastBuild)" +
			" VALUES (20261026, 'dev_old', 'agt_old', 'acc_old', 100, 1, 1, 2, NULL)",
		"PRAGMA user_version = 1",
	}
	for _, stmt := range oldDDL {
		if _, err := raw.Exec(stmt); err != nil {
			raw.Close()
			t.Fatalf("造老库 %q: %v", stmt, err)
		}
	}
	if err := raw.Close(); err != nil {
		t.Fatalf("关闭老库: %v", err)
	}

	s, err := Open(dbPath)
	if err != nil {
		t.Fatalf("迁移 Open: %v", err)
	}
	defer s.Close()

	if s.Version() != SchemaVersion {
		t.Fatalf("迁移后 Version = %d", s.Version())
	}
	if got := pragmaInt(t, s.db.DB, "PRAGMA user_version"); got != SchemaVersion {
		t.Fatalf("迁移后 user_version = %d", got)
	}

	for _, col := range []struct{ table, column string }{
		{"devices", "apnsToken"}, {"devices", "pushUpdatedAt"}, {"devices", "deviceKey"},
		{"pairCodes", "revokedAt"}, {"pairCodes", "useCount"},
		{"feedbackThreads", "subject"}, {"feedbackMessages", "format"},
		{"notices", "format"}, {"agents", "connectorVersion"}, {"agents", "versionsAt"},
		{"usageDaily", "prompts"}, {"usageDaily", "answers"},
	} {
		if !hasColumn(t, s.db.DB, col.table, col.column) {
			t.Errorf("迁移后 %s 仍缺 %s", col.table, col.column)
		}
	}

	// migrate 9：老用量行保留，新列默认 0；升级后可以立即写入计数。
	var prompts, answers int64
	if err := s.db.QueryRow("SELECT prompts, answers FROM usageDaily"+
		" WHERE day=20261026 AND deviceId='dev_old'").Scan(&prompts, &answers); err != nil {
		t.Fatalf("读老用量行的计数列: %v", err)
	}
	if prompts != 0 || answers != 0 {
		t.Fatalf("老用量行默认计数 = %d/%d，期望 0/0", prompts, answers)
	}
	if _, err := s.db.Exec("UPDATE usageDaily SET prompts=3, answers=1" +
		" WHERE day=20261026 AND deviceId='dev_old'"); err != nil {
		t.Fatalf("升级后写计数: %v", err)
	}

	// migrate 5：noticeDeliveries 从 deviceId 换成 accountId，旧投递按 devices.accountId 归属。
	var accountID string
	if err := s.db.QueryRow("SELECT accountId FROM noticeDeliveries WHERE noticeId='notice_1'").Scan(&accountID); err != nil {
		t.Fatalf("读迁移后的投递: %v", err)
	}
	if accountID != "acc_old" {
		t.Fatalf("投递归属 = %q, 期望 acc_old", accountID)
	}

	// migrate 7：pairCodes.expiresAt 必须可空（持久码写 NULL）。
	if _, err := s.db.Exec(
		"INSERT INTO pairCodes(codeHash, agentId, accountId, createdAt, expiresAt)" +
			" VALUES('h1','agt_old','acc_old',1700000000003,NULL)",
	); err != nil {
		t.Fatalf("持久码写 NULL expiresAt: %v", err)
	}

	// 旧数据一条不少。
	var deviceName string
	if err := s.db.QueryRow("SELECT name FROM devices WHERE deviceId='dev_old'").Scan(&deviceName); err != nil {
		t.Fatalf("读旧设备: %v", err)
	}
	if deviceName != "旧手机" {
		t.Fatalf("旧设备名 = %q", deviceName)
	}
}

// TestNewerSchemaVersionIsLeftAlone：库比这份代码新时只建表、不改版本，回滚不能降级。
func TestNewerSchemaVersionIsLeftAlone(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "future.db")

	first, err := Open(dbPath)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if _, err := first.db.Exec("PRAGMA user_version = 99"); err != nil {
		t.Fatalf("写未来版本: %v", err)
	}
	if err := first.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	second, err := Open(dbPath)
	if err != nil {
		t.Fatalf("再次 Open: %v", err)
	}
	defer second.Close()

	if second.Version() != 99 {
		t.Fatalf("Version = %d, 期望保持 99", second.Version())
	}
	if got := pragmaInt(t, second.db.DB, "PRAGMA user_version"); got != 99 {
		t.Fatalf("user_version = %d, 期望 99", got)
	}
}

func TestPing(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "state.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer s.Close()
	if err := s.Ping(context.Background()); err != nil {
		t.Fatalf("Ping: %v", err)
	}
}
