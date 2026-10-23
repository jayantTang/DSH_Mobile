package files

import (
	"bytes"
	"encoding/json"
	"log/slog"
	"net/http"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/dlp"
)

// transferLogBuffer 收集 JSON 日志。
type transferLogBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *transferLogBuffer) Write(payload []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(payload)
}

func (b *transferLogBuffer) text() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

func (b *transferLogBuffer) entries(t *testing.T) []map[string]any {
	t.Helper()
	entries := make([]map[string]any, 0, 4)
	for _, line := range strings.Split(strings.TrimSpace(b.text()), "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		var entry map[string]any
		if err := json.Unmarshal([]byte(line), &entry); err != nil {
			t.Fatalf("日志不是 JSON：%v (%s)", err, line)
		}
		entries = append(entries, entry)
	}
	return entries
}

func (b *transferLogBuffer) find(t *testing.T, message string) map[string]any {
	t.Helper()
	for _, entry := range b.entries(t) {
		if entry["msg"] == message {
			return entry
		}
	}
	t.Fatalf("没有日志 %q：%v", message, b.entries(t))
	return nil
}

func TestDownloadTransferLogsBidScopeStatusAndNeverThePath(t *testing.T) {
	buffer := &transferLogBuffer{}
	fx := newFileFixture(t, fixtureOptions{
		logger: slog.New(slog.NewJSONHandler(buffer, nil)),
	})
	fx.attachAgent()
	body := testBody(3 * 1024)
	done := fx.run(func() error {
		return serveDownload(fx, body, 1024, "v1", nil)
	})
	response, payload, err := fx.download(
		"scopeId=session-scope-7&path=%2FUsers%2Fsomeone%2Fsecret.txt&bid=app-bid-1", nil)
	if err != nil {
		t.Fatalf("请求失败：%v", err)
	}
	waitStub(t, done)
	if response.StatusCode != http.StatusOK || !bytes.Equal(payload, body) {
		t.Fatalf("下载失败：%d %s", response.StatusCode, payload)
	}

	started := buffer.find(t, "relay: file transfer started")
	if started["op"] != "download" || started["deviceId"] != fx.device.DeviceID ||
		started["agentId"] != fx.agentRow.AgentID || started["bid"] == "" ||
		started["scope"] != "session-scope-7" {
		t.Fatalf("started = %v", started)
	}

	finished := buffer.find(t, "relay: file transfer finished")
	if finished["status"] != float64(http.StatusOK) || finished["ok"] != true {
		t.Fatalf("finished = %v", finished)
	}
	if bytesField, _ := finished["bytes"].(float64); int(bytesField) != len(body) {
		t.Fatalf("bytes = %v，期望 %d", finished["bytes"], len(body))
	}
	if _, present := finished["duration_ms"]; !present {
		t.Fatalf("finished 缺 duration_ms：%v", finished)
	}
	if finished["bid"] != started["bid"] {
		t.Fatalf("begin/end 的 bid 不一致：%v/%v", started["bid"], finished["bid"])
	}

	// 路径与文件名不得进日志：只要请求里的 path 值出现，就是泄漏。
	for _, forbidden := range []string{"/Users/someone", "secret.txt"} {
		if strings.Contains(buffer.text(), forbidden) {
			t.Fatalf("传输日志泄露了 %q：%s", forbidden, buffer.text())
		}
	}
}

func TestFailedUploadIsLoggedAsWarnWithErrorCode(t *testing.T) {
	buffer := &transferLogBuffer{}
	fx := newFileFixture(t, fixtureOptions{
		logger: slog.New(slog.NewJSONHandler(buffer, nil)),
	})
	fx.attachAgent()
	done := fx.run(func() error {
		begin, err := fx.nextKind("fsPutBegin", stubTimeout)
		if err != nil {
			return err
		}
		return fx.deliver(dlp.Frame{"t": "fsErr", "bid": begin["bid"],
			"code": "file/too-large", "message": "connector refused"})
	})
	response, payload, err := fx.upload("sessionId=s1&name=photos.zip&bid=b1&bytes=3",
		[]byte("abc"))
	if err != nil {
		t.Fatalf("请求失败：%v", err)
	}
	waitStub(t, done)
	if response.StatusCode != http.StatusConflict {
		t.Fatalf("状态码 = %d：%s", response.StatusCode, payload)
	}

	finished := buffer.find(t, "relay: file transfer finished")
	if finished["level"] != "WARN" || finished["ok"] != false {
		t.Fatalf("失败传输日志 = %v", finished)
	}
	if finished["code"] != "file/too-large" ||
		finished["status"] != float64(http.StatusConflict) {
		t.Fatalf("code/status = %v/%v", finished["code"], finished["status"])
	}
	if strings.Contains(buffer.text(), filepath.Base("photos.zip")) {
		t.Fatalf("日志里出现了文件名：%s", buffer.text())
	}
}
