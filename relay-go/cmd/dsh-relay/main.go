// dsh-relay 是 DSH 中转的 Go 实现。
//
// 三类入口共用一个二进制：
//   - `dsh-relay [serve] <参数>`：起 HTTP 服务。**不带子命令时默认 serve**，
//     所以黑盒测试的 RELAY_CMD 可以直接指向这个二进制；
//   - `dsh-relay admin --db <path> <子命令>`：管理面，JSON 输出对齐 admin.py；
//   - `dsh-relay alert-dispatch` / `dsh-relay purge`：运维 timer 用的两个动作，
//     分别投递告警队列与清理设备死记录（见 relay-go/deploy 的两个 timer）。
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"runtime/debug"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/jayantTang/DSH_Mobile/relay-go/internal/admincli"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/config"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/dlp"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/feedback"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/files"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/httpapi"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/hub"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/monitor"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/purge"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/push"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/store"
	"github.com/jayantTang/DSH_Mobile/relay-go/internal/wsapi"
)

// shutdownTimeout 是优雅退出的上限（DESIGN §5.5：目标 5 秒内完成）。
const shutdownTimeout = 5 * time.Second

func main() {
	os.Exit(run(os.Args[1:], os.Getenv, os.Stdout, os.Stderr))
}

func run(args []string, getenv func(string) string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		// 无参数 = serve（用默认参数），与 Python 版 `relay.py` 裸跑等价。
		return runServe(nil, getenv, stderr)
	}
	switch args[0] {
	case "serve":
		return runServe(args[1:], getenv, stderr)
	case "admin":
		return admincli.Main(args[1:], getenv, stdout, stderr)
	case "alert-dispatch":
		// 运维 timer 入口：与 `admin alert-dispatch` 共用同一份实现。
		return admincli.AlertDispatch(args[1:], getenv, stdout, stderr)
	case "purge":
		// 设备死记录清理（Python purge-revoked-devices.py 的 Go 版本）。
		// 注意与 `admin purge`（过期配对码）不是同一件事，见两个命令的帮助。
		return purge.Main(args[1:], getenv, stdout, stderr)
	case "-h", "--help", "help":
		usage(stdout)
		return 0
	default:
		if strings.HasPrefix(args[0], "-") {
			// 没有子命令、直接给了参数：按 serve 处理，RELAY_CMD 就是这条路。
			return runServe(args, getenv, stderr)
		}
		fmt.Fprintf(stderr, "dsh-relay: 未知子命令 %q\n\n", args[0])
		usage(stderr)
		return 2
	}
}

func runServe(args []string, getenv func(string) string, stderr io.Writer) int {
	cfg, err := config.Load(args, getenv)
	if err != nil {
		if errors.Is(err, flag.ErrHelp) {
			usage(os.Stdout)
			return 0
		}
		fmt.Fprintf(stderr, "dsh-relay serve: %v\n", err)
		return 2
	}

	logger := slog.New(slog.NewJSONHandler(stderr, &slog.HandlerOptions{Level: cfg.SlogLevel()}))
	slog.SetDefault(logger)

	// GC 百分比只有一个来源（config），启动时应用一次；/stats 与日志拿到的都是同一份。
	previousGC := debug.SetGCPercent(cfg.GCPercent)

	// 版本与部署指纹：优先取可执行文件旁的 build.json（与 Python version.py 同口径），
	// 读不到就是 0.0.0，不编造版本。
	version, build := httpapi.LoadBuild(executableDir())

	// pprof 只在显式给了环回地址时开启；失败即启动失败（不要带病跑一个没开成的诊断面）。
	stopPprof := func() {}
	if cfg.PprofAddr != "" {
		stop, _, err := startPprof(cfg.PprofAddr, logger)
		if err != nil {
			logger.Error("relay: pprof listen failed", "error", err, "addr", cfg.PprofAddr)
			return 1
		}
		stopPprof = stop
	}
	defer stopPprof()

	// 打开库会建目录、建表、迁移到当前 schema 版本；失败就不带病启动。
	st, err := store.OpenWith(cfg.DBPath, store.Options{Logger: logger})
	if err != nil {
		logger.Error("relay: open store failed", "error", err, "db", cfg.DBPath)
		return 1
	}
	defer st.Close()

	// 限额只在这里从启动参数翻译一次；hub 拿着它转发，/stats 也用同一份。
	limits := hub.Limits{
		MaxFrameBytes:           dlp.MaxFrameBytes,
		QueueDepth:              cfg.QueueDepth,
		AgentQueueDepth:         httpapi.DefaultAgentQueueDepth,
		QueueBytes:              cfg.QueueBytes,
		BridgeBytes:             cfg.BridgeBytes,
		MaxDevicesPerAgent:      cfg.MaxDevicesPerAgent,
		DeviceBytesPerSecond:    cfg.DeviceBytesPerSecond(),
		DeviceDailyBytes:        cfg.DeviceDailyBytes(),
		DeadDeviceWarnThreshold: cfg.DeadDeviceWarnThreshold,
	}
	// 监控与推送都在启动时按环境变量装配一次：
	//   - DLP_ALERT_DIR 为空 = 监控关闭（所有方法都是空操作）；
	//   - APNs 配置缺失或 DLP_APNS_ENABLED=0 = 推送关闭（转发行为逐字不变）。
	incidents := monitor.FromEnv(getenv, logger)
	sender := push.FromEnv(getenv, nil, logger)
	defer func() { _ = sender.Close() }()

	// hub 是活连接、队列与心跳的所有者；日额度与用量在 internal/quota。HTTP 与
	// WS 都只通过 hub 读写。
	revokeInterval := cfg.RevokeReconcileInterval()
	if revokeInterval <= 0 {
		revokeInterval = -1 // 0/负数 = 关闭（Python 的 `> 0` 判据）
	}
	live := hub.New(hub.Options{
		Store:                   st,
		Limits:                  limits,
		Logger:                  logger,
		RelayVersion:            versionOrDefault(version),
		RevokeReconcileInterval: revokeInterval,
		Push:                    sender,
		Monitor:                 incidents,
	})

	// 三个子 handler 在组合根构造：它们各自的仓储端口不同（wsapi 4、files 1、
	// feedback 9），httpapi 只负责路由与中间件，不再替它们 new（DESIGN §2.5）。
	// 注入的是同一个 Store；各包只看到自己声明的那几个方法。
	wsHandlers := wsapi.New(wsapi.Options{
		Hub: live, Store: st, Logger: logger, Monitor: incidents,
	})
	fileHandlers := files.New(files.Options{Store: st, Hub: live, Logger: logger})
	// 限流桶的键复用 httpapi.ClientIdentifier：信任边界只允许有一份实现。
	feedbackHandlers := feedback.New(feedback.Options{
		Store: st, ClientID: httpapi.ClientIdentifier, Logger: logger,
	})

	handler := httpapi.New(httpapi.Options{
		Store:            st,
		Health:           httpapi.Health{Version: version, Build: build},
		PairTTL:          cfg.PairTTL(),
		DeviceTTL:        cfg.DeviceTTL(),
		MaxPairedDevices: cfg.MaxPairedDevices,
		Limits:           limits,
		Hub:              live,
		WS:               wsHandlers,
		Files:            fileHandlers,
		Feedback:         feedbackHandlers,
		BasePath:         cfg.MountPath(),
		Logger:           logger,
		Monitor:          incidents,
		AccessLog:        cfg.AccessLog,
	})
	server := &http.Server{
		Handler: handler,
		// 静态端点的头读取上限；WebSocket 路径在 M2 按端点单独配。
		ReadHeaderTimeout: 10 * time.Second,
	}

	listener, err := net.Listen("tcp", net.JoinHostPort(cfg.Host, strconv.Itoa(cfg.Port)))
	if err != nil {
		logger.Error("relay: listen failed", "error", err,
			"host", cfg.Host, "port", cfg.Port)
		return 1
	}

	ctx, stopSignals := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stopSignals()

	// 用量冲盘与撤销对账随 ctx 结束退出；进程收尾的最后一次冲盘在下面单独做。
	live.StartBackground(ctx)
	// 监控的状态文件每 60 秒落一次（没变化时是空操作），与 Python 的 _monitor_tick 同口径。
	go monitorLoop(ctx, incidents)
	if described := incidents.Describe(); described["enabled"] == true {
		logger.Info("relay: incident monitor enabled",
			"alertDir", described["alertDir"], "maxPerHour", described["maxPerHour"],
			"maxPerDay", described["maxPerDay"],
			"flapThreshold", described["flapThreshold"])
	}

	serveErr := make(chan error, 1)
	go func() { serveErr <- server.Serve(listener) }()

	// 端口写实际监听的地址：--port 0 时只有这里能看出内核分配了哪个端口。
	logger.Info("relay: listening",
		"addr", "http://"+listener.Addr().String()+cfg.MountPath(),
		"db", st.Path(), "schemaVersion", st.Version(), "relayVersion", versionOrDefault(version),
		"basePath", cfg.MountPath(), "gcPercent", cfg.GCPercent, "gcPercentDefault", previousGC)

	select {
	case <-ctx.Done():
		logger.Info("relay: shutting down")
	case err := <-serveErr:
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("relay: serve failed", "error", err)
			return 1
		}
		return 0
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancel()
	// 先通知所有 WebSocket：http.Server.Shutdown **不等待**被劫持的连接，
	// 不先关它们的话，读循环会一直挂着，进程只能等到超时被 SIGKILL。
	// 连接关闭给 2 秒（关闭握手通常几十毫秒），剩下 3 秒留给 HTTP 收尾。
	linkCtx, linkCancel := context.WithTimeout(shutdownCtx, 2*time.Second)
	live.Shutdown(linkCtx)
	linkCancel()
	if err := server.Shutdown(shutdownCtx); err != nil {
		// 超时也要继续收尾：监听已关，残留连接由进程退出带走。
		logger.Warn("relay: shutdown incomplete", "error", err)
	}
	// 进程收尾也是"今天"的一部分：把内存里最后一批用量写掉再退出。写失败不阻止
	// 退出（账已经记在日志与内存里，但进程一走就没了——这是 M3 的已知边界）。
	flushCtx, flushCancel := context.WithTimeout(context.Background(), 3*time.Second)
	if err := live.FlushUsage(flushCtx); err != nil {
		logger.Warn("relay: final usage flush failed", "error", err)
	}
	flushCancel()
	// 关停时无条件把监控计数落盘：重启后同一类别不该再报一次。
	incidents.SaveState()
	logger.Info("relay: stopped")
	return 0
}

// monitorLoop 每 60 秒把监控的计数落一次盘（没变化时是空操作）。
func monitorLoop(ctx context.Context, incidents *monitor.Monitor) {
	ticker := time.NewTicker(time.Minute)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			incidents.Flush()
		}
	}
}

// executableDir 返回可执行文件所在目录；取不到时返回当前目录。
func executableDir() string {
	exe, err := os.Executable()
	if err != nil {
		return "."
	}
	return filepath.Dir(exe)
}

func versionOrDefault(version string) string {
	if version == "" {
		return httpapi.Unversioned
	}
	return version
}

func usage(w io.Writer) {
	fmt.Fprintln(w, "dsh-relay — DSH Link Protocol v1 中转（Go 版）")
	fmt.Fprintln(w)
	fmt.Fprintln(w, "用法:")
	fmt.Fprintln(w, "  dsh-relay [serve] [参数]              起中转（不带子命令时默认 serve）")
	fmt.Fprintln(w, "  dsh-relay admin --db <path> <子命令>  管理面（account-create / agent-register /")
	fmt.Fprintln(w, "                                        code-mint / invite-mint / device-list）")
	fmt.Fprintln(w, "  dsh-relay alert-dispatch [参数]      把告警队列投进信箱（运维 timer）")
	fmt.Fprintln(w, "  dsh-relay purge --db <path> ...      清理已撤销/已过期设备行（运维 timer）")
	fmt.Fprintln(w)
	fmt.Fprintln(w, "serve 参数（默认值见下；同名 DLP_* 环境变量改默认值，命令行覆盖环境变量）:")
	config.Usage(w)
}
