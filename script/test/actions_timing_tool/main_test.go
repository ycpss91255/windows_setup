package main

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestRunRequiresIndependentIdentityAndNeverPublishesInvalidData(t *testing.T) {
	path := filepath.Join(t.TempDir(), "input.json")
	data := `{"run":{"id":123,"run_attempt":1,"head_sha":"` + strings.Repeat("a", 40) + `","repository":{"full_name":"example/repo"}},"pages":[{"page_number":1,"per_page":100,"total_count":1,"jobs":[{"id":5,"run_id":123,"run_attempt":1,"name":"job","status":"completed","conclusion":"success","created_at":null,"started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:00:01Z","steps":[]}]}]}`
	if err := os.WriteFile(path, []byte(data), 0600); err != nil {
		t.Fatal(err)
	}
	args := []string{"--input", path, "--repository", "example/repo", "--run-id", "123", "--attempt", "1", "--head-sha", strings.Repeat("a", 40)}
	var out bytes.Buffer
	if err := run(args, &out); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), `"elapsed_ms":1000`) || !strings.Contains(out.String(), `"pending_ms":null`) {
		t.Fatalf("incorrect observation: %s", out.String())
	}
	out.Reset()
	bad := append(append([]string{}, args...), "--run-id", "124")
	if err := run(bad, &out); err == nil || out.Len() != 0 {
		t.Fatal("mismatch published observation")
	}
	if err := run([]string{"--input", path}, &bytes.Buffer{}); err == nil {
		t.Fatal("missing expected identity accepted")
	}
}

func TestInstrumentedCLIRejectsMismatchAndPreservesNullTiming(t *testing.T) {
	repo, err := filepath.Abs("../../..")
	if err != nil {
		t.Fatal(err)
	}
	goexe := filepath.Join(runtime.GOROOT(), "bin", "go")
	if runtime.GOOS == "windows" {
		goexe += ".exe"
	}
	executable := filepath.Join(t.TempDir(), "timing.exe")
	build := exec.Command(goexe, "build", "-mod=vendor", "-cover", "-coverpkg=./script/test/...", "-o", executable, "./script/test/actions_timing_tool")
	build.Dir = repo
	if b, e := build.CombinedOutput(); e != nil {
		t.Fatalf("CLI build: %v %s", e, b)
	}
	cover := os.Getenv("WINDOWS_SETUP_CLI_COVERAGE_DIR")
	if cover == "" {
		cover = t.TempDir()
	}
	path := filepath.Join(t.TempDir(), "input.json")
	sha := strings.Repeat("a", 40)
	data := `{"run":{"id":123,"run_attempt":1,"head_sha":"` + sha + `","repository":{"full_name":"example/repo"}},"pages":[{"page_number":1,"per_page":100,"total_count":1,"jobs":[{"id":5,"run_id":123,"run_attempt":1,"name":"job","status":"completed","conclusion":"success","created_at":null,"started_at":null,"completed_at":null,"steps":[]}]}]}`
	if err = os.WriteFile(path, []byte(data), 0600); err != nil {
		t.Fatal(err)
	}
	args := []string{"--input", path, "--repository", "example/repo", "--run-id", "123", "--attempt", "1", "--head-sha", sha}
	for _, bad := range []bool{false, true} {
		use := append([]string{}, args...)
		if bad {
			use = append(use, "--attempt", "2")
		}
		cmd := exec.Command(executable, use...)
		cmd.Env = append(os.Environ(), "GOCOVERDIR="+cover)
		var stdout, stderr bytes.Buffer
		cmd.Stdout = &stdout
		cmd.Stderr = &stderr
		e := cmd.Run()
		if (e == nil) == bad {
			t.Fatalf("unexpected exit: %v %s", e, stderr.String())
		}
		if bad && stdout.Len() != 0 {
			t.Fatal("mismatch published observation")
		}
		if !bad && (!strings.Contains(stdout.String(), `"elapsed_ms":null`) || !strings.Contains(stdout.String(), `"origin":"caller_supplied_unverified"`)) {
			t.Fatalf("invalid output: %s", stdout.String())
		}
	}
}
