package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

// StateWrite 是一条待写的账户状态。
type StateWrite struct {
	Key       string
	Value     json.RawMessage
	UpdatedAt int64
}

// CountPairedDevices 是该账户未撤销的 client 台数（配对上限就是比它）。
func (s *Store) CountPairedDevices(ctx context.Context, accountID string) (int, error) {
	var count int
	if err := s.db.QueryRowContext(ctx,
		"SELECT COUNT(*) FROM devices WHERE accountId=? AND revokedAt IS NULL",
		accountID).Scan(&count); err != nil {
		return 0, fmt.Errorf("store: 统计已配对设备: %w", err)
	}
	return count, nil
}

// AccountState 读一个账户的状态条目；keys 为空读全部（Python account_state）。
//
// 值解析不出来（手工写坏、旧版本格式）时按字符串原样返回，不抛错：一条坏状态
// 不该让整次读取失败，其他设备还要靠它对齐。
func (s *Store) AccountState(ctx context.Context, accountID string, keys []string) (map[string]StateValue, error) {
	query := "SELECT accountId, key, value, updatedAt, updatedByDeviceId FROM accountState" +
		" WHERE accountId=?"
	args := []any{accountID}
	if len(keys) > 0 {
		marks := strings.TrimSuffix(strings.Repeat("?,", len(keys)), ",")
		query += " AND key IN (" + marks + ")"
		for _, key := range keys {
			args = append(args, key)
		}
	}

	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("store: 读账户状态: %w", err)
	}
	defer rows.Close()

	state := map[string]StateValue{}
	for rows.Next() {
		var (
			owner    string
			key      string
			raw      string
			updated  int64
			deviceID sql.NullString
		)
		if err := rows.Scan(&owner, &key, &raw, &updated, &deviceID); err != nil {
			return nil, fmt.Errorf("store: 读账户状态行: %w", err)
		}
		state[key] = StateValue{
			Value:             decodeStateValue(raw),
			UpdatedAt:         updated,
			UpdatedByDeviceID: nullString(deviceID),
		}
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: 读账户状态行: %w", err)
	}
	return state, nil
}

// PutAccountState 写一条账户状态，只前进不后退（Python put_account_state）。
//
// 来件的 updatedAt 不大于已存的就拒收（Applied=false），返回已存的那份；相等按
// 幂等处理。多台设备并发写同一项时，旧的那台晚到一步也盖不回新值。
func (s *Store) PutAccountState(ctx context.Context, accountID string, write StateWrite,
	deviceID *string) (PutStateResult, error) {
	batch, err := s.PutAccountStateBatch(ctx, accountID, []StateWrite{write}, deviceID)
	if err != nil {
		return PutStateResult{}, err
	}
	result := PutStateResult{Key: write.Key, Stored: batch.Stored[write.Key]}
	for _, key := range batch.Applied {
		if key == write.Key {
			result.Applied = true
		}
	}
	return result, nil
}

// PutAccountStateBatch 在一个事务里写一批账户状态（DESIGN §6：64 条要么全生效、
// 要么全不生效，修复 Python 版逐条提交的部分提交缺口）。
//
// 批次内按入参顺序处理，同一 key 出现多次时后者按单调规则覆盖前者（与 Python
// 逐条提交后的最终状态一致）。返回的 Applied 按入参顺序、可含重复 key；Stored 是
// 每个 key 最后一次的结果。
func (s *Store) PutAccountStateBatch(ctx context.Context, accountID string,
	writes []StateWrite, deviceID *string) (BatchPutResult, error) {
	result := BatchPutResult{Applied: []string{}, Stored: map[string]StoredState{}}
	if len(writes) == 0 {
		return result, nil
	}

	// 先校验并压缩全部值再进事务：坏 JSON 不该让另外 63 条生效（Python 在逐条
	// 写入时才序列化，会出现部分提交）。
	serialized := make([]string, len(writes))
	for index, write := range writes {
		value, err := encodeStateValue(write.Value)
		if err != nil {
			return BatchPutResult{}, fmt.Errorf("store: 第 %d 条账户状态: %w", index+1, err)
		}
		serialized[index] = value
	}

	err := s.writeTx(ctx, func(ctx context.Context, q execQuerier) error {
		for index, write := range writes {
			var existingRaw string
			var existingUpdated int64
			var existingDevice sql.NullString
			err := q.QueryRowContext(ctx,
				"SELECT value, updatedAt, updatedByDeviceId FROM accountState"+
					" WHERE accountId=? AND key=?", accountID, write.Key).
				Scan(&existingRaw, &existingUpdated, &existingDevice)
			switch {
			case errors.Is(err, sql.ErrNoRows):
			case err != nil:
				return fmt.Errorf("store: 读账户状态 %s: %w", write.Key, err)
			}

			if err == nil && existingUpdated >= write.UpdatedAt {
				result.Stored[write.Key] = StoredState{
					Key:               write.Key,
					Value:             decodeStateValue(existingRaw),
					UpdatedAt:         existingUpdated,
					UpdatedByDeviceID: nullString(existingDevice),
				}
				continue
			}

			if _, err := q.ExecContext(ctx,
				"INSERT INTO accountState(accountId, key, value, updatedAt, updatedByDeviceId)"+
					" VALUES(?,?,?,?,?)"+
					" ON CONFLICT(accountId, key) DO UPDATE SET"+
					" value=excluded.value, updatedAt=excluded.updatedAt,"+
					" updatedByDeviceId=excluded.updatedByDeviceId",
				accountID, write.Key, serialized[index], write.UpdatedAt,
				nullStringValue(deviceID)); err != nil {
				return fmt.Errorf("store: 写账户状态 %s: %w", write.Key, err)
			}
			result.Applied = append(result.Applied, write.Key)
			result.Stored[write.Key] = StoredState{
				Key:               write.Key,
				Value:             json.RawMessage(serialized[index]),
				UpdatedAt:         write.UpdatedAt,
				UpdatedByDeviceID: deviceID,
			}
		}
		return nil
	})
	if err != nil {
		return BatchPutResult{}, err
	}
	return result, nil
}
