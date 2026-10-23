package httpapi

import (
	"net"
	"net/http"
	"strings"
)

// forwardedFor 是前置（Caddy header_up X-Real-IP / X-Forwarded-For）必须设置的请求头。
const forwardedFor = "X-Forwarded-For"

// peerHost 取 socket 对端地址（去掉端口）。
func peerHost(remoteAddr string) string {
	host, _, err := net.SplitHostPort(strings.TrimSpace(remoteAddr))
	if err != nil {
		return strings.TrimSpace(remoteAddr)
	}
	return host
}

// isLoopback 判断一个地址是不是回环地址。
//
// 这是中转的**信任边界**：凡是要回答"这个请求真的来自我们自己的前置吗"的地方
// ——X-Forwarded-For 与运维用的 /stats——都只问它，答案不会各自漂移。
func isLoopback(value string) bool {
	if value == "" {
		return false
	}
	text := strings.TrimSpace(value)
	if strings.HasPrefix(text, "[") && strings.HasSuffix(text, "]") {
		text = text[1 : len(text)-1] // IPv6 字面量带方括号
	}
	text = strings.TrimPrefix(text, "::ffff:") // 双栈主机上报的 IPv4-mapped IPv6
	if ip := net.ParseIP(text); ip != nil {
		return ip.IsLoopback()
	}
	// 主机名形态（unix socket 对端、localhost）只认 localhost；其余一律不可信。
	return text == "localhost"
}

// ClientIdentifier 是限流桶的键（Python api.client_identifier）。
//
// 前面有前置时所有请求都来自 127.0.0.1，只用 socket 对端会把全互联网放进一个桶。
// 规则：
//   - 对端是回环**且** X-Forwarded-For 可用 → 取最左一项（部署的 Caddy 是替换语义）；
//   - 其余情况一律用 socket 对端，完全忽略该头（客户端可以自己伪造它）。
//
// 导出是因为 feedback 的限流桶键也要用它：子 handler 在组合根构造（DESIGN §2.5），
// 而"客户端是什么"的信任边界只允许有一份实现。
func ClientIdentifier(r *http.Request) string {
	peer := strings.TrimSpace(peerHost(r.RemoteAddr))
	if isLoopback(peer) {
		forwarded := r.Header.Get(forwardedFor)
		if first, _, _ := strings.Cut(forwarded, ","); strings.TrimSpace(first) != "" {
			return strings.TrimSpace(first)
		}
	}
	if peer != "" {
		return peer
	}
	return "unknown"
}
