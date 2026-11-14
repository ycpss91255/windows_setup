package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	rc "windows_setup/script/test/repo_coverage"
)

func shardCLIFixture(t *testing.T) (string, string, string) {
	t.Helper()
	root := t.TempDir()
	for name, text := range map[string]string{"core/value.ps1": "function Value { return 1 }\n", "test/powershell/unit/side_0_tests.ps1": "Value\n", "test/powershell/unit/side_1_tests.ps1": "Value\n", "test/powershell/coverage/safe_suite.ps1": "param($SuitePath,$SourceRoot)\n& $SuitePath\n"} {
		p := filepath.Join(root, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(p), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(text), 0600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.MkdirAll(filepath.Join(root, "test/powershell/integration"), 0700); err != nil {
		t.Fatal(err)
	}
	git := func(args ...string) string {
		t.Helper()
		cmd := exec.Command("git", append([]string{"-C", root}, args...)...)
		b, e := cmd.CombinedOutput()
		if e != nil {
			t.Fatalf("git fixture: %v %s", e, b)
		}
		return strings.TrimSpace(string(b))
	}
	git("init", "-q")
	git("add", ".")
	git("-c", "user.name=CoverageFixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture")
	sha := git("rev-parse", "HEAD")
	manifest := filepath.Join(t.TempDir(), "manifest.json")
	b, _ := json.Marshal(map[string]any{"SourceRoot": root, "Sources": []string{"core/value.ps1"}, "Tests": []string{"test/powershell/unit/side_0_tests.ps1", "test/powershell/unit/side_1_tests.ps1"}, "TestEngines": map[string]string{}, "Wrapper": "test/powershell/coverage/safe_suite.ps1"})
	if err := os.WriteFile(manifest, b, 0600); err != nil {
		t.Fatal(err)
	}
	return root, manifest, sha
}

func shardCLIArgs(root, manifest, sha string) []string {
	return []string{"--source-root", root, "--manifest", manifest, "--expected-sha", sha, "--expected-run-url", "https://github.com/example/repo/actions/runs/123", "--run-attempt", "1", "--shard-count", "2"}
}

func TestPowerShellShardPlanPreservesCanonicalScope(t *testing.T) {
	root, manifest, sha := shardCLIFixture(t)
	output := filepath.Join(t.TempDir(), "plan")
	args := append(shardCLIArgs(root, manifest, sha), "--shard-index", "1", "--output-dir", output)
	if err := powershellShardPlan(args, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(filepath.Join(output, "privatecollection_manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	var plan shardCollectionManifest
	if err = json.Unmarshal(b, &plan); err != nil {
		t.Fatal(err)
	}
	if plan.SourceRoot != root || len(plan.Sources) != 1 || len(plan.Tests) != 1 || plan.Tests[0] != "test/powershell/unit/side_1_tests.ps1" || plan.Wrapper != "test/powershell/coverage/safe_suite.ps1" || plan.ShardContext == nil || plan.ShardContext.Commit != sha || plan.ShardContext.RunAttempt != 1 || len(plan.ShardContext.GlobalIndices) != 1 || plan.ShardContext.GlobalIndices[0] != 1 {
		t.Fatalf("scope changed: %#v", plan)
	}
	if err := powershellShardPlan(args, &bytes.Buffer{}); err == nil {
		t.Fatal("existing output accepted")
	}
}

func TestRuntimeShardIgnoresMaintenanceSource(t *testing.T) {
	root, manifest, _ := shardCLIFixture(t)
	path := filepath.Join(root, "script", "maintenance.ps1")
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("Write-Output 'maintenance'\n"), 0600); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{{"add", "script/maintenance.ps1"}, {"-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "maintenance"}} {
		if b, e := exec.Command("git", append([]string{"-C", root}, args...)...).CombinedOutput(); e != nil {
			t.Fatalf("git: %v %s", e, b)
		}
	}
	b, err := exec.Command("git", "-C", root, "rev-parse", "HEAD").Output()
	if err != nil {
		t.Fatal(err)
	}
	args := append(shardCLIArgs(root, manifest, strings.TrimSpace(string(b))), "--runtime", "--shard-index", "0", "--output-dir", filepath.Join(t.TempDir(), "plan"))
	if err := powershellShardPlan(args, &bytes.Buffer{}); err != nil {
		t.Fatalf("runtime shard includes maintenance source: %v", err)
	}
}

func TestRuntimePowerShellExportIgnoresMaintenanceSource(t *testing.T) {
	root, _, _ := shardCLIFixture(t)
	proof := filepath.Join(t.TempDir(), "proof")
	writeShardCLIProof(t, root, proof, 12, true)
	path := filepath.Join(root, "script", "maintenance.ps1")
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("Write-Output 'maintenance'\n"), 0600); err != nil {
		t.Fatal(err)
	}
	args := []string{"--runtime", "--source-root", root, "--evidence-dir", proof, "--output-dir", filepath.Join(t.TempDir(), "output")}
	if err := exportPowerShell(args, &bytes.Buffer{}); err != nil {
		t.Fatalf("runtime raw export rejected: %v", err)
	}
}

func TestRuntimeShardIncludesPowerShellModules(t *testing.T) {
	root, manifest, _ := shardCLIFixture(t)
	if err := os.WriteFile(filepath.Join(root, "core", "helper.psm1"), []byte("function Get-Helper { 1 }\n"), 0600); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{{"add", "core/helper.psm1"}, {"-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "module"}} {
		if b, e := exec.Command("git", append([]string{"-C", root}, args...)...).CombinedOutput(); e != nil {
			t.Fatalf("git: %v %s", e, b)
		}
	}
	head, err := exec.Command("git", "-C", root, "rev-parse", "HEAD").Output()
	if err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(manifest)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err = json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	m["Sources"] = []string{"core/helper.psm1", "core/value.ps1"}
	b, _ = json.Marshal(m)
	if err = os.WriteFile(manifest, b, 0600); err != nil {
		t.Fatal(err)
	}
	args := append(shardCLIArgs(root, manifest, strings.TrimSpace(string(head))), "--runtime", "--shard-index", "0", "--output-dir", filepath.Join(t.TempDir(), "plan"))
	if err := powershellShardPlan(args, &bytes.Buffer{}); err != nil {
		t.Fatalf("runtime module rejected: %v", err)
	}
}

func TestPowerShellShardPlanRejectsMissingCanonicalTest(t *testing.T) {
	root, manifest, sha := shardCLIFixture(t)
	b, _ := os.ReadFile(manifest)
	var m map[string]any
	_ = json.Unmarshal(b, &m)
	m["Tests"] = []string{"test/powershell/unit/side_0_tests.ps1"}
	b, _ = json.Marshal(m)
	_ = os.WriteFile(manifest, b, 0600)
	if err := powershellShardPlan(append(shardCLIArgs(root, manifest, sha), "--shard-index", "0", "--output-dir", filepath.Join(t.TempDir(), "plan")), &bytes.Buffer{}); err == nil {
		t.Fatal("reduced canonical test scope accepted")
	}
}

func TestPowerShellShardCLIRejectsInvalidIdentityAndArguments(t *testing.T) {
	funcs := []func([]string, *bytes.Buffer) error{
		func(a []string, b *bytes.Buffer) error { return powershellShardPlan(a, b) },
		func(a []string, b *bytes.Buffer) error { return powershellShardPack(a, b) },
		func(a []string, b *bytes.Buffer) error { return powershellShardMerge(a, b) },
	}
	for _, f := range funcs {
		for _, args := range [][]string{nil, {"--unknown"}, {"extra"}, {"--source-root", "."}} {
			if f(args, &bytes.Buffer{}) == nil {
				t.Fatal("invalid command accepted")
			}
		}
	}
	root, manifest, sha := shardCLIFixture(t)
	base := shardCLIArgs(root, manifest, sha)
	for _, change := range [][]string{{"--expected-sha", strings.Repeat("A", 40)}, {"--expected-run-url", "http://example.invalid"}, {"--run-attempt", "0"}, {"--shard-count", "0"}, {"--shard-count", "5"}, {"--shard-index", "-1"}, {"--shard-index", "2"}} {
		args := append(append([]string{}, base...), "--shard-index", "0", "--output-dir", filepath.Join(t.TempDir(), "out"))
		args = append(args, change...)
		if powershellShardPlan(args, &bytes.Buffer{}) == nil {
			t.Fatalf("invalid identity accepted %v", change)
		}
	}
}

func TestPowerShellShardPlanRejectsTamperedManifestAndOutput(t *testing.T) {
	for _, kind := range []string{"source", "tests", "wrapper", "engine", "root", "unknown", "duplicate", "trailing", "missing", "dirty", "wrong_commit", "inside_output", "existing_output", "few_tests"} {
		t.Run(kind, func(t *testing.T) {
			root, manifest, sha := shardCLIFixture(t)
			b, _ := os.ReadFile(manifest)
			var m map[string]any
			_ = json.Unmarshal(b, &m)
			output := filepath.Join(t.TempDir(), "plan")
			switch kind {
			case "source":
				m["Sources"] = []string{}
			case "tests":
				m["Tests"] = []string{"test/powershell/unit/side_1_tests.ps1", "test/powershell/unit/side_0_tests.ps1"}
			case "wrapper":
				m["Wrapper"] = "test/powershell/coverage/other.ps1"
			case "engine":
				m["TestEngines"] = map[string]string{"test/powershell/unit/side_0_tests.ps1": "pwsh"}
			case "root":
				m["SourceRoot"] = t.TempDir()
			case "unknown":
				m["Extra"] = true
			case "missing":
				delete(m, "Tests")
			case "dirty":
				_ = os.WriteFile(filepath.Join(root, "untracked.txt"), []byte("not clean"), 0600)
			case "wrong_commit":
				sha = strings.Repeat("a", 40)
			case "inside_output":
				output = filepath.Join(root, "untracked_output")
			case "existing_output":
				output = t.TempDir()
			}
			b, _ = json.Marshal(m)
			if kind == "duplicate" {
				b = append([]byte(`{"SourceRoot":"ignored",`), b[1:]...)
			}
			if kind == "trailing" {
				b = append(b, []byte(` {}`)...)
			}
			_ = os.WriteFile(manifest, b, 0600)
			args := append(shardCLIArgs(root, manifest, sha), "--shard-index", "0", "--output-dir", output)
			if kind == "few_tests" {
				args = append(args, "--shard-count", "3")
			}
			if err := powershellShardPlan(args, &bytes.Buffer{}); err == nil {
				t.Fatalf("invalid %s accepted", kind)
			}
		})
	}
}

// Synthetic typed evidence exercises transport validation only; the parent
// integration suite separately runs actual Pester workers on original files.
func writeShardCLIProof(t *testing.T, root, dir string, pid int, hit bool) {
	t.Helper()
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	text, _ := os.ReadFile(filepath.Join(root, "core/value.ps1"))
	hash := fmt.Sprintf("%x", sha256.Sum256(text))
	engineHash := strings.Repeat("b", 64)
	source := map[string]any{"File": "core/value.ps1", "SHA256": hash, "ExpectedLines": []int{1}}
	worker := map[string]any{"ProcessId": pid, "Engine": "powershell", "EngineVersion": "5.1.0.0", "EngineSHA256": engineHash, "PesterVersion": "6.0.0", "Sources": []any{source}, "Commands": []any{map[string]any{"File": "core/value.ps1", "Line": 1, "Column": 1, "EndLine": 1, "EndColumn": 25, "Hit": hit}}}
	covered := 0
	if hit {
		covered = 1
	}
	proof := map[string]any{"SchemaVersion": 1, "PesterVersion": "6.0.0", "PackageSHA512": "AHIAm7QW11As3sjMayo1rPU4JVIEfBL+ZILAyTyDnMPxMwLFQ3VeAA0prFTx+Y4DgZCUnH2N4+Xb0HDQua2EKA==", "Metric": "FullyCoveredCommandStartLines", "Sources": []any{source}, "Workers": []any{map[string]any{"Index": 0, "ProcessId": pid, "Evidence": "worker_0.json", "Engine": "powershell", "EngineVersion": "5.1.0.0", "EngineSHA256": engineHash}}, "Covered": covered, "Total": 1}
	for name, value := range map[string]any{"worker_0.json": worker, "evidence.json": proof} {
		b, _ := json.Marshal(value)
		if err := os.WriteFile(filepath.Join(dir, name), b, 0600); err != nil {
			t.Fatal(err)
		}
	}
	xml := fmt.Sprintf(`<coverage coverage-schema="1" coverage-metric="complete-executable-lines-v1"><packages><package><classes><class filename="core/value.ps1"><lines><line number="1" hits="%d"/></lines></class></classes></package></packages></coverage>`, covered)
	if err := os.WriteFile(filepath.Join(dir, "coverage.xml"), []byte(xml), 0600); err != nil {
		t.Fatal(err)
	}
	if err := canonicalizeShardCLIProof(root, dir); err != nil {
		t.Fatal(err)
	}
}

func canonicalizeShardCLIProof(root, dir string) error {
	inv, err := rc.ScanInventory(root)
	if err != nil {
		return err
	}
	proof, err := os.ReadFile(filepath.Join(dir, "evidence.json"))
	if err != nil {
		return err
	}
	files, err := rc.ExportPowerShellRawEvidence(proof, func(name string) ([]byte, error) { return os.ReadFile(filepath.Join(dir, name)) }, inv)
	if err != nil {
		return err
	}
	for name, b := range files {
		if err = os.WriteFile(filepath.Join(dir, name), b, 0600); err != nil {
			return err
		}
	}
	return nil
}

func bindShardCLIProof(t *testing.T, root, dir, commit string, index, count, attempt int) {
	t.Helper()
	path := filepath.Join(dir, "worker_0.json")
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var worker map[string]any
	if err = json.Unmarshal(b, &worker); err != nil {
		t.Fatal(err)
	}
	test := fmt.Sprintf("test/powershell/unit/side_%d_tests.ps1", index)
	testBytes, _ := os.ReadFile(filepath.Join(root, filepath.FromSlash(test)))
	wrapper := "test/powershell/coverage/safe_suite.ps1"
	wrapperBytes, _ := os.ReadFile(filepath.Join(root, filepath.FromSlash(wrapper)))
	worker["Context"] = map[string]any{"Commit": commit, "RunUrl": "https://github.com/example/repo/actions/runs/123", "RunAttempt": attempt, "ShardIndex": index, "ShardCount": count, "GlobalIndex": index, "ProcessId": worker["ProcessId"], "TestFile": test, "TestSHA256": fmt.Sprintf("%x", sha256.Sum256(testBytes)), "WrapperFile": wrapper, "WrapperSHA256": fmt.Sprintf("%x", sha256.Sum256(wrapperBytes))}
	b, err = json.Marshal(worker)
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(path, b, 0600); err != nil {
		t.Fatal(err)
	}
	if err := canonicalizeShardCLIProof(root, dir); err != nil {
		t.Fatal(err)
	}
}

func TestPowerShellShardPackAndMergePreserveNativeFields(t *testing.T) {
	root, manifest, sha := shardCLIFixture(t)
	parts := t.TempDir()
	for index := 0; index < 2; index++ {
		dir := filepath.Join(parts, fmt.Sprintf("part_%d", index))
		writeShardCLIProof(t, root, dir, 123+index, index == 1)
		bindShardCLIProof(t, root, dir, sha, index, 2, 1)
		args := append(shardCLIArgs(root, manifest, sha), "--shard-index", fmt.Sprint(index), "--evidence-dir", dir)
		if err := powershellShardPack(args, &bytes.Buffer{}); err != nil {
			t.Fatal(err)
		}
		if err := powershellShardPack(args, &bytes.Buffer{}); err == nil {
			t.Fatal("repacked existing envelope")
		}
	}
	output := filepath.Join(t.TempDir(), "merged")
	args := append(shardCLIArgs(root, manifest, sha), "--input-dir", parts, "--output-dir", output)
	if err := powershellShardMerge(args, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(filepath.Join(output, "evidence.json"))
	if err != nil {
		t.Fatal(err)
	}
	var proof struct {
		Covered, Total int
		Workers        []struct{ Index, ProcessId int }
	}
	if err = json.Unmarshal(b, &proof); err != nil {
		t.Fatal(err)
	}
	if proof.Covered != 1 || proof.Total != 1 || len(proof.Workers) != 2 || proof.Workers[1].Index != 1 || proof.Workers[1].ProcessId != 124 {
		t.Fatalf("evidence identity or actual hit union changed: %#v", proof)
	}
	if err := powershellShardMerge(args, &bytes.Buffer{}); err == nil {
		t.Fatal("existing merge output accepted")
	}
}

func TestPowerShellShardPackAndMergeRejectBadInputs(t *testing.T) {
	root, manifest, sha := shardCLIFixture(t)
	base := shardCLIArgs(root, manifest, sha)
	for _, kind := range []string{"missing", "private_extra", "missing_suite", "invalid_raw"} {
		t.Run("pack_"+kind, func(t *testing.T) {
			dir := filepath.Join(t.TempDir(), "proof")
			writeShardCLIProof(t, root, dir, 123, true)
			count := 2
			if kind == "missing_suite" {
				count = 1
			}
			bindShardCLIProof(t, root, dir, sha, 0, count, 1)
			args := append(append([]string{}, base...), "--shard-index", "0", "--evidence-dir", dir)
			switch kind {
			case "missing":
				_ = os.Remove(filepath.Join(dir, "evidence.json"))
			case "private_extra":
				_ = os.WriteFile(filepath.Join(dir, "private.log"), []byte("never upload"), 0600)
			case "missing_suite":
				args = append(args, "--shard-count", "1")
			case "invalid_raw":
				_ = os.WriteFile(filepath.Join(dir, "worker_0.json"), []byte(`{}`), 0600)
			}
			if err := powershellShardPack(args, &bytes.Buffer{}); err == nil {
				t.Fatalf("bad %s accepted", kind)
			}
			if _, err := os.Stat(filepath.Join(dir, "shard.json")); err == nil {
				t.Fatal("failed pack wrote success envelope")
			}
		})
	}
	for _, kind := range []string{"missing_part", "file_part", "missing_manifest", "invalid_manifest", "wrong_attempt", "changed_worker"} {
		t.Run("merge_"+kind, func(t *testing.T) {
			parts := t.TempDir()
			for i := 0; i < 2; i++ {
				dir := filepath.Join(parts, fmt.Sprint(i))
				writeShardCLIProof(t, root, dir, 123+i, true)
				bindShardCLIProof(t, root, dir, sha, i, 2, 1)
				if err := powershellShardPack(append(append([]string{}, base...), "--shard-index", fmt.Sprint(i), "--evidence-dir", dir), &bytes.Buffer{}); err != nil {
					t.Fatal(err)
				}
			}
			file := filepath.Join(parts, "1", "shard.json")
			switch kind {
			case "missing_part":
				if err := os.Rename(filepath.Join(parts, "1"), filepath.Join(t.TempDir(), "moved")); err != nil {
					t.Fatal(err)
				}
			case "file_part":
				if err := os.Rename(filepath.Join(parts, "1"), filepath.Join(t.TempDir(), "moved")); err != nil {
					t.Fatal(err)
				}
				_ = os.WriteFile(filepath.Join(parts, "file"), []byte("bad"), 0600)
			case "missing_manifest":
				_ = os.Remove(file)
			case "invalid_manifest":
				_ = os.WriteFile(file, []byte(`{}`), 0600)
			case "wrong_attempt":
				b, _ := os.ReadFile(file)
				var v map[string]any
				_ = json.Unmarshal(b, &v)
				v["RunAttempt"] = 2
				b, _ = json.Marshal(v)
				_ = os.WriteFile(file, b, 0600)
			case "changed_worker":
				_ = os.WriteFile(filepath.Join(parts, "1", "worker_0.json"), []byte(`{}`), 0600)
			}
			output := filepath.Join(t.TempDir(), "merged")
			if err := powershellShardMerge(append(append([]string{}, base...), "--input-dir", parts, "--output-dir", output), &bytes.Buffer{}); err == nil {
				t.Fatalf("bad %s accepted", kind)
			}
			if _, err := os.Stat(output); err == nil {
				t.Fatal("failed validation created output")
			}
		})
	}
}

func TestPowerShellShardInstrumentedCommands(t *testing.T) {
	source, manifest, sha := shardCLIFixture(t)
	repo, err := filepath.Abs("../../..")
	if err != nil {
		t.Fatal(err)
	}
	executable := filepath.Join(t.TempDir(), "shards.exe")
	goexe := filepath.Join(runtime.GOROOT(), "bin", "go")
	if runtime.GOOS == "windows" {
		goexe += ".exe"
	}
	build := exec.Command(goexe, "build", "-mod=vendor", "-cover", "-coverpkg=./script/test/...", "-o", executable, "./script/test/repo_coverage_tool")
	build.Dir = repo
	if b, err := build.CombinedOutput(); err != nil {
		t.Fatalf("instrumented build: %v %s", err, b)
	}
	cover := os.Getenv("WINDOWS_SETUP_CLI_COVERAGE_DIR")
	if cover == "" {
		cover = t.TempDir()
	}
	invoke := func(want bool, args ...string) {
		t.Helper()
		cmd := exec.Command(executable, args...)
		cmd.Env = append(os.Environ(), "GOCOVERDIR="+cover)
		b, e := cmd.CombinedOutput()
		if (e == nil) != want {
			t.Fatalf("real instrumented command %v: %v %s", args, e, b)
		}
	}
	common := shardCLIArgs(source, manifest, sha)
	for _, command := range []string{"powershell-shard-plan", "powershell-shard-pack", "powershell-shard-merge"} {
		invoke(false, command)
		invoke(false, command, "--bad-flag")
	}
	for i := 0; i < 2; i++ {
		invoke(true, append([]string{"powershell-shard-plan"}, append(append([]string{}, common...), "--shard-index", fmt.Sprint(i), "--output-dir", filepath.Join(t.TempDir(), "plan"))...)...)
	}
	parts := t.TempDir()
	for i := 0; i < 2; i++ {
		dir := filepath.Join(parts, fmt.Sprint(i))
		writeShardCLIProof(t, source, dir, 700+i, i == 1)
		bindShardCLIProof(t, source, dir, sha, i, 2, 1)
		args := append([]string{"powershell-shard-pack"}, append(append([]string{}, common...), "--shard-index", fmt.Sprint(i), "--evidence-dir", dir)...)
		invoke(true, args...)
		invoke(false, args...)
	}
	invoke(false, append([]string{"powershell-shard-merge"}, append(append([]string{}, common...), "--input-dir", t.TempDir(), "--output-dir", filepath.Join(t.TempDir(), "incomplete"))...)...)
	invoke(true, append([]string{"powershell-shard-merge"}, append(append([]string{}, common...), "--input-dir", parts, "--output-dir", filepath.Join(t.TempDir(), "merged"))...)...)
	counters, err := filepath.Glob(filepath.Join(cover, "covcounters.*"))
	if err != nil || len(counters) == 0 {
		t.Fatal("real commands did not emit Go runtime counters")
	}
}

func TestPowerShellShardPackRejectsUnboundNativeContext(t *testing.T) {
	root, manifest, sha := shardCLIFixture(t)
	dir := filepath.Join(t.TempDir(), "unbound")
	writeShardCLIProof(t, root, dir, 123, true)
	args := append(shardCLIArgs(root, manifest, sha), "--shard-index", "0", "--evidence-dir", dir)
	if err := powershellShardPack(args, &bytes.Buffer{}); err == nil {
		t.Fatal("native worker without actual case/run context must not be relabelled into a current shard")
	}
}

func TestPowerShellShardPackCannotRelabelActualNativeContext(t *testing.T) {
	for _, field := range []string{"attempt", "case", "pid", "wrapper", "run", "commit"} {
		t.Run(field, func(t *testing.T) {
			root, manifest, sha := shardCLIFixture(t)
			dir := filepath.Join(t.TempDir(), "proof")
			writeShardCLIProof(t, root, dir, 123, true)
			bindShardCLIProof(t, root, dir, sha, 0, 2, 1)
			path := filepath.Join(dir, "worker_0.json")
			b, _ := os.ReadFile(path)
			var native map[string]any
			_ = json.Unmarshal(b, &native)
			context := native["Context"].(map[string]any)
			switch field {
			case "attempt":
				context["RunAttempt"] = 2
			case "case":
				context["GlobalIndex"] = 1
				context["ShardIndex"] = 1
				context["TestFile"] = "test/powershell/unit/side_1_tests.ps1"
			case "pid":
				context["ProcessId"] = 999
			case "wrapper":
				context["WrapperSHA256"] = strings.Repeat("f", 64)
			case "run":
				context["RunUrl"] = "https://github.com/example/repo/actions/runs/124"
			case "commit":
				context["Commit"] = strings.Repeat("f", 40)
			}
			b, _ = json.Marshal(native)
			_ = os.WriteFile(path, b, 0600)
			if err := canonicalizeShardCLIProof(root, dir); err != nil && field != "pid" {
				t.Fatal(err)
			}
			err := powershellShardPack(append(shardCLIArgs(root, manifest, sha), "--shard-index", "0", "--evidence-dir", dir), &bytes.Buffer{})
			if err == nil {
				t.Fatalf("actual native %s context was silently relabelled", field)
			}
			if _, e := os.Stat(filepath.Join(dir, "shard.json")); e == nil {
				t.Fatal("invalid native context created successful shard envelope")
			}
		})
	}
}

func TestPowerShellShardPackRejectsUnexportedPrivateXML(t *testing.T) {
	root, manifest, sha := shardCLIFixture(t)
	dir := filepath.Join(t.TempDir(), "proof")
	writeShardCLIProof(t, root, dir, 123, true)
	bindShardCLIProof(t, root, dir, sha, 0, 2, 1)
	path := filepath.Join(dir, "coverage.xml")
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	b = bytes.Replace(b, []byte("<packages>"), []byte("<!-- C:/Users/private/never-public -->\n<packages>"), 1)
	if err = os.WriteFile(path, b, 0600); err != nil {
		t.Fatal(err)
	}
	if err = powershellShardPack(append(shardCLIArgs(root, manifest, sha), "--shard-index", "0", "--evidence-dir", dir), &bytes.Buffer{}); err == nil {
		t.Fatal("ignored XML comments must not leak private paths in an allegedly safe shard")
	}
	if _, err = os.Stat(filepath.Join(dir, "shard.json")); err == nil {
		t.Fatal("private XML created a success envelope")
	}
}
