package config

import (
	"errors"
	"flag"
	"log/slog"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"
)

// env 返回固定映射的 getenv，避免测试互相污染进程环境。
func env(pairs map[string]string) func(string) string {
	return func(key string) string { return pairs[key] }
}

func TestDefaultsMatchPythonParser(t *testing.T) {
	cfg := Default()
	cases := []struct {
		name string
		got  any
		want any
	}{
		{"host", cfg.Host, "127.0.0.1"},
		{"port", cfg.Port, 8787},
		{"db", cfg.DBPath, filepath.Join(".local", "state.db")},
		{"pair-ttl-seconds", cfg.PairTTLSeconds, 600},
		{"device-ttl-days", cfg.DeviceTTLDays, 365},
		{"queue-depth", cfg.QueueDepth, 512},
		{"max-devices-per-agent", cfg.MaxDevicesPerAgent, 0},
		{"max-paired-devices", cfg.MaxPairedDevices, 8},
		{"device-rate-kbps", cfg.DeviceRateKbps, 0.0},
		{"device-daily-mb", cfg.DeviceDailyMB, 0.0},
		{"dead-device-warn-threshold", cfg.DeadDeviceWarnThreshold, 200},
		{"base-path", cfg.BasePath, ""},
		{"log-level", cfg.LogLevel, "INFO"},
		{"gogc", cfg.GCPercent, 50},
		{"queue-bytes", cfg.QueueBytes, int64(4 << 20)},
		{"bridge-bytes", cfg.BridgeBytes, int64(16 << 20)},
	}
	for _, c := range cases {
		if c.got != c.want {
			t.Errorf("%s 默认值 = %v, 期望 %v", c.name, c.got, c.want)
		}
	}
}

// TestFlagSetMatchesPythonParser 钉住参数名清单：relay.py 改了参数，这里应该红。
func TestFlagSetMatchesPythonParser(t *testing.T) {
	cfg := Default()
	fs := flag.NewFlagSet("serve", flag.ContinueOnError)
	cfg.register(fs)

	var names []string
	fs.VisitAll(func(f *flag.Flag) { names = append(names, f.Name) })
	sort.Strings(names)
	want := []string{
		"base-path", "bridge-bytes", "db", "dead-device-warn-threshold", "device-daily-mb",
		"device-rate-kbps", "device-ttl-days", "gogc", "host", "log-level",
		"max-devices-per-agent", "max-paired-devices", "pair-ttl-seconds",
		"port", "pprof-addr", "queue-bytes", "queue-depth",
	}
	if strings.Join(names, ",") != strings.Join(want, ",") {
		t.Fatalf("参数清单 = %v, 期望 %v", names, want)
	}
}

func TestLoadFlagOverrides(t *testing.T) {
	cfg, err := Load([]string{
		"--host", "0.0.0.0",
		"--port", "9000",
		"--db", "/tmp/relay-test.db",
		"--pair-ttl-seconds", "120",
		"--device-ttl-days", "30",
		"--queue-depth", "64",
		"--max-devices-per-agent", "3",
		"--max-paired-devices", "4",
		"--device-rate-kbps", "8",
		"--device-daily-mb", "1.5",
		"--dead-device-warn-threshold", "50",
		"--base-path", "/dsh-link/",
		"--log-level", "debug",
	}, env(nil))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.Host != "0.0.0.0" || cfg.Port != 9000 || cfg.DBPath != "/tmp/relay-test.db" {
		t.Fatalf("host/port/db = %q/%d/%q", cfg.Host, cfg.Port, cfg.DBPath)
	}
	if cfg.PairTTLSeconds != 120 || cfg.DeviceTTLDays != 30 || cfg.QueueDepth != 64 {
		t.Fatalf("ttl/queue = %d/%d/%d", cfg.PairTTLSeconds, cfg.DeviceTTLDays, cfg.QueueDepth)
	}
	if cfg.MaxDevicesPerAgent != 3 || cfg.MaxPairedDevices != 4 {
		t.Fatalf("max devices = %d/%d", cfg.MaxDevicesPerAgent, cfg.MaxPairedDevices)
	}
	if cfg.DeviceRateKbps != 8 || cfg.DeviceDailyMB != 1.5 {
		t.Fatalf("rate/daily = %v/%v", cfg.DeviceRateKbps, cfg.DeviceDailyMB)
	}
	if cfg.DeadDeviceWarnThreshold != 50 {
		t.Fatalf("dead-device-warn-threshold = %d", cfg.DeadDeviceWarnThreshold)
	}
	if got := cfg.MountPath(); got != "/dsh-link" {
		t.Fatalf("MountPath = %q", got)
	}
	if cfg.SlogLevel() != slog.LevelDebug {
		t.Fatalf("SlogLevel = %v", cfg.SlogLevel())
	}
}

func TestLoadEnvDefaultsAndFlagPrecedence(t *testing.T) {
	vars := map[string]string{
		EnvHost:                    "10.0.0.5",
		EnvPort:                    "9100",
		EnvDB:                      "/tmp/from-env.db",
		EnvMaxDevicesPerAgent:      "5",
		EnvMaxPairedDevices:        "6",
		EnvDeviceRateKbps:          "16",
		EnvDeviceDailyMB:           "2.5",
		EnvDeadDeviceWarnThreshold: "7",
		EnvBasePath:                "dsh-link",
		EnvLogLevel:                "warn",
	}
	cfg, err := Load(nil, env(vars))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.Host != "10.0.0.5" || cfg.Port != 9100 || cfg.DBPath != "/tmp/from-env.db" {
		t.Fatalf("env host/port/db = %q/%d/%q", cfg.Host, cfg.Port, cfg.DBPath)
	}
	if cfg.MaxDevicesPerAgent != 5 || cfg.MaxPairedDevices != 6 {
		t.Fatalf("env max devices = %d/%d", cfg.MaxDevicesPerAgent, cfg.MaxPairedDevices)
	}
	if cfg.DeviceRateKbps != 16 || cfg.DeviceDailyMB != 2.5 {
		t.Fatalf("env rate/daily = %v/%v", cfg.DeviceRateKbps, cfg.DeviceDailyMB)
	}
	if cfg.DeadDeviceWarnThreshold != 7 {
		t.Fatalf("env dead warn = %d", cfg.DeadDeviceWarnThreshold)
	}
	if got := cfg.MountPath(); got != "/dsh-link" {
		t.Fatalf("env MountPath = %q", got)
	}
	if cfg.SlogLevel() != slog.LevelWarn {
		t.Fatalf("env log level = %v", cfg.SlogLevel())
	}

	// 命令行覆盖环境变量（Python argparse 的 default 语义）。
	cfg, err = Load([]string{"--port", "9300", "--log-level", "error"}, env(vars))
	if err != nil {
		t.Fatalf("Load with flags: %v", err)
	}
	if cfg.Port != 9300 || cfg.Host != "10.0.0.5" {
		t.Fatalf("flag 未覆盖 env: port=%d host=%q", cfg.Port, cfg.Host)
	}
	if cfg.SlogLevel() != slog.LevelError {
		t.Fatalf("flag log level = %v", cfg.SlogLevel())
	}
}

func TestEnvInvalidNumbersFail(t *testing.T) {
	for _, key := range []string{
		EnvPort, EnvMaxDevicesPerAgent, EnvMaxPairedDevices,
		EnvDeviceRateKbps, EnvDeviceDailyMB,
	} {
		t.Run(key, func(t *testing.T) {
			if _, err := Load(nil, env(map[string]string{key: "not-a-number"})); err == nil {
				t.Fatalf("%s 非法值没有报错", key)
			}
		})
	}
}

// dead-device-warn-threshold 是唯一"坏值回退默认、负数夹到 0"的例外，
// 与 hub.dead_device_warn_threshold_from_env 一致。
func TestDeadDeviceWarnThresholdEnvTolerance(t *testing.T) {
	for _, tc := range []struct {
		raw  string
		want int
	}{
		{"not-a-number", DefaultDeadDeviceWarnThreshold},
		{"-5", 0},
		{"42", 42},
		{" 9 ", 9},
	} {
		cfg, err := Load(nil, env(map[string]string{EnvDeadDeviceWarnThreshold: tc.raw}))
		if err != nil {
			t.Fatalf("%q: %v", tc.raw, err)
		}
		if cfg.DeadDeviceWarnThreshold != tc.want {
			t.Fatalf("%q → %d, 期望 %d", tc.raw, cfg.DeadDeviceWarnThreshold, tc.want)
		}
	}
}

func TestNormalizeBasePath(t *testing.T) {
	for _, tc := range []struct{ raw, want string }{
		{"", ""},
		{"   ", ""},
		{"/", ""},
		{"dsh-link", "/dsh-link"},
		{"/dsh-link", "/dsh-link"},
		{"/dsh-link/", "/dsh-link"},
		{"  /dsh-link//  ", "/dsh-link"},
		{"///", ""},
	} {
		if got := NormalizeBasePath(tc.raw); got != tc.want {
			t.Errorf("NormalizeBasePath(%q) = %q, 期望 %q", tc.raw, got, tc.want)
		}
	}
}

func TestDerivedValues(t *testing.T) {
	cfg := Default()
	if got := cfg.PairTTL(); got != 10*time.Minute {
		t.Errorf("PairTTL = %v", got)
	}
	if got := cfg.DeviceTTL(); got != 365*24*time.Hour {
		t.Errorf("DeviceTTL = %v", got)
	}
	if got := cfg.DeviceBytesPerSecond(); got != 0 {
		t.Errorf("默认 DeviceBytesPerSecond = %v", got)
	}

	cfg.DeviceRateKbps = 8
	if got := cfg.DeviceBytesPerSecond(); got != 1000 {
		t.Errorf("8 kbps → %v B/s, 期望 1000", got)
	}
	cfg.DeviceDailyMB = 1.5
	if got := cfg.DeviceDailyBytes(); got != 1572864 {
		t.Errorf("1.5 MB → %d B", got)
	}
}

func TestSlogLevelMapping(t *testing.T) {
	for _, tc := range []struct {
		raw  string
		want slog.Level
	}{
		{"DEBUG", slog.LevelDebug},
		{"debug", slog.LevelDebug},
		{"INFO", slog.LevelInfo},
		{"WARN", slog.LevelWarn},
		{"warning", slog.LevelWarn},
		{"ERROR", slog.LevelError},
		{"critical", slog.LevelError},
		{"nonsense", slog.LevelInfo},
		{"", slog.LevelInfo},
	} {
		if got := (Config{LogLevel: tc.raw}).SlogLevel(); got != tc.want {
			t.Errorf("SlogLevel(%q) = %v, 期望 %v", tc.raw, got, tc.want)
		}
	}
}

func TestLoadValidation(t *testing.T) {
	if _, err := Load([]string{"--port", "70000"}, env(nil)); err == nil {
		t.Fatal("越界端口没有报错")
	}
	if _, err := Load([]string{"--port", "0"}, env(nil)); err != nil {
		t.Fatalf("端口 0 应该合法（随机端口）: %v", err)
	}
	if _, err := Load([]string{"--db", "  "}, env(nil)); err == nil {
		t.Fatal("空 db 路径没有报错")
	}
}

// TestPprofAddrOnlyLoopback 钉住 pprof 的暴露面：只允许环回，默认关闭。
func TestPprofAddrOnlyLoopback(t *testing.T) {
	for _, ok := range []string{"127.0.0.1:6060", "localhost:6060", "[::1]:6060"} {
		cfg, err := Load([]string{"--pprof-addr", ok}, env(nil))
		if err != nil {
			t.Fatalf("%q 应该合法: %v", ok, err)
		}
		if cfg.PprofAddr != ok {
			t.Fatalf("PprofAddr = %q, 期望 %q", cfg.PprofAddr, ok)
		}
	}
	for _, bad := range []string{"0.0.0.0:6060", ":6060", "192.168.1.10:6060", "127.0.0.1", "127.0.0.1:abc"} {
		if _, err := Load([]string{"--pprof-addr", bad}, env(nil)); err == nil {
			t.Fatalf("%q 应该被拒绝", bad)
		}
	}
	// 默认关闭：不给 --pprof-addr 时为空。
	cfg, err := Load(nil, env(nil))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.PprofAddr != "" {
		t.Fatalf("默认 PprofAddr = %q, 期望空", cfg.PprofAddr)
	}
	// 环境变量路径同样受校验。
	if _, err := Load(nil, env(map[string]string{EnvPprofAddr: "0.0.0.0:6060"})); err == nil {
		t.Fatal("环境变量给了非环回地址时应该报错")
	}
}

// TestGCPercent 钉住 GOGC 的口径：默认 50，命令行与环境变量都能改，非正数拒绝。
func TestGCPercent(t *testing.T) {
	cfg, err := Load(nil, env(nil))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.GCPercent != 50 {
		t.Fatalf("默认 GOGC = %d，期望 50", cfg.GCPercent)
	}
	cfg, err = Load([]string{"--gogc", "100"}, env(nil))
	if err != nil || cfg.GCPercent != 100 {
		t.Fatalf("--gogc 100: %v / %d", err, cfg.GCPercent)
	}
	cfg, err = Load(nil, env(map[string]string{EnvGCPercent: "75"}))
	if err != nil || cfg.GCPercent != 75 {
		t.Fatalf("DLP_GOGC=75: %v / %d", err, cfg.GCPercent)
	}
	for _, bad := range []string{"0", "-1"} {
		if _, err := Load([]string{"--gogc", bad}, env(nil)); err == nil {
			t.Fatalf("--gogc %s 应该被拒绝", bad)
		}
	}
}

// TestBridgeBytes 钉住上行桥额度的口径：默认 16 MiB，命令行与环境变量都能改，
// 0/负数拒绝（0 等于回到"只受队列深度约束"，那是一次静默的回退）。
func TestBridgeBytes(t *testing.T) {
	cfg, err := Load(nil, env(nil))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if cfg.BridgeBytes != 16<<20 {
		t.Fatalf("默认 bridge-bytes = %d，期望 %d", cfg.BridgeBytes, 16<<20)
	}
	cfg, err = Load([]string{"--bridge-bytes", "4194304"}, env(nil))
	if err != nil || cfg.BridgeBytes != 4<<20 {
		t.Fatalf("--bridge-bytes 4 MiB: %v / %d", err, cfg.BridgeBytes)
	}
	cfg, err = Load(nil, env(map[string]string{EnvBridgeBytes: "2097152"}))
	if err != nil || cfg.BridgeBytes != 2<<20 {
		t.Fatalf("DLP_BRIDGE_BYTES=2 MiB: %v / %d", err, cfg.BridgeBytes)
	}
	for _, bad := range []string{"0", "-1"} {
		if _, err := Load([]string{"--bridge-bytes", bad}, env(nil)); err == nil {
			t.Fatalf("--bridge-bytes %s 应该被拒绝", bad)
		}
	}
	if _, err := Load(nil, env(map[string]string{EnvBridgeBytes: "abc"})); err == nil {
		t.Fatal("DLP_BRIDGE_BYTES 非法值没有报错")
	}
}

func TestLoadHelp(t *testing.T) {
	_, err := Load([]string{"--help"}, env(nil))
	if !errors.Is(err, flag.ErrHelp) {
		t.Fatalf("--help 应返回 flag.ErrHelp, 得到 %v", err)
	}
}

// TestRevokeReconcileIntervalEnv 钉住 DLP_REVOKE_RECONCILE_S 的口径：
// 坏值回退默认（Python hub._reconcile_interval_from_env），0/负数 = 关闭。
func TestRevokeReconcileIntervalEnv(t *testing.T) {
	cases := []struct {
		raw  string
		want time.Duration
	}{
		{"5", 5 * time.Second},
		{"0.5", 500 * time.Millisecond},
		{"0", 0},
		{"-1", -time.Second},
		{"not-a-number", 5 * time.Second},
	}
	for _, c := range cases {
		cfg, err := Load(nil, env(map[string]string{EnvRevokeReconcileSeconds: c.raw}))
		if err != nil {
			t.Fatalf("%s: Load: %v", c.raw, err)
		}
		if got := cfg.RevokeReconcileInterval(); got != c.want {
			t.Fatalf("%s: interval = %s, 期望 %s", c.raw, got, c.want)
		}
	}
}
