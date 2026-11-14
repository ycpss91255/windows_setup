package main

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
)

func TestMainPairRejectsWrongEnvironmentAndSource(t *testing.T) {
	all, sha, run := syntheticNativeReport(t, t.TempDir())
	native := map[string][]byte{}
	container := map[string][]byte{}
	for k, v := range all {
		if strings.HasPrefix(k, "main/") {
			native[strings.TrimPrefix(k, "main/")] = append([]byte(nil), v...)
		}
	}
	var n map[string]any
	if err := json.Unmarshal(native["summary.json"], &n); err != nil {
		t.Fatal(err)
	}
	n["Environment"] = "Windows synthetic native"
	native["summary.json"], _ = json.Marshal(n)
	for _, key := range containerNames {
		container[key] = append([]byte(nil), native[key]...)
	}
	delete(n, "RepoCoverage")
	n["Coverage"] = "NotMeasured"
	n["Environment"] = "Windows container / Windows synthetic"
	container["summary.json"], _ = json.Marshal(n)
	label, value := "coverage branch", "not measured"
	l, q := len(label)*7+12, len(value)*7+12
	container["coverage.svg"] = []byte(fmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" height="20" width="%d"><rect width="%d" fill="#555"/><rect width="%d" fill="#9f9f9f"/><g font-size="11"><text>%s</text><text>%s</text></g></svg>`, l+q, l, q, label, value))
	if err := validateMainPairData(native, container, sha, run); err != nil {
		t.Fatalf("valid pair rejected: %v", err)
	}
	for name, alter := range map[string]func(){
		"source":      func() { n["Commit"] = strings.Repeat("b", 40) },
		"run":         func() { n["RunUrl"] = "https://github.com/example/windows_setup/actions/runs/999" },
		"environment": func() { n["Environment"] = "Windows synthetic native" },
		"failed":      func() { n["Success"] = false },
		"not-run":     func() { totals := n["Totals"].(map[string]any); totals["UnexecutedSuites"] = float64(1) },
	} {
		original := append([]byte(nil), container["summary.json"]...)
		alter()
		container["summary.json"], _ = json.Marshal(n)
		if err := validateMainPairData(native, container, sha, run); err == nil {
			t.Errorf("%s accepted", name)
		}
		_ = json.Unmarshal(original, &n)
		container["summary.json"] = original
	}
}
