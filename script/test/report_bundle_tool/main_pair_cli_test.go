package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestMainPairCommandValidatesBothReports(t *testing.T) {
	all, sha, runURL := syntheticNativeReport(t, t.TempDir())
	native, container := map[string][]byte{}, map[string][]byte{}
	for k, v := range all {
		if strings.HasPrefix(k, "main/") {
			native[strings.TrimPrefix(k, "main/")] = append([]byte(nil), v...)
		}
	}
	var report map[string]any
	if err := json.Unmarshal(native["summary.json"], &report); err != nil {
		t.Fatal(err)
	}
	report["Environment"] = "Windows synthetic native"
	native["summary.json"], _ = json.Marshal(report)
	for _, k := range containerNames {
		container[k] = append([]byte(nil), native[k]...)
	}
	delete(report, "RepoCoverage")
	report["Coverage"] = "NotMeasured"
	report["Environment"] = "Windows container / Windows synthetic"
	container["summary.json"], _ = json.Marshal(report)
	label, value := "coverage branch", "not measured"
	l, q := len(label)*7+12, len(value)*7+12
	container["coverage.svg"] = []byte(fmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" height="20" width="%d"><rect width="%d" fill="#555"/><rect width="%d" fill="#9f9f9f"/><g font-size="11"><text>%s</text><text>%s</text></g></svg>`, l+q, l, q, label, value))
	root := t.TempDir()
	dirs := []string{filepath.Join(root, "native"), filepath.Join(root, "container")}
	for i, m := range []map[string][]byte{native, container} {
		if err := os.Mkdir(dirs[i], 0700); err != nil {
			t.Fatal(err)
		}
		for k, v := range m {
			if err := os.WriteFile(filepath.Join(dirs[i], k), v, 0600); err != nil {
				t.Fatal(err)
			}
		}
	}
	old := os.Args
	defer func() { os.Args = old }()
	os.Args = []string{"bundle", "validate-main-pair", "--native-dir", dirs[0], "--container-dir", dirs[1], "--commit", sha, "--run-url", runURL}
	if err := run(); err != nil {
		t.Fatalf("valid pair rejected: %v", err)
	}
	report["RunUrl"] = "https://github.com/example/windows_setup/actions/runs/999"
	b, _ := json.Marshal(report)
	if err := os.WriteFile(filepath.Join(dirs[1], "summary.json"), b, 0600); err != nil {
		t.Fatal(err)
	}
	if err := run(); err == nil {
		t.Fatal("wrong run accepted")
	}
}
