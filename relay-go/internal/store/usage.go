package store

import (
	"context"
	"database/sql"
	"fmt"
	"sort"
)

// AddUsage 把一批按天按设备的出口字节累加进 usageDaily（UPSERT，一次事务）。
//
// 累加而不是覆盖：冲盘是周期性的，一行一天会被写很多次（Python add_usage）。
func (s *Store) AddUsage(ctx context.Context, entries []UsageEntry) (int, error) {
	if len(entries) == 0 {
		return 0, nil
	}
	err := s.writeTx(ctx, func(ctx context.Context, q execQuerier) error {
		for _, entry := range entries {
			if _, err := q.ExecContext(ctx, `
				INSERT INTO usageDaily(day, deviceId, agentId, accountId, egressBytes,
				                       connections, firstSeenAt, lastSeenAt, lastBuild)
				VALUES(?,?,?,?,?,?,?,?,?)
				ON CONFLICT(day, deviceId) DO UPDATE SET
				  egressBytes = egressBytes + excluded.egressBytes,
				  connections = connections + excluded.connections,
				  firstSeenAt = MIN(firstSeenAt, excluded.firstSeenAt),
				  lastSeenAt  = MAX(lastSeenAt, excluded.lastSeenAt),
				  lastBuild   = COALESCE(excluded.lastBuild, lastBuild),
				  agentId     = excluded.agentId,
				  accountId   = excluded.accountId`,
				entry.Day, entry.DeviceID, entry.AgentID, entry.AccountID,
				entry.EgressBytes, entry.Connections, entry.At, entry.At,
				nullStringValue(entry.LastBuild)); err != nil {
				return fmt.Errorf("store: 记用量: %w", err)
			}
		}
		return nil
	})
	if err != nil {
		return 0, err
	}
	return len(entries), nil
}

// UsageRows 是一天里每台设备一行，按出口字节降序（Python usage_rows）。
func (s *Store) UsageRows(ctx context.Context, day int64) ([]UsageRow, error) {
	rows, err := s.db.QueryContext(ctx,
		"SELECT day, deviceId, agentId, accountId, egressBytes, connections, firstSeenAt,"+
			" lastSeenAt, lastBuild FROM usageDaily WHERE day=? ORDER BY egressBytes DESC",
		day)
	if err != nil {
		return nil, fmt.Errorf("store: 读当日用量: %w", err)
	}
	defer rows.Close()

	usage := []UsageRow{}
	for rows.Next() {
		var (
			row       UsageRow
			lastBuild sql.NullString
		)
		if err := rows.Scan(&row.Day, &row.DeviceID, &row.AgentID, &row.AccountID,
			&row.EgressBytes, &row.Connections, &row.FirstSeenAt, &row.LastSeenAt,
			&lastBuild); err != nil {
			return nil, fmt.Errorf("store: 读当日用量行: %w", err)
		}
		row.LastBuild = nullString(lastBuild)
		usage = append(usage, row)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: 读当日用量行: %w", err)
	}
	return usage, nil
}

// UsageBytesOn 是某台设备在某一天已经落库的出口字节；没有那一行时是 0。
//
// 日额度的基线只问这一台设备（Python 的 hub._quota_for 每次都读 usage_rows 再线性
// 找一行，设备多了就是 O(设备数²)）；SQL 仍然只出现在 store 里。
func (s *Store) UsageBytesOn(ctx context.Context, day int64, deviceID string) (int64, error) {
	var egress int64
	err := s.db.QueryRowContext(ctx,
		"SELECT COALESCE(SUM(egressBytes), 0) FROM usageDaily WHERE day=? AND deviceId=?",
		day, deviceID).Scan(&egress)
	if err != nil {
		return 0, fmt.Errorf("store: 读设备当日用量: %w", err)
	}
	return egress, nil
}

// UsageTotals 是最近 `days` 天按账号或按设备汇总（Python usage_totals）。
//
// 汇总放在 SQL 里：调用它的是运维命令与日报，行数再多也不该先全读进进程。
// `by` 只认 account / device（与 argparse 的 choices 同一口径）。
func (s *Store) UsageTotals(ctx context.Context, days int, by string) ([]UsageTotal, error) {
	key := "accountId"
	nameQuery := "(SELECT name FROM accounts WHERE accounts.accountId = u.accountId)"
	if by == "device" {
		key = "deviceId"
		nameQuery = "(SELECT name FROM devices WHERE devices.deviceId = u.deviceId)"
	} else if by != "account" {
		return nil, fmt.Errorf("store: usage 维度只支持 account / device，收到 %q", by)
	}
	rows, err := s.db.QueryContext(ctx,
		"SELECT u.day AS day, u."+key+" AS "+key+", "+nameQuery+" AS name,"+
			" SUM(u.egressBytes) AS egressBytes, SUM(u.connections) AS connections,"+
			" MAX(u.lastSeenAt) AS lastSeenAt, MAX(u.lastBuild) AS lastBuild,"+
			" COUNT(DISTINCT u.deviceId) AS devices"+
			" FROM usageDaily u WHERE u.day >= ? GROUP BY u.day, u."+key+
			" ORDER BY u.day DESC, egressBytes DESC",
		DayFloor(days))
	if err != nil {
		return nil, fmt.Errorf("store: 汇总用量: %w", err)
	}
	defer rows.Close()

	totals := []UsageTotal{}
	for rows.Next() {
		var (
			row       UsageTotal
			keyValue  string
			name      sql.NullString
			lastBuild sql.NullString
		)
		if err := rows.Scan(&row.Day, &keyValue, &name, &row.EgressBytes,
			&row.Connections, &row.LastSeenAt, &lastBuild, &row.Devices); err != nil {
			return nil, fmt.Errorf("store: 读用量汇总行: %w", err)
		}
		if key == "accountId" {
			row.AccountID = &keyValue
		} else {
			row.DeviceID = &keyValue
		}
		if name.Valid {
			value := name.String
			row.Name = &value
		}
		row.LastBuild = nullString(lastBuild)
		totals = append(totals, row)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: 读用量汇总行: %w", err)
	}
	return totals, nil
}

// TodayUsage 汇总某一天（本地日）的出口用量，形状与 Python hub.usage_today 一致。
//
// 只读库里已经冲盘的那一半；memory 里还没落盘的部分由 hub 在同一个结构上合并
// （hub.Today，M2 起生效），函数签名不变。
func (s *Store) TodayUsage(ctx context.Context, day int64) (TodayUsage, error) {
	rows, err := s.UsageRows(ctx, day)
	if err != nil {
		return TodayUsage{}, err
	}

	devices := make([]TodayDevice, 0, len(rows))
	accounts := map[string]*TodayAccount{}
	var total int64
	for _, row := range rows {
		total += row.EgressBytes
		devices = append(devices, TodayDevice{
			DeviceID: row.DeviceID, AgentID: row.AgentID, AccountID: row.AccountID,
			EgressBytes: row.EgressBytes, Connections: row.Connections,
			LastBuild: row.LastBuild,
		})
		bucket, ok := accounts[row.AccountID]
		if !ok {
			bucket = &TodayAccount{AccountID: row.AccountID}
			accounts[row.AccountID] = bucket
		}
		bucket.EgressBytes += row.EgressBytes
		bucket.Devices++
	}

	// UsageRows 已按字节降序；账户侧再排一次（Python 也是两次排序）。
	sort.SliceStable(devices, func(i, j int) bool {
		return devices[i].EgressBytes > devices[j].EgressBytes
	})
	accountRows := make([]TodayAccount, 0, len(accounts))
	for _, bucket := range accounts {
		accountRows = append(accountRows, *bucket)
	}
	sort.SliceStable(accountRows, func(i, j int) bool {
		return accountRows[i].EgressBytes > accountRows[j].EgressBytes
	})

	return TodayUsage{Day: day, TotalEgressBytes: total, Devices: devices,
		Accounts: accountRows}, nil
}
