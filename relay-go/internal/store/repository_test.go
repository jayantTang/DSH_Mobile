package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"path/filepath"
	"strings"
	"testing"
)

// newRepoStore 建一个临时库，测试结束自动关闭。
func newRepoStore(t *testing.T) *Store {
	t.Helper()
	s, err := Open(filepath.Join(t.TempDir(), "state.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() {
		if err := s.Close(); err != nil {
			t.Errorf("Close: %v", err)
		}
	})
	return s
}

// seedTenant 建一个账户与它的一台电脑，返回账户、电脑与明文 secret。
func seedTenant(t *testing.T, s *Store) (Account, Agent, string) {
	t.Helper()
	ctx := context.Background()
	account, err := s.CreateAccount(ctx, "测试账户")
	if err != nil {
		t.Fatalf("CreateAccount: %v", err)
	}
	agent, secret, err := s.RegisterAgent(ctx, account.AccountID, "测试电脑", nil)
	if err != nil {
		t.Fatalf("RegisterAgent: %v", err)
	}
	return account, agent, secret
}

// fakeLimiter 是 FailureLimiter 的可控实现：计数与冻结都由测试摆布。
type fakeLimiter struct {
	blocked map[string]bool
	counts  map[string]int
	total   int
}

func newFakeLimiter() *fakeLimiter {
	return &fakeLimiter{blocked: map[string]bool{}, counts: map[string]int{}}
}

func (f *fakeLimiter) Blocked(key string) bool { return f.blocked[key] }

func (f *fakeLimiter) CountFailure(key string, total bool) {
	f.counts[key]++
	if total {
		f.total++
	}
}

func TestPairCodeClaimReuseAndAudit(t *testing.T) {
	s := newRepoStore(t)
	ctx := context.Background()
	_, agent, _ := seedTenant(t, s)

	minted, err := s.MintPairCode(ctx, agent.AgentID, nil)
	if err != nil {
		t.Fatalf("MintPairCode: %v", err)
	}
	if !minted.Persistent || minted.ExpiresAt != nil || minted.TTLMs != nil {
		t.Fatalf("持久码字段 = %+v", minted)
	}
	if len(minted.Code) != 9 || minted.Code[4] != '-' {
		t.Fatalf("配对码格式 = %q, 期望 XXXX-XXXX", minted.Code)
	}

	first, err := s.ClaimPairCode(ctx, minted.Code, ClaimParams{
		DeviceName: "手机一", TTLMS: DefaultDeviceTTLMS, DeviceKey: "device-key-0001",
		MaxPairedDevices: 8,
	})
	if err != nil {
		t.Fatalf("首次认领: %v", err)
	}
	if first.Reused || first.DeviceID == "" || !strings.HasPrefix(first.DeviceToken, "dt_") {
		t.Fatalf("首次认领结果 = %+v", first)
	}
	if first.ExpiresAt <= NowMS() {
		t.Fatalf("设备过期时间 = %d", first.ExpiresAt)
	}

	// 带同一个 deviceKey 回来：复用 deviceId、只换发 token，不占新名额。
	second, err := s.ClaimPairCode(ctx, minted.Code, ClaimParams{
		DeviceName: "手机一重装", TTLMS: DefaultDeviceTTLMS, DeviceKey: "device-key-0001",
		MaxPairedDevices: 8,
	})
	if err != nil {
		t.Fatalf("复用认领: %v", err)
	}
	if !second.Reused || second.DeviceID != first.DeviceID {
		t.Fatalf("复用结果 = %+v，首次 = %+v", second, first)
	}
	if second.DeviceToken == first.DeviceToken {
		t.Fatal("复用认领没有换发新令牌")
	}

	// 不带 deviceKey 再认领一次：新增一台设备。
	third, err := s.ClaimPairCode(ctx, minted.Code, ClaimParams{
		DeviceName: "手机二", TTLMS: DefaultDeviceTTLMS, MaxPairedDevices: 8,
	})
	if err != nil {
		t.Fatalf("第二次认领: %v", err)
	}
	if third.Reused || third.DeviceID == first.DeviceID {
		t.Fatalf("新设备认领结果 = %+v", third)
	}

	if count, err := s.CountPairedDevices(ctx, agent.AccountID); err != nil || count != 2 {
		t.Fatalf("已配对设备数 = %d, %v, 期望 2", count, err)
	}

	// 没带 deviceKey 的新设备，库里的 deviceKey 必须是 NULL（Python 存的是 None）。
	var storedKey sql.NullString
	if err := s.db.QueryRowContext(ctx,
		"SELECT deviceKey FROM devices WHERE deviceId=?", third.DeviceID).
		Scan(&storedKey); err != nil {
		t.Fatalf("读 deviceKey: %v", err)
	}
	if storedKey.Valid {
		t.Fatalf("无 deviceKey 的设备存成了 %q，期望 NULL", storedKey.String)
	}

	// 审计字段只写一次（usedAt/deviceId 用 COALESCE），使用次数累加。
	var useCount int
	var usedAt, lastUsedAt *int64
	row := s.db.QueryRowContext(ctx,
		"SELECT useCount, usedAt, lastUsedAt FROM pairCodes WHERE agentId=?", agent.AgentID)
	var used, last sql.NullInt64
	if err := row.Scan(&useCount, &used, &last); err != nil {
		t.Fatalf("读配对码审计: %v", err)
	}
	usedAt, lastUsedAt = nullInt64(used), nullInt64(last)
	if useCount != 3 || usedAt == nil || lastUsedAt == nil {
		t.Fatalf("审计字段 useCount=%d usedAt=%v lastUsedAt=%v", useCount, usedAt, lastUsedAt)
	}
}

func TestPairCodeRejectionReasons(t *testing.T) {
	s := newRepoStore(t)
	ctx := context.Background()
	_, agent, _ := seedTenant(t, s)

	// 一出生就过期（admin code-mint --ttl-seconds 0 走的就是这条）。
	zero := int64(0)
	expired, err := s.MintPairCode(ctx, agent.AgentID, &zero)
	if err != nil {
		t.Fatalf("铸过期码: %v", err)
	}
	_, err = s.ClaimPairCode(ctx, expired.Code, ClaimParams{TTLMS: DefaultDeviceTTLMS})
	var rejection *PairCodeClaimRejected
	if !errors.As(err, &rejection) || rejection.Reason != "expired" {
		t.Fatalf("过期码认领错误 = %v", err)
	}

	// 用户点「重新生成」后旧码作废。
	ttl := int64(600_000)
	oldCode, err := s.MintPairCode(ctx, agent.AgentID, &ttl)
	if err != nil {
		t.Fatalf("铸限时码: %v", err)
	}
	if _, revoked, err := s.RegeneratePairCode(ctx, agent.AgentID, nil); err != nil || revoked < 1 {
		t.Fatalf("重新生成 = revoked %d, %v", revoked, err)
	}
	_, err = s.ClaimPairCode(ctx, oldCode.Code, ClaimParams{TTLMS: DefaultDeviceTTLMS})
	if !errors.As(err, &rejection) || rejection.Reason != "revoked" {
		t.Fatalf("作废码认领错误 = %v", err)
	}

	// 从没铸过的码。
	_, err = s.ClaimPairCode(ctx, "ZZZZ-ZZZZ", ClaimParams{TTLMS: DefaultDeviceTTLMS})
	if !errors.As(err, &rejection) || rejection.Reason != "unknown" {
		t.Fatalf("未知码认领错误 = %v", err)
	}
	if rejection.Message != "that pairing code is not valid" {
		t.Fatalf("未知码消息 = %q", rejection.Message)
	}

	// 空码是 NotFound，不是 PairCodeClaimRejected。
	_, err = s.ClaimPairCode(ctx, "  ", ClaimParams{TTLMS: DefaultDeviceTTLMS})
	var notFound *NotFound
	if !errors.As(err, &notFound) {
		t.Fatalf("空码错误 = %v", err)
	}
}

// TestPairCodeScryptMatchesPython 用 Python hashlib.scrypt 生成的哈希做交叉验证。
//
// 夹具：code=ABCD-EFGH，salt=00112233445566778899aabbccddeeff，
// n=1<<14, r=8, p=1, dklen=32。
func TestPairCodeScryptMatchesPython(t *testing.T) {
	const pythonHash = "scrypt$00112233445566778899aabbccddeeff$" +
		"096af9c6d40061747d5e0574af62abb1ce8ecdd105c2bfb7d93ddb0462e60e7c"
	salt := []byte{0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
		0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff}

	if got := HashPairCodeForTest("ABCD-EFGH", salt); got != pythonHash {
		t.Fatalf("Go 生成的哈希与 Python 不一致:\n got %s\nwant %s", got, pythonHash)
	}
	// 认领时大小写与分隔符都被归一化，Python 生成的哈希必须能验过。
	for _, input := range []string{"ABCD-EFGH", "abcd efgh", "  Abcd-Efgh  ", "ABCDEFGH"} {
		if !verifyPairCode(input, pythonHash) {
			t.Fatalf("verifyPairCode(%q) = false", input)
		}
	}
	if verifyPairCode("ABCD-EFGI", pythonHash) {
		t.Fatal("错误的码通过了校验")
	}
	if verifyPairCode("ABCD-EFGH", "scrypt$zz$00") {
		t.Fatal("坏哈希通过了校验")
	}
}

func TestPairCodeDeviceLimit(t *testing.T) {
	s := newRepoStore(t)
	ctx := context.Background()
	_, agent, _ := seedTenant(t, s)

	minted, err := s.MintPairCode(ctx, agent.AgentID, nil)
	if err != nil {
		t.Fatalf("MintPairCode: %v", err)
	}
	first, err := s.ClaimPairCode(ctx, minted.Code, ClaimParams{
		DeviceName: "唯一一台", TTLMS: DefaultDeviceTTLMS, DeviceKey: "device-key-limit",
		MaxPairedDevices: 1,
	})
	if err != nil {
		t.Fatalf("首台认领: %v", err)
	}

	// 到顶后不带 deviceKey 的认领被拒，且不铸令牌。
	_, err = s.ClaimPairCode(ctx, minted.Code, ClaimParams{
		DeviceName: "第二台", TTLMS: DefaultDeviceTTLMS, MaxPairedDevices: 1,
	})
	var limitErr *PairedDeviceLimitReached
	if !errors.As(err, &limitErr) || limitErr.Limit != 1 || limitErr.Live != 1 {
		t.Fatalf("限额错误 = %v", err)
	}
	if count, _ := s.CountPairedDevices(ctx, agent.AccountID); count != 1 {
		t.Fatalf("被拒后设备数 = %d, 期望 1", count)
	}

	// 同一台设备回来换令牌不算新名额。
	again, err := s.ClaimPairCode(ctx, minted.Code, ClaimParams{
		DeviceName: "唯一一台重装", TTLMS: DefaultDeviceTTLMS,
		DeviceKey: "device-key-limit", MaxPairedDevices: 1,
	})
	if err != nil {
		t.Fatalf("满额下复用: %v", err)
	}
	if !again.Reused || again.DeviceID != first.DeviceID {
		t.Fatalf("满额复用结果 = %+v", again)
	}
}

func TestDeviceRefreshRevokeAndHygiene(t *testing.T) {
	s := newRepoStore(t)
	ctx := context.Background()
	_, agent, _ := seedTenant(t, s)

	minted, err := s.MintPairCode(ctx, agent.AgentID, nil)
	if err != nil {
		t.Fatalf("MintPairCode: %v", err)
	}
	claimed, err := s.ClaimPairCode(ctx, minted.Code, ClaimParams{
		DeviceName: "测试手机", Model: stringPtr("iPhone17,1"), AppVersion: stringPtr("9.9.9"),
		TTLMS: DefaultDeviceTTLMS, MaxPairedDevices: 8,
	})
	if err != nil {
		t.Fatalf("认领: %v", err)
	}

	refreshed, err := s.RefreshDevice(ctx, claimed.DeviceToken, DefaultDeviceTTLMS)
	if err != nil {
		t.Fatalf("RefreshDevice: %v", err)
	}
	if refreshed.DeviceToken == claimed.DeviceToken || refreshed.DeviceID != claimed.DeviceID {
		t.Fatalf("刷新结果 = %+v", refreshed)
	}
	if _, found, _ := s.DeviceByToken(ctx, claimed.DeviceToken); found {
		t.Fatal("旧令牌刷新后仍然可用")
	}
	device, found, err := s.DeviceByToken(ctx, refreshed.DeviceToken)
	if err != nil || !found {
		t.Fatalf("新令牌不可用: %v / %v", found, err)
	}
	if device.Model == nil || *device.Model != "iPhone17,1" {
		t.Fatalf("设备机型 = %v", device.Model)
	}

	if err := s.RevokeDevice(ctx, device.DeviceID); err != nil {
		t.Fatalf("RevokeDevice: %v", err)
	}
	if _, found, _ := s.DeviceByToken(ctx, refreshed.DeviceToken); found {
		t.Fatal("撤销后的令牌仍然可用")
	}
	revoked, found, err := s.DeviceByID(ctx, device.DeviceID)
	if err != nil || !found || revoked.RevokedAt == nil {
		t.Fatalf("撤销后设备 = %+v, %v", revoked, err)
	}
	if revoked.APNSToken != nil || revoked.APNSEnv != nil {
		t.Fatal("撤销没有清掉推送登记")
	}
	if err := s.RevokeDevice(ctx, "dev_does-not-exist"); !errors.As(err, new(*NotFound)) {
		t.Fatalf("撤销未知设备错误 = %v", err)
	}

	hygiene, err := s.DeviceHygiene(ctx, agent.AgentID)
	if err != nil {
		t.Fatalf("DeviceHygiene: %v", err)
	}
	if hygiene.Total != 1 || hygiene.Revoked != 1 || hygiene.Live != 0 ||
		hygiene.Expired != 0 || hygiene.Dead != 1 {
		t.Fatalf("设备卫生 = %+v", hygiene)
	}
	listed, err := s.ListDevices(ctx, agent.AgentID, true)
	if err != nil || len(listed) != 1 {
		t.Fatalf("含撤销列表 = %d, %v", len(listed), err)
	}
	active, err := s.ListDevices(ctx, agent.AgentID, false)
	if err != nil || len(active) != 0 {
		t.Fatalf("在用列表 = %d, %v", len(active), err)
	}
}

func stringPtr(value string) *string { return &value }

func TestAccountStateBatchAndMonotonic(t *testing.T) {
	s := newRepoStore(t)
	ctx := context.Background()
	account, _, _ := seedTenant(t, s)
	deviceID := "dev_test-0001"

	result, err := s.PutAccountStateBatch(ctx, account.AccountID, []StateWrite{
		{Key: "alertPrefs", Value: json.RawMessage(`{"turnEnd":false,"attention":true}`),
			UpdatedAt: 1000},
		{Key: "lastSession", Value: json.RawMessage(`"session-1"`), UpdatedAt: 1000},
	}, &deviceID)
	if err != nil {
		t.Fatalf("批量写入: %v", err)
	}
	if strings.Join(result.Applied, ",") != "alertPrefs,lastSession" {
		t.Fatalf("applied = %v", result.Applied)
	}
	if result.Stored["alertPrefs"].UpdatedByDeviceID == nil ||
		*result.Stored["alertPrefs"].UpdatedByDeviceID != deviceID {
		t.Fatalf("写入设备 = %+v", result.Stored["alertPrefs"])
	}
	if result.Stored["alertPrefs"].Key != "alertPrefs" {
		t.Fatalf("写入结果的 key = %q", result.Stored["alertPrefs"].Key)
	}

	state, err := s.AccountState(ctx, account.AccountID, nil)
	if err != nil || len(state) != 2 {
		t.Fatalf("读状态 = %d, %v", len(state), err)
	}
	var prefs map[string]bool
	if err := json.Unmarshal(state["alertPrefs"].Value.(json.RawMessage), &prefs); err != nil {
		t.Fatalf("解析 alertPrefs: %v", err)
	}
	if prefs["turnEnd"] || !prefs["attention"] {
		t.Fatalf("alertPrefs = %+v", prefs)
	}

	// 更旧的时间戳被拒收，返回库里那份；不后退。
	older, err := s.PutAccountState(ctx, account.AccountID,
		StateWrite{Key: "alertPrefs", Value: json.RawMessage(`{"turnEnd":true}`),
			UpdatedAt: 500}, &deviceID)
	if err != nil {
		t.Fatalf("旧时间戳写入: %v", err)
	}
	if older.Applied || older.Stored.UpdatedAt != 1000 {
		t.Fatalf("旧时间戳结果 = %+v", older)
	}

	// 相等按幂等：同样拒收，但返回的是同一份。
	same, err := s.PutAccountState(ctx, account.AccountID,
		StateWrite{Key: "alertPrefs", Value: json.RawMessage(`{"turnEnd":true}`),
			UpdatedAt: 1000}, &deviceID)
	if err != nil || same.Applied {
		t.Fatalf("相等时间戳结果 = %+v, %v", same, err)
	}

	// 更新的时间戳生效。
	newer, err := s.PutAccountState(ctx, account.AccountID,
		StateWrite{Key: "alertPrefs", Value: json.RawMessage(`{"turnEnd":true}`),
			UpdatedAt: 2000}, &deviceID)
	if err != nil || !newer.Applied {
		t.Fatalf("新时间戳结果 = %+v, %v", newer, err)
	}

	// 同一批里同一个 key 按顺序处理：后者时间戳更小而拒收，最终仍是 3000 那份。
	duplicated, err := s.PutAccountStateBatch(ctx, account.AccountID, []StateWrite{
		{Key: "dup", Value: json.RawMessage(`1`), UpdatedAt: 3000},
		{Key: "dup", Value: json.RawMessage(`2`), UpdatedAt: 2500},
	}, &deviceID)
	if err != nil {
		t.Fatalf("重复 key 批量: %v", err)
	}
	if len(duplicated.Applied) != 1 || duplicated.Applied[0] != "dup" {
		t.Fatalf("重复 key applied = %v", duplicated.Applied)
	}
	stored, err := s.AccountState(ctx, account.AccountID, []string{"dup"})
	if err != nil {
		t.Fatalf("读 dup: %v", err)
	}
	if string(stored["dup"].Value.(json.RawMessage)) != "1" {
		t.Fatalf("dup 最终值 = %s, 期望 1", stored["dup"].Value)
	}

	// 过滤只返回请求的 key。
	filtered, err := s.AccountState(ctx, account.AccountID, []string{"lastSession"})
	if err != nil || len(filtered) != 1 {
		t.Fatalf("过滤读取 = %d, %v", len(filtered), err)
	}
}

// TestAccountStateBatchRejectsWholeBatch 钉住"整批先校验"：第二条坏掉时第一条也不写。
//
// Python 版逐条提交，这里会留下半批；DESIGN §6 要求修复，所以整批要么全生效、
// 要么全不生效。
func TestAccountStateBatchRejectsWholeBatch(t *testing.T) {
	s := newRepoStore(t)
	ctx := context.Background()
	account, _, _ := seedTenant(t, s)

	_, err := s.PutAccountStateBatch(ctx, account.AccountID, []StateWrite{
		{Key: "good", Value: json.RawMessage(`1`), UpdatedAt: 1000},
		{Key: "bad", Value: json.RawMessage(`{not json`), UpdatedAt: 1000},
	}, nil)
	if err == nil {
		t.Fatal("坏 JSON 没有报错")
	}
	state, err := s.AccountState(ctx, account.AccountID, nil)
	if err != nil {
		t.Fatalf("读状态: %v", err)
	}
	if len(state) != 0 {
		t.Fatalf("坏批留下了 %d 条状态: %v", len(state), state)
	}
}

// TestWriteTxRollsBackOnError 证明写事务的原子性底座：fn 返回错误时已写入的行被回滚。
func TestWriteTxRollsBackOnError(t *testing.T) {
	s := newRepoStore(t)
	ctx := context.Background()
	boom := errors.New("boom")

	err := s.writeTx(ctx, func(ctx context.Context, q execQuerier) error {
		if _, err := q.ExecContext(ctx,
			"INSERT INTO accounts(accountId, name, createdAt) VALUES(?,?,?)",
			"acc_rollback", "回滚测试", NowMS()); err != nil {
			return err
		}
		return boom
	})
	if !errors.Is(err, boom) {
		t.Fatalf("writeTx 错误 = %v", err)
	}
	var count int
	if err := s.db.QueryRowContext(ctx,
		"SELECT COUNT(*) FROM accounts WHERE accountId='acc_rollback'").Scan(&count); err != nil {
		t.Fatalf("读回滚结果: %v", err)
	}
	if count != 0 {
		t.Fatalf("回滚后仍有 %d 行", count)
	}
}

func TestInviteClaimChargesFailuresAndRejectsReuse(t *testing.T) {
	s := newRepoStore(t)
	ctx := context.Background()
	limiter := newFakeLimiter()

	invite, err := s.MintInvite(ctx, DefaultInviteTTLMS, stringPtr("给测试"), "TEST-INVT-CODE-0001")
	if err != nil {
		t.Fatalf("MintInvite: %v", err)
	}
	if invite.Code != "TEST-INVT-CODE-0001" || invite.Note == nil || *invite.Note != "给测试" {
		t.Fatalf("邀请码 = %+v", invite)
	}

	// 大小写与分隔符不影响兑换。
	identity, err := s.ClaimInvite(ctx, "test invt code 0001", "Late Mac", limiter,
		"code-key", "client-key")
	if err != nil {
		t.Fatalf("兑换邀请码: %v", err)
	}
	if identity.AccountID == "" || identity.AgentID == "" || !strings.HasPrefix(identity.AgentSecret, "as_") {
		t.Fatalf("兑换身份 = %+v", identity)
	}
	if identity.AgentName != "Late Mac" {
		t.Fatalf("电脑名 = %q", identity.AgentName)
	}
	if _, found, _ := s.AgentBySecret(ctx, identity.AgentSecret); !found {
		t.Fatal("兑换返回的 secret 不能用")
	}

	// 再兑换同一枚码：已用过。
	_, err = s.ClaimInvite(ctx, invite.Code, "Second", limiter, "code-key", "client-key")
	var rejected *InviteRejected
	if !errors.As(err, &rejected) || rejected.Reason != "used" {
		t.Fatalf("重复兑换错误 = %v", err)
	}
	if limiter.counts["code-key"] != 1 || limiter.total != 1 {
		t.Fatalf("失败计数 = %+v total=%d", limiter.counts, limiter.total)
	}
	// 来源桶只记账，不进全局总数。
	if limiter.counts["client-key"] != 1 {
		t.Fatalf("来源桶计数 = %d", limiter.counts["client-key"])
	}

	// 过期码。
	zero, err := s.MintInvite(ctx, 0, nil, "TEST-INVT-CODE-0002")
	if err != nil {
		t.Fatalf("铸过期邀请码: %v", err)
	}
	_, err = s.ClaimInvite(ctx, zero.Code, "Expired", limiter, "code-key", "")
	if !errors.As(err, &rejected) || rejected.Reason != "expired" {
		t.Fatalf("过期兑换错误 = %v", err)
	}

	// 桶被冻结后直接拒绝，连行都不读、不再收费。
	before := limiter.total
	limiter.blocked["frozen-key"] = true
	_, err = s.ClaimInvite(ctx, "WHATE-VER", "Frozen", limiter, "frozen-key", "")
	var limited *RateLimited
	if !errors.As(err, &limited) {
		t.Fatalf("冻结桶错误 = %v", err)
	}
	if limiter.total != before {
		t.Fatalf("冻结桶仍然收费: %d -> %d", before, limiter.total)
	}
}

func TestTokensAreStoredHashed(t *testing.T) {
	s := newRepoStore(t)
	ctx := context.Background()
	_, agent, secret := seedTenant(t, s)

	// 电脑 secret 只存 SHA-256。
	var secretHash string
	if err := s.db.QueryRowContext(ctx,
		"SELECT secretHash FROM agents WHERE agentId=?", agent.AgentID).Scan(&secretHash); err != nil {
		t.Fatalf("读 secretHash: %v", err)
	}
	if secretHash == secret || secretHash != SHA256Hex(secret) {
		t.Fatalf("secretHash 没有按 SHA-256 存储: %q", secretHash)
	}

	// 设备令牌只存 SHA-256。
	minted, err := s.MintPairCode(ctx, agent.AgentID, nil)
	if err != nil {
		t.Fatalf("MintPairCode: %v", err)
	}
	claimed, err := s.ClaimPairCode(ctx, minted.Code, ClaimParams{
		DeviceName: "哈希测试", TTLMS: DefaultDeviceTTLMS, MaxPairedDevices: 8,
	})
	if err != nil {
		t.Fatalf("认领: %v", err)
	}
	var tokenHash string
	if err := s.db.QueryRowContext(ctx,
		"SELECT deviceTokenHash FROM devices WHERE deviceId=?",
		claimed.DeviceID).Scan(&tokenHash); err != nil {
		t.Fatalf("读 deviceTokenHash: %v", err)
	}
	if tokenHash == claimed.DeviceToken || tokenHash != SHA256Hex(claimed.DeviceToken) {
		t.Fatalf("deviceTokenHash 没有按 SHA-256 存储: %q", tokenHash)
	}

	// 邀请码只存规范化后的 SHA-256。
	invite, err := s.MintInvite(ctx, DefaultInviteTTLMS, nil, "HASH-INVT-CODE-0001")
	if err != nil {
		t.Fatalf("MintInvite: %v", err)
	}
	var codeHash string
	if err := s.db.QueryRowContext(ctx,
		"SELECT codeHash FROM invites WHERE codeHash=?", HashInviteCode(invite.Code)).
		Scan(&codeHash); err != nil {
		t.Fatalf("读 codeHash: %v", err)
	}
	if codeHash == invite.Code || codeHash != SHA256Hex(NormalizePairCode(invite.Code)) {
		t.Fatalf("邀请码哈希 = %q", codeHash)
	}
}
