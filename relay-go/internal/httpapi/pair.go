package httpapi

import (
	"context"
	"errors"
	"net/http"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/apierr"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// pairClaimResponse 是 /pair/claim 的成功响应（字段与 Python 版逐项一致）。
type pairClaimResponse struct {
	OK          bool   `json:"ok"`
	AgentID     string `json:"agentId"`
	AgentName   string `json:"agentName"`
	AccountID   string `json:"accountId"`
	DeviceID    string `json:"deviceId"`
	DeviceToken string `json:"deviceToken"`
	ExpiresAt   int64  `json:"expiresAt"`
	Reused      bool   `json:"reused"`
}

// pairRefreshResponse 是 /pair/refresh 的成功响应。
type pairRefreshResponse struct {
	OK          bool   `json:"ok"`
	DeviceID    string `json:"deviceId"`
	AgentID     string `json:"agentId"`
	AccountID   string `json:"accountId"`
	DeviceToken string `json:"deviceToken"`
	ExpiresAt   int64  `json:"expiresAt"`
}

// pairCodeResponse 是 /pair/code 与 /pair/code/regenerate 的成功响应。
type pairCodeResponse struct {
	OK               bool   `json:"ok"`
	Code             string `json:"code"`
	ExpiresAt        *int64 `json:"expiresAt"`
	AgentID          string `json:"agentId"`
	TTLMs            *int64 `json:"ttlMs"`
	Persistent       bool   `json:"persistent"`
	Revoked          *int64 `json:"revoked,omitempty"`
	MaxPairedDevices int    `json:"maxPairedDevices"`
	PairedDevices    int    `json:"pairedDevices"`
}

// pairRejectionCodes 是 store 拒绝原因到线上错误码的映射（Python 同名字典）。
//
// "used" 留给老库/老日志：持久码可以反复认领，正常路径不会再产生它。
var pairRejectionCodes = map[string]string{
	"unknown": "pair/invalid-code",
	"used":    "pair/used-code",
	"expired": "pair/expired-code",
	"revoked": "pair/revoked-code",
}

// handlePairClaim 兑换配对码并签发设备令牌（Python api.pair_claim）。
func (s *server) handlePairClaim(w http.ResponseWriter, r *http.Request) {
	body, ok := readJSONObject(r)
	if !ok {
		writeError(w, http.StatusBadRequest, "pair/bad-request", "body must be a JSON object", nil)
		return
	}
	code := stringValue(body["pairCode"])
	if trimSpace(code) == "" {
		writeError(w, http.StatusBadRequest, "pair/bad-request", "pairCode is required", nil)
		return
	}

	peer := ClientIdentifier(r)
	if s.claimLimiter.Blocked(peer) {
		writeError(w, http.StatusTooManyRequests, "pair/rate-limited",
			"too many failed pairing attempts; try again later", nil)
		return
	}

	deviceName := "iOS device"
	if name := stringValue(body["deviceName"]); name != "" {
		deviceName = name
	}
	var model, appVersion *string
	if value, ok := body["deviceModel"].(string); ok {
		model = &value
	}
	if value, ok := body["appVersion"].(string); ok {
		appVersion = &value
	}
	// deviceKey 格式非法按"没带"处理：不因为一个坏字段拒绝整次认领。
	var deviceKey string
	if raw := stringValue(body["deviceKey"]); raw != "" {
		trimmed := trimSpace(raw)
		if store.ValidateDeviceKey(trimmed) {
			deviceKey = trimmed
		}
	}

	result, err := s.store.ClaimPairCode(r.Context(), code, store.ClaimParams{
		DeviceName:       deviceName,
		Model:            model,
		AppVersion:       appVersion,
		TTLMS:            s.deviceTTLMS,
		DeviceKey:        deviceKey,
		MaxPairedDevices: s.maxPairedDevices,
	})
	if err != nil {
		var limitErr *store.PairedDeviceLimitReached
		var rejection *store.PairCodeClaimRejected
		var notFound *store.NotFound
		switch {
		case errors.As(err, &limitErr):
			// 设备数到顶与猜测无关：清空失败预算，别让用户"再试一次"就撞限流。
			s.claimLimiter.Reset(peer)
			s.log().Info("relay: pair claim refused: paired device limit reached",
				"peer", peer, "live", limitErr.Live, "limit", limitErr.Limit)
			writeError(w, http.StatusConflict, "limit/devices",
				"this account already has as many paired devices as it allows;"+
					" remove one in the app's device list and try again",
				map[string]any{
					"maxPairedDevices": limitErr.Limit,
					"pairedDevices":    limitErr.Live,
				})
			return
		case errors.As(err, &rejection):
			s.claimLimiter.RecordFailure(peer)
			s.log().Info("relay: pair claim rejected",
				"peer", peer, "reason", rejection.Reason, "details", rejection.Details)
			writeError(w, http.StatusNotFound, pairRejectionCodes[rejection.Reason],
				rejection.Message, nil)
			return
		case errors.As(err, &notFound):
			s.claimLimiter.RecordFailure(peer)
			s.log().Info("relay: pair claim rejected", "peer", peer, "error", err)
			writeError(w, http.StatusNotFound, "pair/invalid-code", err.Error(), nil)
			return
		default:
			apierr.WriteStoreError(w, r, s.log(), store.IsBusy, err,
				"internal/error", "the relay could not complete this request")
			return
		}
	}

	s.claimLimiter.Reset(peer)
	s.log().Info("relay: paired device", "deviceId", result.DeviceID, "agentId", result.AgentID)
	writeJSON(w, http.StatusOK, pairClaimResponse{
		OK: true, AgentID: result.AgentID, AgentName: result.AgentName,
		AccountID: result.AccountID, DeviceID: result.DeviceID,
		DeviceToken: result.DeviceToken, ExpiresAt: result.ExpiresAt, Reused: result.Reused,
	})
}

// handlePairRefresh 轮换设备令牌（Python api.pair_refresh）。
func (s *server) handlePairRefresh(w http.ResponseWriter, r *http.Request) {
	body, _ := readJSONObject(r)
	token := bearerToken(r)
	if token == "" {
		token = stringValue(body["deviceToken"])
	}
	if token == "" {
		writeError(w, http.StatusUnauthorized, "auth/missing-token", "device token is required", nil)
		return
	}

	result, err := s.store.RefreshDevice(r.Context(), token, s.deviceTTLMS)
	if err != nil {
		var notFound *store.NotFound
		if errors.As(err, &notFound) {
			writeError(w, http.StatusUnauthorized, "auth/invalid-token", err.Error(), nil)
			return
		}
		apierr.WriteStoreError(w, r, s.log(), store.IsBusy, err,
			"internal/error", "the relay could not complete this request")
		return
	}
	writeJSON(w, http.StatusOK, pairRefreshResponse{
		OK: true, DeviceID: result.DeviceID, AgentID: result.AgentID,
		AccountID: result.AccountID, DeviceToken: result.DeviceToken, ExpiresAt: result.ExpiresAt,
	})
}

// handlePairCode 铸一枚配对码（Python api.pair_code）。
//
// 默认铸**持久码**：不带 ttlMs、显式 null、或 persistent:true 都表示不过期；
// 带正数 ttlMs 的老连接器仍是限时码，行为不变。
func (s *server) handlePairCode(w http.ResponseWriter, r *http.Request) {
	body, _ := readJSONObject(r)
	agent, ok := s.agentFromBearer(w, r)
	if !ok {
		return
	}
	if wanted := stringValue(body["agentId"]); wanted != "" && wanted != agent.AgentID {
		writeError(w, http.StatusForbidden, "auth/agent-mismatch",
			"token does not belong to that agent", nil)
		return
	}

	ttlMS := s.pairTTLFromBody(body, false)
	minted, err := s.store.MintPairCode(r.Context(), agent.AgentID, ttlMS)
	if err != nil {
		apierr.WriteStoreError(w, r, s.log(), store.IsBusy, err,
			"internal/error", "the relay could not complete this request")
		return
	}
	writeJSON(w, http.StatusOK, s.pairCodePayload(r.Context(), minted, nil, agent.AccountID))
}

// handlePairCodeRegenerate 作废该 agent 现存的所有码，再铸一枚新的（Python
// api.pair_code_regenerate）。不碰 devices：换码不该把已在用的设备踢下线。
func (s *server) handlePairCodeRegenerate(w http.ResponseWriter, r *http.Request) {
	body, _ := readJSONObject(r)
	agent, ok := s.agentFromBearer(w, r)
	if !ok {
		return
	}
	if wanted := stringValue(body["agentId"]); wanted != "" && wanted != agent.AgentID {
		writeError(w, http.StatusForbidden, "auth/agent-mismatch",
			"token does not belong to that agent", nil)
		return
	}

	ttlMS := s.pairTTLFromBody(body, true)
	minted, revoked, err := s.store.RegeneratePairCode(r.Context(), agent.AgentID, ttlMS)
	if err != nil {
		apierr.WriteStoreError(w, r, s.log(), store.IsBusy, err,
			"internal/error", "the relay could not complete this request")
		return
	}
	s.log().Info("relay: regenerated pairing code", "agentId", agent.AgentID, "revoked", revoked)
	writeJSON(w, http.StatusOK, s.pairCodePayload(r.Context(), minted, &revoked, agent.AccountID))
}

// agentFromBearer 用 Bearer 电脑凭据认人；失败时已经写好 401 响应并返回 false。
func (s *server) agentFromBearer(w http.ResponseWriter, r *http.Request) (store.Agent, bool) {
	token := bearerToken(r)
	if token == "" {
		writeError(w, http.StatusUnauthorized, "auth/invalid-agent",
			"a valid agent bearer token is required", nil)
		return store.Agent{}, false
	}
	agent, ok, err := s.store.AgentBySecret(r.Context(), token)
	if err != nil {
		apierr.WriteStoreError(w, r, s.log(), store.IsBusy, err,
			"internal/error", "the relay could not complete this request")
		return store.Agent{}, false
	}
	if !ok {
		writeError(w, http.StatusUnauthorized, "auth/invalid-agent",
			"a valid agent bearer token is required", nil)
		return store.Agent{}, false
	}
	return agent, true
}

// pairTTLFromBody 解析铸码请求的有效期（Python api.pair_code 的 ttl 规则）。
//
// regenerate=true 时口径略有不同（Python 版就是这么写的）：只有显式
// persistent:false 才是限时码；铸码接口则是"没给 ttlMs / 给了 null"都算持久。
func (s *server) pairTTLFromBody(body map[string]any, regenerate bool) *int64 {
	persistent := true
	if regenerate {
		// Python: body.get("persistent") is not False —— 只有显式布尔 false 才限时。
		if flag, ok := body["persistent"].(bool); ok && !flag {
			persistent = false
		}
	} else {
		// Python: body.get("persistent") is True or body.get("ttlMs") is None。
		flagIsTrue := false
		if flag, ok := body["persistent"].(bool); ok && flag {
			flagIsTrue = true
		}
		requested, hasTTL := body["ttlMs"]
		persistent = flagIsTrue || !hasTTL || requested == nil
	}
	if persistent {
		return nil
	}

	ttl := s.pairTTLMS
	if requested, ok := jsonInt(body["ttlMs"]); ok && requested > 0 {
		ttl = requested
	}
	// 与 Python 一致：网页/连接器自助铸的限时码最多一小时。
	const maxTTLMS int64 = 60 * 60 * 1000
	if ttl > maxTTLMS {
		ttl = maxTTLMS
	}
	return &ttl
}

// pairCodePayload 组装铸码响应：码本身 + "还能配几台"（以中转的库为准）。
func (s *server) pairCodePayload(ctx context.Context, minted store.MintedPairCode,
	revoked *int64, accountID string) pairCodeResponse {
	paired, err := s.store.CountPairedDevices(ctx, accountID)
	if err != nil {
		// 这里失败不该把已经铸好的码丢掉：数字回 0，错误进日志。
		s.log().Warn("relay: could not count paired devices", "error", err)
	}
	return pairCodeResponse{
		OK: true, Code: minted.Code, ExpiresAt: minted.ExpiresAt, AgentID: minted.AgentID,
		TTLMs: minted.TTLMs, Persistent: minted.Persistent, Revoked: revoked,
		MaxPairedDevices: s.maxPairedDevices, PairedDevices: paired,
	}
}
