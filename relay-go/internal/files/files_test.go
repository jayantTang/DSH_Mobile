package files

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strconv"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/dlp"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/hub"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// 文件通道的用例都经**真 HTTP + 真 hub + 真 store** 跑，连接器一侧是内存桩：
// 这样 Range/Content-Length/正文截断这些"实现外部可观察"的部分不被 mock 掩盖。

const stubTimeout = 3 * time.Second

// fileFixture 是一套隔离的 store + hub + HTTP 服务，外加一条连接器桩。
type fileFixture struct {
	t        *testing.T
	store    *store.Store
	hub      *hub.Hub
	handlers *Handlers
	server   *httptest.Server
	client   *http.Client

	agentRow  store.Agent
	agent     *hub.AgentLink
	agentSink *agentSink

	device store.Device
	token  string
}

// agentSink 把 hub 发给连接器的帧塞进通道，供用例按序读取。
//
// gate 非 nil 时，fsPutChunk 的写入会阻塞到它关闭——这正是"连接器读得慢"：
// 写循环卡在 socket 写上，队列里的分片与它们占的桥额度因此积压起来。
type agentSink struct {
	frames chan dlp.Frame

	mu   sync.Mutex
	gate chan struct{}
}

func newAgentSink() *agentSink { return &agentSink{frames: make(chan dlp.Frame, 1024)} }

// blockChunks 让后续的分片写入阻塞；返回的放行函数幂等。
func (s *agentSink) blockChunks() func() {
	gate := make(chan struct{})
	s.mu.Lock()
	s.gate = gate
	s.mu.Unlock()
	var once sync.Once
	return func() {
		once.Do(func() {
			s.mu.Lock()
			s.gate = nil
			s.mu.Unlock()
			close(gate)
		})
	}
}

func (s *agentSink) Write(ctx context.Context, payload []byte) error {
	frame, _, err := dlp.Parse(payload)
	if err != nil {
		return nil // hub 只会写合法帧；真坏了也不让桩把用例挂住
	}
	if frame.Type() == "fsPutChunk" {
		s.mu.Lock()
		gate := s.gate
		s.mu.Unlock()
		if gate != nil {
			select {
			case <-gate:
			case <-ctx.Done():
				return ctx.Err()
			}
		}
	}
	select {
	case s.frames <- frame:
	default:
	}
	return nil
}

func (s *agentSink) Ping(context.Context) error { return nil }
func (s *agentSink) Close(int, string) error    { return nil }

// options 是可选的夹具参数。
type fixtureOptions struct {
	limits       hub.Limits
	ackTimeout   time.Duration
	idleTimeout  time.Duration
	writeTimeout time.Duration
}

func newFileFixture(t *testing.T, options fixtureOptions) *fileFixture {
	t.Helper()
	if options.limits == (hub.Limits{}) {
		options.limits = hub.DefaultLimits()
	}
	if options.ackTimeout <= 0 {
		options.ackTimeout = 200 * time.Millisecond
	}
	if options.idleTimeout <= 0 {
		options.idleTimeout = 2 * time.Second
	}

	st, err := store.Open(filepath.Join(t.TempDir(), "state.db"))
	if err != nil {
		t.Fatalf("打开临时库: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })

	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	ctx := context.Background()
	account, err := st.CreateAccount(ctx, "files")
	if err != nil {
		t.Fatalf("CreateAccount: %v", err)
	}
	agent, _, err := st.RegisterAgent(ctx, account.AccountID, "files", nil)
	if err != nil {
		t.Fatalf("RegisterAgent: %v", err)
	}
	minted, err := st.MintPairCode(ctx, agent.AgentID, nil)
	if err != nil {
		t.Fatalf("MintPairCode: %v", err)
	}
	claim, err := st.ClaimPairCode(ctx, minted.Code, store.ClaimParams{
		DeviceName: "files-phone", TTLMS: store.DefaultDeviceTTLMS, MaxPairedDevices: 8,
	})
	if err != nil {
		t.Fatalf("ClaimPairCode: %v", err)
	}
	device, found, err := st.DeviceByID(ctx, claim.DeviceID)
	if err != nil || !found {
		t.Fatalf("DeviceByID: found=%v err=%v", found, err)
	}

	live := hub.New(hub.Options{
		Store: st, Limits: options.limits, Logger: logger,
		WriteTimeout: options.writeTimeout, RevokeReconcileInterval: -1,
	})
	handlers := New(Options{
		Store: st, Hub: live, Logger: logger,
		AckTimeout: options.ackTimeout, IdleTimeout: options.idleTimeout,
	})
	mux := http.NewServeMux()
	handlers.Register(mux, "")
	server := httptest.NewServer(mux)
	t.Cleanup(server.Close)

	return &fileFixture{
		t: t, store: st, hub: live, handlers: handlers, server: server,
		client: &http.Client{Timeout: 10 * time.Second},
		device: device, token: claim.DeviceToken, agentRow: agent,
	}
}

// attachAgent 挂一条连接器连接（"电脑在线"）。
func (f *fileFixture) attachAgent() *agentSink {
	f.t.Helper()
	sink := newAgentSink()
	f.agent = f.hub.AttachAgent(context.Background(), f.agentRow, sink)
	f.agentSink = sink
	f.t.Cleanup(func() { f.hub.DetachAgent(f.agent) })
	return sink
}

// attachDevice 挂上手机自己的 WebSocket（限速桶与出口记账都在它身上）。
func (f *fileFixture) attachDevice() *hub.DeviceLink {
	f.t.Helper()
	link, err := f.hub.AttachDevice(context.Background(), f.device, &deviceSink{})
	if err != nil {
		f.t.Fatalf("AttachDevice: %v", err)
	}
	f.t.Cleanup(func() { f.hub.DetachDevice(link) })
	return link
}

// deviceSink 是设备 WS 的空实现（本包只关心它带来的桶与记账对象）。
type deviceSink struct{}

func (deviceSink) Write(context.Context, []byte) error { return nil }
func (deviceSink) Ping(context.Context) error          { return nil }
func (deviceSink) Close(int, string) error             { return nil }

// next 读下一帧；超时即失败（用例不允许挂死）。
func (f *fileFixture) next(timeout time.Duration) (dlp.Frame, error) {
	select {
	case frame := <-f.agentSink.frames:
		return frame, nil
	case <-time.After(timeout):
		return nil, fmt.Errorf("等待连接器帧超时（%.0fms）", float64(timeout)/float64(time.Millisecond))
	}
}

// nextKind 等一条指定类型的帧，忽略其它（设备生命周期帧等）。
func (f *fileFixture) nextKind(kind string, timeout time.Duration) (dlp.Frame, error) {
	deadline := time.Now().Add(timeout)
	for {
		remaining := time.Until(deadline)
		if remaining <= 0 {
			return nil, fmt.Errorf("没等到 %s", kind)
		}
		frame, err := f.next(remaining)
		if err != nil {
			return nil, err
		}
		if frame.Type() == kind {
			return frame, nil
		}
	}
}

// nextBegin 等 fsGetBegin，跳过 fsGetCancel（续传/重启之间可能插一条）。
func (f *fileFixture) nextBegin(timeout time.Duration) (dlp.Frame, error) {
	return f.nextKind("fsGetBegin", timeout)
}

// collectBegin 是"等到 begin 并校验类型"的便捷写法。
func (f *fileFixture) deliver(frame dlp.Frame) error {
	encoded, err := dlp.Encode(frame)
	if err != nil {
		return err
	}
	wire, _, err := dlp.Scan(encoded)
	if err != nil {
		return err
	}
	f.hub.RouteFromAgent(f.agent, wire)
	return nil
}

// run 在后台跑一段连接器桩；返回的通道收它的错误。
func (f *fileFixture) run(stub func() error) <-chan error {
	done := make(chan error, 1)
	go func() { done <- stub() }()
	return done
}

func waitStub(t *testing.T, done <-chan error) {
	t.Helper()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("连接器桩失败：%v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("连接器桩超时")
	}
}

// do 发一次请求并读完正文（不因读错而失败；截断由用例自己判断）。
func (f *fileFixture) do(method, path string, body []byte, headers map[string]string) (*http.Response, []byte, error) {
	f.t.Helper()
	request, err := http.NewRequest(method, f.server.URL+path, bytes.NewReader(body))
	if err != nil {
		f.t.Fatalf("NewRequest: %v", err)
	}
	for name, value := range headers {
		request.Header.Set(name, value)
	}
	response, err := f.client.Do(request)
	if err != nil {
		return nil, nil, err
	}
	defer response.Body.Close()
	payload, readErr := io.ReadAll(response.Body)
	return response, payload, readErr
}

// upload 发一次 /files/up。
func (f *fileFixture) upload(query string, body []byte) (*http.Response, []byte, error) {
	return f.do(http.MethodPut, "/files/up?"+query, body, map[string]string{
		"Authorization": "Bearer " + f.token,
	})
}

// download 发一次 /files/down（可带额外头）。
func (f *fileFixture) download(query string, headers map[string]string) (*http.Response, []byte, error) {
	merged := map[string]string{"Authorization": "Bearer " + f.token}
	for name, value := range headers {
		merged[name] = value
	}
	return f.do(http.MethodGet, "/files/down?"+query, nil, merged)
}

func errorCode(t *testing.T, payload []byte) string {
	t.Helper()
	var envelope struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal(payload, &envelope); err != nil {
		t.Fatalf("错误响应不是 JSON：%v（%s）", err, payload)
	}
	return envelope.Error.Code
}

// intField 读取整数帧字段（可在连接器桩的 goroutine 里安全使用）。
func intField(frame dlp.Frame, key string) (int64, bool) {
	number, ok := frame[key].(json.Number)
	if !ok {
		return 0, false
	}
	value, err := number.Int64()
	if err != nil {
		return 0, false
	}
	return value, true
}

// testBody 是"每个字节都可辨认"的一段内容（错位一秒就能看出来）。
func testBody(size int) []byte {
	body := make([]byte, size)
	for index := range body {
		body[index] = byte(index % 251)
	}
	return body
}

// ── 上传 ────────────────────────────────────────────────────────────────────

func TestUploadStreamsOneMegabyteChunksWithContinuousSeq(t *testing.T) {
	fx := newFileFixture(t, fixtureOptions{})
	fx.attachAgent()
	body := testBody(BridgeChunkBytes + 300*1024) // 跨两片

	done := fx.run(func() error {
		begin, err := fx.nextKind("fsPutBegin", stubTimeout)
		if err != nil {
			return err
		}
		if declared, ok := intField(begin, "bytes"); !ok || declared != int64(len(body)) {
			return fmt.Errorf("fsPutBegin = %v", begin)
		}
		if begin["sessionId"] != "s1" || begin["name"] != "big.bin" ||
			begin["bid"] != "app-bid-1" {
			return fmt.Errorf("fsPutBegin = %v", begin)
		}
		if begin["deviceId"] != fx.device.DeviceID {
			return fmt.Errorf("fsPutBegin 的 deviceId = %v", begin["deviceId"])
		}
		if err := fx.deliver(dlp.Frame{"t": "fsPutAck", "bid": "app-bid-1", "received": 0}); err != nil {
			return err
		}
		var received []byte
		var seqs []int64
		for {
			frame, err := fx.next(stubTimeout)
			if err != nil {
				return err
			}
			switch frame.Type() {
			case "fsPutChunk":
				piece, decodeErr := base64.StdEncoding.DecodeString(textValue(frame["data"]))
				if decodeErr != nil {
					return decodeErr
				}
				received = append(received, piece...)
				seq, ok := intField(frame, "seq")
				if !ok {
					return fmt.Errorf("seq 不是整数：%v", frame["seq"])
				}
				seqs = append(seqs, seq)
			case "fsPutEnd":
				if len(seqs) != 2 || seqs[0] != 0 || seqs[1] != 1 {
					return fmt.Errorf("分片序号必须从 0 连续：%v", seqs)
				}
				if !bytes.Equal(received, body) {
					return fmt.Errorf("拼起来与原文件不同：%d != %d", len(received), len(body))
				}
				return fx.deliver(dlp.Frame{
					"t": "fsPutDone", "bid": "app-bid-1",
					"path": "/home/u/.dsh/inbox/s1/big.bin", "bytes": len(body),
				})
			}
		}
	})

	response, payload, err := fx.upload(
		fmt.Sprintf("sessionId=s1&name=big.bin&bid=app-bid-1&bytes=%d", len(body)), body)
	if err != nil {
		t.Fatalf("上传请求失败：%v", err)
	}
	waitStub(t, done)
	if response.StatusCode != http.StatusOK {
		t.Fatalf("状态码 = %d：%s", response.StatusCode, payload)
	}
	var result struct {
		OK    bool   `json:"ok"`
		Path  string `json:"path"`
		Bytes int64  `json:"bytes"`
	}
	if err := json.Unmarshal(payload, &result); err != nil {
		t.Fatalf("响应不是 JSON：%v", err)
	}
	if !result.OK || result.Bytes != int64(len(body)) ||
		result.Path != "/home/u/.dsh/inbox/s1/big.bin" {
		t.Fatalf("响应 = %+v", result)
	}
}

func TestUploadWithoutAConnectedAgentAnswers503(t *testing.T) {
	fx := newFileFixture(t, fixtureOptions{})
	response, payload, err := fx.upload("sessionId=s1&name=n&bid=b&bytes=3", []byte("abc"))
	if err != nil {
		t.Fatalf("请求失败：%v", err)
	}
	if response.StatusCode != http.StatusServiceUnavailable ||
		errorCode(t, payload) != "host/offline" {
		t.Fatalf("状态码 = %d：%s", response.StatusCode, payload)
	}
}

func TestUploadValidatesTheQueryBeforeTalkingToTheConnector(t *testing.T) {
	fx := newFileFixture(t, fixtureOptions{})
	fx.attachAgent()

	cases := []struct {
		query string
		code  string
	}{
		{"sessionId=s1", "request/incomplete"},
		{"sessionId=s1&name=n&bid=b&bytes=abc", "request/bytes"},
		{"sessionId=s1&name=n&bid=b&bytes=-1", "request/bytes"},
	}
	for _, entry := range cases {
		response, payload, err := fx.upload(entry.query, nil)
		if err != nil {
			t.Fatalf("%s 请求失败：%v", entry.query, err)
		}
		if response.StatusCode != http.StatusBadRequest || errorCode(t, payload) != entry.code {
			t.Fatalf("%s → %d %s", entry.query, response.StatusCode, payload)
		}
	}
	if len(fx.agentSink.frames) != 0 {
		t.Fatalf("参数不合法时不该给连接器发帧：%v", <-fx.agentSink.frames)
	}
}

func TestUploadRequiresADeviceToken(t *testing.T) {
	fx := newFileFixture(t, fixtureOptions{})
	response, payload, err := fx.do(http.MethodPut, "/files/up?sessionId=s&name=n&bid=b&bytes=1",
		[]byte("a"), nil)
	if err != nil {
		t.Fatalf("请求失败：%v", err)
	}
	if response.StatusCode != http.StatusUnauthorized ||
		errorCode(t, payload) != "auth/invalid-token" {
		t.Fatalf("状态码 = %d：%s", response.StatusCode, payload)
	}
}

func TestUploadAckDeadlineAnswers501(t *testing.T) {
	fx := newFileFixture(t, fixtureOptions{ackTimeout: 50 * time.Millisecond})
	fx.attachAgent()
	done := fx.run(func() error {
		_, err := fx.nextKind("fsPutBegin", stubTimeout)
		return err // 不 ack：模拟旧连接器静默忽略
	})
	response, payload, err := fx.upload("sessionId=s1&name=n&bid=b&bytes=3", []byte("abc"))
	if err != nil {
		t.Fatalf("请求失败：%v", err)
	}
	waitStub(t, done)
	if response.StatusCode != http.StatusNotImplemented ||
		errorCode(t, payload) != "file/unsupported" {
		t.Fatalf("状态码 = %d：%s", response.StatusCode, payload)
	}
}

func TestUploadCarriesTheConnectorsOwnError(t *testing.T) {
	fx := newFileFixture(t, fixtureOptions{})
	fx.attachAgent()
	done := fx.run(func() error {
		begin, err := fx.nextKind("fsPutBegin", stubTimeout)
		if err != nil {
			return err
		}
		return fx.deliver(dlp.Frame{
			"t": "fsErr", "bid": begin["bid"],
			"code": "workspace-file/too-large", "message": "no room",
		})
	})
	response, payload, err := fx.upload("sessionId=s1&name=n&bid=b&bytes=3", []byte("abc"))
	if err != nil {
		t.Fatalf("请求失败：%v", err)
	}
	waitStub(t, done)
	if response.StatusCode != http.StatusConflict {
		t.Fatalf("状态码 = %d：%s", response.StatusCode, payload)
	}
	var envelope struct {
		Error struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(payload, &envelope); err != nil {
		t.Fatalf("响应不是 JSON：%v", err)
	}
	if envelope.Error.Code != "workspace-file/too-large" || envelope.Error.Message != "no room" {
		t.Fatalf("连接器的错误没有被原样带回：%s", payload)
	}
}

func TestUploadRefusesABodyShorterOrLongerThanDeclared(t *testing.T) {
	for _, entry := range []struct {
		name     string
		declared int
		body     []byte
	}{
		{"shorter", 10, []byte("12345")},
		{"longer", 3, []byte("abcde")},
	} {
		t.Run(entry.name, func(t *testing.T) {
			fx := newFileFixture(t, fixtureOptions{})
			fx.attachAgent()
			done := fx.run(func() error {
				begin, err := fx.nextKind("fsPutBegin", stubTimeout)
				if err != nil {
					return err
				}
				return fx.deliver(dlp.Frame{"t": "fsPutAck", "bid": begin["bid"]})
			})
			response, payload, err := fx.upload(
				fmt.Sprintf("sessionId=s1&name=n&bid=b&bytes=%d", entry.declared), entry.body)
			if err != nil {
				t.Fatalf("请求失败：%v", err)
			}
			waitStub(t, done)
			if response.StatusCode != http.StatusBadRequest ||
				errorCode(t, payload) != "request/bytes" {
				t.Fatalf("状态码 = %d：%s", response.StatusCode, payload)
			}
		})
	}
}

// ── 下载 ────────────────────────────────────────────────────────────────────

// serveDownload 是下载桩的公共骨架：ack 之后按窗口送 chunk，最后送 end。
func serveDownload(fx *fileFixture, body []byte, window int, version string,
	onBegin func(dlp.Frame) error) error {
	begin, err := fx.nextBegin(stubTimeout)
	if err != nil {
		return err
	}
	if onBegin != nil {
		if err := onBegin(begin); err != nil {
			return err
		}
	}
	bid, _ := begin["bid"].(string)
	offsetValue, ok := intField(begin, "offset")
	if !ok {
		return fmt.Errorf("fsGetBegin 的 offset 不是整数：%v", begin["offset"])
	}
	offset := int(offsetValue)
	ack := dlp.Frame{"t": "fsGetAck", "bid": bid, "size": len(body)}
	if version != "" {
		ack["version"] = version
	}
	if err := fx.deliver(ack); err != nil {
		return err
	}
	for start := offset; start < len(body); start += window {
		end := start + window
		if end > len(body) {
			end = len(body)
		}
		piece := body[start:end]
		if err := fx.deliver(dlp.Frame{
			"t": "fsGetChunk", "bid": bid,
			"data": base64.StdEncoding.EncodeToString(piece),
			"eof":  end == len(body),
		}); err != nil {
			return err
		}
	}
	return fx.deliver(dlp.Frame{"t": "fsGetEnd", "bid": bid})
}

func TestDownloadStreamsTheWholeFileAndStatesItsTotal(t *testing.T) {
	fx := newFileFixture(t, fixtureOptions{})
	fx.attachAgent()
	body := testBody(BridgeChunkBytes + 128*1024)
	done := fx.run(func() error {
		return serveDownload(fx, body, 256*1024, "v1", func(begin dlp.Frame) error {
			if begin["scopeId"] != "s1" || begin["path"] != "big.bin" {
				return fmt.Errorf("fsGetBegin = %v", begin)
			}
			if offset, ok := intField(begin, "offset"); !ok || offset != 0 {
				return fmt.Errorf("fsGetBegin 的 offset = %v", begin["offset"])
			}
			if begin["bid"] == "app-bid-down" {
				return fmt.Errorf("bid 必须由中转现铸")
			}
			if begin["replaces"] != "app-bid-down" {
				return fmt.Errorf("replaces = %v", begin["replaces"])
			}
			return nil
		})
	})
	response, payload, err := fx.download("scopeId=s1&path=big.bin&bid=app-bid-down", nil)
	if err != nil {
		t.Fatalf("请求失败：%v", err)
	}
	waitStub(t, done)
	if response.StatusCode != http.StatusOK {
		t.Fatalf("状态码 = %d：%s", response.StatusCode, payload)
	}
	if !bytes.Equal(payload, body) {
		t.Fatalf("正文不一致：%d != %d", len(payload), len(body))
	}
	if header := response.Header.Get("Content-Length"); header != strconv.Itoa(len(body)) {
		t.Fatalf("Content-Length = %q", header)
	}
	if header := response.Header.Get("Accept-Ranges"); header != "bytes" {
		t.Fatalf("Accept-Ranges = %q", header)
	}
	if header := response.Header.Get("ETag"); header != `"dsh-v1-`+strconv.Itoa(len(body))+`"` {
		t.Fatalf("ETag = %q", header)
	}
	if header := response.Header.Get("Cache-Control"); header != "no-store" {
		t.Fatalf("Cache-Control = %q", header)
	}
	if header := response.Header.Get("Content-Range"); header != "" {
		t.Fatalf("整份下载不该有 Content-Range：%q", header)
	}
}

func TestDownloadRangeResumesAtTheOffsetTheConnectorSees(t *testing.T) {
	fx := newFileFixture(t, fixtureOptions{})
	fx.attachAgent()
	body := testBody(1 << 20)
	offset := 700_000
	done := fx.run(func() error {
		return serveDownload(fx, body, 256*1024, "v-abc", func(begin dlp.Frame) error {
			if got, ok := intField(begin, "offset"); !ok || got != int64(offset) {
				return fmt.Errorf("连接器看到的 offset = %v", begin["offset"])
			}
			return nil
		})
	})
	response, payload, err := fx.download("scopeId=s1&path=big.bin",
		map[string]string{"Range": fmt.Sprintf("bytes=%d-", offset)})
	if err != nil {
		t.Fatalf("请求失败：%v", err)
	}
	waitStub(t, done)
	if response.StatusCode != http.StatusPartialContent {
		t.Fatalf("状态码 = %d：%s", response.StatusCode, payload)
	}
	if !bytes.Equal(payload, body[offset:]) {
		t.Fatalf("续传正文不一致：%d != %d", len(payload), len(body)-offset)
	}
	if header := response.Header.Get("Content-Range"); header !=
		fmt.Sprintf("bytes %d-%d/%d", offset, len(body)-1, len(body)) {
		t.Fatalf("Content-Range = %q", header)
	}
	if header := response.Header.Get("X-DSH-Offset"); header != strconv.Itoa(offset) {
		t.Fatalf("X-DSH-Offset = %q", header)
	}
	if header := response.Header.Get("Content-Length"); header != strconv.Itoa(len(body)-offset) {
		t.Fatalf("Content-Length = %q", header)
	}
}

func TestDownloadOffsetQueryWorksWithoutARangeHeader(t *testing.T) {
	fx := newFileFixture(t, fixtureOptions{})
	fx.attachAgent()
	body := testBody(100_000)
	done := fx.run(func() error {
		return serveDownload(fx, body, 30_000, "", func(begin dlp.Frame) error {
			if got, ok := intField(begin, "offset"); !ok || got != 40_000 {
				return fmt.Errorf("offset = %v", begin["offset"])
			}
			return nil
		})
	})
	response, payload, err := fx.download("scopeId=s1&path=big.bin&offset=40000", nil)
	if err != nil {
		t.Fatalf("请求失败：%v", err)
	}
	waitStub(t, done)
	if response.StatusCode != http.StatusPartialContent || !bytes.Equal(payload, body[40_000:]) {
		t.Fatalf("状态码 = %d，正文 %d 字节", response.StatusCode, len(payload))
	}
}

func TestDownloadOffsetPastTheEndAnswers416(t *testing.T) {
	fx := newFileFixture(t, fixtureOptions{})
	fx.attachAgent()
	body := testBody(1000)
	done := fx.run(func() error {
		begin, err := fx.nextBegin(stubTimeout)
		if err != nil {
			return err
		}
		if err := fx.deliver(dlp.Frame{
			"t": "fsGetAck", "bid": begin["bid"], "size": len(body), "version": "v1",
		}); err != nil {
			return err
		}
		// 中转先读一条窗口才检查 total；给一条终局帧即可（不必真送正文）。
		return fx.deliver(dlp.Frame{"t": "fsGetEnd", "bid": begin["bid"]})
	})
	response, payload, err := fx.download("scopeId=s1&path=big.bin",
		map[string]string{"Range": "bytes=1000-"})
	if err != nil {
		t.Fatalf("请求失败：%v", err)
	}
	waitStub(t, done)
	if response.StatusCode != http.StatusRequestedRangeNotSatisfiable ||
		errorCode(t, payload) != "request/offset" {
		t.Fatalf("状态码 = %d：%s", response.StatusCode, payload)
	}
}

func TestDownloadCarriesTheConnectorsOwnError(t *testing.T) {
	fx := newFileFixture(t, fixtureOptions{})
	fx.attachAgent()
	done := fx.run(func() error {
		begin, err := fx.nextBegin(stubTimeout)
		if err != nil {
			return err
		}
		return fx.deliver(dlp.Frame{
			"t": "fsErr", "bid": begin["bid"],
			"code": "workspace-file/not-found", "message": "no such file",
		})
	})
	response, payload, err := fx.download("scopeId=s1&path=nope.bin", nil)
	if err != nil {
		t.Fatalf("请求失败：%v", err)
	}
	waitStub(t, done)
	if response.StatusCode != http.StatusConflict ||
		errorCode(t, payload) != "workspace-file/not-found" {
		t.Fatalf("状态码 = %d：%s", response.StatusCode, payload)
	}
}

func TestDownloadAckDeadlineAnswers501(t *testing.T) {
	fx := newFileFixture(t, fixtureOptions{ackTimeout: 50 * time.Millisecond})
	fx.attachAgent()
	done := fx.run(func() error {
		_, err := fx.nextBegin(stubTimeout)
		return err // 不 ack
	})
	response, payload, err := fx.download("scopeId=s1&path=f.bin", nil)
	if err != nil {
		t.Fatalf("请求失败：%v", err)
	}
	waitStub(t, done)
	if response.StatusCode != http.StatusNotImplemented ||
		errorCode(t, payload) != "file/unsupported" {
		t.Fatalf("状态码 = %d：%s", response.StatusCode, payload)
	}
}

func TestDownloadWithoutAConnectedAgentAnswers503(t *testing.T) {
	fx := newFileFixture(t, fixtureOptions{})
	response, payload, err := fx.download("scopeId=s1&path=f.bin", nil)
	if err != nil {
		t.Fatalf("请求失败：%v", err)
	}
	if response.StatusCode != http.StatusServiceUnavailable ||
		errorCode(t, payload) != "host/offline" {
		t.Fatalf("状态码 = %d：%s", response.StatusCode, payload)
	}
}

func TestAnInterruptedDownloadCanResumeWithRange(t *testing.T) {
	fx := newFileFixture(t, fixtureOptions{})
	fx.attachAgent()
	body := testBody(5120)
	const window = 2560
	first := fx.run(func() error {
		begin, err := fx.nextBegin(stubTimeout)
		if err != nil {
			return err
		}
		bid, _ := begin["bid"].(string)
		if err := fx.deliver(dlp.Frame{
			"t": "fsGetAck", "bid": bid, "size": len(body), "version": "v1",
		}); err != nil {
			return err
		}
		if err := fx.deliver(dlp.Frame{
			"t": "fsGetChunk", "bid": bid,
			"data": base64.StdEncoding.EncodeToString(body[:window]), "eof": false,
		}); err != nil {
			return err
		}
		return fx.deliver(dlp.Frame{
			"t": "fsErr", "bid": bid,
			"code": "workspace-file/read-failed", "message": "lost the file",
		})
	})
	response, payload, readErr := fx.download("scopeId=s1&path=big.bin", nil)
	waitStub(t, first)
	if response.StatusCode != http.StatusOK {
		t.Fatalf("状态码 = %d", response.StatusCode)
	}
	if len(payload) != window {
		t.Fatalf("中断后应只收到第一片：%d", len(payload))
	}
	// Content-Length 声明了 5120、正文只有 2560：客户端必须看到"短包"而不是成功。
	if readErr == nil {
		t.Fatal("截断的正文必须让客户端读到错误")
	}

	second := fx.run(func() error {
		return serveDownload(fx, body, window, "v1", func(begin dlp.Frame) error {
			if got, ok := intField(begin, "offset"); !ok || got != int64(len(payload)) {
				return fmt.Errorf("续传 offset = %v", begin["offset"])
			}
			return nil
		})
	})
	resumed, resumedPayload, err := fx.download("scopeId=s1&path=big.bin",
		map[string]string{"Range": fmt.Sprintf("bytes=%d-", len(payload))})
	if err != nil {
		t.Fatalf("续传失败：%v", err)
	}
	waitStub(t, second)
	if resumed.StatusCode != http.StatusPartialContent ||
		!bytes.Equal(resumedPayload, body[len(payload):]) {
		t.Fatalf("续传状态 = %d，正文 %d 字节", resumed.StatusCode, len(resumedPayload))
	}
}

func TestACancelledDownloadTellsTheConnectorToStop(t *testing.T) {
	fx := newFileFixture(t, fixtureOptions{})
	fx.attachAgent()
	body := testBody(4096)
	cancelSeen := make(chan error, 1)
	go func() {
		begin, err := fx.nextBegin(stubTimeout)
		if err != nil {
			cancelSeen <- err
			return
		}
		bid, _ := begin["bid"].(string)
		if err := fx.deliver(dlp.Frame{
			"t": "fsGetAck", "bid": bid, "size": len(body), "version": "v1",
		}); err != nil {
			cancelSeen <- err
			return
		}
		if err := fx.deliver(dlp.Frame{
			"t": "fsGetChunk", "bid": bid,
			"data": base64.StdEncoding.EncodeToString(body[:1024]), "eof": false,
		}); err != nil {
			cancelSeen <- err
			return
		}
		// 不再送窗口：手机取消后应当收到 fsGetCancel。
		deadline := time.Now().Add(3 * time.Second)
		for time.Now().Before(deadline) {
			frame, err := fx.next(200 * time.Millisecond)
			if err != nil {
				continue
			}
			if frame.Type() == "fsGetCancel" && frame["bid"] == bid {
				cancelSeen <- nil
				return
			}
		}
		cancelSeen <- fmt.Errorf("没有收到 fsGetCancel")
	}()

	ctx, cancel := context.WithCancel(context.Background())
	request, err := http.NewRequestWithContext(ctx, http.MethodGet,
		fx.server.URL+"/files/down?scopeId=s1&path=big.bin", nil)
	if err != nil {
		t.Fatalf("NewRequest: %v", err)
	}
	request.Header.Set("Authorization", "Bearer "+fx.token)
	response, err := fx.client.Do(request)
	if err != nil {
		t.Fatalf("请求失败：%v", err)
	}
	received := make([]byte, 1024)
	if _, err := io.ReadFull(response.Body, received); err != nil {
		t.Fatalf("读第一片：%v", err)
	}
	cancel()
	_ = response.Body.Close()

	select {
	case err := <-cancelSeen:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("取消后连接器没有收到 fsGetCancel")
	}
}

func TestIfRangeWithAStaleETagRestartsFromZero(t *testing.T) {
	fx := newFileFixture(t, fixtureOptions{})
	fx.attachAgent()
	body := testBody(102_400)
	var firstBid, secondBid string
	done := fx.run(func() error {
		begin, err := fx.nextBegin(stubTimeout)
		if err != nil {
			return err
		}
		firstBid, _ = begin["bid"].(string)
		if err := fx.deliver(dlp.Frame{
			"t": "fsGetAck", "bid": firstBid, "size": len(body), "version": "v-new",
		}); err != nil {
			return err
		}
		// 中转要读到第一条窗口才会检查 If-Range；这条旧 run 的窗口随后会被丢弃。
		if err := fx.deliver(dlp.Frame{
			"t": "fsGetChunk", "bid": firstBid,
			"data": base64.StdEncoding.EncodeToString(body[40_000 : 40_000+1024]),
			"eof":  false,
		}); err != nil {
			return err
		}
		// 等第二条 fsGetBegin（中间可能插一条针对旧 run 的 fsGetCancel）。
		for {
			frame, err := fx.next(stubTimeout)
			if err != nil {
				return err
			}
			if frame.Type() == "fsGetCancel" {
				if frame["bid"] != firstBid {
					return fmt.Errorf("叫停的是新 run：%v", frame)
				}
				continue
			}
			if frame.Type() != "fsGetBegin" {
				continue
			}
			begin = frame
			break
		}
		secondBid, _ = begin["bid"].(string)
		if secondBid == firstBid {
			return fmt.Errorf("重启必须换一个新 bid")
		}
		if got, ok := intField(begin, "offset"); !ok || got != 0 {
			return fmt.Errorf("重启必须从 0 读：%v", begin["offset"])
		}
		const window = 1 << 20
		if err := fx.deliver(dlp.Frame{
			"t": "fsGetAck", "bid": secondBid, "size": len(body), "version": "v-new",
		}); err != nil {
			return err
		}
		for start := 0; start < len(body); start += window {
			end := start + window
			if end > len(body) {
				end = len(body)
			}
			if err := fx.deliver(dlp.Frame{
				"t": "fsGetChunk", "bid": secondBid,
				"data": base64.StdEncoding.EncodeToString(body[start:end]),
				"eof":  end == len(body),
			}); err != nil {
				return err
			}
		}
		return fx.deliver(dlp.Frame{"t": "fsGetEnd", "bid": secondBid})
	})

	response, payload, err := fx.download("scopeId=s1&path=f.bin&bid=bid-stale",
		map[string]string{"Range": "bytes=40000-", "If-Range": `"dsh-v-old-102400"`})
	if err != nil {
		t.Fatalf("请求失败：%v", err)
	}
	waitStub(t, done)
	if response.StatusCode != http.StatusOK {
		t.Fatalf("换了 ETag 就不再是部分内容：%d", response.StatusCode)
	}
	if !bytes.Equal(payload, body) {
		t.Fatalf("重启后必须回整份：%d != %d", len(payload), len(body))
	}
	if header := response.Header.Get("Content-Range"); header != "" {
		t.Fatalf("重启后不该有 Content-Range：%q", header)
	}
	if header := response.Header.Get("ETag"); header != `"dsh-v-new-102400"` {
		t.Fatalf("ETag = %q", header)
	}
}

func TestDownloadIsCappedByTheDailyAllowance(t *testing.T) {
	limits := hub.DefaultLimits()
	limits.DeviceDailyBytes = 1024
	fx := newFileFixture(t, fixtureOptions{limits: limits})
	fx.attachAgent()

	body := testBody(4096)
	done := fx.run(func() error {
		return serveDownload(fx, body, 1<<20, "v1", nil)
	})
	response, payload, err := fx.download("scopeId=s1&path=big.bin", nil)
	if err != nil {
		t.Fatalf("请求失败：%v", err)
	}
	waitStub(t, done)
	if response.StatusCode != http.StatusOK {
		t.Fatalf("状态码 = %d", response.StatusCode)
	}
	if len(payload) != 1024 {
		t.Fatalf("额度只有 1024 字节，正文却有 %d 字节", len(payload))
	}
	if header := response.Header.Get("Content-Length"); header != "1024" {
		t.Fatalf("Content-Length 没有按额度截短：%q", header)
	}
}

func TestADownloadCountsAsTheDevicesEgress(t *testing.T) {
	fx := newFileFixture(t, fixtureOptions{})
	fx.attachAgent()
	link := fx.attachDevice()
	// 挂上设备本身会写一条 hostStatus（也计入出口，而且是异步写出的）。等它落账
	// 之后再取基线，否则基线会落在 hostStatus 之前。
	deadline := time.Now().Add(2 * time.Second)
	for link.EgressBytes() == 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	baseline := link.EgressBytes()
	before, err := fx.hub.Today(context.Background())
	if err != nil {
		t.Fatalf("Today: %v", err)
	}
	body := testBody(4096)
	done := fx.run(func() error {
		return serveDownload(fx, body, 1<<20, "v1", nil)
	})
	response, payload, err := fx.download("scopeId=s1&path=big.bin", nil)
	if err != nil {
		t.Fatalf("请求失败：%v", err)
	}
	waitStub(t, done)
	if response.StatusCode != http.StatusOK || len(payload) != len(body) {
		t.Fatalf("状态码 = %d，正文 %d 字节", response.StatusCode, len(payload))
	}
	if egress := link.EgressBytes() - baseline; egress != int64(len(body)) {
		t.Fatalf("这次下载的出口字节 = %d，期望 %d", egress, len(body))
	}
	after, err := fx.hub.Today(context.Background())
	if err != nil {
		t.Fatalf("Today: %v", err)
	}
	if delta := after.TotalEgressBytes - before.TotalEgressBytes; delta != int64(len(body)) {
		t.Fatalf("today 增长 = %d，期望 %d", delta, len(body))
	}
}

func TestADownloadIsPacedByTheDevicesBucket(t *testing.T) {
	if testing.Short() {
		t.Skip("限速用例要真等约 0.5 秒")
	}
	limits := hub.DefaultLimits()
	limits.DeviceBytesPerSecond = 128 * 1024
	fx := newFileFixture(t, fixtureOptions{limits: limits})
	fx.attachAgent()
	link := fx.attachDevice()

	body := testBody(192 * 1024)
	done := fx.run(func() error {
		return serveDownload(fx, body, 64*1024, "v1", nil)
	})
	response, payload, err := fx.download("scopeId=s1&path=big.bin", nil)
	if err != nil {
		t.Fatalf("请求失败：%v", err)
	}
	waitStub(t, done)
	if response.StatusCode != http.StatusOK || len(payload) != len(body) {
		t.Fatalf("状态码 = %d，正文 %d 字节", response.StatusCode, len(payload))
	}
	// 桶的 burst 是 128 KiB，正文 192 KiB：至少要为 64 KiB 等 0.5 秒。
	if paced := link.PacedSeconds(); paced < 0.3 {
		t.Fatalf("下载没有经过限速桶：pacedSeconds = %.3f", paced)
	}
}

func TestRangeParserAcceptsOnlyBytesNToTheEnd(t *testing.T) {
	cases := []struct {
		header string
		offset int64
		found  bool
	}{
		{"bytes=0-", 0, true},
		{"bytes=123-", 123, true},
		{" Bytes=7- ", 7, true},
		{"bytes=-10", 0, false},
		{"bytes=1-2", 0, false},
		{"bytes=1-2,3-4", 0, false},
		{"bytes=abc-", 0, false},
		{"items=1-", 0, false},
		{"", 0, false},
	}
	for _, entry := range cases {
		offset, found := parseRange(entry.header)
		if found != entry.found || (found && offset != entry.offset) {
			t.Fatalf("parseRange(%q) = %d,%v", entry.header, offset, found)
		}
	}
}

// ── 上行桥的字节额度（M4a） ─────────────────────────────────────────────────

// countReader 记录请求体已经被读走多少字节：额度生效时它会在上限附近停住。
type countReader struct {
	reader io.Reader
	read   atomic.Int64
}

func (r *countReader) Read(buffer []byte) (int, error) {
	n, err := r.reader.Read(buffer)
	r.read.Add(int64(n))
	return n, err
}

func (r *countReader) consumed() int64 { return r.read.Load() }

// waitUntil 在 5 秒内等一个条件；超时即失败（不做无声的 sleep 等待）。
func waitUntil(t *testing.T, what string, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if condition() {
			return
		}
		time.Sleep(2 * time.Millisecond)
	}
	t.Fatalf("等待超时：%s", what)
}

// uploadDirect 直接调 handler，返回"请求结束"的通道与 recorder。
//
// 不走真 socket 是为了能看见请求体被读了多少——正是背压要证明的那件事。
func uploadDirect(fx *fileFixture, ctx context.Context, query string,
	body io.Reader) (*httptest.ResponseRecorder, <-chan struct{}) {
	fx.t.Helper()
	request := httptest.NewRequest(http.MethodPut, "/files/up?"+query, body)
	request = request.WithContext(ctx)
	request.Header.Set("Authorization", "Bearer "+fx.token)
	recorder := httptest.NewRecorder()
	finished := make(chan struct{})
	go func() {
		fx.handlers.HandleUpload(recorder, request)
		close(finished)
	}()
	return recorder, finished
}

// 慢连接器：额度用满后 handler 必须停止读请求体（内存有界），放行后整份内容
// 一字不差地送达（不丢数据）。
func TestUploadStopsReadingWhenTheBridgeBudgetIsExhausted(t *testing.T) {
	const budget = int64(2 << 20)
	fx := newFileFixture(t, fixtureOptions{limits: hub.Limits{BridgeBytes: budget}})
	fx.attachAgent()
	release := fx.agentSink.blockChunks()
	body := testBody(6 * BridgeChunkBytes)

	var received []byte
	var seqs []int64
	stubDone := fx.run(func() error {
		if _, err := fx.nextKind("fsPutBegin", stubTimeout); err != nil {
			return err
		}
		if err := fx.deliver(dlp.Frame{"t": "fsPutAck", "bid": "budget-1"}); err != nil {
			return err
		}
		for {
			frame, err := fx.next(stubTimeout)
			if err != nil {
				return err
			}
			switch frame.Type() {
			case "fsPutChunk":
				piece, decodeErr := base64.StdEncoding.DecodeString(textValue(frame["data"]))
				if decodeErr != nil {
					return decodeErr
				}
				received = append(received, piece...)
				seq, ok := intField(frame, "seq")
				if !ok {
					return fmt.Errorf("seq 不是整数：%v", frame["seq"])
				}
				seqs = append(seqs, seq)
			case "fsPutEnd":
				if !bytes.Equal(received, body) {
					return fmt.Errorf("慢连接器收到的内容与原文件不同：%d != %d",
						len(received), len(body))
				}
				if len(seqs) != 6 {
					return fmt.Errorf("分片数 = %d，期望 6", len(seqs))
				}
				for index, seq := range seqs {
					if seq != int64(index) {
						return fmt.Errorf("分片序号不连续：%v", seqs)
					}
				}
				return fx.deliver(dlp.Frame{
					"t": "fsPutDone", "bid": "budget-1",
					"path": "/inbox/big.bin", "bytes": len(body),
				})
			}
		}
	})

	reader := &countReader{reader: bytes.NewReader(body)}
	recorder, finished := uploadDirect(fx,
		context.Background(),
		fmt.Sprintf("sessionId=s1&name=big.bin&bid=budget-1&bytes=%d", len(body)),
		reader)

	waitUntil(t, "第一片入队并占住额度", func() bool {
		return fx.agent.BridgeBytesInUse() > 0
	})
	waitUntil(t, "第一片被读进内存", func() bool {
		return reader.consumed() >= BridgeChunkBytes
	})
	// 稳定窗口：handler 已经卡在额度上，请求体不再被读。
	before := reader.consumed()
	time.Sleep(120 * time.Millisecond)
	after := reader.consumed()
	if after != before {
		t.Fatalf("额度用满后仍在读请求体：%d → %d 字节", before, after)
	}
	if after > budget {
		t.Fatalf("额度 %d 字节，请求体却被读了 %d 字节", budget, after)
	}
	if used := fx.agent.BridgeBytesInUse(); used > budget {
		t.Fatalf("在途额度 %d 超过上限 %d", used, budget)
	}

	release()
	select {
	case <-finished:
	case <-time.After(5 * time.Second):
		t.Fatal("放行慢连接器之后上传仍未结束")
	}
	waitStub(t, stubDone)
	if recorder.Code != http.StatusOK {
		t.Fatalf("状态码 = %d：%s", recorder.Code, recorder.Body.String())
	}
}

// 取消：客户端在额度上等待时走了，那笔已取得的额度必须立刻归还（不泄漏）。
func TestUploadReleasesTheBridgeBudgetWhenTheClientCancels(t *testing.T) {
	const budget = int64(2 << 20)
	fx := newFileFixture(t, fixtureOptions{limits: hub.Limits{BridgeBytes: budget}})
	fx.attachAgent()
	release := fx.agentSink.blockChunks()
	body := testBody(8 * BridgeChunkBytes)

	stubDone := fx.run(func() error {
		if _, err := fx.nextKind("fsPutBegin", stubTimeout); err != nil {
			return err
		}
		return fx.deliver(dlp.Frame{"t": "fsPutAck", "bid": "cancel-1"})
	})

	ctx, cancel := context.WithCancel(context.Background())
	reader := &countReader{reader: bytes.NewReader(body)}
	_, finished := uploadDirect(fx, ctx,
		fmt.Sprintf("sessionId=s1&name=big.bin&bid=cancel-1&bytes=%d", len(body)), reader)

	waitUntil(t, "第一片占住额度", func() bool {
		return fx.agent.BridgeBytesInUse() > 0
	})
	waitUntil(t, "请求体已经被读了一部分", func() bool {
		return reader.consumed() >= BridgeChunkBytes
	})
	cancel()
	select {
	case <-finished:
	case <-time.After(5 * time.Second):
		t.Fatal("取消之后上传 handler 没有退出")
	}
	waitStub(t, stubDone)

	// 放行写循环：已入队那一片的额度在写出去之后归还，取消的那一笔由 handler 归还。
	release()
	waitUntil(t, "取消后额度全部归零", func() bool {
		return fx.agent.BridgeBytesInUse() == 0
	})
}

// 顶替：连接器换了人，旧链路上等额度的请求立刻失败，旧额度归零，新链路从头开始。
func TestSupersedingTheConnectorReleasesTheBridgeBudget(t *testing.T) {
	const budget = int64(2 << 20)
	fx := newFileFixture(t, fixtureOptions{
		limits:       hub.Limits{BridgeBytes: budget},
		writeTimeout: 50 * time.Millisecond,
	})
	fx.attachAgent()
	fx.agentSink.blockChunks()
	body := testBody(8 * BridgeChunkBytes)

	stubDone := fx.run(func() error {
		if _, err := fx.nextKind("fsPutBegin", stubTimeout); err != nil {
			return err
		}
		return fx.deliver(dlp.Frame{"t": "fsPutAck", "bid": "supersede-1"})
	})

	reader := &countReader{reader: bytes.NewReader(body)}
	recorder, finished := uploadDirect(fx, context.Background(),
		fmt.Sprintf("sessionId=s1&name=big.bin&bid=supersede-1&bytes=%d", len(body)), reader)

	waitUntil(t, "第一片占住额度", func() bool {
		return fx.agent.BridgeBytesInUse() > 0
	})
	waitUntil(t, "请求体已经被读了一部分", func() bool {
		return reader.consumed() >= BridgeChunkBytes
	})

	old := fx.agent
	superseding := fx.hub.AttachAgent(context.Background(), fx.agentRow, newAgentSink())
	t.Cleanup(func() { fx.hub.DetachAgent(superseding) })

	select {
	case <-finished:
	case <-time.After(5 * time.Second):
		t.Fatal("连接器被顶替之后上传 handler 没有退出")
	}
	waitStub(t, stubDone)
	if recorder.Code != http.StatusServiceUnavailable ||
		errorCode(t, recorder.Body.Bytes()) != "host/offline" {
		t.Fatalf("状态码 = %d：%s", recorder.Code, recorder.Body.String())
	}
	waitUntil(t, "被顶替链路的额度归零", func() bool {
		return old.BridgeBytesInUse() == 0
	})
	if got := superseding.BridgeBytesInUse(); got != 0 {
		t.Fatalf("新链路的在途额度 = %d，期望 0", got)
	}
	if got := superseding.BridgeBytesCapacity(); got != budget {
		t.Fatalf("新链路额度 = %d，期望 %d", got, budget)
	}
}

// 额度必须按 base64 之后的真实排队字节计：否则"16 MiB 上限"实际会堆到 21 MiB。
func TestUploadChunkCreditCoversTheEncodedFrame(t *testing.T) {
	for _, raw := range []int{1, 2, 3, 64 * 1024, BridgeChunkBytes} {
		data := base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{0x5a}, raw))
		payload, err := dlp.Encode(dlp.Frame{
			"t": "fsPutChunk", "deviceId": "dev_0123456789abcdef",
			"bid": "0123456789abcdef0123456789abcdef", "seq": 999999, "data": data,
		})
		if err != nil {
			t.Fatalf("Encode: %v", err)
		}
		if credit := chunkCredit(raw); credit < int64(len(payload)) {
			t.Fatalf("raw=%d：额度 %d 小于帧字节 %d", raw, credit, len(payload))
		}
	}
}
