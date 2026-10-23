// Package config 收拢 dsh-relay 的启动参数。
//
// 口径按 Python 版 relay/relay.py 的 build_parser 逐项对齐：参数名、环境变量名、
// 默认值与换算关系只在这里定义一份。优先级：命令行 flag > 环境变量 > 常量默认值。
package config

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// 与 Python 版逐项对应的默认值。
const (
	DefaultHost           = "127.0.0.1"
	DefaultPort           = 8787
	DefaultPairTTLSeconds = 600 // store.DEFAULT_PAIR_TTL_MS // 1000
	DefaultDeviceTTLDays  = 365 // store.DEFAULT_DEVICE_TTL_MS // 86_400_000
	DefaultQueueDepth     = 512
	// DefaultQueueBytes 是每连接发送队列的字节上限（M2.5）。4 MiB 盖住正常流量
	// （几百个 1 KiB 的帧），又能在慢客户端堆积大帧时提前触发背压而不是吃满内存。
	DefaultQueueBytes = 4 << 20
	// DefaultBridgeBytes 是每条连接器链路上文件上行桥的在途字节上限（M4a）。
	//
	// 上行分片不可丢（ClassControl），绕过队列字节上限；慢连接器读时，4096 深度
	// 的队列最坏能堆到 4096 × 1.33 MB。16 MiB 大约等于 12 个 1 MiB 分片同时在路上，
	// 正常家用宽带（几十 MB/s）不会把上传压慢，而慢连接器时内存有确定上界。
	DefaultBridgeBytes             = 16 << 20
	DefaultMaxDevicesPerAgent      = 0   // 0 = 不限
	DefaultMaxPairedDevices        = 8   // store.DEFAULT_MAX_PAIRED_DEVICES
	DefaultDeviceRateKbps          = 0.0 // 0 = 不限速
	DefaultDeviceDailyMB           = 0.0 // 0 = 不限量
	DefaultDeadDeviceWarnThreshold = 200 // hub.DEFAULT_DEAD_DEVICE_WARN_THRESHOLD
	DefaultBasePath                = ""
	DefaultLogLevel                = "INFO"
	// DefaultPprofAddr 为空 = 不监听。pprof 是诊断面，必须显式开启（DESIGN §8）。
	DefaultPprofAddr = ""
	// DefaultRevokeReconcileSeconds 是撤销对账周期（Python hub 的
	// DLP_REVOKE_RECONCILE_S 默认 5 秒；0 或负数 = 关闭）。
	DefaultRevokeReconcileSeconds = 5.0
	// DefaultGCPercent 是 GOGC 的默认值。
	//
	// 为什么不是 Go 默认的 100：中转的堆里常驻的是"连接 + 队列"（M2.5 实测 300 档
	// 存活堆 33 MiB，其中队列 11 MiB），垃圾周转很快。GOGC=100 的翻倍余量在配对
	// 高峰（100 台设备要 200 次 scrypt，每次 16 MiB 临时缓冲）会把峰值推到 71 MiB。
	// M2.5 实测（100 设备档）：供给阶段峰值 71.5 → 52.7 MiB、转发阶段 41.9 → 37.2 MiB，
	// CPU 3.83 → 3.78 s（在噪声内）。数字与复现命令见 M2.5 报告 §5。
	DefaultGCPercent = 50
)

// 环境变量名，与 Python 版复用同一套（部署脚本体不用改）。
const (
	EnvHost                    = "DLP_HOST"
	EnvPort                    = "DLP_PORT"
	EnvDB                      = "DLP_DB"
	EnvBridgeBytes             = "DLP_BRIDGE_BYTES"
	EnvMaxDevicesPerAgent      = "DLP_MAX_DEVICES_PER_AGENT"
	EnvMaxPairedDevices        = "DLP_MAX_PAIRED_DEVICES"
	EnvDeviceRateKbps          = "DLP_DEVICE_RATE_KBPS"
	EnvDeviceDailyMB           = "DLP_DEVICE_DAILY_MB"
	EnvDeadDeviceWarnThreshold = "DLP_DEAD_DEVICE_WARN_THRESHOLD"
	EnvBasePath                = "DLP_BASE_PATH"
	EnvLogLevel                = "DLP_LOG_LEVEL"
	// EnvPprofAddr 是 Go 版独有的诊断开关（Python 版没有），与 DLP_* 同前缀便于部署。
	EnvPprofAddr = "DLP_PPROF_ADDR"
	// EnvGCPercent 是 Go 版的 GC 百分比（Python 版没有），与 Go 的 GOGC 同义。
	EnvGCPercent = "DLP_GOGC"
	// EnvRevokeReconcileSeconds 是撤销对账周期（秒）；坏值回退默认、<=0 关闭，
	// 与 Python hub._reconcile_interval_from_env 同口径。
	EnvRevokeReconcileSeconds = "DLP_REVOKE_RECONCILE_S"
)

// DefaultDBPath 是 --db 的默认值：当前目录下的 .local/state.db。
//
// Python 版落在源码目录的 .local/ 下（"源码目录只放源码"）；Go 版没有稳定的源码目录，
// 取工作目录等价位置。生产部署不受影响：systemd 显式传 --db。
func DefaultDBPath() string {
	return filepath.Join(".local", "state.db")
}

// Config 是 serve 子命令的全部启动参数。M0 只用到 Host/Port/DBPath/BasePath/LogLevel，
// 其余是 M1/M2 要用的配额与 TTL；默认值现在就对齐，避免之后两套口径。
type Config struct {
	Host                    string
	Port                    int
	DBPath                  string
	PairTTLSeconds          int
	DeviceTTLDays           int
	QueueDepth              int
	QueueBytes              int64
	BridgeBytes             int64
	MaxDevicesPerAgent      int
	MaxPairedDevices        int
	DeviceRateKbps          float64
	DeviceDailyMB           float64
	DeadDeviceWarnThreshold int
	BasePath                string
	LogLevel                string
	// PprofAddr 是 pprof 监听地址（host:port）；空 = 关闭。只接受环回地址。
	PprofAddr string
	// GCPercent 是 GOGC（100 = Go 默认；越小越省内存、GC 越频繁）。
	GCPercent int
	// RevokeReconcileSeconds 是「库已撤销但 socket 还活着」的对账周期（秒，
	// <=0 关闭）。只有环境变量，没有命令行开关（Python 版同样没有）。
	RevokeReconcileSeconds float64
}

// Default 返回常量默认值（不读环境变量），对应 Python 版 argparse 的 default。
func Default() Config {
	return Config{
		Host:                    DefaultHost,
		Port:                    DefaultPort,
		DBPath:                  DefaultDBPath(),
		PairTTLSeconds:          DefaultPairTTLSeconds,
		DeviceTTLDays:           DefaultDeviceTTLDays,
		QueueDepth:              DefaultQueueDepth,
		QueueBytes:              DefaultQueueBytes,
		BridgeBytes:             DefaultBridgeBytes,
		MaxDevicesPerAgent:      DefaultMaxDevicesPerAgent,
		MaxPairedDevices:        DefaultMaxPairedDevices,
		DeviceRateKbps:          DefaultDeviceRateKbps,
		DeviceDailyMB:           DefaultDeviceDailyMB,
		DeadDeviceWarnThreshold: DefaultDeadDeviceWarnThreshold,
		BasePath:                DefaultBasePath,
		LogLevel:                DefaultLogLevel,
		PprofAddr:               DefaultPprofAddr,
		GCPercent:               DefaultGCPercent,
		RevokeReconcileSeconds:  DefaultRevokeReconcileSeconds,
	}
}

// Load 解析 serve 的参数：先叠加 DLP_* 环境变量，再用命令行覆盖。
//
// getenv 由调用方传入（生产是 os.Getenv，测试用固定映射），便于逐项验证。
func Load(args []string, getenv func(string) string) (Config, error) {
	cfg := Default()
	if err := cfg.applyEnv(getenv); err != nil {
		return Config{}, err
	}
	fs := flag.NewFlagSet("serve", flag.ContinueOnError)
	// 用法文本由 main 打印；这里只负责解析，出错时不要把整页 usage 写进错误。
	fs.SetOutput(io.Discard)
	cfg.register(fs)
	if err := fs.Parse(args); err != nil {
		return Config{}, err
	}
	if err := cfg.Validate(); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

// Usage 把 serve 的参数说明写到 w。
//
// 参数表由 flag 包按注册表生成，默认值直接取自 Default()，不会与真正解析的
// 默认值漂移。
func Usage(w io.Writer) {
	cfg := Default()
	fs := flag.NewFlagSet("serve", flag.ContinueOnError)
	fs.SetOutput(w)
	cfg.register(fs)
	fs.PrintDefaults()
}

// register 把配置项挂到 flag 上；flag 的默认值就是叠加环境变量后的值。
func (c *Config) register(fs *flag.FlagSet) {
	fs.StringVar(&c.Host, "host", c.Host, "监听地址")
	fs.IntVar(&c.Port, "port", c.Port, "监听端口（0 = 由内核分配）")
	fs.StringVar(&c.DBPath, "db", c.DBPath, "SQLite 库路径")
	fs.IntVar(&c.PairTTLSeconds, "pair-ttl-seconds", c.PairTTLSeconds, "配对码有效期（秒）")
	fs.IntVar(&c.DeviceTTLDays, "device-ttl-days", c.DeviceTTLDays, "设备有效期（天）")
	fs.IntVar(&c.QueueDepth, "queue-depth", c.QueueDepth, "每设备发送队列深度")
	fs.Int64Var(&c.QueueBytes, "queue-bytes", c.QueueBytes,
		"每连接发送队列的字节上限（0 = 只按帧上限兜底）")
	fs.Int64Var(&c.BridgeBytes, "bridge-bytes", c.BridgeBytes,
		"每条连接器链路上文件上行桥的在途字节上限（默认 16 MiB，必须为正）")
	fs.IntVar(&c.MaxDevicesPerAgent, "max-devices-per-agent", c.MaxDevicesPerAgent,
		"一个连接器最多同时接入多少台设备（0 = 不限）")
	fs.IntVar(&c.MaxPairedDevices, "max-paired-devices", c.MaxPairedDevices,
		"一个账户最多多少台未撤销设备（0 = 不限）")
	fs.Float64Var(&c.DeviceRateKbps, "device-rate-kbps", c.DeviceRateKbps,
		"每设备出口限速（kbps，0 = 不限）")
	fs.Float64Var(&c.DeviceDailyMB, "device-daily-mb", c.DeviceDailyMB,
		"每设备每日出口额度（MB，0 = 不限）")
	fs.IntVar(&c.DeadDeviceWarnThreshold, "dead-device-warn-threshold", c.DeadDeviceWarnThreshold,
		"一个连接器下失效设备记录超过该数时告警（0 = 不告警）")
	fs.StringVar(&c.BasePath, "base-path", c.BasePath,
		"挂载前缀，例如 /dsh-link；带前缀与去前缀两种形式都服务")
	fs.StringVar(&c.LogLevel, "log-level", c.LogLevel, "日志级别：debug / info / warn / error")
	fs.StringVar(&c.PprofAddr, "pprof-addr", c.PprofAddr,
		"pprof 监听地址（host:port，只允许环回；默认关闭）")
	fs.IntVar(&c.GCPercent, "gogc", c.GCPercent,
		"GOGC 百分比（默认 50；100 = Go 默认，越小越省内存）")
}

// applyEnv 按 Python 版的取值规则叠加环境变量。
//
// 除 dead-device-warn-threshold 外，数值环境变量非法即报错（Python 版在 argparse
// 构造阶段 int()/float() 抛 ValueError，同样是启动失败）。该例外按
// hub.dead_device_warn_threshold_from_env：坏值回退默认、负数夹到 0。
func (c *Config) applyEnv(getenv func(string) string) error {
	if v := getenv(EnvHost); v != "" {
		c.Host = v
	}
	if v := getenv(EnvPort); v != "" {
		port, err := strconv.Atoi(strings.TrimSpace(v))
		if err != nil {
			return fmt.Errorf("%s=%q: %w", EnvPort, v, err)
		}
		c.Port = port
	}
	// 空字符串按"未设置"处理：Python 版只有未设置才取默认值，但把空路径交给
	// sqlite3 会得到一个临时库，反而更糟，这里明确当成未设置。
	if v := getenv(EnvDB); v != "" {
		c.DBPath = v
	}
	if v := getenv(EnvBridgeBytes); v != "" {
		n, err := strconv.ParseInt(strings.TrimSpace(v), 10, 64)
		if err != nil {
			return fmt.Errorf("%s=%q: %w", EnvBridgeBytes, v, err)
		}
		c.BridgeBytes = n
	}
	if v := getenv(EnvMaxDevicesPerAgent); v != "" {
		n, err := strconv.Atoi(strings.TrimSpace(v))
		if err != nil {
			return fmt.Errorf("%s=%q: %w", EnvMaxDevicesPerAgent, v, err)
		}
		c.MaxDevicesPerAgent = n
	}
	if v := getenv(EnvMaxPairedDevices); v != "" {
		n, err := strconv.Atoi(strings.TrimSpace(v))
		if err != nil {
			return fmt.Errorf("%s=%q: %w", EnvMaxPairedDevices, v, err)
		}
		c.MaxPairedDevices = n
	}
	if v := getenv(EnvDeviceRateKbps); v != "" {
		f, err := strconv.ParseFloat(strings.TrimSpace(v), 64)
		if err != nil {
			return fmt.Errorf("%s=%q: %w", EnvDeviceRateKbps, v, err)
		}
		c.DeviceRateKbps = f
	}
	if v := getenv(EnvDeviceDailyMB); v != "" {
		f, err := strconv.ParseFloat(strings.TrimSpace(v), 64)
		if err != nil {
			return fmt.Errorf("%s=%q: %w", EnvDeviceDailyMB, v, err)
		}
		c.DeviceDailyMB = f
	}
	if v := getenv(EnvDeadDeviceWarnThreshold); v != "" {
		if n, err := strconv.Atoi(strings.TrimSpace(v)); err == nil {
			if n < 0 {
				n = 0
			}
			c.DeadDeviceWarnThreshold = n
		}
	}
	if v := getenv(EnvBasePath); v != "" {
		c.BasePath = v
	}
	if v := getenv(EnvLogLevel); v != "" {
		c.LogLevel = v
	}
	if v := getenv(EnvPprofAddr); v != "" {
		c.PprofAddr = v
	}
	if v := getenv(EnvGCPercent); v != "" {
		n, err := strconv.Atoi(strings.TrimSpace(v))
		if err != nil {
			return fmt.Errorf("%s=%q: %w", EnvGCPercent, v, err)
		}
		c.GCPercent = n
	}
	// 坏值回退默认（Python hub._reconcile_interval_from_env 就是这么做的）：
	// 对账是兜底功能，不该因为一个写错的环境变量让中转起不来。
	if v := getenv(EnvRevokeReconcileSeconds); v != "" {
		if seconds, err := strconv.ParseFloat(strings.TrimSpace(v), 64); err == nil {
			c.RevokeReconcileSeconds = seconds
		}
	}
	return nil
}

// Validate 只做启动前必须拦下的检查，取值范围与 Python 版一致的地方不额外加限制。
func (c Config) Validate() error {
	if c.Port < 0 || c.Port > 65535 {
		return fmt.Errorf("port %d 超出 0-65535", c.Port)
	}
	if strings.TrimSpace(c.DBPath) == "" {
		return errors.New("db 路径为空")
	}
	if err := validatePprofAddr(c.PprofAddr); err != nil {
		return err
	}
	// 0 会让 GC 每次分配都跑（可用但等于自残），负数在 Go 里是"关闭 GC"——
	// 一个长连接服务不该允许关掉 GC，所以两者都按配置错误拒绝。
	if c.GCPercent <= 0 {
		return fmt.Errorf("gogc 需要正整数（默认 %d；100 = Go 默认）", DefaultGCPercent)
	}
	// 额度为 0 等于"没有额度"（回到 M3 的 4096 深度无上限），那不是可配置的
	// 中间态，而是一次静默的回退；要放宽就给一个大数。
	if c.BridgeBytes <= 0 {
		return fmt.Errorf("bridge-bytes 需要正整数（默认 %d）", DefaultBridgeBytes)
	}
	return nil
}

// validatePprofAddr 只允许环回监听。
//
// pprof 会把堆、goroutine 栈与 CPU 采样暴露成可读页面，那些内容里有设备 id、帧内容
// 与连接标识。DESIGN §8 的要求是"仅监听环回"，所以这里在启动前就拒绝 0.0.0.0、
// 通配地址与任何非环回 IP——不能靠运维记得加防火墙。
func validatePprofAddr(raw string) error {
	text := strings.TrimSpace(raw)
	if text == "" {
		return nil
	}
	host, port, err := net.SplitHostPort(text)
	if err != nil {
		return fmt.Errorf("pprof-addr %q 需要 host:port 形式: %w", raw, err)
	}
	if _, err := strconv.Atoi(port); err != nil {
		return fmt.Errorf("pprof-addr %q 的端口不是数字", raw)
	}
	if strings.EqualFold(host, "localhost") {
		return nil
	}
	ip := net.ParseIP(host)
	if ip == nil || !ip.IsLoopback() {
		return fmt.Errorf("pprof-addr %q 不是环回地址；只允许 127.0.0.1 / ::1 / localhost", raw)
	}
	return nil
}

// MountPath 返回规范化后的挂载前缀："" 或 "/prefix"（无尾斜杠）。
func (c Config) MountPath() string {
	return NormalizeBasePath(c.BasePath)
}

// NormalizeBasePath 与 Python 版 relay.normalize_base_path 逐条一致。
//
// 前端可以剥掉前缀（Caddy handle_path）也可以原样转发；每条路由两种形式都注册。
func NormalizeBasePath(raw string) string {
	text := strings.TrimSpace(raw)
	if text == "" || text == "/" {
		return ""
	}
	if !strings.HasPrefix(text, "/") {
		text = "/" + text
	}
	return strings.TrimRight(text, "/")
}

// PairTTL 是配对码有效期（--pair-ttl-seconds 换算）。
func (c Config) PairTTL() time.Duration {
	return time.Duration(c.PairTTLSeconds) * time.Second
}

// DeviceTTL 是设备有效期（--device-ttl-days 换算）。
func (c Config) DeviceTTL() time.Duration {
	return time.Duration(c.DeviceTTLDays) * 24 * time.Hour
}

// DeviceBytesPerSecond 把 kbps 换成每秒字节数（relay.py 的换算）。
func (c Config) DeviceBytesPerSecond() float64 {
	return c.DeviceRateKbps * 1000 / 8
}

// DeviceDailyBytes 把 MB 换成字节数（Python 版用 int() 截断，这里同样截断）。
func (c Config) DeviceDailyBytes() int64 {
	return int64(c.DeviceDailyMB * 1024 * 1024)
}

// RevokeReconcileInterval 把秒换成时长；<=0 表示关闭（Python 的 `> 0` 判据）。
func (c Config) RevokeReconcileInterval() time.Duration {
	return time.Duration(c.RevokeReconcileSeconds * float64(time.Second))
}

// SlogLevel 把 --log-level 映射成 slog 级别。
//
// 认不出的值回退 INFO，与 Python 版 getattr(logging, name, logging.INFO) 一致。
func (c Config) SlogLevel() slog.Level {
	switch strings.ToUpper(strings.TrimSpace(c.LogLevel)) {
	case "DEBUG":
		return slog.LevelDebug
	case "WARN", "WARNING":
		return slog.LevelWarn
	case "ERROR", "CRITICAL", "FATAL":
		return slog.LevelError
	default:
		return slog.LevelInfo
	}
}
