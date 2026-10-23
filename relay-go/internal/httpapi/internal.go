package httpapi

import (
	"fmt"
	"net/http"
	"time"
)

// `/internal/*` 是**服务间**端点：信件服务（mail）在同一个机房/同一台机器上调用，
// 不是对外接口。两道门与 Python 版逐项一致：
//
//   - 只认环回来源（socket peer，不是请求头）：公网到达回 404，探测者不该分辨得出
//     这个端点是否存在（与 /stats 同一道守卫、同一个理由）；
//   - 令牌解析另有一份独立预算（DESIGN-20261015 I-1）：600 次/10 分钟，只防 mail
//     侧失控，不是对外防线。
const (
	internalResolveLimit  = 600
	internalResolveWindow = 10 * time.Minute
)

// tokenResolveResponse 是 POST /internal/tokens/resolve 的响应。
//
// 机型/版本不在返回里：信件线程行需要的展示字段由 App 随请求体自带并快照，
// mail 不需要持续的设备元数据。
type tokenResolveResponse struct {
	DeviceID  string `json:"deviceId"`
	AccountID string `json:"accountId"`
	ExpiresAt int64  `json:"expiresAt"`
}

// handleInternalTokenResolve 让信件服务拿设备令牌换账号/设备归属。
//
// 只读、幂等、无副作用。未知 / 撤销 / 过期 / 格式不对一律 404，与既有"坏令牌
// 降级匿名"的语义一致，不给调用方区分"撤销"与"不存在"。
func (s *server) handleInternalTokenResolve(w http.ResponseWriter, r *http.Request) {
	if !isLoopback(peerHost(r.RemoteAddr)) {
		s.log().Info("relay: refused /internal/tokens/resolve for non-loopback peer",
			"peer", r.RemoteAddr)
		writeError(w, http.StatusNotFound, "not-found", "not found", nil)
		return
	}
	if s.internalResolveLimiter.Blocked("resolve") {
		writeError(w, http.StatusTooManyRequests, "internal/rate-limited",
			"too many resolve requests", nil)
		return
	}
	s.internalResolveLimiter.CountFailure("resolve", false)

	body, ok := readJSONObject(r)
	if !ok {
		writeError(w, http.StatusBadRequest, "internal/bad-request",
			`body must be {"token": "..."}`, nil)
		return
	}
	token, ok := body["token"].(string)
	if !ok || token == "" {
		writeError(w, http.StatusBadRequest, "internal/bad-request",
			`body must be {"token": "..."}`, nil)
		return
	}
	// 纯空白不是"缺字段"：它被当成一个令牌去查，结果与任何未知令牌相同（404）。
	device, found, err := s.store.DeviceByToken(r.Context(), token)
	if err != nil {
		s.writeStoreError(w, r, err)
		return
	}
	if !found {
		writeError(w, http.StatusNotFound, "internal/not-found", "token not found", nil)
		return
	}
	writeJSON(w, http.StatusOK, tokenResolveResponse{
		DeviceID:  device.DeviceID,
		AccountID: device.AccountID,
		ExpiresAt: device.ExpiresAt,
	})
}

// handleInternalAccountStateTouch 在信件"已读"落库后通知同账户的其他设备。
//
// mail 与 relay 是两个进程、两张库。信件的已读本来就是账户级，这里**不写任何
// 状态**，只是借中转的在线连接扇一帧"去看看信件"——否则同一个人两台手机，一台
// 读过的未读蓝点要在另一台上等到下次前台刷新才消失。
func (s *server) handleInternalAccountStateTouch(w http.ResponseWriter, r *http.Request) {
	if !isLoopback(peerHost(r.RemoteAddr)) {
		s.log().Info("relay: refused /internal/account-state/touch for non-loopback peer",
			"peer", r.RemoteAddr)
		writeError(w, http.StatusNotFound, "not-found", "not found", nil)
		return
	}

	body, ok := readJSONObject(r)
	if !ok {
		body = map[string]any{} // 与 Python 的 `read_json(request) or {}` 同口径
	}
	accountID, _ := body["accountId"].(string)
	if accountID == "" {
		writeError(w, http.StatusBadRequest, "internal/bad-request",
			`body must be {"accountId": "..."}`, nil)
		return
	}
	keys := []string{"feedback"}
	if raw, ok := body["keys"].([]any); ok && len(raw) > 0 {
		keys = make([]string, 0, len(raw))
		for _, item := range raw {
			keys = append(keys, internalKey(item))
		}
	}
	sent := s.hub.NotifyAccountState(accountID, keys, "")
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "notified": sent})
}

// internalKey 把请求体里的一个 key 转成字符串（Python 的 str(item)）。
func internalKey(value any) string {
	if text, ok := value.(string); ok {
		return text
	}
	return fmt.Sprint(value)
}
