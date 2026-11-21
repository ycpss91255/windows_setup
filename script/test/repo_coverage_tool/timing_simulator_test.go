package main

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func simulatorFixture(t *testing.T) (string, string, string, string, string) {
	t.Helper()
	root, manifest, _ := shardCLIFixture(t)
	tests := []string{}
	for i := 0; i < 8; i++ {
		name := fmt.Sprintf("test/powershell/unit/side_%d_tests.ps1", i)
		tests = append(tests, name)
		if err := os.WriteFile(filepath.Join(root, filepath.FromSlash(name)), []byte("Value\n"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	runGit := func(args ...string) string {
		cmd := exec.Command("git", append([]string{"-C", root}, args...)...)
		b, e := cmd.CombinedOutput()
		if e != nil {
			t.Fatalf("git: %v %s", e, b)
		}
		return strings.TrimSpace(string(b))
	}
	maintenance := filepath.Join(root, "script", "maintenance.ps1")
	if err := os.MkdirAll(filepath.Dir(maintenance), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(maintenance, []byte("Write-Output maintenance\n"), 0600); err != nil {
		t.Fatal(err)
	}
	runGit("add", ".")
	runGit("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "more suites")
	sha := runGit("rev-parse", "HEAD")
	b, _ := json.Marshal(map[string]any{"SourceRoot": root, "Sources": []string{"core/value.ps1"}, "Tests": tests, "TestEngines": map[string]string{}, "Wrapper": "test/powershell/coverage/safe_suite.ps1"})
	if e := os.WriteFile(manifest, b, 0600); e != nil {
		t.Fatal(e)
	}
	parts := t.TempDir()
	receipts := []timingReceipt{}
	for i := 0; i < 4; i++ {
		dir := filepath.Join(parts, fmt.Sprint(i))
		writeShardCLIProof(t, root, dir, 100+i*2, true)
		bindShardCLIProof(t, root, dir, sha, i, 4, 1)
		workerPath := filepath.Join(dir, "worker_0.json")
		b, e := os.ReadFile(workerPath)
		if e != nil {
			t.Fatal(e)
		}
		var worker map[string]any
		if e = json.Unmarshal(b, &worker); e != nil {
			t.Fatal(e)
		}
		var w struct{ Context json.RawMessage }
		if e = json.Unmarshal(b, &w); e != nil {
			t.Fatal(e)
		}
		var r timingReceipt
		if e = json.Unmarshal(w.Context, &r.Context); e != nil {
			t.Fatal(e)
		}
		receipts = append(receipts, timingReceipt{1, r.Context, []timingPhase{{"worker_setup", int64(i + 1)}, {"pester_instrumentation_and_test", 0}, {"serialization", 0}}})
		worker["ProcessId"] = 200 + i
		ctx := worker["Context"].(map[string]any)
		ctx["ProcessId"] = 200 + i
		ctx["GlobalIndex"] = i + 4
		ctx["TestFile"] = tests[i+4]
		b, _ = json.Marshal(worker)
		if e = os.WriteFile(filepath.Join(dir, "worker_1.json"), b, 0600); e != nil {
			t.Fatal(e)
		}
		var r2 timingReceipt
		if e = json.Unmarshal(b, &w); e != nil {
			t.Fatal(e)
		}
		if e = json.Unmarshal(w.Context, &r2.Context); e != nil {
			t.Fatal(e)
		}
		receipts = append(receipts, timingReceipt{1, r2.Context, []timingPhase{{"worker_setup", int64(i + 5)}, {"pester_instrumentation_and_test", 0}, {"serialization", 0}}})
		p := filepath.Join(dir, "evidence.json")
		b, e = os.ReadFile(p)
		if e != nil {
			t.Fatal(e)
		}
		var proof map[string]any
		if e = json.Unmarshal(b, &proof); e != nil {
			t.Fatal(e)
		}
		workers := proof["Workers"].([]any)
		descriptor := map[string]any{}
		for k, v := range workers[0].(map[string]any) {
			descriptor[k] = v
		}
		descriptor["Index"] = 1
		descriptor["ProcessId"] = 200 + i
		descriptor["Evidence"] = "worker_1.json"
		proof["Workers"] = append(workers, descriptor)
		b, _ = json.Marshal(proof)
		if e = os.WriteFile(p, b, 0600); e != nil {
			t.Fatal(e)
		}
		if e = canonicalizeShardCLIProof(root, dir); e != nil {
			t.Fatal(e)
		}
		args := append(shardCLIArgs(root, manifest, sha), "--runtime", "--shard-count", "4", "--shard-index", fmt.Sprint(i), "--evidence-dir", dir)
		if e = powershellShardPack(args, os.Stdout); e != nil {
			t.Fatal(e)
		}
	}
	timing := filepath.Join(t.TempDir(), "timing.json")
	b, _ = json.Marshal(receipts)
	if e := os.WriteFile(timing, b, 0600); e != nil {
		t.Fatal(e)
	}
	return root, manifest, sha, parts, timing
}

func TestTimingSimulatorActualCLI(t *testing.T) {
	root, manifest, sha, parts, timing := simulatorFixture(t)
	cover := os.Getenv("WINDOWS_SETUP_CLI_COVERAGE_DIR")
	if cover == "" {
		cover = t.TempDir()
	}
	before, e := filepath.Glob(filepath.Join(cover, "covcounters.*"))
	if e != nil {
		t.Fatal(e)
	}
	t.Setenv("GOCOVERDIR", cover)
	exe := filepath.Join(t.TempDir(), "tool")
	if runtime.GOOS == "windows" {
		exe += ".exe"
	}
	repo, err := filepath.Abs("../../..")
	if err != nil {
		t.Fatal(err)
	}
	build := exec.Command("go", "build", "-mod=vendor", "-cover", "-coverpkg=./script/test/...", "-o", exe, "./script/test/repo_coverage_tool")
	build.Dir = repo
	if b, e := build.CombinedOutput(); e != nil {
		t.Fatalf("build: %v %s", e, b)
	}
	args := append([]string{"powershell-timing-simulate"}, shardCLIArgs(root, manifest, sha)...)
	args = append(args, "--runtime", "--shard-count", "4", "--input-dir", parts, "--timing-file", timing)
	b, e := exec.Command(exe, args...).CombinedOutput()
	if e != nil {
		t.Fatalf("valid timing simulation failed: %v %s", e, b)
	}
	withoutRuntime := make([]string, 0, len(args))
	for _, arg := range args {
		if arg != "--runtime" {
			withoutRuntime = append(withoutRuntime, arg)
		}
	}
	if out, err := exec.Command(exe, withoutRuntime...).CombinedOutput(); err == nil {
		t.Fatalf("accepted runtime manifest as full-source measurement: %s", out)
	}
	var report struct {
		Tool struct {
			Name          string `json:"name"`
			SchemaVersion int    `json:"schema_version"`
			BinarySHA256  string `json:"binary_sha256"`
			Revision      string `json:"revision"`
		} `json:"tool"`
		CriticalPath string                                  `json:"critical_path"`
		Catalog      []struct{ File, SHA256, Engine string } `json:"catalog"`
		Baseline     struct {
			Shards []struct {
				Suites            []int `json:"suites"`
				BatchMilliseconds int64 `json:"batch_milliseconds"`
			} `json:"shards"`
		} `json:"baseline"`
		Plans []struct {
			Shards []struct {
				Suites            []int `json:"suites"`
				BatchMilliseconds int64 `json:"batch_milliseconds"`
			} `json:"shards"`
		} `json:"plans"`
	}
	if e = json.Unmarshal(b, &report); e != nil {
		t.Fatal(e)
	}
	if report.CriticalPath != "unavailable" || len(report.Plans) != 2 {
		t.Fatalf("invalid report: %s", b)
	}
	binary, e := os.ReadFile(exe)
	if e != nil {
		t.Fatal(e)
	}
	if report.Tool.Name != "repo_coverage_tool" || report.Tool.SchemaVersion != 1 || report.Tool.BinarySHA256 != fmt.Sprintf("%x", sha256.Sum256(binary)) || report.Tool.Revision == sha || report.Tool.Revision == "" {
		t.Fatalf("tool identity missing or confused with measurement: %s", b)
	}
	if len(report.Catalog) != 8 || report.Catalog[0].File != "test/powershell/unit/side_0_tests.ps1" || len(report.Catalog[0].SHA256) != 64 || report.Catalog[0].Engine != "powershell" {
		t.Fatalf("missing identity mapping: %s", b)
	}
	if fmt.Sprint(report.Plans[0].Shards[0].Suites) != "[7 0]" || fmt.Sprint(report.Plans[0].Shards[3].Suites) != "[4 3]" {
		t.Fatalf("unexpected LPT assignment: %s", b)
	}
	if len(report.Baseline.Shards) != 4 || fmt.Sprint(report.Baseline.Shards[0].Suites) != "[0 4]" || report.Baseline.Shards[0].BatchMilliseconds != 5 || report.Plans[0].Shards[0].BatchMilliseconds != 8 {
		t.Fatalf("missing current modulo and pair-barrier model: %s", b)
	}
	for j, n := range []int{4, 8} {
		if len(report.Plans[j].Shards) != n {
			t.Fatalf("wrong shard count: %s", b)
		}
		seen := map[int]bool{}
		for _, s := range report.Plans[j].Shards {
			for _, id := range s.Suites {
				if id < 0 || id >= 8 || seen[id] {
					t.Fatalf("invalid suite assignment: %s", b)
				}
				seen[id] = true
			}
		}
		if len(seen) != 8 {
			t.Fatalf("missing suite: %s", b)
		}
	}
	original, e := os.ReadFile(timing)
	if e != nil {
		t.Fatal(e)
	}
	for _, kind := range []string{"missing", "duplicate", "unknown_suite", "wrong_attempt", "wrong_hash", "negative", "overflow"} {
		t.Run(kind, func(t *testing.T) {
			var rows []timingReceipt
			if e := json.Unmarshal(original, &rows); e != nil {
				t.Fatal(e)
			}
			switch kind {
			case "missing":
				rows = rows[1:]
			case "duplicate":
				rows[1] = rows[0]
			case "unknown_suite":
				rows[0].Context.GlobalIndex = 99
			case "wrong_attempt":
				rows[0].Context.RunAttempt++
			case "wrong_hash":
				rows[0].Context.TestSHA256 = strings.Repeat("a", 64)
			case "negative":
				rows[0].Phases[0].Milliseconds = -1
			case "overflow":
				rows[0].Phases[0].Milliseconds = 9223372036854775807
				rows[0].Phases[1].Milliseconds = 1
			}
			data, e := json.Marshal(rows)
			if e != nil {
				t.Fatal(e)
			}
			if e = os.WriteFile(timing, data, 0600); e != nil {
				t.Fatal(e)
			}
			if b, e := exec.Command(exe, args...).CombinedOutput(); e == nil {
				t.Fatalf("accepted %s: %s", kind, b)
			}
		})
	}
	after, e := filepath.Glob(filepath.Join(cover, "covcounters.*"))
	if e != nil || len(after) <= len(before) {
		t.Fatal("CLI commands emitted no Go runtime coverage counters")
	}
}
