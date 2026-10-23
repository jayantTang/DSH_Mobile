package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
)

// MintPairCode 铸一枚配对码（Python mint_pair_code）。
//
// ttlMS == nil 表示**持久码**（不过期，直到用户重新生成）；非 nil 时按该时长过期。
func (s *Store) MintPairCode(ctx context.Context, agentID string, ttlMS *int64) (MintedPairCode, error) {
	code := newPairCode()
	created := NowMS()
	var minted MintedPairCode

	err := s.writeTx(ctx, func(ctx context.Context, q execQuerier) error {
		agent, err := agentForPairing(ctx, q, agentID)
		if err != nil {
			return err
		}
		var expiresAt *int64
		if ttlMS != nil {
			value := created + *ttlMS
			expiresAt = &value
		}
		if _, err := q.ExecContext(ctx,
			"INSERT INTO pairCodes(codeHash, agentId, accountId, createdAt, expiresAt)"+
				" VALUES(?,?,?,?,?)",
			hashPairCode(code), agent.AgentID, agent.AccountID, created,
			nullInt64Value(expiresAt)); err != nil {
			return fmt.Errorf("store: 铸配对码: %w", err)
		}
		minted = MintedPairCode{Code: code, ExpiresAt: expiresAt, AgentID: agent.AgentID,
			TTLMs: ttlMS, Persistent: ttlMS == nil}
		return nil
	})
	if err != nil {
		return MintedPairCode{}, err
	}
	return minted, nil
}

// RegeneratePairCode 作废该 agent 现存的所有码，再铸一枚新的（Python regenerate_pair_code）。
//
// 只作废码、不碰 devices：已在用的手机/浏览器靠各自的 deviceToken 活着。
// 作废与新铸在同一个事务里，不会出现"旧的已死、新的没铸出来"。
func (s *Store) RegeneratePairCode(ctx context.Context, agentID string,
	ttlMS *int64) (MintedPairCode, int64, error) {
	code := newPairCode()
	stamp := NowMS()
	var minted MintedPairCode
	var revoked int64

	err := s.writeTx(ctx, func(ctx context.Context, q execQuerier) error {
		agent, err := agentForPairing(ctx, q, agentID)
		if err != nil {
			return err
		}
		result, err := q.ExecContext(ctx,
			"UPDATE pairCodes SET revokedAt=? WHERE agentId=? AND revokedAt IS NULL",
			stamp, agentID)
		if err != nil {
			return fmt.Errorf("store: 作废旧配对码: %w", err)
		}
		if revoked, err = result.RowsAffected(); err != nil {
			return fmt.Errorf("store: 作废旧配对码: %w", err)
		}

		var expiresAt *int64
		if ttlMS != nil {
			value := stamp + *ttlMS
			expiresAt = &value
		}
		if _, err := q.ExecContext(ctx,
			"INSERT INTO pairCodes(codeHash, agentId, accountId, createdAt, expiresAt)"+
				" VALUES(?,?,?,?,?)",
			hashPairCode(code), agent.AgentID, agent.AccountID, stamp,
			nullInt64Value(expiresAt)); err != nil {
			return fmt.Errorf("store: 铸新配对码: %w", err)
		}
		minted = MintedPairCode{Code: code, ExpiresAt: expiresAt, AgentID: agent.AgentID,
			TTLMs: ttlMS, Persistent: ttlMS == nil}
		return nil
	})
	if err != nil {
		return MintedPairCode{}, 0, err
	}
	return minted, revoked, nil
}

// agentForPairing 读一台可铸码的电脑：不存在是 NotFound，已停用是 Conflict。
func agentForPairing(ctx context.Context, q execQuerier, agentID string) (Agent, error) {
	row := q.QueryRowContext(ctx, "SELECT "+agentColumns+" FROM agents WHERE agentId=?", agentID)
	agent, err := scanAgent(row)
	if errors.Is(err, sql.ErrNoRows) {
		return Agent{}, newNotFound("agent %s does not exist", agentID)
	}
	if err != nil {
		return Agent{}, fmt.Errorf("store: 读 agent %s: %w", agentID, err)
	}
	if agent.Disabled != 0 {
		return Agent{}, newConflict("agent %s is disabled", agentID)
	}
	return agent, nil
}

// ClaimParams 是认领配对码的全部输入（Python claim_pair_code 的具名参数）。
type ClaimParams struct {
	DeviceName       string
	Model            *string
	AppVersion       *string
	TTLMS            int64
	DeviceKey        string
	MaxPairedDevices int
}

// ClaimPairCode 兑换配对码并签发长期设备令牌（Python claim_pair_code）。
//
// 持久码可以反复认领：门槛是"未撤销且未过期"。带 deviceKey 且命中一台未撤销设备时
// 复用它的 deviceId、只换发 token，不占新名额；否则按账户统计未撤销设备数，达到
// 上限就拒绝（PairedDeviceLimitReached），不铸令牌。
//
// 整段在一个写事务里：码校验、限额判定、令牌签发、审计字段更新要么全生效、
// 要么全不生效——两台手机同时认领也不会各铸一枚却只留一个。
func (s *Store) ClaimPairCode(ctx context.Context, code string, params ClaimParams) (ClaimResult, error) {
	normalized := normalizePairCode(code)
	if normalized == "" {
		return ClaimResult{}, newNotFound("empty pairing code")
	}
	stamp := NowMS()
	var claimed ClaimResult

	err := s.writeTx(ctx, func(ctx context.Context, q execQuerier) error {
		rows, err := q.QueryContext(ctx,
			"SELECT "+pairCodeColumns+" FROM pairCodes WHERE revokedAt IS NULL"+
				" AND (expiresAt IS NULL OR expiresAt > ?) ORDER BY createdAt DESC LIMIT ?",
			stamp, pairClaimScanLimit)
		if err != nil {
			return fmt.Errorf("store: 查有效配对码: %w", err)
		}
		var match *PairCode
		for rows.Next() {
			candidate, err := scanPairCode(rows)
			if err != nil {
				rows.Close()
				return fmt.Errorf("store: 读配对码行: %w", err)
			}
			if verifyPairCode(normalized, candidate.CodeHash) {
				match = &candidate
				break
			}
		}
		if err := rows.Err(); err != nil {
			rows.Close()
			return fmt.Errorf("store: 读配对码行: %w", err)
		}
		rows.Close()
		if match == nil {
			return pairCodeRejection(ctx, q, normalized, stamp)
		}

		agentRow := q.QueryRowContext(ctx, "SELECT "+agentColumns+
			" FROM agents WHERE agentId=?", match.AgentID)
		agent, err := scanAgent(agentRow)
		if errors.Is(err, sql.ErrNoRows) {
			return newNotFound("the agent for this pairing code is unavailable")
		}
		if err != nil {
			return fmt.Errorf("store: 读配对码的 agent: %w", err)
		}
		if agent.Disabled != 0 {
			return newNotFound("the agent for this pairing code is unavailable")
		}

		var reused *Device
		if params.DeviceKey != "" {
			row := q.QueryRowContext(ctx, "SELECT "+deviceColumns+
				" FROM devices WHERE accountId=? AND deviceKey=? AND revokedAt IS NULL"+
				" ORDER BY createdAt DESC LIMIT 1", agent.AccountID, params.DeviceKey)
			existing, err := scanDevice(row)
			switch {
			case err == nil:
				reused = &existing
			case errors.Is(err, sql.ErrNoRows):
			default:
				return fmt.Errorf("store: 按 deviceKey 查设备: %w", err)
			}
		}

		if reused == nil {
			var live int
			if err := q.QueryRowContext(ctx,
				"SELECT COUNT(*) FROM devices WHERE accountId=? AND revokedAt IS NULL",
				agent.AccountID).Scan(&live); err != nil {
				return fmt.Errorf("store: 统计已配对设备: %w", err)
			}
			if params.MaxPairedDevices > 0 && live >= params.MaxPairedDevices {
				return &PairedDeviceLimitReached{
					Limit: params.MaxPairedDevices, Live: live,
					StoreError: StoreError{Message: fmt.Sprintf(
						"this account already has %d paired devices (limit %d)",
						live, params.MaxPairedDevices)},
				}
			}
		}

		token := newToken("dt")
		expires := stamp + params.TTLMS
		deviceID := ""
		if reused != nil {
			deviceID = reused.DeviceID
			name := params.DeviceName
			if name == "" {
				name = reused.Name
			}
			model := params.Model
			if model == nil || *model == "" {
				model = reused.Model
			}
			appVersion := params.AppVersion
			if appVersion == nil || *appVersion == "" {
				appVersion = reused.AppVersion
			}
			if _, err := q.ExecContext(ctx,
				"UPDATE devices SET deviceTokenHash=?, name=?, model=?, appVersion=?,"+
					" expiresAt=?, lastSeenAt=? WHERE deviceId=?",
				SHA256Hex(token), name, nullStringValue(model), nullStringValue(appVersion),
				expires, stamp, deviceID); err != nil {
				return fmt.Errorf("store: 复用设备换发令牌: %w", err)
			}
		} else {
			deviceID = newID("dev")
			name := params.DeviceName
			if name == "" {
				name = "iOS device"
			}
			var deviceKey any
			if params.DeviceKey != "" {
				deviceKey = params.DeviceKey
			}
			if _, err := q.ExecContext(ctx,
				"INSERT INTO devices(deviceId, deviceTokenHash, agentId, accountId, name, model,"+
					" appVersion, createdAt, expiresAt, deviceKey) VALUES(?,?,?,?,?,?,?,?,?,?)",
				deviceID, SHA256Hex(token), agent.AgentID, agent.AccountID, name,
				nullStringValue(params.Model), nullStringValue(params.AppVersion),
				stamp, expires, deviceKey); err != nil {
				return fmt.Errorf("store: 建设备: %w", err)
			}
		}

		if _, err := q.ExecContext(ctx,
			"UPDATE pairCodes SET useCount=useCount+1, lastUsedAt=?,"+
				" usedAt=COALESCE(usedAt, ?), deviceId=COALESCE(deviceId, ?) WHERE codeHash=?",
			stamp, stamp, deviceID, match.CodeHash); err != nil {
			return fmt.Errorf("store: 记配对码使用: %w", err)
		}

		claimed = ClaimResult{
			AgentID: agent.AgentID, AgentName: agent.Name, AccountID: agent.AccountID,
			DeviceID: deviceID, DeviceToken: token, ExpiresAt: expires,
			Reused: reused != nil,
		}
		return nil
	})
	if err != nil {
		return ClaimResult{}, err
	}
	return claimed, nil
}

// pairCodeRejection 说明一枚没匹配到有效码的提交命中了什么：已作废、已过期、还是从没铸过。
//
// 只从失败路径调用，且候选集**故意排除仍然有效的行**——那些刚才已经验证过且不匹配，
// 这里命中只可能是作废或过期，结论不会与刚才的判定矛盾。时间窗与行数双重设界：
// 每行一次 scrypt 很贵，拒绝路径不能变成全表扫描。
func pairCodeRejection(ctx context.Context, q execQuerier, normalized string,
	stamp int64) error {
	rows, err := q.QueryContext(ctx,
		"SELECT "+pairCodeColumns+" FROM pairCodes WHERE createdAt > ?"+
			" AND (revokedAt IS NOT NULL OR (expiresAt IS NOT NULL AND expiresAt <= ?))"+
			" ORDER BY createdAt DESC LIMIT ?",
		stamp-pairRejectLookbackMS, stamp, pairRejectLimit)
	if err != nil {
		return fmt.Errorf("store: 查被拒配对码: %w", err)
	}
	defer rows.Close()

	for rows.Next() {
		candidate, err := scanPairCode(rows)
		if err != nil {
			return fmt.Errorf("store: 读被拒配对码行: %w", err)
		}
		if !verifyPairCode(normalized, candidate.CodeHash) {
			continue
		}
		if candidate.RevokedAt != nil {
			return &PairCodeClaimRejected{
				Reason: "revoked",
				Details: map[string]any{
					"agentId": candidate.AgentID, "createdAt": candidate.CreatedAt,
					"revokedAt": *candidate.RevokedAt,
				},
				StoreError: StoreError{Message: "that pairing code was replaced by a newer one"},
			}
		}
		details := map[string]any{"agentId": candidate.AgentID, "createdAt": candidate.CreatedAt}
		if candidate.ExpiresAt != nil {
			details["expiresAt"] = *candidate.ExpiresAt
		}
		return &PairCodeClaimRejected{
			Reason:     "expired",
			Details:    details,
			StoreError: StoreError{Message: "that pairing code has expired"},
		}
	}
	if err := rows.Err(); err != nil {
		return fmt.Errorf("store: 读被拒配对码行: %w", err)
	}
	return &PairCodeClaimRejected{
		Reason:     "unknown",
		StoreError: StoreError{Message: "that pairing code is not valid"},
	}
}

// PurgeExpired 删掉过期码，以及早于拒绝回查窗口的作废码（Python purge_expired）。
//
// 作废码本身不会过期（持久码 expiresAt 为 NULL），留到窗口外再删：窗口内还要靠它把
// "码被重新生成"与"打错字"分开。
func (s *Store) PurgeExpired(ctx context.Context, at int64) (int64, error) {
	if at == 0 {
		at = NowMS()
	}
	var deleted int64
	err := s.writeTx(ctx, func(ctx context.Context, q execQuerier) error {
		result, err := q.ExecContext(ctx,
			"DELETE FROM pairCodes WHERE (expiresAt IS NOT NULL AND expiresAt < ?)"+
				" OR (revokedAt IS NOT NULL AND revokedAt < ?)",
			at, at-pairRejectLookbackMS)
		if err != nil {
			return fmt.Errorf("store: 清理配对码: %w", err)
		}
		deleted, err = result.RowsAffected()
		if err != nil {
			return fmt.Errorf("store: 清理配对码: %w", err)
		}
		return nil
	})
	return deleted, err
}
