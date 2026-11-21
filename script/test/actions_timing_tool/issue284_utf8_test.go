package main

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	at "windows_setup/script/test/actions_timing"
)

func TestCLIRejectsInvalidUTF8AndPreservesValidUnicode(t *testing.T) {
	repo, err := filepath.Abs("../../..")
	if err != nil {
		t.Fatal(err)
	}
	goexe := filepath.Join(runtime.GOROOT(), "bin", "go")
	if runtime.GOOS == "windows" {
		goexe += ".exe"
	}
	exe := filepath.Join(t.TempDir(), "timing.exe")
	build := exec.Command(goexe, "build", "-mod=vendor", "-o", exe, "./script/test/actions_timing_tool")
	build.Dir = repo
	if b, e := build.CombinedOutput(); e != nil {
		t.Fatalf("build: %v %s", e, b)
	}
	sha := strings.Repeat("a", 40)
	prefix := `{"run":{"id":123,"run_attempt":1,"head_sha":"` + sha + `","repository":{"full_name":"example/repo"}},"pages":[{"page_number":1,"per_page":100,"total_count":1,"jobs":[{"id":5,"run_id":123,"run_attempt":1,"name":"`
	suffix := `","status":"completed","conclusion":"success","created_at":null,"started_at":null,"completed_at":null,"steps":[]}]}]}`
	expected := at.Expected{Repository: "example/repo", RunID: 123, Attempt: 1, HeadSHA: sha}
	for _, tc := range []struct {
		name  string
		value []byte
		valid bool
	}{
		{"invalid", []byte{'B', 'A', 'D', 0xff}, false},
		{"chinese", []byte("工作"), true},
		{"replacement_rune", []byte("合法�"), true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			data := append(append([]byte(prefix), tc.value...), []byte(suffix)...)
			_, decodeErr := at.Decode(data, expected)
			if (decodeErr == nil) != tc.valid {
				t.Errorf("Decode error = %v, want valid %v", decodeErr, tc.valid)
			}
			path := filepath.Join(t.TempDir(), "input.json")
			if err := os.WriteFile(path, data, 0600); err != nil {
				t.Fatal(err)
			}
			cmd := exec.Command(exe, "--input", path, "--repository", "example/repo", "--run-id", "123", "--attempt", "1", "--head-sha", sha)
			var out, stderr bytes.Buffer
			cmd.Stdout, cmd.Stderr = &out, &stderr
			err := cmd.Run()
			if (err == nil) != tc.valid {
				t.Errorf("CLI exit = %v, stderr %s, want valid %v", err, stderr.String(), tc.valid)
			}
			if !tc.valid && out.Len() != 0 {
				t.Errorf("invalid input published: %s", out.String())
			}
			if tc.valid && !bytes.Contains(out.Bytes(), tc.value) {
				t.Errorf("Unicode not preserved: %s", out.String())
			}
		})
	}
}
