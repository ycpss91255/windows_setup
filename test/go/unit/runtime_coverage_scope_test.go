package unit_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	rc "windows_setup/script/test/repo_coverage"
)

func TestRuntimeCoverageInventoryScopeAndUnknownExecutable(t *testing.T) {
	root := t.TempDir()
	files := map[string]string{
		"core/start.ps1":             "Write-Output 'fixture'\n",
		"modules/demo/app.ps1":       "Write-Output 'fixture'\n",
		"modules/demo/native/app.cs": "class Demo { int Value() { return 1; } }\n",
		"core/launch.cmd":            "@echo off\r\npowershell.exe -File \"%~dp0start.ps1\"\r\n",
		"script/test/tool.go":        "package main\nfunc main() {}\n",
	}
	for name, data := range files {
		path := filepath.Join(root, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(data), 0600); err != nil {
			t.Fatal(err)
		}
	}
	inv, err := rc.ScanRuntimeInventory(root)
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]bool{}
	for _, s := range inv.Sources {
		got[s.Path] = true
	}
	if len(got) != 3 || !got["core/start.ps1"] || !got["modules/demo/app.ps1"] || !got["modules/demo/native/app.cs"] {
		t.Fatalf("incorrect runtime roster: %v", got)
	}
	if len(inv.Blockers) != 0 {
		t.Fatalf("valid scope blocked: %v", inv.Blockers)
	}
	for _, name := range []string{"core/native/new.cs", "modules/demo/new.py", "core/new.go", "modules/demo/new.exe", "modules/demo/new.wsf", "modules/demo/new.vbe", "modules/demo/new.jar", "modules/demo/new.wasm", "modules/demo/new.msi"} {
		path := filepath.Join(root, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("fixture"), 0600); err != nil {
			t.Fatal(err)
		}
		inv, err = rc.ScanRuntimeInventory(root)
		if err != nil {
			t.Fatal(err)
		}
		found := false
		for _, blocker := range inv.Blockers {
			if strings.HasPrefix(blocker, name+":") {
				found = true
			}
		}
		if !found {
			t.Errorf("new unsupported runtime executable not blocked: %s", name)
		}
	}
}

func TestRuntimeCoverageInventoryActualSource(t *testing.T) {
	root, err := filepath.Abs("../../..")
	if err != nil {
		t.Fatal(err)
	}
	inv, err := rc.ScanRuntimeInventory(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(inv.Blockers) != 0 || len(inv.Sources) == 0 {
		t.Fatalf("actual runtime inventory blocked or empty: %v", inv.Blockers)
	}
}

func TestRuntimeInventoryDoesNotExcludeOwnedNamedDirectories(t *testing.T) {
	root := t.TempDir()
	paths := []string{"core/win11debloat/owned.ps1", "modules/demo/win11debloat/owned.ps1", "core/vendor/owned.ps1", "modules/demo/test/owned.psm1", "core/docs/owned.ps1", "modules/demo/reports/owned.ps1", "modules/demo/coverage/owned.ps1"}
	for _, name := range append(append([]string{}, paths...), "modules/debloat/win11debloat/upstream.ps1") {
		p := filepath.Join(root, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(p), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte("Write-Output 1\n"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	inv, err := rc.ScanRuntimeInventory(root)
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]bool{}
	for _, source := range inv.Sources {
		got[source.Path] = true
	}
	for _, name := range paths {
		if !got[name] {
			t.Errorf("owned source silently excluded: %s", name)
		}
	}
	if got["modules/debloat/win11debloat/upstream.ps1"] {
		t.Fatal("actual pinned third-party source included")
	}
}
