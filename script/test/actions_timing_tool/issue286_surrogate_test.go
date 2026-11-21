package main

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	at "windows_setup/script/test/actions_timing"
)

func TestIssue286SurrogatesInCLIAndDecode(t *testing.T) {
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
	prefix := `{"run":{"id":123,"run_attempt":1,"head_sha":"` + sha + `","repository":{"full_name":"example/repo"}},"pages":[{"page_number":1,"per_page":100,"total_count":1,"jobs":[{"id":5,"run_id":123,"run_attempt":1,`
	suffix := `,"status":"completed","conclusion":"success","created_at":null,"started_at":null,"completed_at":null,"steps":[]}]}]}`
	expected := at.Expected{Repository: "example/repo", RunID: 123, Attempt: 1, HeadSHA: sha}
	cases := []struct {
		name, field, want string
		valid             bool
	}{
		{"high_value", `"name":"\ud800"`, "", false},
		{"low_value", `"name":"\udc00"`, "", false},
		{"reversed", `"name":"\udc00\ud800"`, "", false},
		{"mismatched", `"name":"\ud800\u0041"`, "", false},
		{"two_high", `"name":"\ud800\ud800"`, "", false},
		{"high_key", `"\ud800":1,"name":"ok"`, "", false},
		{"low_key", `"\udc00":1,"name":"ok"`, "", false},
		{"pair", `"name":"\ud83d\ude00"`, "😀", true},
		{"chinese", `"name":"中文"`, "中文", true},
		{"literal_replacement", `"name":"�"`, "�", true},
		{"escaped_replacement", `"name":"\ufffd"`, "�", true},
		{"literal_escape", `"name":"\\ud800"`, `\ud800`, true},
		{"pair_key", `"\ud83d\ude00":1,"name":"ok"`, "ok", true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			data := []byte(prefix + tc.field + suffix)
			result, decodeErr := at.Decode(data, expected)
			if (decodeErr == nil) != tc.valid {
				t.Errorf("Decode error=%v valid=%v", decodeErr, tc.valid)
			}
			if tc.valid && decodeErr == nil && (len(result.Jobs) != 1 || result.Jobs[0].Name != tc.want) {
				t.Errorf("Decode name: %+v", result.Jobs)
			}
			path := filepath.Join(t.TempDir(), "input.json")
			if err := os.WriteFile(path, data, 0600); err != nil {
				t.Fatal(err)
			}
			cmd := exec.Command(exe, "--input", path, "--repository", "example/repo", "--run-id", "123", "--attempt", "1", "--head-sha", sha)
			var out, stderr bytes.Buffer
			cmd.Stdout = &out
			cmd.Stderr = &stderr
			err := cmd.Run()
			if (err == nil) != tc.valid {
				t.Errorf("CLI err=%v stderr=%s valid=%v", err, stderr.String(), tc.valid)
			}
			if !tc.valid && out.Len() != 0 {
				t.Errorf("invalid output: %s", out.String())
			}
			if tc.valid && err == nil {
				var output at.Output
				if e := json.Unmarshal(out.Bytes(), &output); e != nil || len(output.Jobs) != 1 || output.Jobs[0].Name != tc.want {
					t.Errorf("CLI output=%s error=%v", out.String(), e)
				}
			}
		})
	}
}
