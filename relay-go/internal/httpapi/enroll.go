package httpapi

import (
	"errors"
	"net/http"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/apierr"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// enrollResponse 是 /agents/enroll 的成功响应。
type enrollResponse struct {
	OK          bool   `json:"ok"`
	AgentID     string `json:"agentId"`
	AgentSecret string `json:"agentSecret"`
	AgentName   string `json:"agentName"`
	AccountID   string `json:"accountId"`
}

// handleAgentsEnroll 用邀请码换一台新电脑的身份（Python api.agents_enroll）。
//
// 没有有效、未用、未过期的邀请码就没有身份。两道预算：
//   - **码桶是闸门**：同一个码失败 5 次后冻结，之后直接 429，不再读库；
//   - **来源桶只记账**：它累计失败供运维查看，但永不否决运营者发出的合法邀请码
//     （2026-09-25 的决定）。所以下面只检查码桶。
func (s *server) handleAgentsEnroll(w http.ResponseWriter, r *http.Request) {
	body, ok := readJSONObject(r)
	if !ok {
		writeError(w, http.StatusBadRequest, "enroll/bad-request", "body must be a JSON object", nil)
		return
	}
	code := stringValue(body["inviteCode"])
	if trimSpace(code) == "" {
		writeError(w, http.StatusBadRequest, "enroll/bad-request", "inviteCode is required", nil)
		return
	}
	agentName := "My computer"
	if name := trimSpace(stringValue(body["name"])); name != "" {
		agentName = name
	}

	codeKey := store.HashInviteCode(code)
	clientKey := ClientIdentifier(r)
	if s.enrollLimiter.Blocked(codeKey) {
		writeError(w, http.StatusTooManyRequests, "enroll/rate-limited",
			"too many failed attempts for that invite code; try again later", nil)
		return
	}

	result, err := s.store.ClaimInvite(r.Context(), code, agentName, s.enrollLimiter,
		codeKey, clientKey)
	if err != nil {
		var limited *store.RateLimited
		var rejected *store.InviteRejected
		var storeErr *store.StoreError
		switch {
		case errors.As(err, &limited):
			// 并发请求先把桶填满了；这次连行都没读，不再收费。
			s.log().Info("relay: invite rate-limited",
				"failuresTotal", s.enrollLimiter.FailuresTotal())
			writeError(w, http.StatusTooManyRequests, "enroll/rate-limited",
				"too many failed attempts for that invite code; try again later", nil)
			return
		case errors.As(err, &rejected):
			s.log().Info("relay: invite rejected", "reason", rejected.Reason)
			writeError(w, http.StatusNotFound, "enroll/"+rejected.Reason, rejected.Message, nil)
			return
		case errors.As(err, &storeErr):
			// 邀请码看着没问题、但建身份失败：事务已回滚，码仍可兑换。
			s.log().Warn("relay: invite redemption failed", "error", err)
			apierr.WriteFor(w, r, http.StatusInternalServerError, "enroll/store-error",
				"the relay could not complete the enrollment", nil)
			return
		default:
			apierr.WriteStoreError(w, r, s.log(), store.IsBusy, err,
				"internal/error", "the relay could not complete this request")
			return
		}
	}

	s.enrollLimiter.Reset(codeKey)
	s.enrollLimiter.Reset(clientKey)
	s.log().Info("relay: enrolled agent from an invite", "agentId", result.AgentID)
	writeJSON(w, http.StatusOK, enrollResponse{
		OK: true, AgentID: result.AgentID, AgentSecret: result.AgentSecret,
		AgentName: result.AgentName, AccountID: result.AccountID,
	})
}
