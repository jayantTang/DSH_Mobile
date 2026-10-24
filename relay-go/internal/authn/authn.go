// Package authn 是 HTTP/WebSocket 共用的"凭据从哪里取"的唯一实现。
//
// HTTP 面与 WS 握手都要回答同一个问题：这次请求带着哪枚 Bearer 令牌。设备侧还有
// 第二处：浏览器无法在 WS 握手设置 Authorization 头，所以额外接受
// `Sec-WebSocket-Protocol: dsh.device.<token>`。两处口径若各写一份就会漂移，因此
// 只在这里定义一次。
package authn

import (
	"context"
	"net/http"
	"strings"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/reqctx"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// DeviceByTokenStore 是 DeviceFromBearer 需要的最小仓储端口（1 个方法）。
//
// *store.Store 天然满足它；httpapi 与 files 各自的窄端口（都含 DeviceByToken）
// 可以直接传入，测试里的 fake 同理。
type DeviceByTokenStore interface {
	DeviceByToken(ctx context.Context, token string) (store.Device, bool, error)
}

// DeviceFromBearer 用 Bearer 设备令牌认人；ok=false 时调用方回 401。
//
// 认出来之后把 deviceId/agentId 记进请求作用域：访问日志的两个身份字段由此而来，
// 没有第二条"日志自己解析令牌"的路径。
func DeviceFromBearer(ctx context.Context, st DeviceByTokenStore, r *http.Request) (store.Device, bool, error) {
	token := BearerToken(r)
	if token == "" {
		return store.Device{}, false, nil
	}
	device, found, err := st.DeviceByToken(ctx, token)
	if err == nil && found {
		reqctx.NoteDevice(ctx, device.DeviceID)
		reqctx.NoteAgent(ctx, device.AgentID)
	}
	return device, found, err
}

// DeviceSubprotocolPrefix 是设备子协议凭据的固定前缀（Python 的
// DEVICE_SUBPROTOCOL_PREFIX）：后缀是设备令牌原文。
const DeviceSubprotocolPrefix = "dsh.device."

// BearerToken 从 Authorization 头取 Bearer 令牌；缺失或格式不对返回空串。
func BearerToken(r *http.Request) string {
	scheme, value, found := strings.Cut(r.Header.Get("Authorization"), " ")
	if !found || !strings.EqualFold(scheme, "bearer") {
		return ""
	}
	return strings.TrimSpace(value)
}

// DeviceSubprotocolToken 从 Sec-WebSocket-Protocol 里取出设备令牌；没有时返回空串。
//
// 多个候选协议用逗号分隔，只认第一枚带前缀的。
func DeviceSubprotocolToken(r *http.Request) string {
	for _, item := range strings.Split(r.Header.Get("Sec-WebSocket-Protocol"), ",") {
		candidate := strings.TrimSpace(item)
		if !strings.HasPrefix(candidate, DeviceSubprotocolPrefix) {
			continue
		}
		if token := strings.TrimSpace(strings.TrimPrefix(candidate, DeviceSubprotocolPrefix)); token != "" {
			return token
		}
	}
	return ""
}

// DeviceProtocolsOffered 返回客户端提出的、需要中转回显的 `dsh.device.*` 子协议。
//
// 回显是 WebSocket 规范里"服务端接受了这个子协议"的唯一信号：不回显时浏览器与
// 客户端库都可能把握手判为失败（Python 版同样是显式回显，见 relay._make_socket）。
func DeviceProtocolsOffered(r *http.Request) []string {
	var offered []string
	for _, item := range strings.Split(r.Header.Get("Sec-WebSocket-Protocol"), ",") {
		candidate := strings.TrimSpace(item)
		if strings.HasPrefix(candidate, DeviceSubprotocolPrefix) {
			offered = append(offered, candidate)
		}
	}
	return offered
}
