//go:build windows

package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestWindowsProfileContainsAllOwnedEngineSources(t *testing.T) {
	root, err := filepath.Abs("../../..")
	if err != nil {
		t.Fatal(err)
	}
	tracked, err := exec.Command("git", "-C", root, "ls-files", "--", "script/test/clean_test_artifacts/*.go").Output()
	if err != nil {
		t.Fatal(err)
	}
	goExe, err := exec.LookPath("go")
	if err != nil {
		t.Fatal(err)
	}
	profile := filepath.Join(t.TempDir(), "engine.cover")
	cmd := exec.Command(goExe, "test", "-count=1", "-cover", "-coverprofile="+profile, "-run", "^TestOwnedArtifactsRequireSelectionCompletionAndExpiry$", ".")
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("compiler coverage run: %v: %s", err, output)
	}
	raw, err := os.ReadFile(profile)
	if err != nil {
		t.Fatal(err)
	}
	seen := make(map[string]bool)
	for _, line := range strings.Split(string(raw), "\n") {
		if i := strings.IndexByte(line, ':'); i > 0 {
			seen[line[:i]] = true
		}
	}
	count := 0
	for _, path := range strings.Split(strings.TrimSpace(string(tracked)), "\n") {
		if !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			continue
		}
		path = "windows_setup/" + path
		count++
		if !seen[path] {
			t.Errorf("owned engine Go source omitted from actual Windows profile: %s", path)
		}
	}
	if count == 0 {
		t.Fatal("owned engine inventory empty")
	}
}
