# DSH 中转 Go 版（M0）。
#
# 本机沙箱不允许写 ~/go，Go 的模块缓存与构建缓存固定在本目录下；所有 go 命令
# 都经 make 执行，保证环境变量一致。GOSUMDB=off 只用于本机开发，发布构建按 CI
# 口径恢复校验（见 maintainers/设计/20261023-Go中转重写.md）。
export GOMODCACHE := $(CURDIR)/.gocache/mod
export GOCACHE    := $(CURDIR)/.gocache/build
export GOPROXY    := https://goproxy.cn,direct
export GOSUMDB    := off
export GOFLAGS    := -trimpath
# 生产构建默认启用 cgo：CGO_ENABLED=1 时 store 用 mattn/go-sqlite3（基准更快），
# CGO_ENABLED=0 时自动退回纯 Go 的 modernc（见 internal/store/driver_*.go）。
export CGO_ENABLED := 1

BIN   := bin
RELAY := $(BIN)/dsh-relay
# 黑盒套件与演练脚本用仓库根目录的共享 Python 环境（依赖见 requirements-dev.txt）。
PYTHON ?= ../.venv/bin/python

.PHONY: all build build-purego test test-pkg test-purego test-blackbox soak-smoke vet fmt fmt-check size run clean

all: build

build:
	mkdir -p $(BIN)
	go build -o $(RELAY) ./cmd/dsh-relay

test:
	go test ./...

# 单包靶向测试（本地提交防线用）：make test-pkg PKG=internal/hub
test-pkg:
	go test ./$(PKG)

# 纯 Go 构建（无 cgo 机器 / 静态部署 / 交叉编译）。默认构建不走这条。
build-purego:
	mkdir -p $(BIN)
	CGO_ENABLED=0 go build -o $(BIN)/dsh-relay-purego ./cmd/dsh-relay

test-purego:
	CGO_ENABLED=0 go test ./...

# 黑盒契约套件对本二进制跑（tests/blackbox 只认 RELAY_CMD / ADMIN_CMD
# 两个环境变量，见该目录 conftest.py）。Python 依赖见 requirements-dev.txt。
test-blackbox: build
	RELAY_CMD="$(CURDIR)/$(RELAY) serve" ADMIN_CMD="$(CURDIR)/$(RELAY) admin" \
		$(PYTHON) -m pytest tests/blackbox -q

# soak 冒烟档（20 秒注入，验证脚本与二进制本身能跑通；不进默认 test）。
soak-smoke: build
	$(PYTHON) scripts/m4b/soak.py \
		--seconds 20 --sample 5 --devices 20 --agents 4

vet:
	go vet ./...

fmt:
	gofmt -l -w cmd internal

# 只检查本项目源码：gofmt -l . 会走进 .gocache/mod（第三方模块缓存，含故意写坏的
# testdata），那不是本仓库的代码。
fmt-check:
	@out="$$(gofmt -l cmd internal)"; if [ -n "$$out" ]; then echo "$$out"; exit 1; fi

# 二进制体积对照（-s -w 与发布构建同口径）。
size:
	mkdir -p $(BIN)/size
	CGO_ENABLED=0 go build -ldflags "-s -w" -o $(BIN)/size/dsh-relay-nocgo ./cmd/dsh-relay
	CGO_ENABLED=1 go build -ldflags "-s -w" -o $(BIN)/size/dsh-relay-cgo ./cmd/dsh-relay
	@ls -l $(BIN)/size

# 本机跑一次：随机端口、临时库更容易看清启动流程。
run: build
	./$(RELAY) serve --port 0 --db $(CURDIR)/.local/state.db

clean:
	rm -rf $(BIN)
