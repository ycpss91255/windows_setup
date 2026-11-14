package integration_test

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	c "windows_setup/script/test/repo_coverage"
)

func TestRequirementsGateTestsOnlyDoesNotRequireGoCoverageInventory(t *testing.T) {
	root, err := filepath.Abs("../../..")
	if err != nil {
		t.Fatal(err)
	}
	source := t.TempDir()
	inputs := map[string]string{
		"readme.md": "init.cmd windows.cmd Shift+F10 -AfterRestart -VerifyOnly\n![CI](https://github.com/example/repo/actions/workflows/windows_tests.yml/badge.svg)\n",
		"init.cmd":  "@echo off\r\n", "windows.cmd": "@echo off\r\n", ".github/workflows/windows_tests.yml": "name: fixture\n",
		"script/test/tool/a.go": "package tool\n", "script/package/tool/b.go": "package tool\n",
	}
	for name, body := range inputs {
		p := filepath.Join(source, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(p), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0600); err != nil {
			t.Fatal(err)
		}
	}
	for _, args := range [][]string{{"init", "-q"}, {"add", "."}} {
		if b, e := exec.Command("git", append([]string{"-C", source}, args...)...).CombinedOutput(); e != nil {
			t.Fatalf("git fixture: %v %s", e, b)
		}
	}
	report := files(t, os.Getenv("WINDOWS_SETUP_ARTIFACT_DIR"))
	identity := decode(t, report)
	artifact := t.TempDir()
	for name, data := range report {
		if err := os.WriteFile(filepath.Join(artifact, name), data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	args := []string{"run", "./script/test/requirements_gate", "--tests-only", "--artifact-dir", artifact, "--source-root", source, "--expected-sha", identity.Commit, "--expected-run-url", identity.RunUrl}
	cmd := exec.Command("go", args...)
	cmd.Dir = root
	if b, e := cmd.CombinedOutput(); e != nil {
		t.Fatalf("tests-only gate rejected supported maintenance Go: %v %s", e, b)
	}
	conflict := append(append([]string(nil), args...), "--require-runtime")
	cmd = exec.Command("go", conflict...)
	cmd.Dir = root
	if b, e := cmd.CombinedOutput(); e == nil || !strings.Contains(string(b), "不可混用") {
		t.Fatalf("mixed modes accepted: %v %s", e, b)
	}
	args = append(args[:2], args[3:]...)
	cmd = exec.Command("go", args...)
	cmd.Dir = root
	expected := "runtime"
	if identity.RepoCoverage != nil && identity.RepoCoverage.SchemaVersion == c.RuntimeSchemaVersion {
		expected = "coverage inventory omitted or added owned source"
	}
	if b, e := cmd.CombinedOutput(); e == nil || !strings.Contains(string(b), expected) {
		t.Fatalf("default gate must reject incompatible runtime evidence: %v %s", e, b)
	}
}
