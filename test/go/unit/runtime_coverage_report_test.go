package unit_test

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	a "windows_setup/script/test/acceptance"
	rc "windows_setup/script/test/repo_coverage"
)

func TestRuntimeCoverageReportAcceptsNewScopeAndPreservesHistory(t *testing.T) {
	id := rc.Identity{Commit: strings.Repeat("a", 40), RunUrl: "https://github.com/example/repo/actions/runs/1", MeasuredAt: "2026-01-01T00:00:00Z", SourceState: "Clean"}
	name := "core/a.ps1"
	inv := rc.Inventory{Sources: []rc.Source{{Path: name, Language: "powershell", SHA256: strings.Repeat("b", 64), ExpectedLines: []int{1}}}}
	report := rc.Report{SchemaVersion: 1, Metric: rc.Metric, Files: map[string]map[int]bool{name: {1: true}}}
	for _, modern := range []bool{false, true} {
		var artifacts rc.Artifacts
		var err error
		if modern {
			artifacts, err = rc.CreateRuntimeEvidence(inv, []rc.Report{report}, id)
		} else {
			artifacts, err = rc.CreateEvidence(inv, []rc.Report{report}, id)
		}
		if err != nil {
			t.Fatal(err)
		}
		var doc any
		if err = json.Unmarshal(artifacts.Summary, &doc); err != nil {
			t.Fatal(err)
		}
		summary, err := json.Marshal(map[string]any{"RepoCoverage": doc})
		if err != nil {
			t.Fatal(err)
		}
		files := map[string][]byte{"repo_coverage.json": artifacts.Summary, "coverage_inventory.json": artifacts.Inventory, "coverage.xml": artifacts.XML}
		read := func(n string) ([]byte, error) {
			b, ok := files[n]
			if !ok {
				return nil, fmt.Errorf("missing")
			}
			return b, nil
		}
		if _, err = a.ValidateRepoCoverageReport(read, summary, id.Commit, id.RunUrl, false); err != nil {
			t.Errorf("modern=%v valid report rejected: %v", modern, err)
		}
	}
}

func TestRuntimePortalRequiresVisiblePowerShellCSharpScope(t *testing.T) {
	pct := 80.0
	e := rc.Evidence{SchemaVersion: rc.RuntimeSchemaVersion, Metric: rc.RuntimeMetric, Scope: rc.RuntimeScope, Result: rc.Result{Complete: true, Covered: 4, Executable: 5, Percent: &pct}}
	summary, err := json.Marshal(map[string]any{"SchemaVersion": 2, "RepoCoverage": e})
	if err != nil {
		t.Fatal(err)
	}
	if err := a.ValidatePortalCoverage("PowerShell/C# runtime 覆蓋率 80.0% 4/5 可執行行", summary); err != nil {
		t.Fatalf("explicit runtime scope rejected: %v", err)
	}
	if err := a.ValidatePortalCoverage("整體覆蓋率 80.0% 4/5 可執行行", summary); err == nil {
		t.Fatal("runtime scope mislabeled as all-owned coverage")
	}
}

func TestRuntimeCoverageBadgeRequiresLanguageScope(t *testing.T) {
	pct := 80.0
	r := a.Report{SchemaVersion: 2, RefType: "Branch", RepoCoverage: &rc.Evidence{SchemaVersion: rc.RuntimeSchemaVersion, Metric: rc.RuntimeMetric, Scope: rc.RuntimeScope, Result: rc.Result{Complete: true, Covered: 4, Executable: 5, Percent: &pct}}}
	label, value := "runtime PowerShell/C#", "80.0%"
	left, right := len(label)*7+12, len(value)*7+12
	svg := []byte(fmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="20" aria-label="%s branch: %s"><title>%s branch: %s</title><rect width="%d" fill="#555"/><rect width="%d" fill="#007ec6"/><g font-size="11"><text>%s</text><text>%s</text></g></svg>`, left+right, label, value, label, value, left, right, label, value))
	if err := a.ValidateSVG(svg, r, "coverage"); err != nil {
		t.Fatalf("runtime badge rejected: %v", err)
	}
}
