package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	a "windows_setup/script/test/acceptance"
)

// These are synthetic transport fixtures, never repository measurement results.
type nativeStageFixture struct{ root, report, goDir, sha, run string }

func newNativeStageFixture(t *testing.T) nativeStageFixture {
	return newNativeStageFixtureRef(t, "Branch")
}
func newNativeStageFixtureRef(t *testing.T, refType string) nativeStageFixture {
	t.Helper()
	base := t.TempDir()
	f := nativeStageFixture{root: filepath.Join(base, "source"), report: filepath.Join(base, "report"), goDir: filepath.Join(base, "go"), run: "https://github.com/example/setup/actions/runs/42"}
	write := func(path string, data []byte) {
		t.Helper()
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	for path, text := range map[string]string{
		"go.mod": "module windows_setup\n\ngo 1.27.3\n", "script/test/owned.go": "package owned\nfunc Value() int { return 1 }\n",
		"test/powershell/unit/owned_tests.ps1": "# synthetic transport source\n", "test/powershell/integration/owned_tests.ps1": "# synthetic transport source\n",
	} {
		write(filepath.Join(f.root, filepath.FromSlash(path)), []byte(text))
	}
	git := func(args ...string) string {
		t.Helper()
		out, err := exec.Command("git", append([]string{"-C", f.root}, args...)...).CombinedOutput()
		if err != nil {
			t.Fatalf("fixture git: %s: %v", out, err)
		}
		return strings.TrimSpace(string(out))
	}
	git("init", "--quiet")
	git("add", ".")
	git("-c", "user.name=Stage fixture", "-c", "user.email=fixture@example.invalid", "commit", "--quiet", "-m", "Synthetic native stage fixture")
	f.sha = git("rev-parse", "HEAD")
	yes := true
	r := a.Report{SchemaVersion: 2, RequestedLayer: "All", Commit: f.sha, RunUrl: f.run, SourceState: "Clean", Coverage: "NotMeasured", RefType: refType, RefName: "fixture/native_stage", Environment: "Synthetic stage transport / Windows PowerShell 5.1", Version: "v0.2.1", MeasuredAt: "2026-11-08T00:00:00Z", Success: true,
		Checks: []a.Check{{Name: "PowerShell 5.1 語法", Layer: "Static", Status: "Passed", Executed: true, Passed: &yes, Assertions: []a.Assertion{}}, {Name: "Unit.owned", Layer: "Unit", Status: "Passed", Executed: true, Passed: &yes, Assertions: []a.Assertion{{Name: "synthetic transport", Passed: &yes}}}, {Name: "Integration.owned", Layer: "Integration", Status: "Passed", Executed: true, Passed: &yes, Assertions: []a.Assertion{{Name: "synthetic transport", Passed: &yes}}}}, Totals: a.Totals{SuitesExecuted: 3, AssertionsExecuted: 2, AssertionsPassed: 2}}
	if refType == "Release" {
		r.RefName = r.Version
	}
	data, _ := json.Marshal(r)
	var summary map[string]any
	json.Unmarshal(data, &summary)
	delete(summary, "RepoCoverage")
	data, _ = json.Marshal(summary)
	write(filepath.Join(f.report, "summary.json"), data)
	write(filepath.Join(f.report, "summary.md"), []byte("Synthetic transport fixture "+f.sha+" "+r.MeasuredAt))
	write(filepath.Join(f.report, "index.html"), []byte(`<html><body>單元與隔離整合測試通過 <a href="summary.json">JSON</a><a href="summary.md">摘要</a><a href="junit.xml">JUnit</a></body></html>`))
	write(filepath.Join(f.report, "junit.xml"), []byte(`<testsuites><testsuite name="PowerShell 5.1 語法"><testcase/></testsuite><testsuite name="Unit.owned"><testcase/></testsuite><testsuite name="Integration.owned"><testcase/></testsuite></testsuites>`))
	for _, name := range []string{"unit", "integration", "coverage"} {
		label, value, color := name+" "+strings.ToLower(refType), "passed", "#4c1"
		if name == "coverage" {
			value, color = "not measured", "#9f9f9f"
		}
		view := fmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="20"><rect width="%d" fill="#555"/><rect width="%d" fill="%s"/><g font-size="11"><text>%s</text><text>%s</text></g></svg>`, (len(label)+len(value))*7+24, len(label)*7+12, len(value)*7+12, color, label, value)
		write(filepath.Join(f.report, name+".svg"), []byte(view))
	}
	read := func(name string) ([]byte, error) { return os.ReadFile(filepath.Join(f.report, name)) }
	if _, err := a.ValidateReport(read, f.sha, f.run, false); err != nil {
		t.Fatalf("invalid synthetic report fixture: %v", err)
	}
	files, err := a.OwnedGoFiles(f.root)
	if err != nil {
		t.Fatal(err)
	}
	coverage, profile, err := a.CreateCoverageEvidence([][]byte{[]byte("mode: set\nwindows_setup/script/test/owned.go:2.1,2.30 1 1\n")}, files, a.CoverageProvenance{Commit: f.sha, RunUrl: f.run, MeasuredAt: r.MeasuredAt, SourceState: "Clean", GoVersion: "go1.27.3", Environment: "Synthetic stage transport"})
	if err != nil {
		t.Fatal(err)
	}
	data, _ = json.Marshal(coverage)
	write(filepath.Join(f.goDir, "go_coverage.json"), data)
	write(filepath.Join(f.goDir, "go_coverage.out"), profile)
	return f
}

func (f nativeStageFixture) args(command, input, output string) []string {
	args := []string{command, "--source-root", f.root, "--expected-sha", f.sha, "--expected-run-url", f.run, "--run-attempt", "2", "--output-dir", output}
	if command == "native-stage-pack" {
		return append(args, "--report-dir", f.report, "--go-dir", f.goDir)
	}
	return append(args, "--input-dir", input)
}

func TestNativeStageTransportPreservesBytesAndPartialState(t *testing.T) {
	for _, refType := range []string{"Branch", "Release"} {
		t.Run(refType, func(t *testing.T) {
			f := newNativeStageFixtureRef(t, refType)
			stage, restored := filepath.Join(t.TempDir(), "stage"), filepath.Join(t.TempDir(), "restored")
			var out bytes.Buffer
			if err := run(f.args("native-stage-pack", "", stage), &out); err != nil {
				t.Fatalf("safe native/Go stage must be supported: %v", err)
			}
			data, err := os.ReadFile(filepath.Join(stage, "stage.json"))
			if err != nil {
				t.Fatal(err)
			}
			var metadata map[string]any
			if err = json.Unmarshal(data, &metadata); err != nil {
				t.Fatal(err)
			}
			if metadata["Complete"] != false || metadata["Publishable"] != false || metadata["Kind"] != "NativeAndGoStage" || metadata["RunAttempt"] != float64(2) {
				t.Fatalf("partial stage mislabeled: %s", data)
			}
			if err = run(f.args("native-stage-restore", stage, restored), &out); err != nil {
				t.Fatal(err)
			}
			for _, item := range []struct{ source, prefix string }{{f.report, "report"}, {f.goDir, "go"}} {
				entries, _ := os.ReadDir(item.source)
				for _, entry := range entries {
					before, _ := os.ReadFile(filepath.Join(item.source, entry.Name()))
					after, e := os.ReadFile(filepath.Join(restored, item.prefix, entry.Name()))
					if e != nil || !bytes.Equal(before, after) {
						t.Fatalf("original evidence modified: %s: %v", entry.Name(), e)
					}
				}
			}
			if _, err = os.Stat(filepath.Join(restored, "report", "repo_coverage.json")); !os.IsNotExist(err) {
				t.Fatal("native stage must not invent whole-repository coverage")
			}
		})
	}
}

func TestRuntimeNativeStageDoesNotRequireGoCoverage(t *testing.T) {
	f := newNativeStageFixture(t)
	stage, restored := filepath.Join(t.TempDir(), "stage"), filepath.Join(t.TempDir(), "restored")
	base := []string{"--runtime", "--source-root", f.root, "--expected-sha", f.sha, "--expected-run-url", f.run, "--run-attempt", "2"}
	pack := append([]string{"native-stage-pack"}, base...)
	pack = append(pack, "--report-dir", f.report, "--output-dir", stage)
	if err := run(pack, &bytes.Buffer{}); err != nil {
		t.Fatalf("runtime stage required Go coverage: %v", err)
	}
	restore := append([]string{"native-stage-restore"}, base...)
	restore = append(restore, "--input-dir", stage, "--output-dir", restored)
	if err := run(restore, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	legacyRestore := f.args("native-stage-restore", stage, filepath.Join(t.TempDir(), "legacy"))
	if err := run(legacyRestore, &bytes.Buffer{}); err == nil {
		t.Fatal("runtime stage accepted as historical native and Go stage")
	}
	if _, err := os.Stat(filepath.Join(restored, "go")); !os.IsNotExist(err) {
		t.Fatalf("runtime stage unexpectedly requires Go coverage: %v", err)
	}
	before, err := os.ReadFile(filepath.Join(f.report, "summary.json"))
	if err != nil {
		t.Fatal(err)
	}
	after, err := os.ReadFile(filepath.Join(restored, "report", "summary.json"))
	if err != nil || !bytes.Equal(before, after) {
		t.Fatalf("native report changed: %v", err)
	}
}

func TestNativeStageRejectsIdentityTamperAndIncompleteInputs(t *testing.T) {
	for _, kind := range []string{"wrong_sha", "wrong_run", "wrong_attempt", "missing_report", "extra_report", "missing_go", "tampered_go", "dirty_source", "existing_output", "output_inside_source", "report_failure", "report_unit_only", "report_old_schema", "report_claimed_coverage", "missing_suite"} {
		t.Run(kind, func(t *testing.T) {
			f := newNativeStageFixture(t)
			output := filepath.Join(t.TempDir(), "stage")
			args := f.args("native-stage-pack", "", output)
			mutateSummary := func(change func(map[string]any)) {
				path := filepath.Join(f.report, "summary.json")
				b, _ := os.ReadFile(path)
				var q map[string]any
				json.Unmarshal(b, &q)
				change(q)
				b, _ = json.Marshal(q)
				os.WriteFile(path, b, 0600)
			}
			switch kind {
			case "wrong_sha":
				args[4] = strings.Repeat("b", 40)
			case "wrong_run":
				args[6] = f.run + "0"
			case "wrong_attempt":
				args[8] = "0"
			case "missing_report":
				os.Remove(filepath.Join(f.report, "junit.xml"))
			case "extra_report":
				os.WriteFile(filepath.Join(f.report, "private.log"), []byte("must never export"), 0600)
			case "missing_go":
				os.Remove(filepath.Join(f.goDir, "go_coverage.out"))
			case "tampered_go":
				os.WriteFile(filepath.Join(f.goDir, "go_coverage.out"), []byte("mode: set\n"), 0600)
			case "dirty_source":
				os.WriteFile(filepath.Join(f.root, "unexpected.ps1"), []byte("# dirty"), 0600)
			case "existing_output":
				os.Mkdir(output, 0700)
			case "output_inside_source":
				output = filepath.Join(f.root, "stage")
				args = f.args("native-stage-pack", "", output)
			case "report_failure":
				mutateSummary(func(q map[string]any) {
					q["Success"] = false
					check := q["Checks"].([]any)[1].(map[string]any)
					check["Passed"], check["Status"] = false, "Failed"
					check["Assertions"].([]any)[0].(map[string]any)["Passed"] = false
					totals := q["Totals"].(map[string]any)
					totals["AssertionsPassed"], totals["AssertionsFailed"] = 1, 1
				})
				junit := filepath.Join(f.report, "junit.xml")
				b, _ := os.ReadFile(junit)
				os.WriteFile(junit, bytes.Replace(b, []byte(`<testsuite name="Unit.owned"><testcase/>`), []byte(`<testsuite name="Unit.owned"><testcase><failure/></testcase>`), 1), 0600)
				badge := filepath.Join(f.report, "unit.svg")
				b, _ = os.ReadFile(badge)
				b = bytes.ReplaceAll(bytes.ReplaceAll(b, []byte("passed"), []byte("failed")), []byte("#4c1"), []byte("#e05d44"))
				os.WriteFile(badge, b, 0600)
				page := filepath.Join(f.report, "index.html")
				b, _ = os.ReadFile(page)
				os.WriteFile(page, bytes.ReplaceAll(b, []byte("單元與隔離整合測試通過"), []byte("本次測試未通過")), 0600)
				if _, err := a.ValidateReport(func(n string) ([]byte, error) { return os.ReadFile(filepath.Join(f.report, n)) }, f.sha, f.run, false); err != nil {
					t.Fatalf("failed producer fixture must otherwise be internally consistent: %v", err)
				}
			case "report_unit_only":
				mutateSummary(func(q map[string]any) { q["RequestedLayer"] = "Unit" })
			case "report_old_schema":
				mutateSummary(func(q map[string]any) { q["SchemaVersion"] = 1 })
			case "report_claimed_coverage":
				mutateSummary(func(q map[string]any) { q["Coverage"] = "Measured" })
			case "missing_suite":
				os.WriteFile(filepath.Join(f.root, "test/powershell/unit/unexecuted_tests.ps1"), []byte("# synthetic omitted suite\n"), 0600)
				for _, command := range [][]string{{"add", "."}, {"-c", "user.name=Stage fixture", "-c", "user.email=fixture@example.invalid", "commit", "--quiet", "-m", "Synthetic extra native suite"}} {
					if output, err := exec.Command("git", append([]string{"-C", f.root}, command...)...).CombinedOutput(); err != nil {
						t.Fatalf("fixture source update: %s: %v", output, err)
					}
				}
				sha, _ := exec.Command("git", "-C", f.root, "rev-parse", "HEAD").Output()
				newSHA := strings.TrimSpace(string(sha))
				for _, p := range []string{filepath.Join(f.report, "summary.json"), filepath.Join(f.report, "summary.md"), filepath.Join(f.goDir, "go_coverage.json")} {
					b, _ := os.ReadFile(p)
					os.WriteFile(p, bytes.ReplaceAll(b, []byte(f.sha), []byte(newSHA)), 0600)
				}
				f.sha = newSHA
				args = f.args("native-stage-pack", "", output)
				if _, err := a.ValidateReport(func(n string) ([]byte, error) { return os.ReadFile(filepath.Join(f.report, n)) }, f.sha, f.run, false); err != nil {
					t.Fatalf("omitted source roster fixture report must otherwise be valid: %v", err)
				}
			}
			var out bytes.Buffer
			if err := run(args, &out); err == nil {
				t.Fatal("invalid stage accepted")
			}
			if kind != "existing_output" {
				if _, err := os.Stat(output); !os.IsNotExist(err) {
					t.Fatal("invalid stage created output")
				}
			}
		})
	}
}

func TestNativeStageRestoreRejectsChangedOrAliasedTransport(t *testing.T) {
	for _, kind := range []string{"wrong_sha", "wrong_run", "wrong_attempt", "content_tamper", "missing_file", "extra_file", "complete_claim", "publishable_claim", "duplicate_key", "case_alias", "unknown_field", "string_attempt", "path_escape", "wrong_native_count", "existing_output", "overlapping_output", "dirty_source", "input_link", "output_parent_link"} {
		t.Run(kind, func(t *testing.T) {
			f := newNativeStageFixture(t)
			stage, output := filepath.Join(t.TempDir(), "stage"), filepath.Join(t.TempDir(), "restore")
			var out bytes.Buffer
			if err := run(f.args("native-stage-pack", "", stage), &out); err != nil {
				t.Fatal(err)
			}
			args := f.args("native-stage-restore", stage, output)
			path := filepath.Join(stage, "stage.json")
			data, _ := os.ReadFile(path)
			replace := func(before, after string) {
				t.Helper()
				if !bytes.Contains(data, []byte(before)) {
					t.Fatalf("expected stage contract field absent: %s", before)
				}
				data = bytes.Replace(data, []byte(before), []byte(after), 1)
				if err := os.WriteFile(path, data, 0600); err != nil {
					t.Fatal(err)
				}
			}
			linkDirectory := func(link, target string) {
				t.Helper()
				if err := os.Symlink(target, link); err != nil {
					if out, nativeErr := exec.Command("cmd.exe", "/d", "/c", "mklink", "/J", link, target).CombinedOutput(); nativeErr != nil {
						t.Fatalf("owned link fixture unavailable: %v: %s", nativeErr, out)
					}
				}
			}
			switch kind {
			case "wrong_sha":
				args[4] = strings.Repeat("c", 40)
			case "wrong_run":
				args[6] = f.run + "1"
			case "wrong_attempt":
				args[8] = "3"
			case "content_tamper":
				p := filepath.Join(stage, "report", "summary.md")
				original, _ := os.ReadFile(p)
				os.WriteFile(p, append(original, []byte(" changed")...), 0600)
			case "missing_file":
				os.Remove(filepath.Join(stage, "go", "go_coverage.out"))
			case "extra_file":
				os.WriteFile(filepath.Join(stage, "private.log"), []byte("never export"), 0600)
			case "complete_claim":
				replace(`"Complete": false`, `"Complete": true`)
			case "publishable_claim":
				replace(`"Publishable": false`, `"Publishable": true`)
			case "duplicate_key":
				os.WriteFile(path, append([]byte(`{"Commit":"`+f.sha+`",`), data[1:]...), 0600)
			case "case_alias":
				replace(`"Commit":`, `"commit":`)
			case "unknown_field":
				os.WriteFile(path, append(data[:len(data)-1], []byte(`,"Unexpected":true}`)...), 0600)
			case "string_attempt":
				replace(`"RunAttempt": 2`, `"RunAttempt": "2"`)
			case "path_escape":
				replace(`"report/summary.json"`, `"report/../summary.json"`)
			case "wrong_native_count":
				replace(`"NativeChecks": 3`, `"NativeChecks": 4`)
			case "existing_output":
				os.Mkdir(output, 0700)
			case "overlapping_output":
				output = filepath.Join(stage, "restore")
				args = f.args("native-stage-restore", stage, output)
			case "dirty_source":
				os.WriteFile(filepath.Join(f.root, "unexpected.ps1"), []byte("# dirty"), 0600)
			case "input_link":
				alias := filepath.Join(t.TempDir(), "input_alias")
				linkDirectory(alias, stage)
				args = f.args("native-stage-restore", alias, output)
			case "output_parent_link":
				alias := filepath.Join(t.TempDir(), "output_alias")
				linkDirectory(alias, f.root)
				output = filepath.Join(alias, "restore")
				args = f.args("native-stage-restore", stage, output)
			}
			if err := run(args, &out); err == nil {
				t.Fatal("changed or aliased stage accepted")
			}
			if kind != "existing_output" {
				if _, err := os.Stat(output); !os.IsNotExist(err) {
					t.Fatal("invalid restore created output")
				}
			}
		})
	}
}
