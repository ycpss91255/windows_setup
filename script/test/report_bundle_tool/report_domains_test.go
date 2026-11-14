package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestReportDomainsSharedFixture(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "test", "fixtures", "report_domains.json"))
	if err != nil {
		t.Fatal(err)
	}
	var cases []struct{ Name, Domain, Environment, Status string }
	if err = json.Unmarshal(data, &cases); err != nil {
		t.Fatal(err)
	}
	reports := map[string]map[string]any{}
	for _, env := range []string{"native", "container"} {
		reports[env] = map[string]any{"Success": false, "Totals": map[string]any{"SuitesExecuted": 6, "AssertionsPassed": 1, "AssertionsExecuted": 2, "AssertionsFailed": 1, "UnexecutedSuites": 1}, "Checks": []any{}}
	}
	for _, c := range cases {
		if got := reportDomain(c.Name); got != c.Domain {
			t.Errorf("%s: got %q want %q", c.Name, got, c.Domain)
		}
		r := reports[c.Environment]
		r["Checks"] = append(r["Checks"].([]any), map[string]any{"Name": c.Name, "Layer": "Unit", "Status": c.Status})
	}
	native, _ := json.Marshal(reports["native"])
	container, _ := json.Marshal(reports["container"])
	page, _ := overviewRootDocuments("v1.2.3", map[string][]byte{"summary.json": native}, map[string][]byte{"summary.json": container})
	text := string(page)
	groups := map[string]bool{}
	for _, c := range cases {
		groups[c.Domain] = true
		if strings.Count(text, c.Name) != 1 {
			t.Errorf("name not exactly once: %s", c.Name)
		}
	}
	for group := range groups {
		if strings.Count(text, group) != 1 {
			t.Errorf("domain not exactly once: %s", group)
		}
	}
	if strings.Index(text, "硬體與驅動包") > strings.Index(text, "網路與 SSH") || strings.Index(text, "網路與 SSH") > strings.Index(text, "帳號與權限") {
		t.Error("failed domain not first")
	}
	expectedOrder := []string{"硬體與驅動包", "網路與 SSH", "帳號與權限", "版本與來源準備", "Windows 設定與清理", "測試與交付工具", "其他檢查"}
	prior := -1
	for _, domain := range expectedOrder {
		at := strings.Index(text, domain)
		if at <= prior {
			t.Errorf("domain order: %s", domain)
		}
		prior = at
	}
	if !strings.Contains(text, "原生 2 組") || !strings.Contains(text, "容器 1 組（失敗 1、未執行 0）") {
		t.Error("environment counts missing or combined")
	}
}
