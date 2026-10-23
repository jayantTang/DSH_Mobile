package main

import (
	"context"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"net/http/pprof"
	"runtime"
	"time"
)

// pprofSampleRate 是开启 pprof 时的内存采样间隔。
//
// 默认 512 KiB 在 30k 帧的压测窗口里只有几百个样本，定位不到"每连接"的小对象；
// 16 KiB 能把每帧的分配也采到。代价是每次分配多一条栈采集，**会抬高 CPU**，
// 所以只在显式 --pprof-addr 时生效，不用于性能数字（README 里写明）。
const pprofSampleRate = 16 << 10

// startPprof 在 addr 上起一个只有 pprof 端点的 HTTP 服务。
//
// 返回停止函数与真正监听的地址（--port 0 时只有后者能说明绑到了哪个端口）。
// 地址的环回校验在 config.Validate 里做完：这里不做第二份判断，避免两处口径分叉。
// 默认不调用（--pprof-addr 为空）。
func startPprof(addr string, log *slog.Logger) (func(), string, error) {
	listener, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, "", err
	}
	runtime.MemProfileRate = pprofSampleRate

	// 独立 mux：不碰 http.DefaultServeMux，也不把 /debug/pprof 挂到对外的服务端口上。
	mux := http.NewServeMux()
	mux.HandleFunc("/debug/pprof/", pprof.Index)
	mux.HandleFunc("/debug/pprof/cmdline", pprof.Cmdline)
	mux.HandleFunc("/debug/pprof/profile", pprof.Profile)
	mux.HandleFunc("/debug/pprof/symbol", pprof.Symbol)
	mux.HandleFunc("/debug/pprof/trace", pprof.Trace)

	server := &http.Server{Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	go func() {
		if err := server.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Error("relay: pprof server stopped", "error", err)
		}
	}()
	log.Info("relay: pprof listening",
		"addr", "http://"+listener.Addr().String()+"/debug/pprof/",
		"memProfileRate", pprofSampleRate)

	stop := func() {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_ = server.Shutdown(ctx)
	}
	return stop, listener.Addr().String(), nil
}
