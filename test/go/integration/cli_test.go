package integration_test

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	a "windows_setup/script/test/acceptance"
)

func TestCLICommands(t *testing.T) {
	root, _ := filepath.Abs("../../..")
	goexe := filepath.Join(runtime.GOROOT(), "bin", "go")
	if runtime.GOOS == "windows" {
		goexe += ".exe"
	}
	r := decode(t, files(t, os.Getenv("WINDOWS_SETUP_ARTIFACT_DIR")))
	coverageDir := os.Getenv("WINDOWS_SETUP_CLI_COVERAGE_DIR")
	if coverageDir == "" {
		coverageDir = t.TempDir()
	}
	if e := os.MkdirAll(coverageDir, 0700); e != nil {
		t.Fatal(e)
	}
	t.Setenv("GOCOVERDIR", coverageDir)
	binaries := map[string]string{}
	binaryDir := t.TempDir()
	run := func(args ...string) (string, error) {
		if len(args) < 2 || args[0] != "run" {
			t.Fatal("CLI test requires a package")
		}
		pkg := args[1]
		exe, ok := binaries[pkg]
		if !ok {
			exe = filepath.Join(binaryDir, filepath.Base(pkg)+".exe")
			build := exec.Command(goexe, "build", "-cover", "-coverpkg=./script/test/...", "-o", exe, pkg)
			build.Dir = root
			b, e := build.CombinedOutput()
			if e != nil {
				t.Fatalf("instrumented CLI build: %s %v", b, e)
			}
			binaries[pkg] = exe
		}
		c := exec.Command(exe, args[2:]...)
		c.Dir = root
		b, e := c.CombinedOutput()
		return string(b), e
	}
	// Exercise the actual CLI for both ref types at whichever report stage CI supplies.
	for _, ref := range []string{"Branch", "Release"} {
		t.Run("ref_context_"+ref, func(t *testing.T) {
			original := files(t, os.Getenv("WINDOWS_SETUP_ARTIFACT_DIR"))
			prior := decode(t, original)
			m := synthetic(t, original, true, ref)
			var sourceRaw, scenarioRaw map[string]json.RawMessage
			if e := json.Unmarshal(original["summary.json"], &sourceRaw); e != nil {
				t.Fatal(e)
			}
			if e := json.Unmarshal(m["summary.json"], &scenarioRaw); e != nil {
				t.Fatal(e)
			}
			if goEvidence, ok := sourceRaw["GoCoverage"]; ok {
				m["index.html"] = original["index.html"]
				scenarioRaw["GoCoverage"] = goEvidence
				m["summary.json"], _ = json.Marshal(scenarioRaw)
			}
			if prior.RefType != ref {
				m["go_coverage.svg"] = []byte(strings.ReplaceAll(string(m["go_coverage.svg"]), "go coverage "+strings.ToLower(prior.RefType), "go coverage "+strings.ToLower(ref)))
			}
			q := decode(t, m)
			dir := t.TempDir()
			for n, b := range m {
				if e := os.WriteFile(filepath.Join(dir, n), b, 0600); e != nil {
					t.Fatal(e)
				}
			}
			if ref == "Release" && len(m["go_coverage.json"]) > 0 {
				var raw map[string]json.RawMessage
				if e := json.Unmarshal(m["summary.json"], &raw); e != nil {
					t.Fatal(e)
				}
				raw["RunUrl"] = json.RawMessage(`""`)
				if v, ok := raw["RepoCoverage"]; ok && string(v) != "null" {
					var repo map[string]json.RawMessage
					if e := json.Unmarshal(v, &repo); e != nil {
						t.Fatal(e)
					}
					repo["RunUrl"] = json.RawMessage(`""`)
					raw["RepoCoverage"], _ = json.Marshal(repo)
				}
				var goEvidence map[string]json.RawMessage
				if e := json.Unmarshal(raw["GoCoverage"], &goEvidence); e != nil {
					t.Fatal(e)
				}
				goEvidence["RunUrl"] = json.RawMessage(`""`)
				raw["GoCoverage"], _ = json.Marshal(goEvidence)
				bad := copyFiles(m)
				bad["summary.json"], _ = json.Marshal(raw)
				if repo, ok := raw["RepoCoverage"]; ok && string(repo) != "null" {
					bad["repo_coverage.json"] = repo
				}
				bad["go_coverage.json"], _ = json.Marshal(goEvidence)
				badDir := t.TempDir()
				for n, b := range bad {
					if e := os.WriteFile(filepath.Join(badDir, n), b, 0600); e != nil {
						t.Fatal(e)
					}
				}
				if b, e := run("run", "./script/test/requirements_gate", "--tests-only", "--artifact-dir", badDir, "--source-root", root, "--expected-sha", q.Commit, "--expected-run-url", ""); e == nil || !strings.Contains(b, "fresh schema2 release Go evidence") {
					t.Fatalf("empty release run was not refused for expected reason: %s %v", b, e)
				}
			}
			for _, tc := range []struct {
				name, sha, url string
				success        bool
			}{
				{"valid", q.Commit, q.RunUrl, true}, {"wrong_sha", strings.Repeat("0", 40), q.RunUrl, false}, {"wrong_url", q.Commit, q.RunUrl + "0", false},
			} {
				t.Run(tc.name, func(t *testing.T) {
					b, e := run("run", "./script/test/requirements_gate", "--tests-only", "--artifact-dir", dir, "--source-root", root, "--expected-sha", tc.sha, "--expected-run-url", tc.url)
					if (e == nil) != tc.success {
						t.Fatalf("unexpected CLI outcome: %s %v", b, e)
					}
				})
			}
		})
	}
	t.Run("synthetic_release_go_evidence_requires_run", func(t *testing.T) {
		m := synthetic(t, files(t, os.Getenv("WINDOWS_SETUP_ARTIFACT_DIR")), true, "Release")
		r := decode(t, m)
		coverage, profile, err := a.CreateCoverageEvidence([][]byte{[]byte("mode: set\nwindows_setup/script/test/example.go:1.1,1.2 1 1\n")}, []string{"windows_setup/script/test/example.go"}, a.CoverageProvenance{Commit: r.Commit, RunUrl: r.RunUrl, MeasuredAt: r.MeasuredAt, SourceState: "Clean", GoVersion: "go1.27.3", Environment: "Synthetic identity fixture"})
		if err != nil {
			t.Fatal(err)
		}
		m = identityFixture(t, m, r.Commit, "")
		coverage.RunUrl = ""
		var summary map[string]any
		if err = json.Unmarshal(m["summary.json"], &summary); err != nil {
			t.Fatal(err)
		}
		summary["GoCoverage"] = coverage
		m["summary.json"], _ = json.Marshal(summary)
		m["go_coverage.json"], _ = json.Marshal(coverage)
		m["go_coverage.out"] = profile
		dir := t.TempDir()
		for n, b := range m {
			if err := os.WriteFile(filepath.Join(dir, n), b, 0600); err != nil {
				t.Fatal(err)
			}
		}
		b, e := run("run", "./script/test/requirements_gate", "--tests-only", "--artifact-dir", dir, "--source-root", root, "--expected-sha", r.Commit, "--expected-run-url", "")
		if e == nil || !strings.Contains(b, "fresh schema2 release Go evidence") {
			t.Fatalf("release with Go evidence and empty run accepted or wrong failure: %s %v", b, e)
		}
	})
	t.Run("valid_report", func(t *testing.T) {
		b, e := run("run", "./script/test/requirements_gate", "--tests-only", "--artifact-dir", os.Getenv("WINDOWS_SETUP_ARTIFACT_DIR"), "--source-root", root, "--expected-sha", r.Commit, "--expected-run-url", r.RunUrl)
		if e != nil || !strings.Contains(b, "需求驗收通過") {
			t.Fatalf("%s %v", b, e)
		}
	})
	t.Run("local_report_empty_run_url", func(t *testing.T) {
		m := synthetic(t, files(t, os.Getenv("WINDOWS_SETUP_ARTIFACT_DIR")), true, "Branch")
		q := decode(t, m)
		m = identityFixture(t, m, q.Commit, "")
		q = decode(t, m)
		if q.RepoCoverage != nil && q.RepoCoverage.RunUrl != q.RunUrl {
			t.Fatal("local fixture aggregate evidence still belongs to the CI run")
		}
		dir := t.TempDir()
		for n, b := range m {
			if e := os.WriteFile(filepath.Join(dir, n), b, 0600); e != nil {
				t.Fatal(e)
			}
		}
		b, e := run("run", "./script/test/requirements_gate", "--tests-only", "--artifact-dir", dir, "--source-root", root, "--expected-sha", q.Commit, "--expected-run-url", "")
		if e != nil || !strings.Contains(b, "需求驗收通過") {
			t.Fatalf("local no-CI evidence rejected: %s %v", b, e)
		}
	})
	t.Run("wrong_sha_exit", func(t *testing.T) {
		before, _ := filepath.Glob(filepath.Join(coverageDir, "covcounters.*"))
		b, e := run("run", "./script/test/requirements_gate", "--tests-only", "--artifact-dir", os.Getenv("WINDOWS_SETUP_ARTIFACT_DIR"), "--source-root", root, "--expected-sha", strings.Repeat("0", 40), "--expected-run-url", r.RunUrl)
		if e == nil || !strings.Contains(b, "需求驗收失敗") {
			t.Fatalf("%s %v", b, e)
		}
		after, _ := filepath.Glob(filepath.Join(coverageDir, "covcounters.*"))
		if len(after) <= len(before) {
			t.Fatal("exit 1 CLI did not write its own new coverage counter")
		}
	})
	t.Run("https_only", func(t *testing.T) {
		b, e := run("run", "./script/test/verify_deployment", "--base-url", "http://example.com/", "--readme", filepath.Join(root, "readme.md"), "--expected-sha", r.Commit, "--expected-run-url", r.RunUrl)
		if e == nil || !strings.Contains(b, "HTTPS") {
			t.Fatalf("%s %v", b, e)
		}
	})
	t.Run("instrumented_cli_evidence", func(t *testing.T) {
		dir := os.Getenv("GOCOVERDIR")
		if dir == "" {
			dir = t.TempDir()
			t.Setenv("GOCOVERDIR", dir)
		}
		b, e := run("run", "./script/test/requirements_gate", "--tests-only", "--artifact-dir", os.Getenv("WINDOWS_SETUP_ARTIFACT_DIR"), "--source-root", root, "--expected-sha", r.Commit, "--expected-run-url", r.RunUrl)
		if e != nil {
			t.Fatalf("CLI prerequisite: %s %v", b, e)
		}
		matches, e := filepath.Glob(filepath.Join(dir, "covcounters.*"))
		if e != nil || len(matches) == 0 {
			t.Fatalf("actual CLI coverage counters missing: %v", e)
		}
	})
	t.Run("coverage_producer_real_compiler_profile", func(t *testing.T) {
		source := t.TempDir()
		write := func(n, s string) {
			p := filepath.Join(source, n)
			os.MkdirAll(filepath.Dir(p), 0700)
			if e := os.WriteFile(p, []byte(s), 0600); e != nil {
				t.Fatal(e)
			}
		}
		write("go.mod", "module windows_setup\n\ngo 1.27.3\n")
		write("script/test/sample/sample.go", "package sample\nfunc Sum(a,b int) int{return a+b}\n")
		write("script/test/sample/sample_test.go", "package sample\nimport \"testing\"\nfunc TestSum(t *testing.T){if Sum(1,2)!=3{t.Fatal(\"sum\")}}\n")
		command := func(exe string, args ...string) string {
			c := exec.Command(exe, args...)
			c.Dir = source
			b, e := c.CombinedOutput()
			if e != nil {
				t.Fatalf("fixture command: %s %v", b, e)
			}
			return strings.TrimSpace(string(b))
		}
		command("git", "init", "-q")
		command("git", "add", ".")
		command("git", "-c", "user.name=Synthetic fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "Synthetic coverage fixture")
		sha := command("git", "rev-parse", "HEAD")
		profile := filepath.Join(t.TempDir(), "unit.out")
		command(goexe, "test", "-count=1", "-coverpkg=./script/test/...", "-coverprofile="+profile, "./...")
		m := synthetic(t, files(t, os.Getenv("WINDOWS_SETUP_ARTIFACT_DIR")), true, "Branch")
		q := decode(t, m)
		m = identityFixture(t, m, sha, "https://github.com/example/fixture/actions/runs/1")
		q = decode(t, m)
		if q.RepoCoverage != nil {
			t.Fatal("new sample source inherited unrelated repository coverage")
		}
		reportDir := t.TempDir()
		for n, b := range m {
			os.WriteFile(filepath.Join(reportDir, n), b, 0600)
		}
		out := filepath.Join(t.TempDir(), "coverage")
		b, e := run("run", "./script/test/go_coverage", "--unit-profile", profile, "--cli-profile", profile, "--source-root", source, "--report-dir", reportDir, "--output-dir", out)
		if e != nil {
			t.Fatalf("real compiler profile producer: %s %v", b, e)
		}
		for _, n := range []string{"go_coverage.json", "go_coverage.out"} {
			if _, e := os.Stat(filepath.Join(out, n)); e != nil {
				t.Fatal(e)
			}
		}
		for _, kind := range []string{"missing_flags", "existing_output", "inside_source", "missing_profile", "missing_report"} {
			t.Run(kind, func(t *testing.T) {
				args := []string{"run", "./script/test/go_coverage", "--unit-profile", profile, "--cli-profile", profile, "--source-root", source, "--report-dir", reportDir, "--output-dir", filepath.Join(t.TempDir(), "new")}
				switch kind {
				case "missing_flags":
					args = args[:2]
				case "existing_output":
					args[len(args)-1] = out
				case "inside_source":
					args[len(args)-1] = filepath.Join(source, "output")
				case "missing_profile":
					args[3] = filepath.Join(t.TempDir(), "missing.out")
				case "missing_report":
					args[9] = t.TempDir()
				}
				b, e := run(args...)
				if e == nil || !strings.Contains(b, "Go coverage failed") {
					t.Fatalf("producer error not propagated: %s %v", b, e)
				}
			})
		}
	})
}
