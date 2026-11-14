package main

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	a "windows_setup/script/test/acceptance"
	rc "windows_setup/script/test/repo_coverage"
)

func TestCollectInputCases(t *testing.T) {
	source, raw := t.TempDir(), t.TempDir()
	write := func(root, name, text string) {
		t.Helper()
		p := filepath.Join(root, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(p), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(text), 0600); err != nil {
			t.Fatal(err)
		}
	}
	write(source, "go.mod", "module windows_setup\n\ngo 1.27.3\n")
	write(source, "script/test/example/value.go", "package example\nfunc Value() int { return 1 }\n")
	write(source, "script/test/example/value_test.go", "package example\nimport \"testing\"\nfunc TestValue(t *testing.T){if Value()!=1{t.Fatal(\"Value contract\")}}\n")
	psText := "function Get-Example { return 1 }"
	write(source, "core/value.ps1", psText)
	git := func(args ...string) string {
		t.Helper()
		cmd := exec.Command("git", append([]string{"-C", source}, args...)...)
		b, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("synthetic source git: %v %s", err, b)
		}
		return strings.TrimSpace(string(b))
	}
	git("init", "-q")
	git("add", ".")
	git("-c", "user.name=Coverage fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "Synthetic collector input fixture")
	sha := git("rev-parse", "HEAD")
	goexe := filepath.Join(runtime.GOROOT(), "bin", "go")
	if runtime.GOOS == "windows" {
		goexe += ".exe"
	}
	profilePath := filepath.Join(raw, "go.out")
	cmd := exec.Command(goexe, "test", "-mod=vendor", "-count=1", "-coverprofile="+profilePath, "./script/test/example")
	cmd.Dir = source
	if b, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("actual fixture Go compiler profile: %v %s", err, b)
	}
	profile, err := os.ReadFile(profilePath)
	if err != nil {
		t.Fatal(err)
	}
	provenance := a.CoverageProvenance{Commit: sha, MeasuredAt: "2026-01-01T00:00:00Z", SourceState: "Clean", GoVersion: "go1.27.3", Environment: "Synthetic collector validation fixture"}
	goProof, canonical, err := a.CreateCoverageEvidence([][]byte{profile}, []string{"windows_setup/script/test/example/value.go"}, provenance)
	if err != nil {
		t.Fatal(err)
	}
	proofBytes, err := json.Marshal(goProof)
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(profilePath, canonical, 0600); err != nil {
		t.Fatal(err)
	}
	goPath := filepath.Join(raw, "go.json")
	if err = os.WriteFile(goPath, proofBytes, 0600); err != nil {
		t.Fatal(err)
	}
	inv, err := rc.ScanInventory(source)
	if err != nil {
		t.Fatal(err)
	}
	psHash := ""
	for _, s := range inv.Sources {
		if s.Path == "core/value.ps1" {
			psHash = s.SHA256
		}
	}
	if psHash == "" {
		t.Fatal("synthetic PowerShell source not inventoried")
	}
	engineHash := strings.Repeat("b", 64)
	psSource := map[string]any{"File": "core/value.ps1", "SHA256": psHash, "ExpectedLines": []int{1}}
	// Synthetic raw PowerShell input tests the importer contract. It is confined
	// to this disposable source and never used as repository measurement data.
	worker := map[string]any{"ProcessId": 123, "Engine": "powershell", "EngineVersion": "5.1.0.0", "EngineSHA256": engineHash, "PesterVersion": "6.0.0", "Sources": []any{psSource}, "Commands": []any{map[string]any{"File": "core/value.ps1", "Line": 1, "Column": 1, "EndLine": 1, "EndColumn": len(psText) + 1, "Hit": true}}}
	psProof := map[string]any{"SchemaVersion": 1, "PesterVersion": "6.0.0", "PackageSHA512": "AHIAm7QW11As3sjMayo1rPU4JVIEfBL+ZILAyTyDnMPxMwLFQ3VeAA0prFTx+Y4DgZCUnH2N4+Xb0HDQua2EKA==", "Metric": "FullyCoveredCommandStartLines", "Sources": []any{psSource}, "Workers": []any{map[string]any{"Index": 0, "ProcessId": 123, "Evidence": "worker_0.json", "Engine": "powershell", "EngineVersion": "5.1.0.0", "EngineSHA256": engineHash}}, "Covered": 1, "Total": 1}
	marshal := func(name string, v any) {
		t.Helper()
		b, err := json.Marshal(v)
		if err != nil {
			t.Fatal(err)
		}
		if err = os.WriteFile(filepath.Join(raw, name), b, 0600); err != nil {
			t.Fatal(err)
		}
	}
	marshal("worker_0.json", worker)
	marshal("ps.json", psProof)
	write(raw, "coverage.xml", `<coverage coverage-schema="1" coverage-metric="complete-executable-lines-v1"><packages><package><classes><class filename="core/value.ps1"><lines><line number="1" hits="1"/></lines></class></classes></package></packages></coverage>`)
	args := func(output string) []string {
		return []string{"--source-root", source, "--output-dir", output, "--expected-sha", sha, "--go-evidence", goPath, "--go-profile", profilePath, "--powershell-evidence", filepath.Join(raw, "ps.json")}
	}
	reject := func(t *testing.T, argv []string) error {
		t.Helper()
		err := collect(argv, &bytes.Buffer{})
		if err == nil {
			t.Fatalf("bad collector input accepted: %v", argv)
		}
		return err
	}
	t.Run("required_inputs", func(t *testing.T) { reject(t, nil) })
	t.Run("runtime_scope_without_go_coverage", func(t *testing.T) {
		output := filepath.Join(t.TempDir(), "runtime")
		argv := []string{"--runtime", "--source-root", source, "--output-dir", output, "--expected-sha", sha, "--powershell-evidence", filepath.Join(raw, "ps.json")}
		if err := collect(argv, &bytes.Buffer{}); err != nil {
			t.Fatalf("runtime collection requires Go coverage: %v", err)
		}
		var data [3][]byte
		for i, name := range []string{"repo_coverage.json", "coverage_inventory.json", "coverage.xml"} {
			var e error
			data[i], e = os.ReadFile(filepath.Join(output, name))
			if e != nil {
				t.Fatal(e)
			}
		}
		proof, err := rc.ValidateRuntimeEvidence(data[0], data[1], data[2], sha, "")
		if err != nil || !proof.Result.Complete || proof.Result.Covered != 1 || proof.Result.Executable != 1 {
			t.Fatalf("runtime proof: %+v %v", proof, err)
		}
		if err := rc.ValidateRuntimeInventory(source, data[1]); err != nil {
			t.Fatal(err)
		}
	})
	t.Run("inside_source_output", func(t *testing.T) { reject(t, args(filepath.Join(source, "coverage"))) })
	t.Run("existing_output", func(t *testing.T) { reject(t, args(t.TempDir())) })
	t.Run("source_commit_mismatch", func(t *testing.T) {
		v := args(filepath.Join(t.TempDir(), "new"))
		v[5] = strings.Repeat("f", 40)
		reject(t, v)
	})
	t.Run("missing_go_identity", func(t *testing.T) {
		v := args(filepath.Join(t.TempDir(), "new"))
		v[7] = filepath.Join(raw, "absent.json")
		reject(t, v)
	})
	t.Run("missing_go_profile", func(t *testing.T) {
		v := args(filepath.Join(t.TempDir(), "new"))
		v[9] = filepath.Join(raw, "absent.out")
		reject(t, v)
	})
	t.Run("go_and_powershell_source_binding", func(t *testing.T) {
		output := filepath.Join(t.TempDir(), "coverage")
		var out bytes.Buffer
		if err := collect(args(output), &out); err != nil {
			t.Fatal(err)
		}
		var data [3][]byte
		for i, n := range []string{"repo_coverage.json", "coverage_inventory.json", "coverage.xml"} {
			b, err := os.ReadFile(filepath.Join(output, n))
			if err != nil {
				t.Fatal(err)
			}
			data[i] = b
		}
		proof, err := rc.ValidateEvidence(data[0], data[1], data[2], sha, "")
		if err != nil || !proof.Result.Complete || proof.Result.Covered != 2 || proof.Result.Executable != 2 {
			t.Fatalf("source-bound synthetic corpus: %+v %v", proof, err)
		}
		if err := rc.ValidateInventory(source, data[1]); err != nil {
			t.Fatal(err)
		}
	})
	t.Run("missing_ps_raw_file", func(t *testing.T) {
		v := args(filepath.Join(t.TempDir(), "new"))
		v[len(v)-1] = filepath.Join(raw, "missing.json")
		reject(t, v)
	})
	t.Run("malformed_ps_raw_file", func(t *testing.T) {
		bad := filepath.Join(raw, "bad_ps.json")
		write(raw, "bad_ps.json", "{}")
		v := args(filepath.Join(t.TempDir(), "new"))
		v[len(v)-1] = bad
		reject(t, v)
	})
	t.Run("missing_ps_worker", func(t *testing.T) {
		path := filepath.Join(raw, "worker_0.json")
		saved, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if err = os.Remove(path); err != nil {
			t.Fatal(err)
		}
		defer os.WriteFile(path, saved, 0600)
		if err := reject(t, args(filepath.Join(t.TempDir(), "new"))); !strings.Contains(err.Error(), "worker_0.json") {
			t.Fatalf("did not reach worker read boundary: %v", err)
		}
	})
	for _, kind := range []string{"missing_cmd", "ambiguous_cmd", "invalid_cmd", "missing_managed", "invalid_managed"} {
		t.Run(kind, func(t *testing.T) {
			v := args(filepath.Join(t.TempDir(), "new"))
			switch kind {
			case "missing_cmd":
				v = append(v, "--cmd-evidence", filepath.Join(raw, "missing_cmd.json"))
			case "ambiguous_cmd":
				write(raw, "ambiguous_cmd.json", `{"SchemaVersion":1,"SchemaVersion":2}`)
				v = append(v, "--cmd-evidence", filepath.Join(raw, "ambiguous_cmd.json"))
			case "invalid_cmd":
				write(raw, "invalid_cmd.json", `{"SchemaVersion":1}`)
				v = append(v, "--cmd-evidence", filepath.Join(raw, "invalid_cmd.json"))
			case "missing_managed":
				v = append(v, "--managed-evidence", filepath.Join(raw, "missing_managed.json"))
			case "invalid_managed":
				write(raw, "invalid_managed.json", `{}`)
				v = append(v, "--managed-evidence", filepath.Join(raw, "invalid_managed.json"))
			}
			reject(t, v)
		})
	}
	t.Run("missing_output_parent", func(t *testing.T) { reject(t, args(filepath.Join(t.TempDir(), "absent", "coverage"))) })
	t.Run("dirty_source_inventory", func(t *testing.T) {
		git("rm", "--cached", "script/test/example/value.go")
		defer git("add", "script/test/example/value.go") // Dirty source must fail before reading proofs.
		reject(t, args(filepath.Join(t.TempDir(), "new")))
	})
	t.Run("invalid_go_ast_span", func(t *testing.T) {
		badProfile := []byte("mode: set\nwindows_setup/script/test/example/value.go:99.1,99.2 1 1\n")
		badProof, badProfile, err := a.CreateCoverageEvidence([][]byte{badProfile}, []string{"windows_setup/script/test/example/value.go"}, provenance)
		if err != nil {
			t.Fatal(err)
		}
		b, err := json.Marshal(badProof)
		if err != nil {
			t.Fatal(err)
		}
		write(raw, "invalid_go.json", string(b))
		write(raw, "invalid_go.out", string(badProfile))
		v := args(filepath.Join(t.TempDir(), "new"))
		v[7] = filepath.Join(raw, "invalid_go.json")
		v[9] = filepath.Join(raw, "invalid_go.out")
		if err := reject(t, v); !strings.Contains(err.Error(), "outside original source") {
			t.Fatalf("did not reach original Go AST span rejection: %v", err)
		}
	})
	t.Run("unavailable_git", func(t *testing.T) { t.Setenv("PATH", t.TempDir()); reject(t, args(filepath.Join(t.TempDir(), "new"))) })
	t.Run("unknown_flag", func(t *testing.T) { reject(t, []string{"--unknown"}) })
	t.Run("missing_tracked_go_source", func(t *testing.T) {
		git("rm", "--", "script/test/example/value.go")
		git("-c", "user.name=Coverage fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "Synthetic removal of measured Go source")
		v := args(filepath.Join(t.TempDir(), "new"))
		v[5] = git("rev-parse", "HEAD")
		err := collect(v, &bytes.Buffer{})
		if err == nil || !strings.Contains(err.Error(), "no owned Go source") {
			t.Fatalf("missing tracked Go source was not identified before consuming profiles: %v", err)
		}
	})
}
