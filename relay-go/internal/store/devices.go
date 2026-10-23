package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
)

// DeviceByToken 用明文设备令牌反查设备（Python device_by_token）。
//
// 空令牌、未知哈希、已撤销、已过期都返回 (zero, false)：调用方拿到 false 就回 401，
// 不给它区分"撤销"与"不存在"。
func (s *Store) DeviceByToken(ctx context.Context, token string) (Device, bool, error) {
	if token == "" {
		return Device{}, false, nil
	}
	row := s.db.QueryRowContext(ctx, "SELECT "+deviceColumns+
		" FROM devices WHERE deviceTokenHash=?", SHA256Hex(token))
	device, err := scanDevice(row)
	if errors.Is(err, sql.ErrNoRows) {
		return Device{}, false, nil
	}
	if err != nil {
		return Device{}, false, fmt.Errorf("store: 用令牌读设备: %w", err)
	}
	if device.RevokedAt != nil {
		return Device{}, false, nil
	}
	if device.ExpiresAt <= NowMS() {
		return Device{}, false, nil
	}
	return device, true, nil
}

// DeviceByID 按 ID 读设备（含已撤销的；调用方自己判断 revokedAt）。
func (s *Store) DeviceByID(ctx context.Context, deviceID string) (Device, bool, error) {
	row := s.db.QueryRowContext(ctx, "SELECT "+deviceColumns+" FROM devices WHERE deviceId=?",
		deviceID)
	device, err := scanDevice(row)
	if errors.Is(err, sql.ErrNoRows) {
		return Device{}, false, nil
	}
	if err != nil {
		return Device{}, false, fmt.Errorf("store: 读设备 %s: %w", deviceID, err)
	}
	return device, true, nil
}

// RevokedIDsAmong 返回这些设备 ID 里已撤销的那些。
//
// 对账循环拿它检查"在线但库里已撤销"这种中转绝不能停留的状态；只读，分批查询
// （SQLite 绑定变量历史上限 999）。
func (s *Store) RevokedIDsAmong(ctx context.Context, deviceIDs []string) (map[string]struct{}, error) {
	return s.idsAmong(ctx, deviceIDs, "revokedAt IS NOT NULL", nil)
}

// GoneIDsAmong 返回这些设备 ID 里"再也不可能通过认证"的那些：已撤销，或已过期。
//
// 只用于当前不在线的设备（在线 socket 不因过期单独断开），见 DESIGN 与
// Python gone_ids_among。
func (s *Store) GoneIDsAmong(ctx context.Context, deviceIDs []string) (map[string]struct{}, error) {
	stamp := NowMS()
	return s.idsAmong(ctx, deviceIDs, "(revokedAt IS NOT NULL OR expiresAt <= ?)", []any{stamp})
}

// ExpiredIDsOfAgent 返回该 agent 名下配对已过 TTL 的设备（不含撤销的那一半）。
func (s *Store) ExpiredIDsOfAgent(ctx context.Context, agentID string) (map[string]struct{}, error) {
	rows, err := s.db.QueryContext(ctx,
		"SELECT deviceId FROM devices WHERE agentId=? AND expiresAt <= ?", agentID, NowMS())
	if err != nil {
		return nil, fmt.Errorf("store: 查过期设备: %w", err)
	}
	defer rows.Close()

	found := map[string]struct{}{}
	for rows.Next() {
		var deviceID string
		if err := rows.Scan(&deviceID); err != nil {
			return nil, fmt.Errorf("store: 读过期设备: %w", err)
		}
		found[deviceID] = struct{}{}
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: 读过期设备: %w", err)
	}
	return found, nil
}

// idsAmong 是设备 ID 集合查询的共用实现；candidate 里的占位符按条件顺序绑定。
func (s *Store) idsAmong(ctx context.Context, deviceIDs []string,
	condition string, leading []any) (map[string]struct{}, error) {
	seen := map[string]struct{}{}
	unique := make([]string, 0, len(deviceIDs))
	for _, id := range deviceIDs {
		if id == "" {
			continue
		}
		if _, ok := seen[id]; ok {
			continue
		}
		seen[id] = struct{}{}
		unique = append(unique, id)
	}
	if len(unique) == 0 {
		return map[string]struct{}{}, nil
	}

	found := map[string]struct{}{}
	const chunkSize = 500
	for start := 0; start < len(unique); start += chunkSize {
		end := start + chunkSize
		if end > len(unique) {
			end = len(unique)
		}
		chunk := unique[start:end]
		marks := strings.TrimSuffix(strings.Repeat("?,", len(chunk)), ",")
		args := make([]any, 0, len(leading)+len(chunk))
		args = append(args, leading...)
		for _, id := range chunk {
			args = append(args, id)
		}
		rows, err := s.db.QueryContext(ctx,
			"SELECT deviceId FROM devices WHERE "+condition+" AND deviceId IN ("+marks+")",
			args...)
		if err != nil {
			return nil, fmt.Errorf("store: 查设备集合: %w", err)
		}
		for rows.Next() {
			var deviceID string
			if err := rows.Scan(&deviceID); err != nil {
				rows.Close()
				return nil, fmt.Errorf("store: 读设备集合: %w", err)
			}
			found[deviceID] = struct{}{}
		}
		if err := rows.Err(); err != nil {
			rows.Close()
			return nil, fmt.Errorf("store: 读设备集合: %w", err)
		}
		rows.Close()
	}
	return found, nil
}

// DeviceHygiene 是设备记录的健康计数（Python device_hygiene）。
//
// 口径与清理工具逐字相同：revoked = revokedAt IS NOT NULL，expired = expiresAt <= now，
// live = 两者都不成立，dead = 并集去重（撤销过的行也可能同时过期，所以
// revoked + expired >= dead，不能拿前两个相加当 dead）。
func (s *Store) DeviceHygiene(ctx context.Context, agentID string) (Hygiene, error) {
	stamp := NowMS()
	query := "SELECT COUNT(*) AS total," +
		" COALESCE(SUM(CASE WHEN revokedAt IS NOT NULL THEN 1 ELSE 0 END), 0) AS revoked," +
		" COALESCE(SUM(CASE WHEN expiresAt <= ? THEN 1 ELSE 0 END), 0) AS expired," +
		" COALESCE(SUM(CASE WHEN revokedAt IS NULL AND expiresAt > ? THEN 1 ELSE 0 END), 0) AS live," +
		" COALESCE(SUM(CASE WHEN revokedAt IS NOT NULL OR expiresAt <= ? THEN 1 ELSE 0 END), 0) AS dead" +
		" FROM devices"
	args := []any{stamp, stamp, stamp}
	if agentID != "" {
		query += " WHERE agentId=?"
		args = append(args, agentID)
	}

	var hygiene Hygiene
	if err := s.db.QueryRowContext(ctx, query, args...).Scan(&hygiene.Total,
		&hygiene.Revoked, &hygiene.Expired, &hygiene.Live, &hygiene.Dead); err != nil {
		return Hygiene{}, fmt.Errorf("store: 统计设备记录: %w", err)
	}
	if agentID != "" {
		hygiene.AgentID = agentID
	}
	return hygiene, nil
}

// ListDevices 列出一个 agent（或全部）的设备，默认不含已撤销的（Python list_devices）。
func (s *Store) ListDevices(ctx context.Context, agentID string,
	includeRevoked bool) ([]Device, error) {
	clauses := []string{}
	args := []any{}
	if agentID != "" {
		clauses = append(clauses, "agentId=?")
		args = append(args, agentID)
	}
	if !includeRevoked {
		clauses = append(clauses, "revokedAt IS NULL")
	}
	query := "SELECT " + deviceColumns + " FROM devices"
	if len(clauses) > 0 {
		query += " WHERE " + strings.Join(clauses, " AND ")
	}
	query += " ORDER BY createdAt"

	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("store: 列设备: %w", err)
	}
	defer rows.Close()

	devices := []Device{}
	for rows.Next() {
		device, err := scanDevice(rows)
		if err != nil {
			return nil, fmt.Errorf("store: 读设备行: %w", err)
		}
		devices = append(devices, device)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: 读设备行: %w", err)
	}
	return devices, nil
}

// RefreshDevice 轮换设备令牌并延长有效期（Python refresh_device）。
//
// 读旧行与写新行在同一个写事务里：两次并发刷新不会各发一枚、只留最后一枚。
func (s *Store) RefreshDevice(ctx context.Context, token string, ttlMS int64) (RefreshResult, error) {
	if token == "" {
		return RefreshResult{}, newNotFound("device token is invalid, revoked, or expired")
	}
	now := NowMS()
	var refreshed RefreshResult

	err := s.writeTx(ctx, func(ctx context.Context, q execQuerier) error {
		row := q.QueryRowContext(ctx, "SELECT "+deviceColumns+
			" FROM devices WHERE deviceTokenHash=?", SHA256Hex(token))
		device, err := scanDevice(row)
		if errors.Is(err, sql.ErrNoRows) {
			return newNotFound("device token is invalid, revoked, or expired")
		}
		if err != nil {
			return fmt.Errorf("store: 读待刷新设备: %w", err)
		}
		if device.RevokedAt != nil || device.ExpiresAt <= now {
			return newNotFound("device token is invalid, revoked, or expired")
		}
		fresh := newToken("dt")
		expires := now + ttlMS
		if _, err := q.ExecContext(ctx,
			"UPDATE devices SET deviceTokenHash=?, expiresAt=? WHERE deviceId=?",
			SHA256Hex(fresh), expires, device.DeviceID); err != nil {
			return fmt.Errorf("store: 刷新设备令牌: %w", err)
		}
		refreshed = RefreshResult{DeviceID: device.DeviceID, AgentID: device.AgentID,
			AccountID: device.AccountID, DeviceToken: fresh, ExpiresAt: expires}
		return nil
	})
	if err != nil {
		return RefreshResult{}, err
	}
	return refreshed, nil
}

// RevokeDevice 撤销一台设备（Python revoke_device）。
//
// 顺手清掉推送登记：这台设备不会再回来，留着令牌只会让中转继续往一台已经解绑的
// 手机推。
func (s *Store) RevokeDevice(ctx context.Context, deviceID string) error {
	stamp := NowMS()
	return s.writeTx(ctx, func(ctx context.Context, q execQuerier) error {
		var exists int
		err := q.QueryRowContext(ctx, "SELECT 1 FROM devices WHERE deviceId=?", deviceID).Scan(&exists)
		if errors.Is(err, sql.ErrNoRows) {
			return newNotFound("device %s does not exist", deviceID)
		}
		if err != nil {
			return fmt.Errorf("store: 查设备 %s: %w", deviceID, err)
		}
		if _, err := q.ExecContext(ctx,
			"UPDATE devices SET revokedAt=?, apnsToken=NULL, apnsEnv=NULL, pushUpdatedAt=?"+
				" WHERE deviceId=?", stamp, stamp, deviceID); err != nil {
			return fmt.Errorf("store: 撤销设备 %s: %w", deviceID, err)
		}
		return nil
	})
}

// SetPush 登记（或清除）一台设备的 APNs 令牌与两个提醒开关（Python set_push）。
//
// token 为空表示清除：用户在设置里关掉通知时 App 就是这么上报的。
func (s *Store) SetPush(ctx context.Context, deviceID string, token, env *string,
	turnEnd, attention bool) error {
	var value *string
	if token != nil {
		trimmed := strings.TrimSpace(*token)
		if trimmed != "" {
			value = &trimmed
		}
	}
	var environment *string
	if value != nil {
		environment = env
	}
	return s.writeTx(ctx, func(ctx context.Context, q execQuerier) error {
		var exists int
		err := q.QueryRowContext(ctx, "SELECT 1 FROM devices WHERE deviceId=?", deviceID).Scan(&exists)
		if errors.Is(err, sql.ErrNoRows) {
			return newNotFound("device %s does not exist", deviceID)
		}
		if err != nil {
			return fmt.Errorf("store: 查设备 %s: %w", deviceID, err)
		}
		if _, err := q.ExecContext(ctx,
			"UPDATE devices SET apnsToken=?, apnsEnv=?, pushTurnEnd=?, pushAttention=?,"+
				" pushUpdatedAt=? WHERE deviceId=?",
			nullStringValue(value), nullStringValue(environment), boolInt(turnEnd),
			boolInt(attention), NowMS(), deviceID); err != nil {
			return fmt.Errorf("store: 登记推送: %w", err)
		}
		return nil
	})
}

// ClearPush 只清掉 APNs 令牌，不动开关（Python clear_push）。
//
// Apple 回 410 / BadDeviceToken 时用：手机没了或重装了，重试没有意义。
func (s *Store) ClearPush(ctx context.Context, deviceID string) error {
	return s.writeTx(ctx, func(ctx context.Context, q execQuerier) error {
		if _, err := q.ExecContext(ctx,
			"UPDATE devices SET apnsToken=NULL, apnsEnv=NULL, pushUpdatedAt=? WHERE deviceId=?",
			NowMS(), deviceID); err != nil {
			return fmt.Errorf("store: 清推送登记: %w", err)
		}
		return nil
	})
}

// PushTargets 是一台电脑名下可推送的设备（Python push_targets）。
//
// 条件是列：已登记令牌与环境、未撤销、未过期。"此刻在线吗"不在这里判断——只有
// hub 知道。
func (s *Store) PushTargets(ctx context.Context, agentID string) ([]Device, error) {
	rows, err := s.db.QueryContext(ctx, "SELECT "+deviceColumns+
		" FROM devices WHERE agentId=? AND apnsToken IS NOT NULL AND apnsEnv IS NOT NULL"+
		" AND revokedAt IS NULL AND expiresAt > ? ORDER BY createdAt", agentID, NowMS())
	if err != nil {
		return nil, fmt.Errorf("store: 列推送目标: %w", err)
	}
	defer rows.Close()

	devices := []Device{}
	for rows.Next() {
		device, err := scanDevice(rows)
		if err != nil {
			return nil, fmt.Errorf("store: 读推送目标行: %w", err)
		}
		devices = append(devices, device)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: 读推送目标行: %w", err)
	}
	return devices, nil
}

// SetDeviceAppVersion 记这台设备刚上报的构建版本（Python set_device_app_version）。
func (s *Store) SetDeviceAppVersion(ctx context.Context, deviceID, version string) error {
	return s.writeTx(ctx, func(ctx context.Context, q execQuerier) error {
		if _, err := q.ExecContext(ctx,
			"UPDATE devices SET appVersion=? WHERE deviceId=?", version, deviceID); err != nil {
			return fmt.Errorf("store: 记设备版本: %w", err)
		}
		return nil
	})
}

// TouchDevice 记一次设备在线时间（Python touch_device）。
func (s *Store) TouchDevice(ctx context.Context, deviceID string, at int64) error {
	if at == 0 {
		at = NowMS()
	}
	return s.writeTx(ctx, func(ctx context.Context, q execQuerier) error {
		if _, err := q.ExecContext(ctx,
			"UPDATE devices SET lastSeenAt=? WHERE deviceId=?", at, deviceID); err != nil {
			return fmt.Errorf("store: 记设备在线: %w", err)
		}
		return nil
	})
}

func boolInt(value bool) int {
	if value {
		return 1
	}
	return 0
}
