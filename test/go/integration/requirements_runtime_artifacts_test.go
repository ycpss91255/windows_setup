package integration_test

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	rc "windows_setup/script/test/repo_coverage"
)

func TestRequirementsRuntimeRejectsMissingOrChangedSourceEvidence(t *testing.T) {
	root, err := filepath.Abs("../../..")
	if err != nil {
		t.Fatal(err)
	}
	fixture := filepath.Join(t.TempDir(), "fixture")
	cmd := exec.Command("go", "test", "-count=1", "-run", "^TestRuntimeReleaseReportDoesNotRequireGoCoverage$", "./script/test/report_bundle_tool")
	cmd.Dir = root
	cmd.Env = append(os.Environ(), "WINDOWS_SETUP_RUNTIME_BUNDLE_FIXTURE_DIR="+fixture)
	if b, e := cmd.CombinedOutput(); e != nil {
		t.Fatalf("synthetic fixture: %v %s", e, b)
	}
	var f struct {
		Commit string
		RunURL string `json:"run_url"`
	}
	b, err := os.ReadFile(filepath.Join(fixture, "fixture.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err = json.Unmarshal(b, &f); err != nil {
		t.Fatal(err)
	}
	source := filepath.Join(fixture, "source")
	inputs := map[string]string{"readme.md": "init.cmd windows.cmd Shift+F10 -AfterRestart -VerifyOnly\n![CI](https://github.com/example/repo/actions/workflows/windows_tests.yml/badge.svg)\n", "init.cmd": "@echo off\n", "windows.cmd": "@echo off\n", ".github/workflows/windows_tests.yml": "name: fixture\n"}
	for n, s := range inputs {
		p := filepath.Join(source, filepath.FromSlash(n))
		if err := os.MkdirAll(filepath.Dir(p), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(s), 0600); err != nil {
			t.Fatal(err)
		}
	}
	for _, args := range [][]string{{"add", "."}, {"-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "synthetic source"}} {
		if b, e := exec.Command("git", append([]string{"-C", source}, args...)...).CombinedOutput(); e != nil {
			t.Fatalf("fixture git: %v %s", e, b)
		}
	}
	head, err := exec.Command("git", "-C", source, "rev-parse", "HEAD").Output()
	if err != nil {
		t.Fatal(err)
	}
	sha := strings.TrimSpace(string(head))
	inv, err := rc.ScanRuntimeInventory(source)
	if err != nil {
		t.Fatal(err)
	}
	if len(inv.Sources) != 1 {
		t.Fatalf("unexpected runtime sources: %+v", inv.Sources)
	}
	inv.Sources[0].ExpectedLines = []int{1}
	art, err := rc.CreateRuntimeEvidence(inv, []rc.Report{{SchemaVersion: 1, Metric: rc.Metric, Files: map[string]map[int]bool{"core/sample.ps1": {1: true}}}}, rc.Identity{Commit: sha, RunUrl: f.RunURL, MeasuredAt: "2026-01-01T00:00:00Z", SourceState: "Clean"})
	if err != nil {
		t.Fatal(err)
	}
	artifact := t.TempDir()
	old := filepath.Join(fixture, "windows-test-reports-1-1")
	entries, err := os.ReadDir(old)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		data, e := os.ReadFile(filepath.Join(old, entry.Name()))
		if e != nil {
			t.Fatal(e)
		}
		data = []byte(strings.ReplaceAll(string(data), f.Commit, sha))
		if e = os.WriteFile(filepath.Join(artifact, entry.Name()), data, 0600); e != nil {
			t.Fatal(e)
		}
	}
	summaryPath := filepath.Join(artifact, "summary.json")
	raw, err := os.ReadFile(summaryPath)
	if err != nil {
		t.Fatal(err)
	}
	var summary map[string]any
	if err = json.Unmarshal(raw, &summary); err != nil {
		t.Fatal(err)
	}
	var evidence any
	if err = json.Unmarshal(art.Summary, &evidence); err != nil {
		t.Fatal(err)
	}
	summary["RepoCoverage"] = evidence
	raw, _ = json.Marshal(summary)
	if err = os.WriteFile(summaryPath, raw, 0600); err != nil {
		t.Fatal(err)
	}
	for n, data := range map[string][]byte{"repo_coverage.json": art.Summary, "coverage_inventory.json": art.Inventory, "coverage.xml": art.XML} {
		if err = os.WriteFile(filepath.Join(artifact, n), data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	args := []string{"run", "./script/test/requirements_gate", "--artifact-dir", artifact, "--source-root", source, "--expected-sha", sha, "--expected-run-url", f.RunURL}
	invoke := func() ([]byte, error) {
		cmd := exec.Command("go", args...)
		cmd.Dir = root
		return cmd.CombinedOutput()
	}
	if out, e := invoke(); e != nil {
		t.Fatalf("valid synthetic runtime rejected: %v %s", e, out)
	}
	if err = os.Remove(filepath.Join(artifact, "coverage.xml")); err != nil {
		t.Fatal(err)
	}
	if out, e := invoke(); e == nil {
		t.Fatalf("missing runtime evidence accepted: %s", out)
	}
	if err = os.WriteFile(filepath.Join(artifact, "coverage.xml"), art.XML, 0600); err != nil {
		t.Fatal(err)
	}
	for name, original := range map[string][]byte{"coverage_inventory.json": art.Inventory, "repo_coverage.json": art.Summary} {
		p := filepath.Join(artifact, name)
		if err = os.WriteFile(p, append(append([]byte(nil), original...), 'x'), 0600); err != nil {
			t.Fatal(err)
		}
		if out, e := invoke(); e == nil {
			t.Fatalf("changed %s accepted: %s", name, out)
		}
		if err = os.WriteFile(p, original, 0600); err != nil {
			t.Fatal(err)
		}
	}
	if err = os.WriteFile(filepath.Join(source, "core", "extra.ps1"), []byte("Write-Output 2\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if out, e := invoke(); e == nil {
		t.Fatalf("changed runtime source accepted: %s", out)
	}
}
