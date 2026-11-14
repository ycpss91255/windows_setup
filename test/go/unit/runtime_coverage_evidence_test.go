package unit_test

import (
	"encoding/json"
	"strings"
	"testing"

	rc "windows_setup/script/test/repo_coverage"
)

func TestRuntimeEvidenceRejectsHistoricalAndAlteredScope(t *testing.T) {
	name := "core/example.ps1"
	identity := rc.Identity{Commit: strings.Repeat("a", 40), RunUrl: "https://github.com/example/repo/actions/runs/1", MeasuredAt: "2026-01-01T00:00:00Z", SourceState: "Clean"}
	inv := rc.Inventory{Sources: []rc.Source{{Path: name, Language: "powershell", SHA256: strings.Repeat("b", 64), ExpectedLines: []int{1}}}}
	report := rc.Report{SchemaVersion: rc.SchemaVersion, Metric: rc.Metric, Files: map[string]map[int]bool{name: {1: true}}}
	fresh, err := rc.CreateRuntimeEvidence(inv, []rc.Report{report}, identity)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = rc.ValidateRuntimeEvidence(fresh.Summary, fresh.Inventory, fresh.XML, identity.Commit, identity.RunUrl); err != nil {
		t.Fatalf("runtime evidence rejected: %v", err)
	}
	old, err := rc.CreateEvidence(inv, []rc.Report{report}, identity)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = rc.ValidateRuntimeEvidence(old.Summary, old.Inventory, old.XML, identity.Commit, identity.RunUrl); err == nil {
		t.Error("historical evidence relabeled runtime")
	}
	var doc map[string]any
	if err = json.Unmarshal(fresh.Summary, &doc); err != nil {
		t.Fatal(err)
	}
	doc["Scope"] = "all-owned"
	altered, err := json.Marshal(doc)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = rc.ValidateRuntimeEvidence(altered, fresh.Inventory, fresh.XML, identity.Commit, identity.RunUrl); err == nil {
		t.Error("altered scope accepted")
	}
	if _, err = rc.ValidateRuntimeEvidence(fresh.Summary, fresh.Inventory, fresh.XML, strings.Repeat("c", 40), identity.RunUrl); err == nil {
		t.Error("altered identity accepted")
	}
	inv.Sources[0].Path = "core/hidden.go"
	if _, err = rc.CreateRuntimeEvidence(inv, []rc.Report{report}, identity); err == nil {
		t.Error("out-of-scope filename accepted as PowerShell")
	}
}

func TestRuntimeEvidenceRejectsPinnedThirdParty(t *testing.T) {
	name := "modules/debloat/win11debloat/upstream.ps1"
	identity := rc.Identity{Commit: strings.Repeat("a", 40), RunUrl: "https://github.com/example/repo/actions/runs/1", MeasuredAt: "2026-01-01T00:00:00Z", SourceState: "Clean"}
	inv := rc.Inventory{Sources: []rc.Source{{Path: name, Language: "powershell", SHA256: strings.Repeat("b", 64), ExpectedLines: []int{1}}}}
	report := rc.Report{SchemaVersion: rc.SchemaVersion, Metric: rc.Metric, Files: map[string]map[int]bool{name: {1: true}}}
	if _, err := rc.CreateRuntimeEvidence(inv, []rc.Report{report}, identity); err == nil {
		t.Error("third-party source accepted in runtime producer")
	}
	old, err := rc.CreateEvidence(inv, []rc.Report{report}, identity)
	if err != nil {
		t.Fatal(err)
	}
	var doc map[string]any
	if err = json.Unmarshal(old.Summary, &doc); err != nil {
		t.Fatal(err)
	}
	doc["SchemaVersion"], doc["Metric"], doc["Scope"] = rc.RuntimeSchemaVersion, rc.RuntimeMetric, rc.RuntimeScope
	relabeled, err := json.Marshal(doc)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = rc.ValidateRuntimeEvidence(relabeled, old.Inventory, old.XML, identity.Commit, identity.RunUrl); err == nil {
		t.Error("third-party source accepted in standalone runtime verifier")
	}
}
