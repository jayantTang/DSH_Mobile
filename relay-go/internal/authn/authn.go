// Package authn 是 HTTP/WebSocket 共用的"凭据从哪里取"的唯一实现。
//
// HTTP 面与 WS 握手都要回答同一个问题：这次请求带着哪枚 Bearer 令牌。设备侧还有
// 第二处：浏览器无法在 WS 握手设置 Authorization 头，所以额外接受
// `Sec-WebSocket-Protocol: dsh.device.<token>`。两处口径若各写一份就会漂移，因此
// 只在这里定义一次。
package authn

import (
	"net/http"
	"strings"
)

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
