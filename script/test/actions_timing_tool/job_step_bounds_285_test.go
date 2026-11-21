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

func TestIssue285CLIRejectsOutsideJobWithoutOutput(t *testing.T) {
	goexe := filepath.Join(runtime.GOROOT(), "bin", "go")
	if runtime.GOOS == "windows" {
		goexe += ".exe"
	}
	exe := filepath.Join(t.TempDir(), "timing.exe")
	build := exec.Command(goexe, "build", "-mod=vendor", "-o", exe, ".")
	if out, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build: %v %s", err, out)
	}
	for _, tc := range []struct{ name, start, end string }{
		{"before", "2026-01-01T00:00:00Z", "2026-01-01T00:00:01Z"},
		{"after", "2026-01-01T00:00:02Z", "2026-01-01T00:00:03Z"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			sha := strings.Repeat("a", 40)
			data := `{"run":{"id":123,"run_attempt":1,"head_sha":"` + sha + `","repository":{"full_name":"example/repo"}},"pages":[{"page_number":1,"per_page":100,"total_count":1,"jobs":[{"id":5,"run_id":123,"run_attempt":1,"name":"job","status":"completed","conclusion":"success","created_at":null,"started_at":"2026-01-01T00:00:01Z","completed_at":"2026-01-01T00:00:02Z","steps":[{"number":1,"name":"step","status":"completed","conclusion":"success","started_at":"` + tc.start + `","completed_at":"` + tc.end + `"}]}]}]}`
			path := filepath.Join(t.TempDir(), "input.json")
			if err := os.WriteFile(path, []byte(data), 0600); err != nil {
				t.Fatal(err)
			}
			cmd := exec.Command(exe, "--input", path, "--repository", "example/repo", "--run-id", "123", "--attempt", "1", "--head-sha", sha)
			var stdout, stderr bytes.Buffer
			cmd.Stdout, cmd.Stderr = &stdout, &stderr
			if err := cmd.Run(); err == nil || stdout.Len() != 0 {
				t.Fatalf("invalid output accepted: err=%v stdout=%q stderr=%q", err, stdout.String(), stderr.String())
			}
		})
	}
}
