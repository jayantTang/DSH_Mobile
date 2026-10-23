package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
)

// ===== accounts =====

// CreateAccount 建一个账户（Python create_account）。
func (s *Store) CreateAccount(ctx context.Context, name string) (Account, error) {
	account := Account{AccountID: newID("acc"), Name: name, CreatedAt: NowMS()}
	err := s.writeTx(ctx, func(ctx context.Context, q execQuerier) error {
		_, err := q.ExecContext(ctx,
			"INSERT INTO accounts(accountId, name, createdAt) VALUES(?,?,?)",
			account.AccountID, account.Name, account.CreatedAt)
		if err != nil {
			return fmt.Errorf("store: 建账户: %w", err)
		}
		return nil
	})
	if err != nil {
		return Account{}, err
	}
	return account, nil
}

// GetAccount 读一个账户，不存在返回 (zero, false)。
func (s *Store) GetAccount(ctx context.Context, accountID string) (Account, bool, error) {
	var account Account
	err := s.db.QueryRowContext(ctx,
		"SELECT accountId, name, createdAt FROM accounts WHERE accountId=?",
		accountID).Scan(&account.AccountID, &account.Name, &account.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return Account{}, false, nil
	}
	if err != nil {
		return Account{}, false, fmt.Errorf("store: 读账户 %s: %w", accountID, err)
	}
	return account, true, nil
}

// ListAccounts 按创建时间列出全部账户（Python list_accounts）。
func (s *Store) ListAccounts(ctx context.Context) ([]Account, error) {
	rows, err := s.db.QueryContext(ctx,
		"SELECT accountId, name, createdAt FROM accounts ORDER BY createdAt")
	if err != nil {
		return nil, fmt.Errorf("store: 列账户: %w", err)
	}
	defer rows.Close()

	accounts := []Account{}
	for rows.Next() {
		var account Account
		if err := rows.Scan(&account.AccountID, &account.Name, &account.CreatedAt); err != nil {
			return nil, fmt.Errorf("store: 读账户行: %w", err)
		}
		accounts = append(accounts, account)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: 读账户行: %w", err)
	}
	return accounts, nil
}

// ===== agents =====

// RegisterAgent 建一台新电脑，或在给定 agentID 时轮换它的 secret（Python register_agent）。
//
// 账户不存在、或要轮换的 agent 不存在，都按 NotFound 拒绝；新建与轮换在同一个
// 事务里完成，轮换会把 disabled 清零（与 Python 一致）。
func (s *Store) RegisterAgent(ctx context.Context, accountID, name string,
	agentID *string) (Agent, string, error) {
	secret := newToken("as")
	stamp := NowMS()
	var created Agent

	err := s.writeTx(ctx, func(ctx context.Context, q execQuerier) error {
		var exists int
		err := q.QueryRowContext(ctx, "SELECT 1 FROM accounts WHERE accountId=?", accountID).Scan(&exists)
		if errors.Is(err, sql.ErrNoRows) {
			return newNotFound("account %s does not exist", accountID)
		}
		if err != nil {
			return fmt.Errorf("store: 查账户 %s: %w", accountID, err)
		}

		if agentID == nil || *agentID == "" {
			created = Agent{
				AgentID: newID("agt"), AccountID: accountID, Name: name,
				SecretHash: SHA256Hex(secret), CreatedAt: stamp, UpdatedAt: stamp,
			}
			_, err := q.ExecContext(ctx,
				"INSERT INTO agents(agentId, accountId, name, secretHash, createdAt, updatedAt)"+
					" VALUES(?,?,?,?,?,?)",
				created.AgentID, created.AccountID, created.Name, created.SecretHash,
				created.CreatedAt, created.UpdatedAt)
			if err != nil {
				return fmt.Errorf("store: 建 agent: %w", err)
			}
			return nil
		}

		row := q.QueryRowContext(ctx, "SELECT "+agentColumns+" FROM agents WHERE agentId=?",
			*agentID)
		existing, err := scanAgent(row)
		if errors.Is(err, sql.ErrNoRows) {
			return newNotFound("agent %s does not exist", *agentID)
		}
		if err != nil {
			return fmt.Errorf("store: 读 agent %s: %w", *agentID, err)
		}
		_, err = q.ExecContext(ctx,
			"UPDATE agents SET name=?, secretHash=?, updatedAt=?, disabled=0 WHERE agentId=?",
			name, SHA256Hex(secret), stamp, existing.AgentID)
		if err != nil {
			return fmt.Errorf("store: 轮换 agent %s: %w", existing.AgentID, err)
		}
		created = existing
		created.Name = name
		created.SecretHash = SHA256Hex(secret)
		created.UpdatedAt = stamp
		created.Disabled = 0
		return nil
	})
	if err != nil {
		return Agent{}, "", err
	}
	return created, secret, nil
}

// SetAgentDisabled 启停一台电脑（Python set_agent_disabled）。
func (s *Store) SetAgentDisabled(ctx context.Context, agentID string, disabled bool) error {
	return s.writeTx(ctx, func(ctx context.Context, q execQuerier) error {
		var exists int
		err := q.QueryRowContext(ctx, "SELECT 1 FROM agents WHERE agentId=?", agentID).Scan(&exists)
		if errors.Is(err, sql.ErrNoRows) {
			return newNotFound("agent %s does not exist", agentID)
		}
		if err != nil {
			return fmt.Errorf("store: 查 agent %s: %w", agentID, err)
		}
		flag := 0
		if disabled {
			flag = 1
		}
		if _, err := q.ExecContext(ctx,
			"UPDATE agents SET disabled=?, updatedAt=? WHERE agentId=?",
			flag, NowMS(), agentID); err != nil {
			return fmt.Errorf("store: 启停 agent %s: %w", agentID, err)
		}
		return nil
	})
}

// AgentByID 读一台电脑，不存在返回 (zero, false)。
func (s *Store) AgentByID(ctx context.Context, agentID string) (Agent, bool, error) {
	row := s.db.QueryRowContext(ctx, "SELECT "+agentColumns+" FROM agents WHERE agentId=?",
		agentID)
	agent, err := scanAgent(row)
	if errors.Is(err, sql.ErrNoRows) {
		return Agent{}, false, nil
	}
	if err != nil {
		return Agent{}, false, fmt.Errorf("store: 读 agent %s: %w", agentID, err)
	}
	return agent, true, nil
}

// AgentBySecret 用明文 secret 反查电脑；空令牌、未知哈希、已禁用都返回 (zero, false)。
func (s *Store) AgentBySecret(ctx context.Context, secret string) (Agent, bool, error) {
	if secret == "" {
		return Agent{}, false, nil
	}
	row := s.db.QueryRowContext(ctx, "SELECT "+agentColumns+" FROM agents WHERE secretHash=?",
		SHA256Hex(secret))
	agent, err := scanAgent(row)
	if errors.Is(err, sql.ErrNoRows) {
		return Agent{}, false, nil
	}
	if err != nil {
		return Agent{}, false, fmt.Errorf("store: 用 secret 读 agent: %w", err)
	}
	if agent.Disabled != 0 {
		return Agent{}, false, nil
	}
	return agent, true, nil
}

// ListAgents 列出全部电脑，或只列一个账户下的（Python list_agents）。
func (s *Store) ListAgents(ctx context.Context, accountID string) ([]Agent, error) {
	query := "SELECT " + agentColumns + " FROM agents"
	args := []any{}
	if accountID != "" {
		query += " WHERE accountId=?"
		args = append(args, accountID)
	}
	query += " ORDER BY createdAt"

	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("store: 列 agent: %w", err)
	}
	defer rows.Close()

	agents := []Agent{}
	for rows.Next() {
		agent, err := scanAgent(rows)
		if err != nil {
			return nil, fmt.Errorf("store: 读 agent 行: %w", err)
		}
		agents = append(agents, agent)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("store: 读 agent 行: %w", err)
	}
	return agents, nil
}

// TouchAgent 记一次在线时间（Python touch_agent）。
func (s *Store) TouchAgent(ctx context.Context, agentID string, at int64) error {
	if at == 0 {
		at = NowMS()
	}
	return s.writeTx(ctx, func(ctx context.Context, q execQuerier) error {
		if _, err := q.ExecContext(ctx,
			"UPDATE agents SET lastSeenAt=? WHERE agentId=?", at, agentID); err != nil {
			return fmt.Errorf("store: 记 agent 在线: %w", err)
		}
		return nil
	})
}

// SetAgentVersions 记连接器与 DSH 的版本（值变了才调用；nil = 上报方没给这一项）。
func (s *Store) SetAgentVersions(ctx context.Context, agentID string,
	connectorVersion, hostVersion *string, at int64) error {
	if at == 0 {
		at = NowMS()
	}
	return s.writeTx(ctx, func(ctx context.Context, q execQuerier) error {
		if _, err := q.ExecContext(ctx,
			"UPDATE agents SET connectorVersion=?, hostVersion=?, versionsAt=? WHERE agentId=?",
			nullStringValue(connectorVersion), nullStringValue(hostVersion), at, agentID); err != nil {
			return fmt.Errorf("store: 记 agent 版本: %w", err)
		}
		return nil
	})
}

// nullStringValue 把 *string 转成可绑定的值：nil 写 NULL。
func nullStringValue(value *string) any {
	if value == nil {
		return nil
	}
	return *value
}

// nullInt64Value 把 *int64 转成可绑定的值：nil 写 NULL。
func nullInt64Value(value *int64) any {
	if value == nil {
		return nil
	}
	return *value
}
