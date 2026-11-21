package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	c "windows_setup/script/test/repo_coverage"
)

// The command's own behavior cases must cover its real executable lines. The
// compiler generates this profile; no fixture coverage is counted here.
func TestDeploymentExecutableLineCoverage(t *testing.T) {
	root, err := filepath.Abs("../../..")
	if err != nil {
		t.Fatal(err)
	}
	profile := filepath.Join(t.TempDir(), "command.out")
	goexe := filepath.Join(runtime.GOROOT(), "bin", "go")
	if runtime.GOOS == "windows" {
		goexe += ".exe"
	}
	cmd := exec.Command(goexe, "test", "-mod=vendor", "-count=1", "-run", "^(TestDeploymentCases|TestPortalArtifactPublicBytes)$", "-coverprofile="+profile, "./script/test/verify_deployment")
	cmd.Dir = root
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("actual deployment cases: %v\n%s", err, out)
	}
	data, err := os.ReadFile(profile)
	if err != nil {
		t.Fatal(err)
	}
	tracked, err := exec.Command("git", "-C", root, "ls-files", "--", "script/test/verify_deployment/*.go").Output()
	if err != nil {
		t.Fatal(err)
	}
	sources := map[string][]byte{}
	for _, path := range strings.Split(strings.TrimSpace(string(tracked)), "\n") {
		if !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			continue
		}
		content, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(path)))
		if err != nil {
			t.Fatal(err)
		}
		sources[path] = content
	}
	if len(sources) == 0 {
		t.Fatal("no owned verifier source")
	}
	report, _, err := c.NormalizeGo([][]byte{data}, sources, "windows_setup")
	if err != nil {
		t.Fatal(err)
	}
	hit := 0
	for _, covered := range report.Files["script/test/verify_deployment/main.go"] {
		if covered {
			hit++
		}
	}
	t.Logf("actual deployment cases: %d/%d complete executable lines", hit, len(report.Files["script/test/verify_deployment/main.go"]))
	tagHit := 0
	for _, covered := range report.Files["script/test/verify_deployment/tag.go"] {
		if covered {
			tagHit++
		}
	}
	if tagHit == 0 {
		t.Fatal("release deployment verifier did not execute")
	}
	if hit < 60 {
		t.Fatalf("deployment command behavior cases cover %d real complete executable lines; require at least 60", hit)
	}
}

// The actual executable must reject unknown flags before any network work.
func TestDeploymentExecutableRejectsUnknownFlag(t *testing.T) {
	root, err := filepath.Abs("../../..")
	if err != nil {
		t.Fatal(err)
	}
	exe := filepath.Join(t.TempDir(), "verify_deployment")
	if runtime.GOOS == "windows" {
		exe += ".exe"
	}
	goexe := filepath.Join(runtime.GOROOT(), "bin", "go")
	if runtime.GOOS == "windows" {
		goexe += ".exe"
	}
	build := exec.Command(goexe, "build", "-mod=vendor", "-o", exe, "./script/test/verify_deployment")
	build.Dir = root
	if out, e := build.CombinedOutput(); e != nil {
		t.Fatalf("build: %v %s", e, out)
	}
	cmd := exec.Command(exe, "--unknown-release-flag")
	cmd.Dir = root
	out, e := cmd.CombinedOutput()
	if e == nil || !strings.Contains(string(out), "flag provided but not defined") {
		t.Fatalf("unknown flag was not rejected: %v %s", e, out)
	}
}
