// Package files 是两条文件通道 HTTP 端点（R-1 C-17 / C-19）：
//
//	PUT /files/up?sessionId=&name=&bid=&bytes=   手机把文件推给家里的电脑
//	GET /files/down?scopeId=&path=&offset=&bid=  手机从家里的电脑拉文件
//
// 中转**不存字节**：上行按 1 MB 切片经连接器的 WebSocket 转发，下行把连接器送来
// 的每一片直接写进 HTTP 正文。分片大小、ack 期限、Range/ETag 的口径逐项对齐
// relay/api.py 的 files_up / files_down，行为参考见 relay/tests/test_files_up.py
// 与 test_files_down.py。
//
// 桥的状态机在 internal/hub（谁拥有连接，谁拥有与连接相关的等待）；这个包只拥有
// HTTP 面：参数校验、分片、Range 解析、响应头与正文写作。
package files

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/apierr"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/authn"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/dlp"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/hub"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/reqctx"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// 桥接分片：1 MB 原始字节（base64 后约 1.33 MB）。192 KB 是给"手机↔中转共享链路"
// 定的妥协；中转↔家里的电脑是服务器↔宽带，没那个顾虑，32 MB 的帧上限留了余量。
const BridgeChunkBytes = 1 << 20

// DownChargeSlice 是下载路径的计费/限速粒度，与连接器回片的大小对齐。
//
// 一个 32 MB 的帧不该一次性计入限速桶：那会让一次下载在桶里留一个负得离谱的数。
const DownChargeSlice = BridgeChunkBytes

// 默认时限。ack 期限只用于"连接器是否认识这族帧"；静默上限只约束两片之间，
// 不是请求级超时（那会掐死一个正在慢慢传的大文件）。
const (
	DefaultAckTimeout  = hub.BridgeAckTimeout
	DefaultIdleTimeout = 120 * time.Second
)

// 下载响应的 CORS 头必须在 WriteHeader **之前**设置。
//
// httpapi 的 CORS 中间件是 handler 返回之后才补头的，而流式响应在 handler 内部
// 就已经把状态行与响应头发了出去：中间件那时再改 headers 不报错也不生效。预检放行
// 不等于正文可读——缺了 ACAO，浏览器会把已经收到的字节判为不可读。
var streamCORSHeaders = map[string]string{
	"access-control-allow-origin":   "*",
	"access-control-expose-headers": "content-range, etag",
}

// Options 是装配两条端点需要的输入。
type Options struct {
	Store  Store // 只用来认设备令牌（见 ports.go）
	Hub    *hub.Hub
	Logger *slog.Logger
	// AckTimeout / IdleTimeout 零值取默认；单测用短值，不真等 5 秒/120 秒。
	AckTimeout  time.Duration
	IdleTimeout time.Duration
}

// Handlers 是 /files/up 与 /files/down 的处理器。
type Handlers struct {
	store       Store
	hub         *hub.Hub
	log         *slog.Logger
	ackTimeout  time.Duration
	idleTimeout time.Duration
}

// New 建一对文件端点处理器。
func New(options Options) *Handlers {
	log := options.Logger
	if log == nil {
		log = slog.Default()
	}
	ackTimeout := options.AckTimeout
	if ackTimeout <= 0 {
		ackTimeout = DefaultAckTimeout
	}
	idleTimeout := options.IdleTimeout
	if idleTimeout <= 0 {
		idleTimeout = DefaultIdleTimeout
	}
	return &Handlers{
		store: options.Store, hub: options.Hub, log: log,
		ackTimeout: ackTimeout, idleTimeout: idleTimeout,
	}
}

// Register 把两条路由挂到 mux 上（base path 的原样与去前缀两种形式由调用方各挂一次）。
func (h *Handlers) Register(mux *http.ServeMux, prefix string) {
	mux.HandleFunc("PUT "+prefix+"/files/up", h.HandleUpload)
	mux.HandleFunc("GET "+prefix+"/files/down", h.HandleDownload)
}

// ── 传输诊断 ───────────────────────────────────────────────────────────────

// transferWriter 记录一次文件传输的响应状态、写出字节与错误码。
//
// 它只观察，不改变响应；Flush/Unwrap 保证流式下载与 ResponseController 照常工作。
// 传输日志的 status/bytes/errorCode 全部取自它，不在每个 return 前手抄一遍。
type transferWriter struct {
	http.ResponseWriter
	status    int
	bytes     int64
	errorCode string

	op       string
	deviceID string
	agentID  string
	bid      string
	scope    string
	start    time.Time
}

func (w *transferWriter) WriteHeader(status int) {
	if w.status == 0 {
		w.status = status
	}
	w.ResponseWriter.WriteHeader(status)
}

func (w *transferWriter) Write(payload []byte) (int, error) {
	if w.status == 0 {
		w.status = http.StatusOK
	}
	written, err := w.ResponseWriter.Write(payload)
	w.bytes += int64(written)
	return written, err
}

func (w *transferWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }

func (w *transferWriter) Flush() {
	if flusher, ok := w.ResponseWriter.(http.Flusher); ok {
		flusher.Flush()
	}
}

// beginTransfer 记传输开始，并把后续写响应导入记录器。
//
// scope 是本次传输的范围标识：上传是 sessionId、下载是 scopeId。**不记文件路径**：
// `name`/`path` 可能含用户目录结构，运维只需要"哪次传输、多少字节、结果如何"。
func (h *Handlers) beginTransfer(w http.ResponseWriter, op string, device store.Device,
	bid, scope string) (*transferWriter, http.ResponseWriter) {
	tracked := &transferWriter{
		ResponseWriter: w, op: op, deviceID: device.DeviceID, agentID: device.AgentID,
		bid: bid, scope: scope, start: time.Now(),
	}
	h.log.Info("relay: file transfer started",
		"op", op, "deviceId", device.DeviceID, "agentId", device.AgentID,
		"bid", bid, "scope", scope)
	return tracked, tracked
}

// finishTransfer 记传输结束：状态码、实际字节、耗时与错误码。
//
// bytes 传本次传输的有效字节（上传=已转发的原始字节，下载=已写出的正文字节）；
// 两者都不想混进 HTTP 响应体的字节数，所以不用 tracked.bytes。
func (h *Handlers) finishTransfer(r *http.Request, tracked *transferWriter, bytes int64) {
	status := tracked.status
	if status == 0 {
		status = http.StatusOK
	}
	code := tracked.errorCode
	if code == "" && r.Context().Err() != nil {
		code = "client/gone"
	}
	level := slog.LevelInfo
	if status >= 400 || code != "" {
		level = slog.LevelWarn
	}
	h.log.Log(r.Context(), level, "relay: file transfer finished",
		"op", tracked.op, "deviceId", tracked.deviceID, "agentId", tracked.agentID,
		"bid", tracked.bid, "scope", tracked.scope, "status", status,
		"bytes", bytes, "duration_ms", time.Since(tracked.start).Milliseconds(),
		"code", code, "ok", status < 400 && code == "")
}

// ── 上行 ────────────────────────────────────────────────────────────────────

// bridgeFrameOverhead 是分片帧里除 data 之外的字段（t / deviceId / bid / seq）在
// JSON 编码后的上限估计。实测约 180–220 字节，按 512 计是"只会多算"的保守值。
const bridgeFrameOverhead = 512

// chunkCredit 是一段原始分片转成 base64 帧之后在连接器队列里占用的字节数。
//
// 额度记的是**排队帧的真实字节**（base64 是 4/3 膨胀），不是原始字节：否则一个
// 16 MiB 的额度会实际堆到 21 MiB，报告里的"内存上界"就成了一笔虚账。
func chunkCredit(raw int) int64 {
	if raw <= 0 {
		return 0
	}
	return int64(base64.StdEncoding.EncodedLen(raw)) + bridgeFrameOverhead
}

// uploadResponse 是上传成功的响应；与 Python 一样回传连接器算出的路径与字节数。
type uploadResponse struct {
	OK    bool    `json:"ok"`
	Path  *string `json:"path"`
	Bytes *int64  `json:"bytes"`
}

// HandleUpload 把一次上传的请求体按片转发给连接器。
//
// 两个必须答得快的分支：电脑不在线 → 立刻 503（不排队、不落盘）；连接器不认这族
// 帧 → 5 秒 ack 期限后 501，而不是让手机一直等。
func (h *Handlers) HandleUpload(w http.ResponseWriter, r *http.Request) {
	device, ok, err := h.deviceFromBearer(r)
	if err != nil {
		h.writeStoreError(w, r, err)
		return
	}
	if !ok {
		writeError(w, http.StatusUnauthorized, "auth/invalid-token",
			"a valid device token is required")
		return
	}

	query := r.URL.Query()
	sessionID := query.Get("sessionId")
	name := query.Get("name")
	bid := query.Get("bid")
	if sessionID == "" || name == "" || bid == "" {
		writeError(w, http.StatusBadRequest, "request/incomplete",
			"sessionId, name and bid are all required")
		return
	}
	declared, err := parseByteCount(query.Get("bytes"))
	if err != nil {
		writeError(w, http.StatusBadRequest, "request/bytes", err.Error())
		return
	}
	if declared < 0 {
		writeError(w, http.StatusBadRequest, "request/bytes", "bytes must not be negative")
		return
	}

	agent := h.hub.Agent(device.AgentID)
	if agent == nil || agent.Closed() {
		writeErrorFor(w, r, http.StatusServiceUnavailable, "host/offline",
			"the PC connector is not connected")
		return
	}

	bridge := h.hub.OpenPutBridge(bid, agent)
	defer h.hub.CloseBridge(bid)

	// 从这里开始是一条真正的文件传输记录：bid、范围、结果、字节与耗时。
	// `name` 不进日志（可能是用户目录里的完整文件名）。
	tracked, w := h.beginTransfer(w, "upload", device, bid, sessionID)
	received := int64(0)
	defer func() { h.finishTransfer(r, tracked, received) }()

	h.hub.SendControl(agent, dlp.Frame{
		"t": "fsPutBegin", "deviceId": device.DeviceID, "bid": bid,
		"sessionId": sessionID, "name": name, "bytes": declared,
	})
	if !bridge.WaitAck(r.Context(), h.ackTimeout) {
		// 旧连接器会静默忽略这一族帧——给个明确的错误，别让它挂死。
		writeError(w, http.StatusNotImplemented, "file/unsupported",
			"连接器版本过旧，不支持后台上传；请更新连接器")
		return
	}
	if outcome, settled := bridge.TryOutcome(); settled {
		// 连接器在 begin 就拒绝了（fsErr）：那也是一个答复，原样把它的码带回去。
		writeBridgeError(w, outcome)
		return
	}

	seq := 0
	// 额度与分片一一对应：**先取得额度，再读请求体**。
	//
	// credit 是当前这一片"已经揣在手里、还没交给队列"的那笔；defer 保证每一条提前
	// 返回（读体出错、客户端取消、编码/入队失败）都把它还掉。入队成功后所有权归
	// 队列，由 outbound.release 在真正写出去（或随连接关闭清空）之后归还。
	credit := int64(0)
	defer func() {
		if credit > 0 {
			agent.ReleaseBridgeBytes(credit)
		}
	}()

	for received < declared {
		size := int64(BridgeChunkBytes)
		if remaining := declared - received; remaining < size {
			size = remaining
		}
		// **背压点**：额度不够时停在这里，不再读请求体。手机的 TCP 窗口随之关闭，
		// 数据留在发送端——不丢、不落盘、也不堆进中转内存。
		credit = chunkCredit(int(size))
		if err := agent.AcquireBridgeBytes(r.Context(), credit); err != nil {
			credit = 0
			if r.Context().Err() != nil {
				// 请求方已经走了：没有可写的响应，连接由 net/http 收掉。
				return
			}
			// 连接器被顶替/断开：这条上传不可能完成，给它一个明确的答复。
			writeErrorFor(w, r, http.StatusServiceUnavailable, "host/offline",
				"the PC connector went away while the upload was in flight")
			return
		}
		piece := make([]byte, int(size))
		read, readErr := io.ReadFull(r.Body, piece)
		if readErr != nil {
			if errors.Is(readErr, io.EOF) || errors.Is(readErr, io.ErrUnexpectedEOF) {
				writeError(w, http.StatusBadRequest, "request/bytes",
					fmt.Sprintf("expected %d bytes but received %d", declared, received+int64(read)))
				return
			}
			// 手机的请求体断了：这不是中转的故障，但它确实没传完。
			h.log.Debug("relay: upload body read ended early",
				"deviceId", device.DeviceID, "bid", bid, "error", readErr)
			writeError(w, http.StatusBadRequest, "request/bytes", "could not read the request body")
			return
		}
		frame := dlp.Frame{
			"t": "fsPutChunk", "deviceId": device.DeviceID, "bid": bid,
			"seq": seq, "data": base64.StdEncoding.EncodeToString(piece),
		}
		// 先把额度交给队列，再清掉本地记账：SendBridgeChunk 在成功与失败两条路上
		// 都只归还一次（成功归写循环，失败立刻归还）。
		creditForFrame := credit
		credit = 0
		if !h.hub.SendBridgeChunk(agent, frame, creditForFrame) {
			writeErrorFor(w, r, http.StatusServiceUnavailable, "host/offline",
				"the PC connector went away while the upload was in flight")
			return
		}
		seq++
		received += size
	}

	// 比声明还长的请求体必须拒绝：多读一个字节就能分辨，Content-Length 与 chunked
	// 两种编码都成立。
	var excess [1]byte
	if extra, readErr := r.Body.Read(excess[:]); extra > 0 {
		writeError(w, http.StatusBadRequest, "request/bytes",
			fmt.Sprintf("the body is longer than the declared %d bytes", declared))
		return
	} else if readErr != nil && !errors.Is(readErr, io.EOF) {
		h.log.Debug("relay: upload body read ended early",
			"deviceId", device.DeviceID, "bid", bid, "error", readErr)
		writeError(w, http.StatusBadRequest, "request/bytes", "could not read the request body")
		return
	}

	h.hub.SendControl(agent, dlp.Frame{
		"t": "fsPutEnd", "deviceId": device.DeviceID, "bid": bid,
	})

	outcome, settled := bridge.WaitDone(r.Context())
	if !settled {
		// 请求被取消（手机走了）：没有可写的响应，连接会由 net/http 收掉。
		return
	}
	if outcome.Failed() {
		writeBridgeError(w, outcome)
		return
	}
	writeJSON(w, http.StatusOK, uploadResponse{OK: true, Path: outcome.Path, Bytes: outcome.Bytes})
}

// ── 下行 ────────────────────────────────────────────────────────────────────

// HandleDownload 把连接器送来的窗口逐片写进 HTTP 正文。
//
// 与上行的关键不对称在**计费**：上行读的是手机推来的正文，下行写出去的是这台设备
// 的出口流量，所以每一片都过同一套限速桶与日额度账本（internal/quota 的 Bucket 与
// Ledger，经 DeviceLink 与 Hub 门面使用），HTTP 下载不能成为绕开它们的第二条通路。
func (h *Handlers) HandleDownload(w http.ResponseWriter, r *http.Request) {
	device, ok, err := h.deviceFromBearer(r)
	if err != nil {
		h.writeStoreError(w, r, err)
		return
	}
	if !ok {
		writeError(w, http.StatusUnauthorized, "auth/invalid-token",
			"a valid device token is required")
		return
	}

	query := r.URL.Query()
	scopeID := query.Get("scopeId")
	path := query.Get("path")
	if scopeID == "" || path == "" {
		writeError(w, http.StatusBadRequest, "request/incomplete",
			"scopeId and path are both required")
		return
	}

	offset, err := parseOffset(query.Get("offset"))
	if err != nil {
		writeError(w, http.StatusBadRequest, "request/offset", err.Error())
		return
	}
	// `Range` 与 offset 同时出现时以 Range 为准：它是续传下载器真正会设的头。
	if ranged, found := parseRange(r.Header.Get("Range")); found {
		offset = ranged
	}

	agent := h.hub.Agent(device.AgentID)
	if agent == nil || agent.Closed() {
		writeErrorFor(w, r, http.StatusServiceUnavailable, "host/offline",
			"the PC connector is not connected")
		return
	}

	// 额度基线在写响应之前落座（读一次库，不在正文热路径上）。
	h.hub.SeatDeviceQuota(r.Context(), device.DeviceID)
	link := h.hub.Device(device.DeviceID)

	// **中转现铸 bid，不沿用 App 的。** 续传请求里冻着上一次的 bid（系统的
	// resume data 是不可改的），沿用会让旧 run 还在路上的分片落进新正文——大小对、
	// 内容错，还会被按版本缓存下来。每次请求一个新名字从根上消除相撞。
	// App 的 bid 只作为 `replaces` 传给连接器：告诉它这次要顶替哪个 run。
	replaced := query.Get("bid")
	bid := newBridgeID()
	bridge := h.hub.OpenFetchBridge(bid, agent)
	current := bid
	defer func() { h.hub.CloseBridge(current) }()

	tracked, w := h.beginTransfer(w, "download", device, bid, scopeID)
	defer func() { h.finishTransfer(r, tracked, tracked.bytes) }()

	begin := dlp.Frame{
		"t": "fsGetBegin", "deviceId": device.DeviceID, "bid": bid,
		"scopeId": scopeID, "path": path, "offset": offset,
	}
	if replaced != "" {
		begin["replaces"] = replaced
	}
	h.hub.SendControl(agent, begin)
	if !bridge.WaitAck(r.Context(), h.ackTimeout) {
		writeError(w, http.StatusNotImplemented, "file/unsupported",
			"连接器版本过旧，不支持后台下载；请更新连接器")
		return
	}

	frame, ok := h.waitFrame(r.Context(), bridge)
	if !ok {
		h.writeNoStart(w, r)
		return
	}
	if code, message, failed := frameError(frame); failed {
		writeError(w, http.StatusConflict, code, message)
		return
	}

	// total/version 是连接器 stat 的产物（P-13b）。旧连接器两个都可能没有，下面
	// 每一处使用都必须容忍：缺总长只是"回到流式答复"，不是失败。
	total, hasTotal := bridge.Size()
	version := bridge.Version()
	var etag *string
	if version != "" && hasTotal {
		value := fmt.Sprintf(`"dsh-%s-%d"`, version, total)
		etag = &value
	}
	// offset >= total 一律 416：回答空正文会被手机当成"下完了"，回答 Range 头又会
	// 出现"首字节位置超过末字节位置"的畸形字段。
	if hasTotal && offset >= total {
		writeError(w, http.StatusRequestedRangeNotSatisfiable, "request/offset",
			"offset is past the end of the file")
		return
	}

	// `If-Range` 是续传**正确**（而不只是便宜）的兜底：文件在这期间被改过时，
	// 唯一安全的答复是从 0 回整份。换 ETag 必须**重开 fetch**，只改状态行会让
	// 正文缺掉开头 offset 个字节。
	if ifRange := r.Header.Get("If-Range"); ifRange != "" && etag != nil &&
		ifRange != *etag && offset != 0 {
		// 旧 run 还在送它收不回的窗口：放弃**并且叫停**，再用新 bid 从 0 重开。
		h.hub.CancelFetch(agent, bridge)
		bridge.Abandon()
		h.hub.CloseBridge(current)
		bid = newBridgeID()
		current = bid
		tracked.bid = bid // 换 bid 重开后，结束日志记的是真正在用的那个
		bridge = h.hub.OpenFetchBridge(bid, agent)
		h.hub.SendControl(agent, dlp.Frame{
			"t": "fsGetBegin", "deviceId": device.DeviceID, "bid": bid,
			"scopeId": scopeID, "path": path, "offset": 0,
		})
		if !bridge.WaitAck(r.Context(), h.ackTimeout) {
			writeError(w, http.StatusNotImplemented, "file/unsupported",
				"连接器版本过旧，不支持后台下载；请更新连接器")
			return
		}
		frame, ok = h.waitFrame(r.Context(), bridge)
		if !ok {
			h.writeNoStart(w, r)
			return
		}
		if code, message, failed := frameError(frame); failed {
			writeError(w, http.StatusConflict, code, message)
			return
		}
		offset = 0
	}

	// 从这里开始，任何出口都意味着"没人再读正文了"：放弃接收窗口，并叫停连接器
	// 的那一次 run（否则它会为没人读的正文读到底）。
	defer func() {
		bridge.Abandon()
		h.hub.CancelFetch(agent, bridge)
	}()

	status := http.StatusOK
	if offset != 0 {
		status = http.StatusPartialContent
	}
	headers := w.Header()
	headers.Set("Content-Type", "application/octet-stream")
	for name, value := range streamCORSHeaders {
		headers.Set(name, value)
	}
	// 连接器与手机之间不许有缓冲代理：一缓冲整条流就没有意义了。
	headers.Set("Cache-Control", "no-store")
	headers.Set("Accept-Ranges", "bytes")
	if etag != nil {
		headers.Set("ETag", *etag)
	}

	var declared *int64
	if hasTotal {
		deliverable := total - offset
		// 只承诺今天还发得起的字节：`Content-Length` 是承诺，被额度打破的承诺会
		// 让客户端等一段永远不来的正文。截短是诚实的——客户端从收到的地方续传。
		if remaining := h.hub.DeviceQuotaRemaining(device.DeviceID); remaining >= 0 &&
			remaining < deliverable {
			deliverable = remaining
		}
		declared = &deliverable
		headers.Set("Content-Length", strconv.FormatInt(deliverable, 10))
		if offset != 0 {
			headers.Set("Content-Range",
				fmt.Sprintf("bytes %d-%d/%d", offset, total-1, total))
		}
	}
	if offset != 0 {
		headers.Set("X-DSH-Offset", strconv.FormatInt(offset, 10))
	}
	// 状态行在这里发出；之后的所有失败只能用"短正文"表达。
	w.WriteHeader(status)
	flush(w)

	h.stream(w, r, tracked, device, link, bridge, frame, declared)
}

// stream 是正文写作循环：每一片都先限速、再计费，最后才写出。
func (h *Handlers) stream(w http.ResponseWriter, r *http.Request, tracked *transferWriter,
	device store.Device, link *hub.DeviceLink, bridge *hub.FetchBridge, frame dlp.Frame,
	declared *int64) {

	remaining := declared
	for frame != nil && (remaining == nil || *remaining > 0) {
		if code, message, failed := frameError(frame); failed {
			// 状态行已经发出，唯一诚实的收场是停下来：手机拿到短包，当成一次
			// 中断的传输（客户端会用 Range 续传）。
			tracked.errorCode = code
			h.log.Warn("relay: download failed mid-stream",
				"bid", bridge.Bid(), "code", code, "message", message)
			return
		}
		piece, err := base64.StdEncoding.DecodeString(textValue(frame["data"]))
		if err != nil {
			tracked.errorCode = "file/bad-window"
			h.log.Warn("relay: download window is not valid base64",
				"bid", bridge.Bid(), "error", err)
			return
		}
		for start := 0; start < len(piece); start += DownChargeSlice {
			end := start + DownChargeSlice
			if end > len(piece) {
				end = len(piece)
			}
			slice := piece[start:end]
			if remaining != nil && int64(len(slice)) > *remaining {
				slice = slice[:*remaining]
			}
			if len(slice) == 0 {
				break
			}
			// 限速用的是 WebSocket 写循环的**同一个**桶；没有设备 socket 就没有桶，
			// 也就没有要等的东西（Python 同样跳过）。
			if link != nil {
				if err := link.Pace(r.Context(), len(slice)); err != nil {
					return // 手机已经走了
				}
			}
			if allowed, _ := h.hub.ChargeDeviceQuota(device.DeviceID, len(slice)); !allowed {
				tracked.errorCode = "quota/exceeded"
				h.log.Warn("relay: device exceeded its daily allowance during a download",
					"deviceId", device.DeviceID, "bid", bridge.Bid())
				return
			}
			if link != nil {
				link.NoteEgress(len(slice))
			}
			if _, err := w.Write(slice); err != nil {
				// 手机在下载途中走了（关 App、切网、锁屏被杀）。这不是故障，
				// 但也是"没人读了"：退出后由 defer 叫停连接器。
				tracked.errorCode = "client/gone"
				h.log.Debug("relay: client went away mid-download",
					"bid", bridge.Bid(), "error", err)
				return
			}
			flush(w)
			if remaining != nil {
				*remaining -= int64(len(slice))
				if *remaining == 0 {
					return
				}
			}
		}
		if terminalFrame(frame) {
			return
		}
		next, ok := h.waitFrame(r.Context(), bridge)
		if !ok {
			if r.Context().Err() != nil {
				return // 手机走了；finishTransfer 会把它记成 client/gone
			}
			tracked.errorCode = "file/stalled"
			h.log.Warn("relay: download stalled", "bid", bridge.Bid(),
				"idleTimeout", h.idleTimeout)
			return
		}
		frame = next
	}
}

// waitFrame 等下一片，最多等 idleTimeout；返回 false 表示读者该收尾了。
func (h *Handlers) waitFrame(ctx context.Context, bridge *hub.FetchBridge) (dlp.Frame, bool) {
	waitCtx, cancel := context.WithTimeout(ctx, h.idleTimeout)
	defer cancel()
	return bridge.NextFrame(waitCtx)
}

// writeNoStart 处理"连接器接受了 ack 却没有开始传输"。
func (h *Handlers) writeNoStart(w http.ResponseWriter, r *http.Request) {
	if r.Context().Err() != nil {
		return // 手机已经不在了，写什么都没有意义
	}
	writeErrorFor(w, r, http.StatusServiceUnavailable, "host/offline", "连接器没有开始传输")
}

// ── 参数解析 ────────────────────────────────────────────────────────────────

// parseByteCount 解析 `bytes` 查询参数（Python int()，空串同样报错）。
func parseByteCount(raw string) (int64, error) {
	value, err := strconv.ParseInt(strings.TrimSpace(raw), 10, 64)
	if err != nil {
		return 0, errors.New("bytes must be an integer")
	}
	return value, nil
}

// parseOffset 解析 `offset`；缺省是 0。
func parseOffset(raw string) (int64, error) {
	if strings.TrimSpace(raw) == "" {
		return 0, nil
	}
	value, err := strconv.ParseInt(strings.TrimSpace(raw), 10, 64)
	if err != nil {
		return 0, errors.New("offset must be an integer")
	}
	if value < 0 {
		return 0, errors.New("offset must not be negative")
	}
	return value, nil
}

// parseRange 只认 `Range: bytes=N-`；其余形式一律忽略（不是错误）。
//
// 故意窄：RFC 7233 允许多种形式，每一种都是答错字节窗口的机会，而续传下载器只
// 需要这一种。无法解析的头必须忽略而不是拒绝——按 HTTP 规范，这是代理改写头的
// 兜底路径。
func parseRange(header string) (int64, bool) {
	value := strings.TrimSpace(header)
	if value == "" || !strings.HasPrefix(strings.ToLower(value), "bytes=") {
		return 0, false
	}
	spec := strings.TrimSpace(value[len("bytes="):])
	if strings.Contains(spec, ",") || !strings.HasSuffix(spec, "-") {
		return 0, false
	}
	number := strings.TrimSpace(strings.TrimSuffix(spec, "-"))
	if number == "" {
		return 0, false
	}
	for _, character := range number {
		if character < '0' || character > '9' {
			return 0, false
		}
	}
	offset, err := strconv.ParseInt(number, 10, 64)
	if err != nil {
		return 0, false
	}
	return offset, true
}

// newBridgeID 铸一个下载桥标识（Python `uuid.uuid4().hex` 的等价物：32 位十六进制）。
func newBridgeID() string {
	var raw [16]byte
	if _, err := rand.Read(raw[:]); err != nil {
		// crypto/rand 在这里失败意味着系统熵源坏了；用时间戳退化也不会撞（bid 只活
		// 在一次请求里），比让请求直接 500 好。
		return fmt.Sprintf("%032x", time.Now().UnixNano())
	}
	return hex.EncodeToString(raw[:])
}

// ── 帧与响应的小工具 ────────────────────────────────────────────────────────

// frameError 判断一条窗口帧是不是连接器的错误（fsErr 被桥包成 terminal）。
func frameError(frame dlp.Frame) (code, message string, failed bool) {
	code, ok := frame["error"].(string)
	if !ok || code == "" {
		return "", "", false
	}
	message, _ = frame["message"].(string)
	if message == "" {
		message = "the connector refused the download"
	}
	return code, message, true
}

// terminalFrame 判断这一帧之后不会再有正文（fsGetEnd 或 fsGetChunk.eof）。
func terminalFrame(frame dlp.Frame) bool {
	if done, ok := frame["_terminal"].(bool); ok && done {
		return true
	}
	if eof, ok := frame["eof"].(bool); ok && eof {
		return true
	}
	return false
}

// textValue 取字符串字段；缺失或类型不对时是空串。
func textValue(value any) string {
	text, _ := value.(string)
	return text
}

// flush 尽量把已写出的字节推给客户端（没有 Flusher 的测试 ResponseWriter 就算了）。
func flush(w http.ResponseWriter) {
	if flusher, ok := w.(http.Flusher); ok {
		flusher.Flush()
	}
}

// writeBridgeError 把桥的终局写成 HTTP 错误（连接器的码原样带回）。
func writeBridgeError(w http.ResponseWriter, outcome hub.BridgeOutcome) {
	if outcome.ErrCode == "" {
		outcome.ErrCode = "file/rejected"
	}
	message := outcome.ErrMessage
	if message == "" {
		message = "the connector refused the transfer"
	}
	writeError(w, http.StatusConflict, outcome.ErrCode, message)
}

// writeJSON 写一次 JSON 响应。
func writeJSON(w http.ResponseWriter, status int, payload any) {
	body, err := json.Marshal(payload)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal/error",
			"the relay could not encode this response")
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_, _ = w.Write(body)
}

// writeError 写一次错误信封（形状与全站一致）。
//
// 如果 w 是本包的传输记录器，顺手把错误码记进去：传输结束日志要回答"以什么码
// 结束"，而错误码只有写响应的这一刻知道。
func writeError(w http.ResponseWriter, status int, code, message string) {
	if tracked, ok := w.(*transferWriter); ok {
		tracked.errorCode = code
	}
	apierr.Write(w, status, code, message, nil)
}

// writeErrorFor 写一次错误信封；5xx 带上这次请求的 requestId（与 httpapi 同口径）。
func writeErrorFor(w http.ResponseWriter, r *http.Request, status int, code, message string) {
	if tracked, ok := w.(*transferWriter); ok {
		tracked.errorCode = code
	}
	if status >= 500 {
		apierr.WriteWithRequestID(w, status, code, message, nil, reqctx.ID(r.Context()))
		return
	}
	apierr.Write(w, status, code, message, nil)
}

// deviceFromBearer 用 Bearer 设备令牌认人；ok=false 时调用方回 401。
//
// 认出来之后把身份记进请求作用域（访问日志的 agentId/deviceId 由此而来）。
func (h *Handlers) deviceFromBearer(r *http.Request) (store.Device, bool, error) {
	token := authn.BearerToken(r)
	if token == "" {
		return store.Device{}, false, nil
	}
	if h.store == nil {
		return store.Device{}, false, nil
	}
	device, found, err := h.store.DeviceByToken(r.Context(), token)
	if err == nil && found {
		reqctx.NoteDevice(r.Context(), device.DeviceID)
		reqctx.NoteAgent(r.Context(), device.AgentID)
	}
	return device, found, err
}

// writeStoreError 把仓储错误兜底成 5xx JSON 信封（busy → 503 + Retry-After）。
func (h *Handlers) writeStoreError(w http.ResponseWriter, r *http.Request, err error) {
	if store.IsBusy(err) {
		w.Header().Set("Retry-After", "1")
		h.log.Warn("relay: file request failed",
			"requestId", reqctx.ID(r.Context()), "method", r.Method,
			"route", r.Pattern, "status", http.StatusServiceUnavailable, "error", err)
		writeErrorFor(w, r, http.StatusServiceUnavailable, "db/busy",
			"the relay database is busy; retry shortly")
		return
	}
	h.log.Error("relay: file request failed",
		"requestId", reqctx.ID(r.Context()), "method", r.Method,
		"route", r.Pattern, "error", err)
	writeErrorFor(w, r, http.StatusInternalServerError, "internal/error",
		"the relay could not complete this request")
}
