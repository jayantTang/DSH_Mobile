package httpapi

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// wantCapabilities 是 Python 版 api.healthz 的能力清单，逐字抄自
// relay/api.py:311。改这里就说明中转的能力契约变了。
var wantCapabilities = []string{
	"device-subprotocol-auth", "persistent-pair-code",
	"account-state", "account-state-push", "file-transfer",
}

func get(t *testing.T, handler http.Handler, path string) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
	return rec
}

func decodeHealth(t *testing.T, rec *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	if rec.Code != http.StatusOK {
		t.Fatalf("状态码 = %d, 期望 200", rec.Code)
	}
	if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "application/json") {
		t.Fatalf("Content-Type = %q", ct)
	}
	var payload map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &payload); err != nil {
		t.Fatalf("响应不是 JSON: %v (%s)", err, rec.Body.String())
	}
	return payload
}

func TestHealthzDefault(t *testing.T) {
	handler := New(Options{})
	rec := get(t, handler, "/healthz")
	payload := decodeHealth(t, rec)

	if payload["ok"] != true {
		t.Fatalf("ok = %v", payload["ok"])
	}
	if payload["version"] != float64(ProtocolVersion) {
		t.Fatalf("version = %v", payload["version"])
	}
	if payload["relayVersion"] != Unversioned {
		t.Fatalf("relayVersion = %v, 期望 %q", payload["relayVersion"], Unversioned)
	}
	if _, ok := payload["build"]; ok {
		t.Fatalf("没有 build.json 时不该输出 build: %v", payload["build"])
	}

	raw, ok := payload["capabilities"].([]any)
	if !ok {
		t.Fatalf("capabilities 类型 = %T", payload["capabilities"])
	}
	var got []string
	for _, item := range raw {
		got = append(got, item.(string))
	}
	if strings.Join(got, ",") != strings.Join(wantCapabilities, ",") {
		t.Fatalf("capabilities = %v\n期望 %v", got, wantCapabilities)
	}

	// 键集合与 Python 版完全一致：多一个少一个都算契约变化。
	wantKeys := "capabilities,ok,relayVersion,version"
	var keys []string
	for key := range payload {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	if strings.Join(keys, ",") != wantKeys {
		t.Fatalf("响应键 = %v, 期望 %s", keys, wantKeys)
	}
}

func TestHealthzWithVersionAndBuild(t *testing.T) {
	handler := New(Options{Health: Health{
		Version: "20261023.1200",
		Build:   &BuildInfo{Commit: "abc1234", DeployedAt: "2026-10-23T12:00:00+08:00"},
	}})
	payload := decodeHealth(t, get(t, handler, "/healthz"))

	if payload["relayVersion"] != "20261023.1200" {
		t.Fatalf("relayVersion = %v", payload["relayVersion"])
	}
	build, ok := payload["build"].(map[string]any)
	if !ok {
		t.Fatalf("build = %v", payload["build"])
	}
	if build["commit"] != "abc1234" || build["deployedAt"] != "2026-10-23T12:00:00+08:00" {
		t.Fatalf("build = %v", build)
	}
}

// TestHealthzBasePathVariants 覆盖 Python 版"两条路径都注册"的行为：
// 前端剥掉前缀或原样转发，都必须命中同一个处理器。
func TestHealthzBasePathVariants(t *testing.T) {
	for _, basePath := range []string{"/dsh-link", "dsh-link", "/dsh-link/"} {
		handler := New(Options{BasePath: basePath})
		for _, path := range []string{"/healthz", "/dsh-link/healthz"} {
			payload := decodeHealth(t, get(t, handler, path))
			if payload["ok"] != true {
				t.Fatalf("basePath=%q %s: ok = %v", basePath, path, payload["ok"])
			}
		}
		if rec := get(t, handler, "/other/healthz"); rec.Code != http.StatusNotFound {
			t.Fatalf("basePath=%q 未知前缀状态码 = %d, 期望 404", basePath, rec.Code)
		}
	}
}

func TestHealthzWithoutBasePathRejectsPrefixedPath(t *testing.T) {
	handler := New(Options{})
	if rec := get(t, handler, "/dsh-link/healthz"); rec.Code != http.StatusNotFound {
		t.Fatalf("无前缀配置下 /dsh-link/healthz = %d, 期望 404", rec.Code)
	}
}

func TestHealthzRejectsNonGet(t *testing.T) {
	handler := New(Options{})
	for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodDelete} {
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, httptest.NewRequest(method, "/healthz", nil))
		if rec.Code != http.StatusMethodNotAllowed {
			t.Fatalf("%s /healthz = %d, 期望 405", method, rec.Code)
		}
	}
}

func TestLoadBuild(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "build.json")

	if version, build := LoadBuild(dir); version != "" || build != nil {
		t.Fatalf("没有 build.json 时 = %q/%v", version, build)
	}

	if err := os.WriteFile(path, []byte(`{"version":"20261023.1200","commit":"abc1234",`+
		`"deployedAt":"2026-10-23T12:00:00+08:00"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	version, build := LoadBuild(dir)
	if version != "20261023.1200" {
		t.Fatalf("version = %q", version)
	}
	if build == nil || build.Commit != "abc1234" {
		t.Fatalf("build = %+v", build)
	}

	// 只有 version、没有指纹：build 不输出（与 Python 版"键缺就不报"一致）。
	if err := os.WriteFile(path, []byte(`{"version":"20261023.1300"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	version, build = LoadBuild(dir)
	if version != "20261023.1300" || build != nil {
		t.Fatalf("仅 version = %q/%v", version, build)
	}

	// 坏 JSON 不编造版本。
	if err := os.WriteFile(path, []byte(`{not json`), 0o644); err != nil {
		t.Fatal(err)
	}
	if version, build := LoadBuild(dir); version != "" || build != nil {
		t.Fatalf("坏 JSON = %q/%v", version, build)
	}
}
