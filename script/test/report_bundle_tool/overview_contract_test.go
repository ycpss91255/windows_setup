package main

import (
	"strings"
	"testing"
)

func TestOverviewDisplaysEvidenceAndSeparatesEnvironments(t *testing.T) {
	native := map[string][]byte{"summary.json": []byte(`{"Commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","MeasuredAt":"2026-01-01T00:00:00Z","Success":true,"Totals":{"SuitesExecuted":7,"AssertionsPassed":11,"AssertionsExecuted":11},"RepoCoverage":{"SchemaVersion":2,"Scope":"core-modules-powershell-and-modules-native-csharp","Result":{"Complete":true,"Covered":82,"Executable":100}}}`)}
	container := map[string][]byte{"summary.json": []byte(`{"Commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","MeasuredAt":"2026-01-01T00:00:00Z","Success":true,"Totals":{"SuitesExecuted":3,"AssertionsPassed":4,"AssertionsExecuted":4}}`)}
	page, _ := overviewRootDocuments("v1.2.3", native, container)
	text := string(page)
	for _, want := range []string{"7 組測試", "3 組測試", "82/100", "PowerShell/C# runtime", "容器未量測", "native/index.html", "windows_container/index.html"} {
		if !strings.Contains(text, want) {
			t.Errorf("missing %q", want)
		}
	}
}

func TestOverviewUsesEachFixturesActualCounts(t *testing.T) {
	for _, tc := range []struct{ covered, total, suites string }{{"17", "23", "9"}, {"51", "67", "4"}} {
		native := map[string][]byte{"summary.json": []byte(`{"Success":true,"Totals":{"SuitesExecuted":` + tc.suites + `,"AssertionsPassed":3,"AssertionsExecuted":3},"Checks":[{"Name":"PASS-MARK","Layer":"Unit","Status":"Passed"}],"RepoCoverage":{"Result":{"Complete":true,"Covered":` + tc.covered + `,"Executable":` + tc.total + `}}}`)}
		container := map[string][]byte{"summary.json": []byte(`{"Success":false,"Totals":{"SuitesExecuted":2,"AssertionsPassed":1,"AssertionsExecuted":2,"AssertionsFailed":1,"UnexecutedSuites":1},"Checks":[{"Name":"後續","Layer":"Unit","Status":"NotRun"},{"Name":"問題","Layer":"Unit","Status":"Failed"}]}`)}
		page, _ := overviewRootDocuments("v1.2.3", native, container)
		text := string(page)
		for _, want := range []string{tc.covered + "/" + tc.total, tc.suites + " 組測試", "測試未通過", "未執行", "失敗"} {
			if !strings.Contains(text, want) {
				t.Errorf("missing %q", want)
			}
		}
		if strings.Index(text, "問題") > strings.Index(text, "PASS-MARK") {
			t.Error("container failure should precede native pass")
		}
		if strings.Index(text, "問題") > strings.Index(text, "後續") {
			t.Error("failed check should precede not-run")
		}
	}
}
