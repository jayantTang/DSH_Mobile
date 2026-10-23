// Package push 是中转的 APNs 投递层（Python 版 relay/push.py 的对应物）。
//
// 手机是主动连到中转的，手机关掉以后中转没有任何下行通道；而一个联系不上主人的
// 终端应用看起来就像什么也没发生。中转本来就已经持有设备台账与鉴权面，所以由它
// 代手机去和 Apple 说话：不引入第二个推送服务，也不引入第二套凭据。
//
// 四条性质按"搞错的代价"排序：
//
//  1. **配置错误绝不碰转发**：FromEnv 在缺配置或 DLP_APNS_ENABLED=0 时返回一个
//     禁用实例；它只打日志，从不 panic。没配置时中转的行为与没有这个包时逐字相同。
//  2. **payload 不含内容**：标题、正文、工具名、文件路径、主机名、错误文本都不出现。
//     锁屏上能看到的只有指向 App 自己字符串表的 title-loc-key；sid/eid 作为不显示的
//     自定义字段传输。payload 只有一个构造点（payloadFor），审计也只需要看一处。
//  3. **这里不写数据库**：失效令牌通过返回值报告，由调用方（持有 store 的那一层）决定
//     是否清掉登记。
//  4. **HTTP 客户端是注入的**：生产用标准库 HTTP/2 transport，测试用桩；不在 import
//     时构造，也不在 Send 里新建第二条通路。
//
// 签名是 ES256（APNs 的 .p8 令牌密钥），一把密钥覆盖所有 bundle 与两个环境，不会
// 自己过期。**环境是逐设备的**：设备令牌与环境绑定，把 sandbox 令牌发到 production
// 会得到 BadDeviceToken，从手机上看就是"推送坏了"。
package push

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Apple 的两扇门。设备令牌只在一个环境有效，所以主机是逐设备选的，不是全局配置。
var Hosts = map[string]string{
	"sandbox":    "https://api.sandbox.push.apple.com",
	"production": "https://api.push.apple.com",
}

// JWTTTL 是一枚已签发 provider JWT 的复用时长。
//
// Apple 拒绝一小时以上的令牌，并要求不超过每 20 分钟刷新一次；50 分钟落在两者之间，
// 给时钟偏差留了余量。
const JWTTTL = 50 * time.Minute

// CollapseIDMax 是 apns-collapse-id 的字节上限（Apple 规定 64）。
const CollapseIDMax = 64

// ExpirationSeconds 是两类提醒各自"还值得送达"的时长。
//
// 一条"跑完了"晚到一小时就是噪音；一个没人回答的问题明天仍然有效。
var ExpirationSeconds = map[string]int64{
	"turnEnd":   60 * 60,
	"attention": 24 * 60 * 60,
}

// AlertKeys 是固定提醒，按 kind 索引。这些是**本地化键，不是文案**：
// 本仓库的字符串表用中文原文当键（en.lproj / zh-Hans.lproj），手机按用户语言渲染。
// 除这两条之外不许再加任何东西——见包注释。
var AlertKeys = map[string]string{
	"turnEnd":   "运行结束",
	"attention": "需要你确认",
}

// DeadTokenReasons 是"这个令牌死了，别再用了"的 APNs 拒绝原因。
//
// 410 是 Unregistered（App 已卸载）；BadDeviceToken 是重装或 apnsEnv 标错之后的
// 令牌/环境不匹配。
var DeadTokenReasons = map[string]struct{}{
	"BadDeviceToken":         {},
	"Unregistered":           {},
	"DeviceTokenNotForTopic": {},
}

// DeadTokenStatuses 是同样含义的 HTTP 状态码（410 Unregistered）。
var DeadTokenStatuses = map[int]struct{}{http.StatusGone: {}}

// Client 是投递用的 HTTP 客户端；生产是标准库 *http.Client，测试是记录请求的桩。
type Client interface {
	Do(*http.Request) (*http.Response, error)
}

// Result 是一次投递尝试的结果，供调用方记录与清理登记。
//
//	OK          Apple 接受了。
//	Status/Reason  APNs 的原话，原样保留：推送"就是不到"时，这是唯一能说明原因的东西。
//	DeadToken   调用方应当清掉这台设备的登记。
//	Skipped     什么都没发，以及原因（disabled / throttled / unknown-env / no-token /
//	            unsupported-kind / signing）。
type Result struct {
	OK        bool    `json:"ok"`
	Status    *int    `json:"status"`
	Reason    *string `json:"reason"`
	APNSID    *string `json:"apnsId"`
	DeadToken bool    `json:"deadToken"`
	Skipped   *string `json:"skipped"`
}

// Target 是一台待推送设备的登记（store.Device 的投影，避免 push 依赖仓储模型）。
type Target struct {
	DeviceID string
	Token    string
	Env      *string
}

// Request 是一次单设备投递的入参。
type Request struct {
	DeviceID string
	Token    string
	// Env 为空时用 Sender 的默认环境；空字符串也按未给处理（Python 的 `env or default`）。
	Env            *string
	Kind           string
	SID            string
	EID            *string
	IgnoreThrottle bool
}

// Sender 是中转进程里唯一的 APNs 投递器。
type Sender struct {
	keyPath    string
	keyID      string
	teamID     string
	topic      string
	defaultEnv string
	minGap     time.Duration
	enabled    bool

	client     Client
	ownsClient bool
	now        func() time.Time

	mu         sync.Mutex
	jwt        string
	jwtIssued  time.Time
	lastSent   map[string]time.Time
	clientLock sync.Mutex
}

// FromEnv 按环境变量构造部署要求的投递器；从不 panic。
//
// 缺任何一项或开关没打开都返回禁用实例：打一行日志，然后每次 Send 都回答
// skipped=disabled。这就是全部安全故事——配了一半的中转照常转发。
//
// getenv 为 nil 时读 os.Getenv；client 为 nil 时首次发送才创建标准库 HTTP/2 客户端。
func FromEnv(getenv func(string) string, client Client) *Sender {
	if getenv == nil {
		getenv = os.Getenv
	}
	enabled := truthy(getenv("DLP_APNS_ENABLED"))
	keyPath := text(getenv("DLP_APNS_KEY_PATH"))
	keyID := text(getenv("DLP_APNS_KEY_ID"))
	teamID := text(getenv("DLP_APNS_TEAM_ID"))
	topic := text(getenv("DLP_APNS_TOPIC"))
	defaultEnv := strings.ToLower(text(getenv("DLP_APNS_ENV_DEFAULT")))
	if defaultEnv == "" {
		defaultEnv = "sandbox"
	}
	if _, ok := Hosts[defaultEnv]; !ok {
		defaultEnv = "sandbox"
	}
	minGap := durationFromEnv(getenv("DLP_APNS_MIN_INTERVAL_S"), 60*time.Second)

	if !enabled {
		slog.Info("relay: APNs 未启用（DLP_APNS_ENABLED 未设或为 0），推送会被跳过")
		return disabledSender(defaultEnv, minGap)
	}
	missing := make([]string, 0, 4)
	for name, value := range map[string]string{
		"DLP_APNS_KEY_PATH": keyPath, "DLP_APNS_KEY_ID": keyID,
		"DLP_APNS_TEAM_ID": teamID, "DLP_APNS_TOPIC": topic,
	} {
		if value == "" {
			missing = append(missing, name)
		}
	}
	if len(missing) > 0 {
		sortStrings(missing)
		slog.Warn("relay: APNs 已启用但配置不全，推送不可用——转发不受影响",
			"missing", strings.Join(missing, ", "))
		return disabledSender(defaultEnv, minGap)
	}
	if _, err := os.Stat(keyPath); err != nil {
		// 只打路径，不打内容：这是唯一能把"密钥放错目录"和"环境变量没生效"
		// 区分开的一行（unit 有 ProtectHome=yes，密钥不能放 /root·/home）。
		slog.Warn("relay: APNs 密钥文件不存在，推送不可用（转发不受影响）", "path", keyPath)
		return disabledSender(defaultEnv, minGap)
	}

	sender := &Sender{
		keyPath: keyPath, keyID: keyID, teamID: teamID, topic: topic,
		defaultEnv: defaultEnv, minGap: minGap, enabled: true,
		client: client, ownsClient: false, now: time.Now,
		lastSent: map[string]time.Time{},
	}
	slog.Info("relay: APNs 已配置", "key", prefix(keyID, 6), "topic", topic,
		"defaultEnv", defaultEnv)
	return sender
}

// Disabled 返回一个永远不发送的实例（与 Python 的 PushSender.disabled 等价）。
func Disabled() *Sender { return disabledSender("sandbox", 60*time.Second) }

func disabledSender(defaultEnv string, minGap time.Duration) *Sender {
	return &Sender{
		defaultEnv: defaultEnv, minGap: minGap, enabled: false,
		now: time.Now, lastSent: map[string]time.Time{},
	}
}

// Enabled 报告这台部署是否真的会发送。
func (s *Sender) Enabled() bool { return s != nil && s.enabled }

// SetNow 注入时钟（测试用；生产不调用）。
func (s *Sender) SetNow(now func() time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if now != nil {
		s.now = now
	}
}

// Close 关闭自己创建的 HTTP 客户端；注入的客户端不归这里管。
func (s *Sender) Close() error {
	s.clientLock.Lock()
	defer s.clientLock.Unlock()
	if s.client != nil && s.ownsClient {
		if closer, ok := s.client.(interface{ CloseIdleConnections() }); ok {
			closer.CloseIdleConnections()
		}
		s.client = nil
		s.ownsClient = false
	}
	return nil
}

// ResetThrottle 忘掉限速状态；deviceID 为空时清空全部。
//
// `push-test` 用它按需发送：排障时不该等 60 秒。
func (s *Sender) ResetThrottle(deviceID string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if deviceID == "" {
		s.lastSent = map[string]time.Time{}
		return
	}
	delete(s.lastSent, deviceID)
}

// ── payload ────────────────────────────────────────────────────────────────

// apsAlert 只带本地化键：没有 title、没有 body，连 loc-args 都没有。
type apsAlert struct {
	TitleLocKey string `json:"title-loc-key"`
}

type apsBody struct {
	Alert    apsAlert `json:"alert"`
	Sound    string   `json:"sound"`
	ThreadID string   `json:"thread-id"`
}

// payload 是推送正文的唯一形状。
//
// 字段顺序与 Python 版一致（aps / kind / sid / eid）；eid 只在有值时出现。
type payload struct {
	APS  apsBody `json:"aps"`
	Kind string  `json:"kind"`
	SID  string  `json:"sid"`
	EID  *string `json:"eid,omitempty"`
}

// payloadFor 是**唯一**构造推送正文的地方（见包注释）。
func payloadFor(kind, sid string, eid *string) payload {
	body := payload{
		APS: apsBody{
			Alert:    apsAlert{TitleLocKey: AlertKeys[kind]},
			Sound:    "default",
			ThreadID: sid,
		},
		Kind: kind,
		SID:  sid,
	}
	if eid != nil && *eid != "" {
		body.EID = eid
	}
	return body
}

// ── signing ────────────────────────────────────────────────────────────────

// jsonHeader / jsonClaims 是 JWT 的两段；字段顺序固定，签出来的字节可复现。
type jsonHeader struct {
	Alg string `json:"alg"`
	Typ string `json:"typ"`
	Kid string `json:"kid"`
}

type jsonClaims struct {
	Iss string `json:"iss"`
	Iat int64  `json:"iat"`
}

// token 返回一枚缓存的 ES256 provider JWT；过期或被要求时才重签。
func (s *Sender) token(force bool) (string, error) {
	now := s.now()
	s.mu.Lock()
	if !force && s.jwt != "" && now.Sub(s.jwtIssued) < JWTTTL {
		cached := s.jwt
		s.mu.Unlock()
		return cached, nil
	}
	s.mu.Unlock()

	// 读密钥放在锁外：文件 I/O 不该把并发的 Send 堵在锁上（重复签一次无害）。
	raw, err := os.ReadFile(s.keyPath)
	if err != nil {
		return "", fmt.Errorf("读 APNs 密钥: %w", err)
	}
	key, err := parseKey(raw)
	if err != nil {
		return "", err
	}
	header, err := json.Marshal(jsonHeader{Alg: "ES256", Typ: "JWT", Kid: s.keyID})
	if err != nil {
		return "", err
	}
	claims, err := json.Marshal(jsonClaims{Iss: s.teamID, Iat: now.Unix()})
	if err != nil {
		return "", err
	}
	signingInput := base64.RawURLEncoding.EncodeToString(header) + "." +
		base64.RawURLEncoding.EncodeToString(claims)
	digest := sha256.Sum256([]byte(signingInput))
	r, signature, err := ecdsa.Sign(rand.Reader, key, digest[:])
	if err != nil {
		return "", fmt.Errorf("签 APNs JWT: %w", err)
	}
	// JWS 的 ES256 签名是定长 R||S（各 32 字节），不是 DER。
	rawSignature := make([]byte, 64)
	r.FillBytes(rawSignature[:32])
	signature.FillBytes(rawSignature[32:])
	signed := signingInput + "." + base64.RawURLEncoding.EncodeToString(rawSignature)

	s.mu.Lock()
	s.jwt = signed
	s.jwtIssued = now
	s.mu.Unlock()
	return signed, nil
}

// parseKey 解析 APNs 的 .p8（PKCS#8 EC 私钥），也接受 SEC1 `EC PRIVATE KEY`。
func parseKey(raw []byte) (*ecdsa.PrivateKey, error) {
	block, _ := pem.Decode(raw)
	if block == nil {
		return nil, errors.New("APNs 密钥不是 PEM")
	}
	if parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes); err == nil {
		key, ok := parsed.(*ecdsa.PrivateKey)
		if !ok {
			return nil, errors.New("APNs 密钥不是 EC 私钥")
		}
		if key.Curve != elliptic.P256() {
			return nil, errors.New("APNs 密钥不是 P-256")
		}
		return key, nil
	}
	key, err := x509.ParseECPrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("解析 APNs 密钥: %w", err)
	}
	if key.Curve != elliptic.P256() {
		return nil, errors.New("APNs 密钥不是 P-256")
	}
	return key, nil
}

// ── sending ────────────────────────────────────────────────────────────────

// throttled 报告同一台设备是否还在最短间隔内。
//
// 内存、进程内，故意的：它存在的目的只是别让一串事件在锁屏上叠起来，不是持久限流。
// 中转重启多赚一条提醒是可以接受的。
func (s *Sender) throttled(deviceID string) bool {
	if s.minGap <= 0 {
		return false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	last, ok := s.lastSent[deviceID]
	return ok && s.now().Sub(last) < s.minGap
}

// Send 投递一条提醒。这是唯一入口（hub 的 notify 与 push-test 都走它）。
//
// 返回而不是 panic：推送是尽力而为，绝不能把调用方（转发热路径）一起带下去。
// DeadToken=true 是调用方清理登记的暗号。
func (s *Sender) Send(ctx context.Context, request Request) Result {
	if !s.Enabled() {
		return Result{Skipped: stringPointer("disabled")}
	}
	if _, ok := AlertKeys[request.Kind]; !ok {
		return Result{Skipped: stringPointer("unsupported-kind")}
	}
	if request.Token == "" {
		return Result{Skipped: stringPointer("no-token")}
	}
	resolved := s.defaultEnv
	if request.Env != nil && *request.Env != "" {
		resolved = strings.ToLower(*request.Env)
	}
	if _, ok := Hosts[resolved]; !ok {
		// 环境叫不出来的令牌不可发送：猜一个会得到 BadDeviceToken，看起来就像"推送坏了"。
		slog.Warn("relay: device reports an unknown apnsEnv; not pushing",
			"deviceId", request.DeviceID)
		return Result{Skipped: stringPointer("unknown-env")}
	}
	if !request.IgnoreThrottle && s.throttled(request.DeviceID) {
		return Result{Skipped: stringPointer("throttled")}
	}

	body, err := marshalNoHTML(payloadFor(request.Kind, request.SID, request.EID))
	if err != nil {
		return Result{Reason: stringPointer("signing: " + err.Error())}
	}
	url := Hosts[resolved] + "/3/device/" + request.Token

	result := s.post(ctx, url, body, request.Kind, request.SID)
	if result.Status != nil && *result.Status == http.StatusForbidden && !request.IgnoreThrottle {
		// 过期或轮换过的 provider 令牌是**重试一次**能修好的唯一失败。
		// 只重试一次：被撤销的密钥否则会无限循环。
		slog.Info("relay: APNs rejected the provider token; re-signing once",
			"reason", stringValue(result.Reason))
		if _, err := s.token(true); err != nil {
			result.Reason = stringPointer("signing: " + err.Error())
			return result
		}
		result = s.post(ctx, url, body, request.Kind, request.SID)
	}

	if result.OK {
		s.mu.Lock()
		s.lastSent[request.DeviceID] = s.now()
		s.mu.Unlock()
	}
	if result.Reason != nil {
		if _, dead := DeadTokenReasons[*result.Reason]; dead {
			result.DeadToken = true
		}
	}
	if result.Status != nil {
		if _, dead := DeadTokenStatuses[*result.Status]; dead {
			result.DeadToken = true
		}
	}
	return result
}

// post 发一次请求，把 APNs 的答案翻成 Result。
func (s *Sender) post(ctx context.Context, url string, body []byte, kind, sid string) Result {
	token, err := s.token(false)
	if err != nil {
		slog.Warn("relay: could not sign the APNs token", "error", err)
		return Result{Reason: stringPointer("signing: " + err.Error())}
	}
	expiration := s.now().Unix() + ExpirationSeconds[kind]
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return Result{Reason: stringPointer("transport: " + err.Error())}
	}
	request.Header.Set("authorization", "bearer "+token)
	request.Header.Set("apns-topic", s.topic)
	request.Header.Set("apns-push-type", "alert")
	request.Header.Set("apns-priority", "10")
	request.Header.Set("apns-collapse-id", truncate(sid, CollapseIDMax))
	request.Header.Set("apns-expiration", strconv.FormatInt(expiration, 10))

	client, err := s.httpClient()
	if err != nil {
		return Result{Reason: stringPointer("transport: " + err.Error())}
	}
	response, err := client.Do(request)
	if err != nil {
		// 尽力而为：记一行日志，绝不把转发带下去。
		slog.Warn("relay: APNs request failed", "error", err)
		return Result{Reason: stringPointer(fmt.Sprintf("transport: %T", err))}
	}
	defer response.Body.Close()
	raw, readErr := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if readErr != nil {
		raw = nil
	}
	status := response.StatusCode
	apnsID := textPointer(response.Header.Get("apns-id"))
	if status == http.StatusOK {
		return Result{OK: true, Status: intPointer(status), APNSID: apnsID}
	}
	reason := reasonOf(string(raw))
	slog.Warn("relay: APNs rejected the push", "status", status,
		"reason", stringValue(reason))
	return Result{Status: intPointer(status), Reason: reason, APNSID: apnsID}
}

// httpClient 惰性创建一次标准库客户端；HTTP/2 由 ForceAttemptHTTP2 启用。
func (s *Sender) httpClient() (Client, error) {
	s.clientLock.Lock()
	defer s.clientLock.Unlock()
	if s.client != nil {
		return s.client, nil
	}
	transport := &http.Transport{
		ForceAttemptHTTP2:   true,
		MaxIdleConns:        8,
		MaxIdleConnsPerHost: 4,
		IdleConnTimeout:     90 * time.Second,
	}
	s.client = &http.Client{Transport: transport, Timeout: 10 * time.Second}
	s.ownsClient = true
	return s.client, nil
}

// SendMany 并发投递多台设备；一台失败绝不影响其余。
//
// 结果顺序与 targets 一一对应（hub 用它逐条记日志、按 deadToken 清登记）。
func (s *Sender) SendMany(ctx context.Context, targets []Target, kind, sid string,
	eid *string, ignoreThrottle bool) []Result {
	results := make([]Result, len(targets))
	var wait sync.WaitGroup
	for index, target := range targets {
		wait.Add(1)
		go func(index int, target Target) {
			defer wait.Done()
			defer func() {
				if recovered := recover(); recovered != nil {
					results[index] = Result{
						Reason: stringPointer(fmt.Sprintf("unexpected: %T", recovered)),
					}
				}
			}()
			results[index] = s.Send(ctx, Request{
				DeviceID: target.DeviceID, Token: target.Token, Env: target.Env,
				Kind: kind, SID: sid, EID: eid, IgnoreThrottle: ignoreThrottle,
			})
		}(index, target)
	}
	wait.Wait()
	return results
}

// ── helpers ────────────────────────────────────────────────────────────────

// marshalNoHTML 与 Python 的 json.dumps(..., ensure_ascii=False,
// separators=(",", ":")) 对齐：不转义 <、>、&，也不追加换行。
func marshalNoHTML(value any) ([]byte, error) {
	var buffer bytes.Buffer
	encoder := json.NewEncoder(&buffer)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(value); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(buffer.Bytes(), []byte("\n")), nil
}

// reasonOf 从 APNs 的错误正文里取 reason；不是 JSON 时取正文前 200 字符。
func reasonOf(body string) *string {
	body = strings.TrimSpace(body)
	if body == "" {
		return nil
	}
	var parsed map[string]any
	if err := json.Unmarshal([]byte(body), &parsed); err == nil {
		if reason, ok := parsed["reason"].(string); ok && reason != "" {
			return &reason
		}
		return nil
	}
	return stringPointer(truncate(body, 200))
}

func truthy(value string) bool {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "1", "true", "yes", "on":
		return true
	default:
		return false
	}
}

func text(value string) string { return strings.TrimSpace(value) }

func durationFromEnv(value string, fallback time.Duration) time.Duration {
	trimmed := strings.TrimSpace(value)
	if trimmed == "" {
		return fallback
	}
	seconds, err := strconv.ParseFloat(trimmed, 64)
	if err != nil {
		return fallback
	}
	return time.Duration(seconds * float64(time.Second))
}

func truncate(value string, limit int) string {
	if len(value) <= limit {
		return value
	}
	return value[:limit]
}

func prefix(value string, count int) string {
	if len(value) <= count {
		return value
	}
	return value[:count]
}

func stringPointer(value string) *string { return &value }

func textPointer(value string) *string {
	if value == "" {
		return nil
	}
	return &value
}

func intPointer(value int) *int { return &value }

func stringValue(value *string) string {
	if value == nil {
		return ""
	}
	return *value
}

// sortStrings 是给缺失变量名排序的小工具（避免为一个日志把 sort 拖进每个分支）。
func sortStrings(values []string) {
	for i := 1; i < len(values); i++ {
		for j := i; j > 0 && values[j] < values[j-1]; j-- {
			values[j], values[j-1] = values[j-1], values[j]
		}
	}
}
