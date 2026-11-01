package httpapi

import (
	"net/http"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/apierr"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/authn"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

type machineResponse struct {
	OK         bool   `json:"ok"`
	AgentID    string `json:"agentId"`
	MacAddress string `json:"macAddress"`
	Updated    bool   `json:"updated"`
}

// handleAgentsMachine 让已登记的老连接器补报 MAC，认证用 agent secret。
// 只填空槽：已有 MAC 时不改写，返回当前值（updated=false）。
func (s *server) handleAgentsMachine(w http.ResponseWriter, r *http.Request) {
	body, ok := readJSONObject(r)
	if !ok {
		writeError(w, http.StatusBadRequest, "enroll/bad-request", "body must be a JSON object", nil)
		return
	}
	raw := ""
	if value, present := body["macAddress"]; present && value != nil {
		text, isString := value.(string)
		if !isString {
			writeError(w, http.StatusBadRequest, "enroll/bad-request", "macAddress must be a string", nil)
			return
		}
		raw = text
	}
	macAddress, valid := normalizeMACAddress(raw)
	if !valid || macAddress == "" {
		writeError(w, http.StatusBadRequest, "enroll/bad-request",
			"macAddress must be a MAC-48 address", nil)
		return
	}
	agent, found, err := authn.AgentFromBearer(r.Context(), s.store, r)
	if err != nil {
		apierr.WriteStoreError(w, r, s.log(), store.IsBusy, err,
			"internal/error", "the relay could not complete this request")
		return
	}
	if !found {
		writeError(w, http.StatusUnauthorized, "auth/invalid-token",
			"a valid agent secret is required", nil)
		return
	}
	stored, updated, err := s.store.SetAgentMAC(r.Context(), agent.AgentID, macAddress)
	if err != nil {
		apierr.WriteStoreError(w, r, s.log(), store.IsBusy, err,
			"internal/error", "the relay could not complete this request")
		return
	}
	current := macAddress
	if stored.MacAddress != nil {
		current = *stored.MacAddress
	}
	writeJSON(w, http.StatusOK, machineResponse{
		OK: true, AgentID: stored.AgentID, MacAddress: current, Updated: updated,
	})
}
