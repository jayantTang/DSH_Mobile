package store

import (
	"context"
	"database/sql"
	"fmt"
	"log/slog"
)

// Schema 是建库 DDL（唯一来源）。
//
// 与 Python 版的唯一差别：这里**不含**文件开头的 PRAGMA。`journal_mode` 是库文件级
// 属性、`foreign_keys`/`busy_timeout` 是每连接属性，交给 store.go 在打开连接时设置
// （database/sql 的连接池会让"一次性脚本"设不全）。
//
// 改这里必须同步 Python 版：M0 用一次性对比脚本核对了表名、列名、索引与
// user_version（见 maintainers/20261023-SQLite驱动基准.md §7），回滚到
// Python 版时库必须能直接打开。
const Schema = `
CREATE TABLE IF NOT EXISTS accounts (
  accountId  TEXT PRIMARY KEY,
  name       TEXT NOT NULL,
  createdAt  INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS agents (
  agentId    TEXT PRIMARY KEY,
  accountId  TEXT NOT NULL,
  name       TEXT NOT NULL,
  secretHash TEXT NOT NULL,
  createdAt  INTEGER NOT NULL,
  updatedAt  INTEGER NOT NULL,
  disabled   INTEGER NOT NULL DEFAULT 0,
  lastSeenAt INTEGER,
  -- 连接器版本观测（035）：hostStatus 上报，值变了才写。
  -- 必须是本表最后几列（迁移靠 ALTER TABLE 追加）。
  connectorVersion TEXT,
  hostVersion      TEXT,
  versionsAt       INTEGER
);
CREATE INDEX IF NOT EXISTS agents_account ON agents(accountId);

CREATE TABLE IF NOT EXISTS devices (
  deviceId        TEXT PRIMARY KEY,
  deviceTokenHash TEXT NOT NULL UNIQUE,
  agentId         TEXT NOT NULL,
  accountId       TEXT NOT NULL,
  name            TEXT NOT NULL,
  model           TEXT,
  appVersion      TEXT,
  createdAt       INTEGER NOT NULL,
  expiresAt       INTEGER NOT NULL,
  lastSeenAt      INTEGER,
  revokedAt       INTEGER,
  -- 推送登记（R-1）。
  apnsToken       TEXT,
  apnsEnv         TEXT,
  pushTurnEnd     INTEGER NOT NULL DEFAULT 1,
  pushAttention   INTEGER NOT NULL DEFAULT 1,
  pushUpdatedAt   INTEGER,
  -- 同一 client 的持久标识（032），必须留在表末。
  deviceKey       TEXT
);
CREATE INDEX IF NOT EXISTS devices_agent ON devices(agentId);

CREATE TABLE IF NOT EXISTS pairCodes (
  codeHash  TEXT PRIMARY KEY,
  agentId   TEXT NOT NULL,
  accountId TEXT NOT NULL,
  createdAt INTEGER NOT NULL,
  -- NULL = 永久有效（持久码，032）。
  expiresAt INTEGER,
  usedAt    INTEGER,
  deviceId  TEXT,
  revokedAt  INTEGER,
  lastUsedAt INTEGER,
  useCount   INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS pair_codes_agent ON pairCodes(agentId);

-- 账户级状态（032）：服务端只按 (accountId, key) 存取并保证 updatedAt 单调，
-- 合并语义由写入方决定。
CREATE TABLE IF NOT EXISTS accountState (
  accountId         TEXT NOT NULL,
  key               TEXT NOT NULL,
  value             TEXT NOT NULL,
  updatedAt         INTEGER NOT NULL,
  updatedByDeviceId TEXT,
  PRIMARY KEY (accountId, key)
);

-- 按天按设备的出口用量记账。day 是服务器本地日（YYYYMMDD）。
CREATE TABLE IF NOT EXISTS usageDaily (
  day         INTEGER NOT NULL,
  deviceId    TEXT NOT NULL,
  agentId     TEXT NOT NULL,
  accountId   TEXT NOT NULL,
  egressBytes INTEGER NOT NULL DEFAULT 0,
  connections INTEGER NOT NULL DEFAULT 0,
  firstSeenAt INTEGER NOT NULL,
  lastSeenAt  INTEGER NOT NULL,
  lastBuild   TEXT,
  PRIMARY KEY (day, deviceId)
);
CREATE INDEX IF NOT EXISTS usageDailyAccount ON usageDaily (day, accountId);

CREATE TABLE IF NOT EXISTS invites (
  codeHash        TEXT PRIMARY KEY,
  createdAt       INTEGER NOT NULL,
  expiresAt       INTEGER NOT NULL,
  usedAt          INTEGER,
  usedByAgentId   TEXT,
  note            TEXT
);

-- 反馈通道（014）：一条反馈是一个线程，线程里是往返留言。
-- 取件凭据只存 SHA-256；故意没有外键——设备撤销不应让反馈消失。
CREATE TABLE IF NOT EXISTS feedbackThreads (
  threadId       TEXT PRIMARY KEY,
  ticketHash     TEXT NOT NULL UNIQUE,
  accountId      TEXT,
  deviceId       TEXT,
  appVersion     TEXT,
  deviceModel    TEXT,
  systemVersion  TEXT,
  createdAt      INTEGER NOT NULL,
  lastMessageAt  INTEGER NOT NULL,
  ownerReadAt    INTEGER,
  userReadAt     INTEGER,
  status         TEXT NOT NULL DEFAULT 'open',
  clientRef      TEXT UNIQUE,
  -- 必须留在表末：老库靠 _migrate_to_3 的 ALTER TABLE 补上。
  subject        TEXT
);
CREATE INDEX IF NOT EXISTS feedbackThreadsByDevice ON feedbackThreads(deviceId);
CREATE INDEX IF NOT EXISTS feedbackThreadsByAccount ON feedbackThreads(accountId);
CREATE INDEX IF NOT EXISTS feedbackThreadsByStatus ON feedbackThreads(status, lastMessageAt);

CREATE TABLE IF NOT EXISTS feedbackMessages (
  messageId  TEXT PRIMARY KEY,
  threadId   TEXT NOT NULL,
  author     TEXT NOT NULL,
  body       TEXT NOT NULL,
  createdAt  INTEGER NOT NULL,
  clientRef  TEXT UNIQUE,
  -- 正文格式（FR-034），必须留在表末。
  format     TEXT NOT NULL DEFAULT 'text'
);
CREATE INDEX IF NOT EXISTS feedbackMessagesByThread ON feedbackMessages(threadId, createdAt);

CREATE TABLE IF NOT EXISTS notices (
  noticeId   TEXT PRIMARY KEY,
  subject    TEXT,
  body       TEXT NOT NULL,
  createdAt  INTEGER NOT NULL,
  createdBy  TEXT,
  format     TEXT NOT NULL DEFAULT 'text'
);

CREATE TABLE IF NOT EXISTS noticeDeliveries (
  noticeId   TEXT NOT NULL,
  accountId  TEXT NOT NULL,
  createdAt  INTEGER NOT NULL,
  readAt     INTEGER,
  PRIMARY KEY (noticeId, accountId)
);
-- noticeDeliveriesByAccount 故意不在这里建：老库里这张表还是 deviceId 那一版，
-- 索引由 _migrate_to_5 建（两条路径都会跑到它）。
`

// SchemaVersion 是这份代码期望的 schema 代（SQLite 的 PRAGMA user_version）。
//
// 为什么需要：Schema 全是 CREATE TABLE IF NOT EXISTS，加表没问题，加列会静默漏掉——
// 升级部署继续用旧库时，新列不存在，直到第一次写入才在"健康"的中转上炸掉。
// 升版本号并在 migrations 里加一步，才会变成启动时迁移。
const SchemaVersion = 8

// migration 是 schema 的一步迁移。每步必须幂等：部分提交后重启会重跑。
type migration struct {
	version int
	apply   func(ctx context.Context, q queryer) error
}

// queryer 是迁移需要的 SQL 能力，*sql.Tx / *sql.Conn 都满足。
type queryer interface {
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}

// migrations 按版本升序执行；与 Python 版 _MIGRATIONS 一一对应。
var migrations = []migration{
	{1, migrateTo1},
	{2, migrateTo2},
	{3, migrateTo3},
	{4, migrateTo4},
	{5, migrateTo5},
	{6, migrateTo6},
	{7, migrateTo7},
	{8, migrateTo8},
}

// migrateTo1 基线：早于版本号的库只盖戳，不改结构。
func migrateTo1(context.Context, queryer) error { return nil }

// migrateTo2 推送登记：devices 加五列（R-1 C-07）。
func migrateTo2(ctx context.Context, q queryer) error {
	present, err := columns(ctx, q, "devices")
	if err != nil {
		return err
	}
	additions := [][2]string{
		{"apnsToken", "TEXT"},
		{"apnsEnv", "TEXT"},
		{"pushTurnEnd", "INTEGER NOT NULL DEFAULT 1"},
		{"pushAttention", "INTEGER NOT NULL DEFAULT 1"},
		{"pushUpdatedAt", "INTEGER"},
	}
	return addColumns(ctx, q, "devices", present, additions)
}

// migrateTo3 界面重做：feedbackThreads 加 subject。
func migrateTo3(ctx context.Context, q queryer) error {
	present, err := columns(ctx, q, "feedbackThreads")
	if err != nil {
		return err
	}
	return addColumns(ctx, q, "feedbackThreads", present, [][2]string{{"subject", "TEXT"}})
}

// migrateTo4 富文本：feedbackMessages 与 notices 各加 format。
func migrateTo4(ctx context.Context, q queryer) error {
	for _, table := range []string{"feedbackMessages", "notices"} {
		present, err := columns(ctx, q, table)
		if err != nil {
			return err
		}
		if err := addColumns(ctx, q, table, present,
			[][2]string{{"format", "TEXT NOT NULL DEFAULT 'text'"}}); err != nil {
			return err
		}
	}
	return nil
}

// migrateTo5 收件箱归属从设备换成账号（019）：重建 noticeDeliveries。
//
// 旧行经 devices.accountId 归属；设备已不存在的行跳过（只记条数），
// 为一条无法归属的历史行让整库迁移失败代价更大。
func migrateTo5(ctx context.Context, q queryer) error {
	present, err := columns(ctx, q, "noticeDeliveries")
	if err != nil {
		return err
	}
	if _, hasAccount := present["accountId"]; hasAccount {
		if _, hasDevice := present["deviceId"]; !hasDevice {
			// 已经迁过；索引仍要补一次——新库建表时故意没建这条索引。
			_, err = q.ExecContext(ctx, "CREATE INDEX IF NOT EXISTS noticeDeliveriesByAccount"+
				" ON noticeDeliveries(accountId, readAt)")
			return err
		}
	}

	var skipped int64
	if err := q.QueryRowContext(ctx,
		"SELECT COUNT(*) FROM noticeDeliveries d"+
			" LEFT JOIN devices v ON v.deviceId = d.deviceId WHERE v.deviceId IS NULL",
	).Scan(&skipped); err != nil {
		return err
	}
	for _, stmt := range []string{
		"CREATE TABLE noticeDeliveries_new (" +
			"  noticeId   TEXT NOT NULL," +
			"  accountId  TEXT NOT NULL," +
			"  createdAt  INTEGER NOT NULL," +
			"  readAt     INTEGER," +
			"  PRIMARY KEY (noticeId, accountId)" +
			")",
		"INSERT OR IGNORE INTO noticeDeliveries_new(noticeId, accountId, createdAt, readAt)" +
			" SELECT d.noticeId, v.accountId, MIN(d.createdAt)," +
			"        MIN(CASE WHEN d.readAt IS NOT NULL THEN d.readAt END)" +
			"   FROM noticeDeliveries d JOIN devices v ON v.deviceId = d.deviceId" +
			"  GROUP BY d.noticeId, v.accountId",
		"DROP TABLE noticeDeliveries",
		"ALTER TABLE noticeDeliveries_new RENAME TO noticeDeliveries",
		"CREATE INDEX IF NOT EXISTS noticeDeliveriesByAccount" +
			" ON noticeDeliveries(accountId, readAt)",
	} {
		if _, err := q.ExecContext(ctx, stmt); err != nil {
			return fmt.Errorf("migrate 5: %w", err)
		}
	}
	if skipped > 0 {
		slog.Info("store: migrate 5: notice delivery rows skipped (device gone)", "rows", skipped)
	}
	return nil
}

// migrateTo6 持久配对码与设备标识（032）。
func migrateTo6(ctx context.Context, q queryer) error {
	present, err := columns(ctx, q, "pairCodes")
	if err != nil {
		return err
	}
	if err := addColumns(ctx, q, "pairCodes", present, [][2]string{
		{"revokedAt", "INTEGER"},
		{"lastUsedAt", "INTEGER"},
		{"useCount", "INTEGER NOT NULL DEFAULT 0"},
	}); err != nil {
		return err
	}

	present, err = columns(ctx, q, "devices")
	if err != nil {
		return err
	}
	if err := addColumns(ctx, q, "devices", present, [][2]string{{"deviceKey", "TEXT"}}); err != nil {
		return err
	}

	_, err = q.ExecContext(ctx, "CREATE INDEX IF NOT EXISTS devices_account_deviceKey"+
		" ON devices(accountId, deviceKey) WHERE deviceKey IS NOT NULL AND revokedAt IS NULL")
	return err
}

// migrateTo7 pairCodes.expiresAt 从 NOT NULL 改成可空（持久码要写 NULL）。
//
// SQLite 改不了列约束，只能重建表。2026-10-16 生产上就是漏了这一步：v6 只加了列，
// 第一枚持久码写入时 NOT NULL 约束当场失败。
func migrateTo7(ctx context.Context, q queryer) error {
	nullable, err := columnAllowsNull(ctx, q, "pairCodes", "expiresAt")
	if err != nil {
		return err
	}
	if nullable {
		return nil
	}
	for _, stmt := range []string{
		`CREATE TABLE pairCodes_new (
		     codeHash  TEXT PRIMARY KEY,
		     agentId   TEXT NOT NULL,
		     accountId TEXT NOT NULL,
		     createdAt INTEGER NOT NULL,
		     expiresAt INTEGER,
		     usedAt    INTEGER,
		     deviceId  TEXT,
		     revokedAt  INTEGER,
		     lastUsedAt INTEGER,
		     useCount   INTEGER NOT NULL DEFAULT 0
		   )`,
		"INSERT INTO pairCodes_new(codeHash, agentId, accountId, createdAt, expiresAt," +
			" usedAt, deviceId, revokedAt, lastUsedAt, useCount)" +
			" SELECT codeHash, agentId, accountId, createdAt, expiresAt," +
			" usedAt, deviceId, revokedAt, lastUsedAt, useCount FROM pairCodes",
		"DROP TABLE pairCodes",
		"ALTER TABLE pairCodes_new RENAME TO pairCodes",
		"CREATE INDEX IF NOT EXISTS pair_codes_agent ON pairCodes(agentId)",
	} {
		if _, err := q.ExecContext(ctx, stmt); err != nil {
			return fmt.Errorf("migrate 7: %w", err)
		}
	}
	return nil
}

// migrateTo8 版本观测（035）：agents 加三列。
func migrateTo8(ctx context.Context, q queryer) error {
	present, err := columns(ctx, q, "agents")
	if err != nil {
		return err
	}
	return addColumns(ctx, q, "agents", present, [][2]string{
		{"connectorVersion", "TEXT"},
		{"hostVersion", "TEXT"},
		{"versionsAt", "INTEGER"},
	})
}

// columns 返回表的列名集合（PRAGMA table_info 的第二列）。
func columns(ctx context.Context, q queryer, table string) (map[string]struct{}, error) {
	rows, err := q.QueryContext(ctx, "PRAGMA table_info("+table+")")
	if err != nil {
		return nil, fmt.Errorf("inspect %s: %w", table, err)
	}
	defer rows.Close()

	present := map[string]struct{}{}
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
			return nil, fmt.Errorf("inspect %s: %w", table, err)
		}
		present[name] = struct{}{}
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("inspect %s: %w", table, err)
	}
	return present, nil
}

// addColumns 补齐缺失列；ADD COLUMN 在 SQLite 里没有 IF NOT EXISTS，所以先查列。
func addColumns(ctx context.Context, q queryer, table string,
	present map[string]struct{}, additions [][2]string) error {
	for _, addition := range additions {
		name, declaration := addition[0], addition[1]
		if _, ok := present[name]; ok {
			continue
		}
		// 声明是写死的字面量（不是用户输入），不能参数化。
		sqlText := "ALTER TABLE " + table + " ADD COLUMN " + name + " " + declaration
		if _, err := q.ExecContext(ctx, sqlText); err != nil {
			return fmt.Errorf("add column %s.%s: %w", table, name, err)
		}
	}
	return nil
}

// columnAllowsNull 报告某列是否可空（PRAGMA table_info 的 notnull 标志）。
func columnAllowsNull(ctx context.Context, q queryer, table, column string) (bool, error) {
	rows, err := q.QueryContext(ctx, "PRAGMA table_info("+table+")")
	if err != nil {
		return false, fmt.Errorf("inspect %s: %w", table, err)
	}
	defer rows.Close()

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
			return false, fmt.Errorf("inspect %s: %w", table, err)
		}
		if name == column {
			return notNull == 0, nil
		}
	}
	if err := rows.Err(); err != nil {
		return false, fmt.Errorf("inspect %s: %w", table, err)
	}
	// 列不存在时按"可空"处理：调用方的重建路径会补上它。
	return true, nil
}
