package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
)

// FailureLimiter 是兑换邀请码时的失败预算。
//
// 由调用方注入而不是在这里实现，是为了让"查预算 / 记失败"与"读那一行"发生在
// 同一个写锁里：否则并发的猜测会全部通过调用方的前置检查，再一起记失败。
type FailureLimiter interface {
	// Blocked 报告该桶是否已用尽；查询本身不收费。
	Blocked(key string) bool
	// CountFailure 记一次失败；total=false 只记账、不进全局计数。
	CountFailure(key string, total bool)
}

// MintInvite 铸一枚邀请码（Python mint_invite）。明文只在这里返回一次，库里只存哈希。
//
// code 非空时用它作为明文（测试钉住已知值用）；生产路径传空串自动生成。
func (s *Store) MintInvite(ctx context.Context, ttlMS int64, note *string, code string) (MintedInvite, error) {
	plaintext := code
	if plaintext == "" {
		plaintext = newInviteCode()
	}
	created := NowMS()
	minted := MintedInvite{
		Code:      plaintext,
		ExpiresAt: created + ttlMS,
		TTLMs:     ttlMS,
		Note:      note,
	}
	err := s.writeTx(ctx, func(ctx context.Context, q execQuerier) error {
		_, err := q.ExecContext(ctx,
			"INSERT INTO invites(codeHash, createdAt, expiresAt, note) VALUES(?,?,?,?)",
			HashInviteCode(plaintext), created, minted.ExpiresAt, nullStringValue(note))
		if err != nil {
			return fmt.Errorf("store: 铸邀请码: %w", err)
		}
		return nil
	})
	if err != nil {
		return MintedInvite{}, err
	}
	return minted, nil
}

// InviteStatus 查看邀请码状态而不消费它（Python invite_status）。
func (s *Store) InviteStatus(ctx context.Context, code string) (InviteStatus, error) {
	row := s.db.QueryRowContext(ctx, "SELECT "+inviteColumns+" FROM invites WHERE codeHash=?",
		HashInviteCode(code))
	invite, err := scanInvite(row)
	if errors.Is(err, sql.ErrNoRows) {
		return InviteStatus{Exists: false}, nil
	}
	if err != nil {
		return InviteStatus{}, fmt.Errorf("store: 读邀请码状态: %w", err)
	}
	if invite.UsedAt != nil {
		return InviteStatus{Exists: true, State: "used", UsedAt: invite.UsedAt,
			UsedByAgentID: invite.UsedByAgentID}, nil
	}
	expires := invite.ExpiresAt
	if expires <= NowMS() {
		return InviteStatus{Exists: true, State: "expired", ExpiresAt: &expires}, nil
	}
	return InviteStatus{Exists: true, State: "unused", ExpiresAt: &expires}, nil
}

// ClaimInvite 兑换一枚邀请码：建账户与它的第一台电脑（Python claim_invite）。
//
// 一个事务：邀请码不可能被标成已用而身份没建出来；两台机器同时兑换同一枚码时
// 只有一个赢家。limiter 在这里被收费，位置就在读行之后、写锁之内。
func (s *Store) ClaimInvite(ctx context.Context, code, name string,
	limiter FailureLimiter, countKey, clientKey string) (EnrolledIdentity, error) {
	normalized := normalizeInviteCode(code)
	stamp := NowMS()
	var enrolled EnrolledIdentity

	err := s.writeTx(ctx, func(ctx context.Context, q execQuerier) error {
		// 先查预算：桶已满时既不读行也不再收费，返回"被限流"而不是"码错了"。
		if limiter != nil && countKey != "" && limiter.Blocked(countKey) {
			return &RateLimited{StoreError{Message: "too many failed attempts for that invite code"}}
		}

		var invite Invite
		reason := ""
		if normalized != "" {
			row := q.QueryRowContext(ctx, "SELECT "+inviteColumns+" FROM invites WHERE codeHash=?",
				HashInviteCode(normalized))
			found, err := scanInvite(row)
			if err == nil {
				invite = found
			} else if !errors.Is(err, sql.ErrNoRows) {
				return fmt.Errorf("store: 读邀请码: %w", err)
			}
		}

		switch {
		case invite.CodeHash == "":
			reason = "unknown"
		case invite.UsedAt != nil:
			reason = "used"
		case invite.ExpiresAt <= stamp:
			reason = "expired"
		}

		if reason != "" {
			// 一次请求只算一次失败：码桶进全局计数，来源桶只记账。
			if limiter != nil && countKey != "" {
				limiter.CountFailure(countKey, true)
				if clientKey != "" {
					limiter.CountFailure(clientKey, false)
				}
			}
			message := map[string]string{
				"unknown": "that invite code is not valid",
				"used":    "that invite code has already been used",
				"expired": "that invite code has expired",
			}[reason]
			return &InviteRejected{Reason: reason, StoreError: StoreError{Message: message}}
		}

		accountID := newID("acc")
		agentID := newID("agt")
		secret := newToken("as")
		agentName := trimOr(name, "My computer")
		if _, err := q.ExecContext(ctx,
			"INSERT INTO accounts(accountId, name, createdAt) VALUES(?,?,?)",
			accountID, agentName, stamp); err != nil {
			return fmt.Errorf("store: 兑换邀请码建账户: %w", err)
		}
		if _, err := q.ExecContext(ctx,
			"INSERT INTO agents(agentId, accountId, name, secretHash, createdAt, updatedAt)"+
				" VALUES(?,?,?,?,?,?)",
			agentID, accountID, agentName, SHA256Hex(secret), stamp, stamp); err != nil {
			return fmt.Errorf("store: 兑换邀请码建 agent: %w", err)
		}
		if _, err := q.ExecContext(ctx,
			"UPDATE invites SET usedAt=?, usedByAgentId=? WHERE codeHash=?",
			stamp, agentID, invite.CodeHash); err != nil {
			return fmt.Errorf("store: 标记邀请码已用: %w", err)
		}

		enrolled = EnrolledIdentity{
			AccountID: accountID, AgentID: agentID, AgentName: agentName,
			AgentSecret: secret, InviteNote: invite.Note,
		}
		return nil
	})
	if err != nil {
		return EnrolledIdentity{}, err
	}
	return enrolled, nil
}

// trimOr 去首尾空白，空值回退 fallback。
func trimOr(value, fallback string) string {
	trimmed := strings.TrimSpace(value)
	if trimmed == "" {
		return fallback
	}
	return trimmed
}

// ListInvites 列出邀请码（只有哈希，永远不给明文）。includeUsed=false 时只列未用的。
func (s *Store) ListInvites(ctx context.Context, includeUsed bool) ([]Invite, error) {
	query := "SELECT " + inviteColumns + " FROM invites"
	if !includeUsed {
		query += " WHERE usedAt IS NULL"
	}
	query += " ORDER BY createdAt"

	rows, err := s.db.QueryContext(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("store: 列邀请码: %w", err)
	}
	defer rows.Close()

	invites := []Invite{}
	for rows.Next() {
		invite, err := scanInvite(rows)
		if err != nil {
			return nil, fmt.Errorf("store: 读邀请码行: %w", err)
		}
		invites = append(invites, invite)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: 读邀请码行: %w", err)
	}
	return invites, nil
}

// RevokeInvite 作废一枚邀请码：把有效期改到现在，而不是删行。
//
// 这样被拒的人看到的仍是 "expired"，备注也留着（Python revoke_invite）。
func (s *Store) RevokeInvite(ctx context.Context, code string, at int64) (RevokeInviteResult, error) {
	if at == 0 {
		at = NowMS()
	}
	normalized := normalizeInviteCode(code)
	if normalized == "" {
		return RevokeInviteResult{Revoked: false, Reason: "malformed"}, nil
	}
	codeHash := HashInviteCode(normalized)
	var result RevokeInviteResult

	err := s.writeTx(ctx, func(ctx context.Context, q execQuerier) error {
		row := q.QueryRowContext(ctx, "SELECT "+inviteColumns+" FROM invites WHERE codeHash=?",
			codeHash)
		invite, err := scanInvite(row)
		if errors.Is(err, sql.ErrNoRows) {
			result = RevokeInviteResult{Revoked: false, Reason: "unknown"}
			return nil
		}
		if err != nil {
			return fmt.Errorf("store: 读邀请码 %s: %w", codeHash[:8], err)
		}
		if invite.UsedAt != nil {
			result = RevokeInviteResult{Revoked: false, Reason: "used",
				UsedAt: invite.UsedAt, UsedByAgentID: invite.UsedByAgentID}
			return nil
		}
		if invite.ExpiresAt <= at {
			expires := invite.ExpiresAt
			result = RevokeInviteResult{Revoked: false, Reason: "already-expired",
				ExpiresAt: &expires}
			return nil
		}
		if _, err := q.ExecContext(ctx,
			"UPDATE invites SET expiresAt=? WHERE codeHash=?", at, codeHash); err != nil {
			return fmt.Errorf("store: 作废邀请码: %w", err)
		}
		short := codeHash
		if len(short) > 12 {
			short = short[:12]
		}
		expires := at
		result = RevokeInviteResult{Revoked: true, CodeHash: short, Note: invite.Note,
			ExpiresAt: &expires}
		return nil
	})
	if err != nil {
		return RevokeInviteResult{}, err
	}
	return result, nil
}

// PurgeInvites 删掉已过期或已使用的邀请码（Python purge_invites）。
func (s *Store) PurgeInvites(ctx context.Context, at int64) (int64, error) {
	if at == 0 {
		at = NowMS()
	}
	var deleted int64
	err := s.writeTx(ctx, func(ctx context.Context, q execQuerier) error {
		result, err := q.ExecContext(ctx,
			"DELETE FROM invites WHERE expiresAt < ? OR usedAt IS NOT NULL", at)
		if err != nil {
			return fmt.Errorf("store: 清理邀请码: %w", err)
		}
		deleted, err = result.RowsAffected()
		if err != nil {
			return fmt.Errorf("store: 清理邀请码: %w", err)
		}
		return nil
	})
	return deleted, err
}

// InviteTotals 是码的账：铸了多少、用掉多少、还剩多少（Python invite_totals）。
func (s *Store) InviteTotals(ctx context.Context) (InviteTotals, error) {
	var minted, used, remaining sql.NullInt64
	err := s.db.QueryRowContext(ctx,
		"SELECT COUNT(*), SUM(CASE WHEN usedAt IS NOT NULL THEN 1 ELSE 0 END),"+
			" SUM(CASE WHEN usedAt IS NULL THEN 1 ELSE 0 END) FROM invites").
		Scan(&minted, &used, &remaining)
	if err != nil {
		return InviteTotals{}, fmt.Errorf("store: 统计邀请码: %w", err)
	}
	return InviteTotals{Minted: int(minted.Int64), Used: int(used.Int64),
		Remaining: int(remaining.Int64)}, nil
}

// ListEnrollments 列出每一次成功的登记（Python list_enrollments）。
func (s *Store) ListEnrollments(ctx context.Context) ([]Enrollment, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT i.usedAt AS usedAt,
		       i.note AS inviteNote,
		       a.accountId AS accountId,
		       acc.name AS accountName,
		       a.agentId AS agentId,
		       a.name AS agentName,
		       (SELECT COUNT(*) FROM devices d WHERE d.agentId = a.agentId) AS devices,
		       (SELECT MAX(d.lastSeenAt) FROM devices d WHERE d.agentId = a.agentId) AS lastSeenAt
		FROM invites i
		JOIN agents a ON a.agentId = i.usedByAgentId
		LEFT JOIN accounts acc ON acc.accountId = a.accountId
		WHERE i.usedAt IS NOT NULL
		ORDER BY i.usedAt DESC`)
	if err != nil {
		return nil, fmt.Errorf("store: 列登记记录: %w", err)
	}
	defer rows.Close()

	enrollments := []Enrollment{}
	for rows.Next() {
		var (
			enrollment  Enrollment
			usedAt      sql.NullInt64
			inviteNote  sql.NullString
			accountName sql.NullString
			lastSeenAt  sql.NullInt64
		)
		if err := rows.Scan(&usedAt, &inviteNote, &enrollment.AccountID, &accountName,
			&enrollment.AgentID, &enrollment.AgentName, &enrollment.Devices,
			&lastSeenAt); err != nil {
			return nil, fmt.Errorf("store: 读登记记录: %w", err)
		}
		enrollment.UsedAt = usedAt.Int64
		enrollment.InviteNote = nullString(inviteNote)
		enrollment.AccountName = nullString(accountName)
		enrollment.LastSeenAt = nullInt64(lastSeenAt)
		enrollments = append(enrollments, enrollment)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: 读登记记录: %w", err)
	}
	return enrollments, nil
}
