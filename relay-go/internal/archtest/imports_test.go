// Package archtest 是结构性守卫：它不测行为，只测依赖方向。
//
// DESIGN-20261023 §2.2 的画法是硬规则的一部分：hub 不能反向依赖 HTTP/WS 服务包，
// quota/bridge/presence/push 不能反过来依赖 hub，store 只能依赖 reqctx。这些规则
// 一旦失守，包图会悄悄绕成环，收窄也就失效了。
package archtest

import (
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"
)

// modulePrefix 是模块内 import 路径的前缀；其余 import（标准库、第三方）不参与判定。
const modulePrefix = "github.com/jayantTang/DSH_Mobile/relay-go/"

// forbiddenImports 是 §2.2 的硬规则：键是包目录，值是它不允许 import 的内部包。
//
// 只写"反向"方向。正向（httpapi → hub、hub → quota/bridge 等）不在这里列举：
// 那是设计允许的，列出来只会让新增合法依赖时多改一处。
var forbiddenImports = map[string][]string{
	"internal/hub": {
		"internal/httpapi", "internal/wsapi", "internal/files", "internal/feedback",
	},
	"internal/quota": {
		"internal/hub", "internal/httpapi", "internal/wsapi", "internal/files",
		"internal/feedback",
	},
	"internal/bridge": {
		"internal/hub", "internal/httpapi", "internal/wsapi", "internal/files",
		"internal/feedback",
	},
	"internal/presence": {
		"internal/hub", "internal/httpapi", "internal/wsapi", "internal/files",
		"internal/feedback",
	},
	"internal/push": {
		"internal/hub", "internal/httpapi", "internal/wsapi", "internal/files",
		"internal/feedback",
	},
}

// storeAllowedInternal 是 store 唯一允许依赖的内部包（DESIGN §2.2：只 import reqctx）。
var storeAllowedInternal = map[string]bool{"internal/reqctx": true}

// internalDir 把一条 import 路径换成包目录；不是本模块的内部包时返回空串。
func internalDir(importPath string) string {
	if !strings.HasPrefix(importPath, modulePrefix+"internal/") {
		return ""
	}
	return strings.TrimPrefix(importPath, modulePrefix)
}

// checkImports 返回所有违反方向规则的边。纯函数，便于用合成数据证明规则真的会红。
//
// imports 的键是包目录（如 "internal/hub"），值是它 import 的全部路径。
func checkImports(imports map[string][]string) []string {
	var violations []string
	for pkg, paths := range imports {
		for _, importPath := range paths {
			target := internalDir(importPath)
			if target == "" {
				continue
			}
			if pkg == "internal/store" && !storeAllowedInternal[target] {
				violations = append(violations,
					"internal/store 不得依赖 "+target+"（只允许 reqctx）")
				continue
			}
			for _, forbidden := range forbiddenImports[pkg] {
				if target == forbidden {
					violations = append(violations, pkg+" 不得依赖 "+target)
				}
			}
		}
	}
	sort.Strings(violations)
	return violations
}

// scanImports 解析真实源码的 import（只看非测试文件：测试可以用更多包做集成）。
func scanImports(t *testing.T, root string) map[string][]string {
	t.Helper()
	imports := map[string][]string{}
	for _, top := range []string{"internal", "cmd"} {
		base := filepath.Join(root, top)
		err := filepath.WalkDir(base, func(path string, entry fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if entry.IsDir() || !strings.HasSuffix(path, ".go") ||
				strings.HasSuffix(path, "_test.go") {
				return nil
			}
			file, err := parser.ParseFile(token.NewFileSet(), path, nil, parser.ImportsOnly)
			if err != nil {
				return err
			}
			relative, err := filepath.Rel(root, filepath.Dir(path))
			if err != nil {
				return err
			}
			pkg := filepath.ToSlash(relative)
			for _, spec := range file.Imports {
				value, err := strconv.Unquote(spec.Path.Value)
				if err != nil {
					return err
				}
				imports[pkg] = append(imports[pkg], value)
			}
			return nil
		})
		if err != nil {
			t.Fatalf("扫描 %s 失败：%v", base, err)
		}
	}
	return imports
}

// repoRoot 用测试的工作目录回推 relay-go 根目录。
//
// 不能用 runtime.Caller：本仓库的 Makefile 带 -trimpath，编译期路径会变成模块
// 路径而不是文件系统路径。go test 会把工作目录设在包源码目录，因此
// internal/archtest → ../.. 是稳定的。
func repoRoot(t *testing.T) string {
	t.Helper()
	wd, err := os.Getwd()
	if err != nil {
		t.Fatalf("无法取得工作目录：%v", err)
	}
	return filepath.Dir(filepath.Dir(wd))
}

// TestDependencyDirections 是真实源码上的守卫。
func TestDependencyDirections(t *testing.T) {
	root := repoRoot(t)
	if _, err := os.Stat(filepath.Join(root, "go.mod")); err != nil {
		t.Fatalf("没有找到 %s/go.mod：%v", root, err)
	}
	imports := scanImports(t, root)

	// 先确认扫描真的看见了关键包；否则一次路径错误会让守卫永远绿。
	for _, pkg := range []string{
		"internal/hub", "internal/quota", "internal/bridge",
		"internal/presence", "internal/push", "internal/store",
	} {
		if len(imports[pkg]) == 0 {
			t.Fatalf("扫描结果里没有 %s 的 import（守卫失效）", pkg)
		}
	}

	if violations := checkImports(imports); len(violations) > 0 {
		t.Fatalf("依赖方向违规：\n  %s", strings.Join(violations, "\n  "))
	}
}

// TestDependencyRulesCatchReverseImports 证明规则本身会红：合成三条反向边，
// 必须全部被 checkImports 抓到（不是"永远绿"的空扫描）。
func TestDependencyRulesCatchReverseImports(t *testing.T) {
	violations := checkImports(map[string][]string{
		"internal/hub":   {modulePrefix + "internal/wsapi"},
		"internal/quota": {modulePrefix + "internal/hub"},
		"internal/store": {modulePrefix + "internal/hub"},
	})
	want := []string{
		"internal/hub 不得依赖 internal/wsapi",
		"internal/quota 不得依赖 internal/hub",
		"internal/store 不得依赖 internal/hub（只允许 reqctx）",
	}
	sort.Strings(want)
	if strings.Join(violations, "\n") != strings.Join(want, "\n") {
		t.Fatalf("规则抓到的违规 = %v，期望 %v", violations, want)
	}

	// 合法图必须无违规：正向依赖与 store → reqctx 都不算越界。
	clean := checkImports(map[string][]string{
		"internal/httpapi": {modulePrefix + "internal/hub", modulePrefix + "internal/wsapi"},
		"internal/hub":     {modulePrefix + "internal/quota", modulePrefix + "internal/push"},
		"internal/quota":   {modulePrefix + "internal/store"},
		"internal/store":   {modulePrefix + "internal/reqctx"},
	})
	if len(clean) != 0 {
		t.Fatalf("合法依赖被误判：%v", clean)
	}
}
