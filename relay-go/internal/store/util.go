package store

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"golang.org/x/crypto/scrypt"
)

// 与 Python 版 store.py 逐字对齐的常量和生成规则。
const (
	// DefaultPairTTLMS 是配对码的默认 TTL（10 分钟）；持久码由调用方传 nil 表达。
	DefaultPairTTLMS int64 = 10 * 60 * 1000
	// DefaultDeviceTTLMS 是设备令牌的有效期（365 天）。
	DefaultDeviceTTLMS int64 = 365 * 24 * 60 * 60 * 1000
	// DefaultInviteTTLMS 是邀请码的有效期（7 天）。
	DefaultInviteTTLMS int64 = 7 * 24 * 60 * 60 * 1000
	// DefaultMaxPairedDevices 是一个账户最多能有多少台未撤销的 client。
	DefaultMaxPairedDevices = 8

	// pairRejectLookbackMS 是"拒绝原因"回查窗口（2 小时），与 Python 一致。
	pairRejectLookbackMS int64 = 2 * 60 * 60 * 1000
	// pairRejectLimit 是一次拒绝回查最多验证多少行（scrypt 很贵，不能扫全表）。
	pairRejectLimit = 50

	// 配对码认领时最多验证多少条有效码（按 createdAt 倒序）。
	pairClaimScanLimit = 200

	// scrypt 参数：与 Python hashlib.scrypt(n=_SCRYPT_N, r=_SCRYPT_R, p=_SCRYPT_P) 一致。
	scryptN       = 1 << 14
	scryptR       = 8
	scryptP       = 1
	scryptKeyLen  = 32
	scryptSaltLen = 16

	// inviteAlphabet 去掉了 0/O/1/I/L：码要在一块屏幕上读、在另一块屏幕上敲。
	inviteAlphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
	inviteGroups   = 4
	inviteGroupLen = 4

	// pairAlphabet 是配对码的字母表（8 位，渲染成 XXXX-XXXX）。
	pairAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
)

// NowMS 是当前的毫秒时间戳（Python 的 store.now_ms）。
func NowMS() int64 { return time.Now().UnixMilli() }

// LocalDay 是服务器本地日的序号，形如 20260921（Python 的 store.local_day）。
//
// 记账与日额度判定都用本地日，两处只走这一个函数。
func LocalDay() int64 { return LocalDayAt(time.Now()) }

// LocalDayAt 是某个时刻的本地日序号。导出给 opsreport：日历序号的编码口径
// （本地时区、YYYYMMDD 整数）只有这一份，报表的 localDayOf 委托到这里。
func LocalDayAt(at time.Time) int64 {
	local := at.In(time.Local)
	return int64(local.Year())*10000 + int64(local.Month())*100 + int64(local.Day())
}

// DayFloor 是 `days` 天前那一天的序号（含今天，所以 days=1 就是今天）。
//
// 与 Python 的 store.day_floor 一致：按本地日、不是按秒数减。跨月跨年由 time 的
// 日历加法负责，不能用整数减（20261003 - 7 不是 20260996）。
func DayFloor(days int) int64 {
	if days < 1 {
		days = 1
	}
	now := time.Now().In(time.Local)
	return LocalDayAt(now.AddDate(0, 0, -(days - 1)))
}

// SHA256Hex 是 token / 邀请码的存储哈希（Python 的 store.sha256_hex）。
func SHA256Hex(value string) string {
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:])
}

// newID 生成带前缀的实体 ID：前缀 + "_" + 9 字节十六进制（Python 的 new_id）。
func newID(prefix string) string {
	raw := make([]byte, 9)
	if _, err := rand.Read(raw); err != nil {
		// crypto/rand 失败在生产上是不可恢复的环境故障；不让调用方拿到半成品。
		panic("store: crypto/rand 不可用: " + err.Error())
	}
	return prefix + "_" + hex.EncodeToString(raw)
}

// newToken 生成带前缀的凭据：前缀 + "_" + 32 字节 URL 安全 base64（无填充）。
//
// Python 的 secrets.token_urlsafe(32) 正是 32 字节的 URL 安全 base64（43 字符），
// 两版生成的令牌格式完全一致。
func newToken(prefix string) string {
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		panic("store: crypto/rand 不可用: " + err.Error())
	}
	return prefix + "_" + base64.RawURLEncoding.EncodeToString(raw)
}

// normalizePairCode 与 Python 版逐条一致：去首尾空白、转大写、只留字母与数字。
//
// Python 用的是 str.isalnum()（Unicode 语义），这里用 unicode.IsLetter/IsDigit，
// 保证非 ASCII 码的处理也相同。
func normalizePairCode(code string) string {
	var out strings.Builder
	for _, ch := range strings.ToUpper(strings.TrimSpace(code)) {
		if unicode.IsLetter(ch) || unicode.IsDigit(ch) {
			out.WriteRune(ch)
		}
	}
	return out.String()
}

// normalizeInviteCode 与 normalizePairCode 相同（Python 版就是直接复用）。
func normalizeInviteCode(code string) string { return normalizePairCode(code) }

// HashInviteCode 是邀请码的存储哈希：SHA-256，不是 scrypt。
//
// 码足够长且由机器生成，没有爆破空间；一次索引查找比扫全表做昂贵的 KDF
// （Python store.hash_invite_code）快得多。导出给 HTTP 层做限流桶的键。
func HashInviteCode(code string) string { return SHA256Hex(normalizeInviteCode(code)) }

// newInviteCode 生成 XXXX-XXXX-XXXX-XXXX 形式的邀请码。
func newInviteCode() string {
	total := inviteGroups * inviteGroupLen
	raw := make([]byte, total)
	for index := range raw {
		raw[index] = inviteAlphabet[randIndex(len(inviteAlphabet))]
	}
	groups := make([]string, 0, inviteGroups)
	for start := 0; start < total; start += inviteGroupLen {
		groups = append(groups, string(raw[start:start+inviteGroupLen]))
	}
	return strings.Join(groups, "-")
}

// newPairCode 生成 XXXX-XXXX 形式的配对码。
func newPairCode() string {
	raw := make([]byte, 8)
	for index := range raw {
		raw[index] = pairAlphabet[randIndex(len(pairAlphabet))]
	}
	return string(raw[:4]) + "-" + string(raw[4:])
}

// randIndex 返回 [0, n) 的均匀随机下标（拒绝采样，避免取模偏差）。
func randIndex(n int) int {
	// n 都是 30 出头，一个字节足够；大于 255 时退回 4 字节路径。
	if n <= 256 {
		limit := 256 - (256 % n)
		for {
			var one [1]byte
			if _, err := rand.Read(one[:]); err != nil {
				panic("store: crypto/rand 不可用: " + err.Error())
			}
			if int(one[0]) < limit {
				return int(one[0]) % n
			}
		}
	}
	var four [4]byte
	for {
		if _, err := rand.Read(four[:]); err != nil {
			panic("store: crypto/rand 不可用: " + err.Error())
		}
		value := int(uint32(four[0])<<24|uint32(four[1])<<16|uint32(four[2])<<8|uint32(four[3])) & 0x7fffffff
		limit := 1<<31 - (1<<31)%n
		if value < limit {
			return value % n
		}
	}
}

// scryptKey 按 Python 版 store.py 的参数派生配对码哈希。
//
// n=1<<14, r=8, p=1, dklen=32；参数写死在一处，测试用已知盐与 Python 交叉验证。
func scryptKey(password, salt []byte) ([]byte, error) {
	return scrypt.Key(password, salt, scryptN, scryptR, scryptP, scryptKeyLen)
}

// hashPairCode 生成 scrypt 哈希，格式与 Python 版一致：scrypt$<hex salt>$<hex digest>。
func hashPairCode(code string) string {
	salt := make([]byte, scryptSaltLen)
	if _, err := rand.Read(salt); err != nil {
		panic("store: crypto/rand 不可用: " + err.Error())
	}
	return hashPairCodeWithSalt(code, salt)
}

// hashPairCodeWithSalt 是固定盐的版本（测试与 Python 交叉验证用）。
func hashPairCodeWithSalt(code string, salt []byte) string {
	digest, err := scryptKey([]byte(normalizePairCode(code)), salt)
	if err != nil {
		// 参数是常量，scrypt 不会在这里失败。
		panic("store: scrypt: " + err.Error())
	}
	return "scrypt$" + hex.EncodeToString(salt) + "$" + hex.EncodeToString(digest)
}

// verifyPairCode 与 Python 版 _verify_pair_code 等价：解析三段的哈希串，恒定时间比较。
func verifyPairCode(code, stored string) bool {
	parts := strings.Split(stored, "$")
	if len(parts) != 3 || parts[0] != "scrypt" {
		return false
	}
	salt, err := hex.DecodeString(parts[1])
	if err != nil {
		return false
	}
	candidate, err := scryptKey([]byte(normalizePairCode(code)), salt)
	if err != nil {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(hex.EncodeToString(candidate)), []byte(parts[2])) == 1
}

// HashPairCodeForTest 只给测试用：固定盐生成哈希，便于与 Python 交叉验证。
func HashPairCodeForTest(code string, salt []byte) string {
	if len(salt) == 0 {
		return hashPairCode(code)
	}
	return hashPairCodeWithSalt(code, salt)
}

// NewInviteCode 导出给 admin CLI 与测试（Python 的 new_invite_code）。
func NewInviteCode() string { return newInviteCode() }

// NormalizePairCode 导出给测试（Python 的 normalize_pair_code）。
func NormalizePairCode(code string) string { return normalizePairCode(code) }

// ValidateDeviceKey 复刻 api.pair_claim 对 deviceKey 的校验：8–128 字符，仅字母数字与 -_。
func ValidateDeviceKey(key string) bool {
	// Python 的 len() 数的是字符，不是字节。
	if length := utf8.RuneCountInString(key); length < 8 || length > 128 {
		return false
	}
	for _, ch := range key {
		if unicode.IsLetter(ch) || unicode.IsDigit(ch) || ch == '-' || ch == '_' {
			continue
		}
		return false
	}
	return true
}
