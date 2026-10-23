package store

import (
	"context"
	"database/sql"
	"fmt"
)

// 设备死记录清理（Python purge-revoked-devices.py）的 SQL 都收在这里。
//
// 判据只有一条：`revokedAt IS NOT NULL OR expiresAt <= now`。撤销是不可逆的产品
// 状态，过期是配对满 TTL（365 天），两种令牌在 DeviceByToken 里都被拒，所以两种
// 都回不来。在用设备（两者都不成立）一行都不碰，这一点由同一个条件在统计与删除
// 两处复用保证——不允许出现「统计说保留、删除却删了」的第二套口径。

const doomedDeviceCondition = "revokedAt IS NOT NULL OR expiresAt <= ?"

// AgentIDsWithDevices 是库里所有还有设备行的 agent（按 id 排序）。
func (s *Store) AgentIDsWithDevices(ctx context.Context) ([]string, error) {
	rows, err := s.db.QueryContext(ctx,
		"SELECT DISTINCT agentId FROM devices ORDER BY agentId")
	if err != nil {
		return nil, fmt.Errorf("store: 列有设备的 agent: %w", err)
	}
	defer rows.Close()
	ids := []string{}
	for rows.Next() {
		var agentID string
		if err := rows.Scan(&agentID); err != nil {
			return nil, fmt.Errorf("store: 读 agent id: %w", err)
		}
		ids = append(ids, agentID)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: 读 agent 列表: %w", err)
	}
	return ids, nil
}

// DevicePurgeAgent 是一个 agent 的待清理明细（Doomed 是即将删除的整行）。
type DevicePurgeAgent struct {
	AgentID string   `json:"agentId"`
	Total   int      `json:"total"`
	Doomed  []Device `json:"doomed"`
	Live    []Device `json:"live"`
}

// DevicePurgeReport 统计每个 agent 的全部设备行，并分成「待删」与「在用」两组。
//
// 只读：预演与真删走同一份统计，预演看到的就是将要删除的。
func (s *Store) DevicePurgeReport(ctx context.Context, agentIDs []string,
	now int64) ([]DevicePurgeAgent, error) {
	report := make([]DevicePurgeAgent, 0, len(agentIDs))
	for _, agentID := range agentIDs {
		devices, err := s.ListDevices(ctx, agentID, true)
		if err != nil {
			return nil, err
		}
		entry := DevicePurgeAgent{
			AgentID: agentID, Total: len(devices),
			Doomed: []Device{}, Live: []Device{},
		}
		for _, device := range devices {
			if device.RevokedAt != nil || device.ExpiresAt <= now {
				entry.Doomed = append(entry.Doomed, device)
			} else {
				entry.Live = append(entry.Live, device)
			}
		}
		if len(entry.Doomed)+len(entry.Live) != entry.Total {
			return nil, fmt.Errorf(
				"store: agent %s 的设备行既不算待删也不算在用（统计不自洽）", agentID)
		}
		report = append(report, entry)
	}
	return report, nil
}

// DeleteDoomedDevices 删掉这些 agent 名下已撤销/已过期的设备行，返回删除行数。
//
// 一个事务：要么全删、要么一行不动。不碰 feedbackThreads / usageDaily（它们按
// deviceId 关联，设备行没了只留下孤立引用，账目与用户反馈必须保住）。
func (s *Store) DeleteDoomedDevices(ctx context.Context, agentIDs []string,
	now int64) (int64, error) {
	var removed int64
	err := s.writeTx(ctx, func(ctx context.Context, q execQuerier) error {
		for _, agentID := range agentIDs {
			result, err := q.ExecContext(ctx,
				"DELETE FROM devices WHERE agentId=? AND ("+doomedDeviceCondition+")",
				agentID, now)
			if err != nil {
				return fmt.Errorf("store: 清理 agent %s 的设备行: %w", agentID, err)
			}
			affected, err := result.RowsAffected()
			if err != nil {
				return fmt.Errorf("store: 读删除行数: %w", err)
			}
			removed += affected
		}
		return nil
	})
	if err != nil {
		return 0, err
	}
	return removed, nil
}

// CountDevicesOfAgents 返回每个 agent 当前的全部设备行数（清理前后核对用）。
func (s *Store) CountDevicesOfAgents(ctx context.Context,
	agentIDs []string) (map[string]int, error) {
	counts := make(map[string]int, len(agentIDs))
	for _, agentID := range agentIDs {
		var count int
		if err := s.db.QueryRowContext(ctx,
			"SELECT COUNT(*) FROM devices WHERE agentId=?", agentID).Scan(&count); err != nil {
			return nil, fmt.Errorf("store: 统计 agent %s 的设备行: %w", agentID, err)
		}
		counts[agentID] = count
	}
	return counts, nil
}

// BackupTo 把整个库复制到 path（VACUUM INTO：一致快照，包含 WAL 里已提交的内容）。
//
// 目标文件必须不存在；调用方用时间戳命名，天然不重复。
func (s *Store) BackupTo(ctx context.Context, path string) error {
	if _, err := s.db.ExecContext(ctx, "VACUUM INTO ?", path); err != nil {
		return fmt.Errorf("store: 备份到 %s: %w", path, err)
	}
	return nil
}

// CountDevicesInBackup 用只读连接读一份备份里这些 agent 的设备行数。
//
// 清理前核对备份行数与源库一致（Python 版同样做这一步）：备份不完整时宁可不删。
func CountDevicesInBackup(ctx context.Context, path string,
	agentIDs []string) (map[string]int, error) {
	db, err := sql.Open(driverName, "file:"+path+"?mode=ro")
	if err != nil {
		return nil, fmt.Errorf("store: 打开备份 %s: %w", path, err)
	}
	defer db.Close()
	counts := make(map[string]int, len(agentIDs))
	for _, agentID := range agentIDs {
		var count int
		if err := db.QueryRowContext(ctx,
			"SELECT COUNT(*) FROM devices WHERE agentId=?", agentID).Scan(&count); err != nil {
			return nil, fmt.Errorf("store: 读备份里的 agent %s: %w", agentID, err)
		}
		counts[agentID] = count
	}
	return counts, nil
}
