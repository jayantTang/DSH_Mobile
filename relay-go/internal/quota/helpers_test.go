package quota

import (
	"io"
	"log/slog"
	"path/filepath"
	"testing"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
)

// discardLogger 把配额/账本的告警丢进虚空（只有断言失败时才需要看日志）。
func discardLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

// openTestStore 开一个临时库，随用例结束关闭。
func openTestStore(t *testing.T) *store.Store {
	t.Helper()
	st, err := store.Open(filepath.Join(t.TempDir(), "state.db"))
	if err != nil {
		t.Fatalf("打开临时库: %v", err)
	}
	t.Cleanup(func() {
		if err := st.Close(); err != nil {
			t.Errorf("关闭临时库: %v", err)
		}
	})
	return st
}
