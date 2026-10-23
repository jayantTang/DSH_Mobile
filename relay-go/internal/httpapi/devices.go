package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/dlp"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// apnsEnvs 是推送登记接受的两种环境。令牌与环境绑定，送错主机 APNs 会回
// BadDeviceToken，从手机上看就像"推送坏了"（见 internal/push）。
var apnsEnvs = map[string]struct{}{"sandbox": {}, "production": {}}

// jsonFlag 复刻 Python 的 `_flag(value, fallback)`：缺省与 null 取 fallback，
// 其余按 bool() 的真值判定（空串、0、空数组/对象为假）。
func jsonFlag(value any, fallback bool) bool {
	if value == nil {
		return fallback
	}
	switch typed := value.(type) {
	case bool:
		return typed
	case string:
		return typed != ""
	case []any:
		return len(typed) > 0
	case map[string]any:
		return len(typed) > 0
	case json.Number:
		number, err := typed.Float64()
		if err != nil {
			return true
		}
		return number != 0
	default:
		return true
	}
}

// deviceRow 是 /devices 列表里的一行（字段与 Python api.devices_list 一致）。
type deviceRow struct {
	DeviceID   string  `json:"deviceId"`
	Name       string  `json:"name"`
	Model      *string `json:"model"`
	CreatedAt  int64   `json:"createdAt"`
	LastSeenAt *int64  `json:"lastSeenAt"`
	Revoked    bool    `json:"revoked"`
}

// devicesListResponse 是 /devices 的响应。
type devicesListResponse struct {
	OK               bool        `json:"ok"`
	CurrentDeviceID  string      `json:"currentDeviceId"`
	MaxPairedDevices int         `json:"maxPairedDevices"`
	PairedDevices    int         `json:"pairedDevices"`
	Devices          []deviceRow `json:"devices"`
}

// handleDevicesList 列出调用方自己那台电脑名下的设备（Python api.devices_list）。
//
// 用设备令牌鉴权而不是运维凭据：手机要能看和管理自己的配对，但看不到别人的。
func (s *server) handleDevicesList(w http.ResponseWriter, r *http.Request) {
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

	devices, err := s.store.ListDevices(r.Context(), device.AgentID, false)
	if err != nil {
		s.writeStoreError(w, r, err)
		return
	}
	paired, err := s.store.CountPairedDevices(r.Context(), device.AccountID)
	if err != nil {
		s.writeStoreError(w, r, err)
		return
	}

	rows := make([]deviceRow, 0, len(devices))
	for _, row := range devices {
		rows = append(rows, deviceRow{
			DeviceID: row.DeviceID, Name: row.Name, Model: row.Model,
			CreatedAt: row.CreatedAt, LastSeenAt: row.LastSeenAt,
			Revoked: row.RevokedAt != nil,
		})
	}
	writeJSON(w, http.StatusOK, devicesListResponse{
		OK: true, CurrentDeviceID: device.DeviceID,
		MaxPairedDevices: s.maxPairedDevices, PairedDevices: paired, Devices: rows,
	})
}

// devicesRevokeResponse 是 /devices/revoke 的响应；iOS 侧在解这个结构，不要改。
type devicesRevokeResponse struct {
	OK       bool   `json:"ok"`
	DeviceID string `json:"deviceId"`
}

// handleDevicesRevoke 撤销调用方自己那台电脑名下的一台设备（Python api.devices_revoke）。
//
// 归属校验是必须的：没有它，任何一枚有效设备令牌都能把中转上所有手机解绑。
//
// 撤销不能只是改库：留着的 socket 会继续用一枚已经无效的令牌收帧，连接器也会继续
// 为它保留 $events 值班流。所以落库之后立刻断开在线的那条，并让连接器收到
// `deviceDetach(reason="revoked")`——那是它放下这台设备的唯一信号。
func (s *server) handleDevicesRevoke(w http.ResponseWriter, r *http.Request) {
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

	body, _ := readJSONObject(r)
	target := stringValue(body["deviceId"])
	if target == "" {
		writeError(w, http.StatusBadRequest, "request/device-id", "deviceId is required", nil)
		return
	}

	row, found, err := s.store.DeviceByID(r.Context(), target)
	if err != nil {
		s.writeStoreError(w, r, err)
		return
	}
	if !found {
		writeError(w, http.StatusNotFound, "request/unknown-device", "no such device", nil)
		return
	}
	if row.AgentID != device.AgentID {
		writeError(w, http.StatusForbidden, "auth/agent-mismatch",
			"that device belongs to another agent", nil)
		return
	}

	if err := s.store.RevokeDevice(r.Context(), target); err != nil {
		var notFound *store.NotFound
		if errors.As(err, &notFound) {
			writeError(w, http.StatusNotFound, "request/unknown-device", "no such device", nil)
			return
		}
		s.writeStoreError(w, r, err)
		return
	}
	// 断开是异步的（关闭握手由连接的写循环执行），HTTP 响应不等它。
	s.hub.DropDevice(target, "revoked", dlp.CloseGoingAway)
	writeJSON(w, http.StatusOK, devicesRevokeResponse{OK: true, DeviceID: target})
}

// devicesPushResponse 是 /devices/push 的响应；iOS 侧只认 ok。
type devicesPushResponse struct {
	OK bool `json:"ok"`
}

// handleDevicesPush 登记（或清除）本机的 APNs 令牌与两个提醒开关
// （Python api.devices_push）。
//
// 用设备令牌鉴权：手机只管自己的登记，碰不到别人的。App 在启动时、令牌变化时、
// 设置里任一开关移动时调用它；用户关掉通知权限时带空令牌调用——"我说不"必须
// 真的能停止推送，所以清除要和登记一样容易。
func (s *server) handleDevicesPush(w http.ResponseWriter, r *http.Request) {
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

	body, parsed := readJSONObject(r)
	if !parsed {
		// Python 是 `await read_json(request) or {}`：坏正文按空对象处理，
		// 于是"缺 apnsToken"的 400 才是它给出的答案。
		body = map[string]any{}
	}
	rawToken, present := body["apnsToken"]
	token, isString := rawToken.(string)
	if !present || !isString {
		writeError(w, http.StatusBadRequest, "request/apns-token",
			"apnsToken must be a string", nil)
		return
	}
	token = strings.TrimSpace(token)

	rawEnv, hasEnv := body["env"]
	var env *string
	if hasEnv && rawEnv != nil {
		value, isString := rawEnv.(string)
		if !isString {
			writeError(w, http.StatusBadRequest, "request/apns-env",
				"env must be sandbox or production", nil)
			return
		}
		if _, accepted := apnsEnvs[value]; !accepted {
			writeError(w, http.StatusBadRequest, "request/apns-env",
				"env must be sandbox or production", nil)
			return
		}
		env = &value
	}
	if token == "" {
		// 空令牌 = 清除登记。环境一并清掉，免得留下一对不一致的值。
		env = nil
	}

	if err := s.store.SetPush(r.Context(), device.DeviceID, &token, env,
		jsonFlag(body["turnEnd"], true), jsonFlag(body["attention"], true)); err != nil {
		s.writeStoreError(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, devicesPushResponse{OK: true})
}
