// Package httpapi 是明文 HTTP 面。
//
// M1 覆盖 /healthz、/stats、配对（claim/refresh/code/regenerate）、设备（list/revoke）、
// 账户状态（GET/PUT）与自助登记（/agents/enroll），统一错误信封、Bearer 鉴权、CORS
// 与内存限流。WebSocket、文件正文、反馈与推送属于 M2/M3。
//
// 所有 SQL 都在 internal/store；本包只做协议与校验。
package httpapi

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/apierr"
)

// Unversioned 是没有部署构建号时的 relayVersion（Python version.UNVERSIONED）。
const Unversioned = "0.0.0"

// ProtocolVersion 是 DLP 协议版本，回答"能不能对话"（`internal/dlp` 的 `ProtocolVersion`）。
const ProtocolVersion = 1

// Capabilities 是 /healthz 的能力清单，逐项对齐 Python 版 api.healthz：
// 客户端读不到这个字段就按"中转需升级"提示，不静默降级。
var Capabilities = []string{
	"device-subprotocol-auth",
	"persistent-pair-code",
	"account-state",
	"account-state-push",
	"file-transfer",
}

// BuildInfo 是部署指纹，对应 `bin/build.json` 里的 commit / deployedAt。
type BuildInfo struct {
	Commit     string `json:"commit,omitempty"`
	DeployedAt string `json:"deployedAt,omitempty"`
}

// Health 是 /healthz 的处理器。
type Health struct {
	// Version 是这份代码的部署构建号（yyyyMMdd.HHmm）；空值按 0.0.0 输出，
	// 表示"这不是一次部署"。
	Version string
	// Build 只在读得到部署指纹时输出。
	Build *BuildInfo
}

// healthResponse 的字段顺序与 Python 版一致：ok、version、relayVersion、build?、capabilities。
type healthResponse struct {
	OK           bool       `json:"ok"`
	Version      int        `json:"version"`
	RelayVersion string     `json:"relayVersion"`
	Build        *BuildInfo `json:"build,omitempty"`
	Capabilities []string   `json:"capabilities"`
}

func (h Health) register(mux *http.ServeMux, pattern string) {
	mux.HandleFunc("GET "+pattern, h.serveHTTP)
}

func (h Health) serveHTTP(w http.ResponseWriter, r *http.Request) {
	version := h.Version
	if strings.TrimSpace(version) == "" {
		version = Unversioned
	}
	body, err := json.Marshal(healthResponse{
		OK:           true,
		Version:      ProtocolVersion,
		RelayVersion: version,
		Build:        h.Build,
		Capabilities: Capabilities,
	})
	if err != nil {
		// 结构体不可能序列化失败；真发生了也必须给 JSON 信封，不能回退纯文本。
		apierr.WriteFor(w, r, http.StatusInternalServerError, "internal/error",
			"healthz: encode response", nil)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(body)
}

// LoadBuild 读 dir/build.json，口径与 Python 版 version.py 一致：
//
//   - 读不到或不是合法 JSON：version 为 ""（调用方回退 Unversioned），指纹为 nil；
//   - version 只在是非空字符串时返回；
//   - 指纹只保留非空的 commit / deployedAt，都为空的 build 视为不存在。
func LoadBuild(dir string) (string, *BuildInfo) {
	raw, err := os.ReadFile(filepath.Join(dir, "build.json"))
	if err != nil {
		return "", nil
	}
	var payload struct {
		Version    string `json:"version"`
		Commit     string `json:"commit"`
		DeployedAt string `json:"deployedAt"`
	}
	if err := json.Unmarshal(raw, &payload); err != nil {
		return "", nil
	}
	info := &BuildInfo{
		Commit:     strings.TrimSpace(payload.Commit),
		DeployedAt: strings.TrimSpace(payload.DeployedAt),
	}
	if info.Commit == "" && info.DeployedAt == "" {
		info = nil
	}
	return strings.TrimSpace(payload.Version), info
}
