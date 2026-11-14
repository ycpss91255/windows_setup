package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	rc "windows_setup/script/test/repo_coverage"
)

func TestRuntimeVerifyEnforcesScopeSourceAndExactThreshold(t *testing.T) {
	root := t.TempDir()
	core := filepath.Join(root, "core")
	if err := os.Mkdir(core, 0700); err != nil {
		t.Fatal(err)
	}
	source := filepath.Join(core, "sample.ps1")
	if err := os.WriteFile(source, []byte("Write-Output 'fixture'\n"), 0600); err != nil {
		t.Fatal(err)
	}
	inv, err := rc.ScanRuntimeInventory(root)
	if err != nil || len(inv.Sources) != 1 {
		t.Fatalf("inventory: %+v %v", inv, err)
	}
	inv.Sources[0].ExpectedLines = []int{1, 2, 3, 4, 5}
	name := inv.Sources[0].Path
	identity := rc.Identity{Commit: strings.Repeat("a", 40), RunUrl: "https://github.com/example/repo/actions/runs/1", MeasuredAt: "2026-01-01T00:00:00Z", SourceState: "Clean"}
	write := func(dir string, hits int, legacy bool) {
		t.Helper()
		lines := map[int]bool{}
		for i := 1; i <= 5; i++ {
			lines[i] = i <= hits
		}
		report := rc.Report{SchemaVersion: rc.SchemaVersion, Metric: rc.Metric, Files: map[string]map[int]bool{name: lines}}
		var a rc.Artifacts
		var e error
		if legacy {
			a, e = rc.CreateEvidence(inv, []rc.Report{report}, identity)
		} else {
			a, e = rc.CreateRuntimeEvidence(inv, []rc.Report{report}, identity)
		}
		if e != nil {
			t.Fatal(e)
		}
		for filename, data := range map[string][]byte{"repo_coverage.json": a.Summary, "coverage_inventory.json": a.Inventory, "coverage.xml": a.XML} {
			if e = os.WriteFile(filepath.Join(dir, filename), data, 0600); e != nil {
				t.Fatal(e)
			}
		}
	}
	args := func(dir string) []string {
		return []string{"verify", "--runtime", "--artifact-dir", dir, "--expected-sha", identity.Commit, "--expected-run-url", identity.RunUrl, "--source-root", root, "--require-complete", "--minimum-percent", "80"}
	}
	valid := t.TempDir()
	write(valid, 4, false)
	var out bytes.Buffer
	if err = run(args(valid), &out); err != nil {
		t.Fatalf("exact 80 percent rejected: %v", err)
	}
	low := t.TempDir()
	write(low, 3, false)
	if err = run(args(low), &out); err == nil {
		t.Error("below 80 percent accepted")
	}
	old := t.TempDir()
	write(old, 4, true)
	if err = run(args(old), &out); err == nil {
		t.Error("historical all-owned evidence accepted as runtime")
	}
	if err = os.Remove(source); err != nil {
		t.Fatal(err)
	}
	if err = run(args(valid), &out); err == nil {
		t.Error("missing runtime source accepted")
	}
}
