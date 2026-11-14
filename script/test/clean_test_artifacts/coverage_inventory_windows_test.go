//go:build windows

package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"windows_setup/script/test/acceptance"
)

func TestWindowsProfileContainsAllOwnedEngineSources(t *testing.T) {
	root, err := filepath.Abs("../../..")
	if err != nil {
		t.Fatal(err)
	}
	owned, err := acceptance.OwnedGoFiles(root)
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
	for _, path := range owned {
		if !strings.HasPrefix(path, "windows_setup/script/test/clean_test_artifacts/") {
			continue
		}
		count++
		if !seen[path] {
			t.Errorf("owned engine Go source omitted from actual Windows profile: %s", path)
		}
	}
	if count == 0 {
		t.Fatal("owned engine inventory empty")
	}
}
