package httpapi

import (
	"context"
	"net/http"
	"strings"
	"testing"
)

// pushDevice 准备一台已配对设备，返回 deviceId 与设备令牌。
func pushDevice(t *testing.T, api *testAPI) (string, string) {
	t.Helper()
	tenant := api.newTenant("push")
	claimed := api.pairDevice(tenant, "BLACKBOX-iPhone", "")
	return claimed["deviceId"].(string), tokenOf(claimed)
}

func TestDevicesPushRequiresAValidDeviceToken(t *testing.T) {
	api := newTestAPI(t)
	rec := api.do(http.MethodPost, "/devices/push", map[string]any{"apnsToken": "aa"}, "")
	assertEnvelope(t, rec, http.StatusUnauthorized, "auth/invalid-token")
}

func TestDevicesPushValidatesTheTokenField(t *testing.T) {
	api := newTestAPI(t)
	_, token := pushDevice(t, api)

	for name, body := range map[string]any{
		"missing": map[string]any{},
		"null":    map[string]any{"apnsToken": nil},
		"number":  map[string]any{"apnsToken": 5},
		"bool":    map[string]any{"apnsToken": true},
		"array":   map[string]any{"apnsToken": []any{"aa"}},
	} {
		rec := api.do(http.MethodPost, "/devices/push", body, token)
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("%s：状态码 = %d", name, rec.Code)
		}
		payload := decodeJSON(t, rec)
		errorObject := payload["error"].(map[string]any)
		if errorObject["code"] != "request/apns-token" {
			t.Fatalf("%s：错误码 = %v", name, errorObject["code"])
		}
	}
}

func TestDevicesPushOnlyAcceptsTheTwoEnvironmentSpellings(t *testing.T) {
	api := newTestAPI(t)
	_, token := pushDevice(t, api)

	for _, env := range []string{"Sandbox", "SANDBOX", "dev", "development", ""} {
		rec := api.do(http.MethodPost, "/devices/push",
			map[string]any{"apnsToken": strings.Repeat("ab", 32), "env": env}, token)
		if rec.Code != http.StatusBadRequest {
			t.Fatalf("env=%q：状态码 = %d", env, rec.Code)
		}
		payload := decodeJSON(t, rec)
		errorObject := payload["error"].(map[string]any)
		if errorObject["code"] != "request/apns-env" {
			t.Fatalf("env=%q：错误码 = %v", env, errorObject["code"])
		}
	}
}

func TestASandboxTokenRegistersAndLandsInTheDeviceRow(t *testing.T) {
	api := newTestAPI(t)
	deviceID, token := pushDevice(t, api)
	apns := strings.Repeat("9f", 32)
	rec := api.do(http.MethodPost, "/devices/push", map[string]any{
		"apnsToken": apns, "env": "sandbox", "turnEnd": true, "attention": true,
	}, token)
	if rec.Code != http.StatusOK {
		t.Fatalf("登记失败：%d %s", rec.Code, rec.Body.String())
	}
	if payload := decodeJSON(t, rec); payload["ok"] != true {
		t.Fatalf("响应 = %v", payload)
	}
	row, found, err := api.store.DeviceByID(context.Background(), deviceID)
	if err != nil || !found {
		t.Fatalf("DeviceByID: found=%v err=%v", found, err)
	}
	if row.APNSToken == nil || *row.APNSToken != apns {
		t.Fatalf("apnsToken = %v", row.APNSToken)
	}
	if row.APNSEnv == nil || *row.APNSEnv != "sandbox" {
		t.Fatalf("apnsEnv = %v", row.APNSEnv)
	}
	if row.PushTurnEnd != 1 || row.PushAttention != 1 {
		t.Fatalf("开关 = %d/%d", row.PushTurnEnd, row.PushAttention)
	}
	targets, err := api.store.PushTargets(context.Background(), row.AgentID)
	if err != nil || len(targets) != 1 {
		t.Fatalf("该设备应进入推送目标集：targets=%d err=%v", len(targets), err)
	}
}

func TestATokenWithoutAnEnvironmentIsStillAccepted(t *testing.T) {
	api := newTestAPI(t)
	deviceID, token := pushDevice(t, api)
	apns := strings.Repeat("ab", 32)
	rec := api.do(http.MethodPost, "/devices/push", map[string]any{"apnsToken": apns}, token)
	if rec.Code != http.StatusOK {
		t.Fatalf("状态码 = %d %s", rec.Code, rec.Body.String())
	}
	row, _, _ := api.store.DeviceByID(context.Background(), deviceID)
	if row.APNSToken == nil || *row.APNSToken != apns {
		t.Fatalf("apnsToken = %v", row.APNSToken)
	}
	if row.APNSEnv != nil {
		t.Fatalf("apnsEnv = %v，期望 null", *row.APNSEnv)
	}
	targets, _ := api.store.PushTargets(context.Background(), row.AgentID)
	if len(targets) != 0 {
		t.Fatal("没有环境的登记不该成为推送目标")
	}
}

func TestClearingARegistrationOmitsTheEnvironment(t *testing.T) {
	api := newTestAPI(t)
	deviceID, token := pushDevice(t, api)
	api.do(http.MethodPost, "/devices/push", map[string]any{
		"apnsToken": strings.Repeat("cd", 32), "env": "sandbox",
	}, token)
	rec := api.do(http.MethodPost, "/devices/push", map[string]any{"apnsToken": ""}, token)
	if rec.Code != http.StatusOK {
		t.Fatalf("清除失败：%d %s", rec.Code, rec.Body.String())
	}
	row, _, _ := api.store.DeviceByID(context.Background(), deviceID)
	if row.APNSToken != nil || row.APNSEnv != nil {
		t.Fatalf("清除后 = token %v / env %v", row.APNSToken, row.APNSEnv)
	}
}

func TestASwitchesOnlyReportKeepsTheToken(t *testing.T) {
	api := newTestAPI(t)
	deviceID, token := pushDevice(t, api)
	apns := strings.Repeat("ef", 32)
	api.do(http.MethodPost, "/devices/push", map[string]any{
		"apnsToken": apns, "env": "sandbox", "turnEnd": true, "attention": true,
	}, token)
	rec := api.do(http.MethodPost, "/devices/push", map[string]any{
		"apnsToken": apns, "env": "sandbox", "turnEnd": true, "attention": false,
	}, token)
	if rec.Code != http.StatusOK {
		t.Fatalf("状态码 = %d %s", rec.Code, rec.Body.String())
	}
	row, _, _ := api.store.DeviceByID(context.Background(), deviceID)
	if row.PushTurnEnd != 1 || row.PushAttention != 0 {
		t.Fatalf("开关 = %d/%d", row.PushTurnEnd, row.PushAttention)
	}
	if row.APNSToken == nil || *row.APNSToken != apns {
		t.Fatalf("令牌被动了：%v", row.APNSToken)
	}
}

func TestATokenIsAcceptedHexLowercaseAsTheAppEncodesIt(t *testing.T) {
	api := newTestAPI(t)
	deviceID, token := pushDevice(t, api)
	apns := strings.Repeat("0a1b2c3d", 8)
	api.do(http.MethodPost, "/devices/push",
		map[string]any{"apnsToken": apns, "env": "sandbox"}, token)
	row, _, _ := api.store.DeviceByID(context.Background(), deviceID)
	if row.APNSToken == nil || *row.APNSToken != apns {
		t.Fatalf("令牌大小写被改：%v", row.APNSToken)
	}
}

func TestAnInvalidBodyIsTreatedAsMissingFields(t *testing.T) {
	api := newTestAPI(t)
	_, token := pushDevice(t, api)
	rec := api.doRaw(http.MethodPost, "/devices/push", []byte("{not json"), token)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("状态码 = %d %s", rec.Code, rec.Body.String())
	}
	payload := decodeJSON(t, rec)
	errorObject := payload["error"].(map[string]any)
	if errorObject["code"] != "request/apns-token" {
		t.Fatalf("错误码 = %v", errorObject["code"])
	}
}
