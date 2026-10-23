package httpapi

import (
	"encoding/json"
	"net/http"
	"strings"
	"unicode/utf8"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// 与 Python api.py 一致的两个上限：一条状态 8 KiB，一次最多 64 条。
const (
	maxAccountStateBytes   = 8 * 1024
	maxAccountStateEntries = 64
	// 单条 key 的字符上限（Python: len(key) > 200）。
	maxAccountStateKeyChars = 200
)

// accountStateGetResponse 是 GET /account/state 的响应。
type accountStateGetResponse struct {
	OK        bool                        `json:"ok"`
	AccountID string                      `json:"accountId"`
	Entries   map[string]store.StateValue `json:"entries"`
}

// accountStatePutResponse 是 PUT /account/state 的响应。
//
// Applied 按请求里的条目顺序；Entries 是每个 key 写入（或未被覆盖）后的结果。
type accountStatePutResponse struct {
	OK      bool                         `json:"ok"`
	Applied []string                     `json:"applied"`
	Entries map[string]store.StoredState `json:"entries"`
}

// handleAccountStateGet 读调用方账户的状态条目（Python api.account_state_get）。
//
// 账号从设备令牌反查，请求里不接受 accountId——否则就是越权读别人。
func (s *server) handleAccountStateGet(w http.ResponseWriter, r *http.Request) {
	device, ok, err := s.deviceFromBearer(r)
	if err != nil {
		s.writeStoreError(w, r, err)
		return
	}
	if !ok {
		writeError(w, http.StatusUnauthorized, "auth/invalid-token",
			"a valid device token is required", nil)
		return
	}

	keys := []string{}
	for _, part := range strings.Split(r.URL.Query().Get("keys"), ",") {
		if trimmed := strings.TrimSpace(part); trimmed != "" {
			keys = append(keys, trimmed)
		}
		if len(keys) >= maxAccountStateEntries {
			break
		}
	}

	state, err := s.store.AccountState(r.Context(), device.AccountID, keys)
	if err != nil {
		s.writeStoreError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, accountStateGetResponse{
		OK: true, AccountID: device.AccountID, Entries: state,
	})
}

// handleAccountStatePut 批量写账户状态，只前进不后退（Python api.account_state_put）。
//
// 与 Python 版的一处有意差异（DESIGN §6 要求的修复）：整批先校验、再在一个事务里
// 写入。Python 逐条提交，第 3 条校验失败时前两条已经生效；Go 版要么 64 条全生效，
// 要么全不生效。
func (s *server) handleAccountStatePut(w http.ResponseWriter, r *http.Request) {
	// 先认人，再挑 body 的毛病：未认证的调用者不该从错误信息里读出参数校验细节。
	device, ok, err := s.deviceFromBearer(r)
	if err != nil {
		s.writeStoreError(w, r, err)
		return
	}
	if !ok {
		writeError(w, http.StatusUnauthorized, "auth/invalid-token",
			"a valid device token is required", nil)
		return
	}

	badRequest := func(message string) {
		writeError(w, http.StatusBadRequest, "account-state/bad-request", message, nil)
	}

	body, ok := readJSONObject(r)
	if !ok {
		badRequest("body must be a JSON object")
		return
	}
	rawEntries, ok := body["entries"].([]any)
	if !ok || len(rawEntries) == 0 {
		badRequest("entries must be a non-empty array")
		return
	}
	if len(rawEntries) > maxAccountStateEntries {
		badRequest("at most 64 entries per request")
		return
	}

	writes := make([]store.StateWrite, 0, len(rawEntries))
	for _, rawEntry := range rawEntries {
		entry, ok := rawEntry.(map[string]any)
		if !ok {
			badRequest("each entry must be an object")
			return
		}
		key, ok := entry["key"].(string)
		if !ok || key == "" || utf8.RuneCountInString(key) > maxAccountStateKeyChars {
			badRequest("each entry needs a short string key")
			return
		}
		stamp, ok := jsonInt(entry["updatedAt"])
		if !ok || stamp <= 0 {
			badRequest("each entry needs an integer updatedAt (ms)")
			return
		}
		value, err := marshalCompact(entry["value"])
		if err != nil {
			badRequest("each entry needs a JSON value")
			return
		}
		if len(value) > maxAccountStateBytes {
			writeError(w, http.StatusRequestEntityTooLarge, "account-state/too-large",
				"one entry may be at most 8192 bytes", nil)
			return
		}
		writes = append(writes, store.StateWrite{
			Key: key, Value: json.RawMessage(value), UpdatedAt: stamp,
		})
	}

	deviceID := device.DeviceID
	result, err := s.store.PutAccountStateBatch(r.Context(), device.AccountID, writes, &deviceID)
	if err != nil {
		s.writeStoreError(w, r, err)
		return
	}

	// 同账户其他在线设备的实时通知（Python hub.notify_account_state）。
	//
	// 尽力而为：入队失败就当没发，不重试、不阻断写入方——最终一致性靠客户端前台
	// 拉取兜底。排除写入者：它自己刚写完，本机已经改了。
	if len(result.Applied) > 0 {
		s.hub.NotifyAccountState(device.AccountID, result.Applied, device.DeviceID)
	}
	writeJSON(w, http.StatusOK, accountStatePutResponse{
		OK: true, Applied: result.Applied, Entries: result.Stored,
	})
}
