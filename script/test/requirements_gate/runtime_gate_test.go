package main

import (
	"testing"
	a "windows_setup/script/test/acceptance"
	rc "windows_setup/script/test/repo_coverage"
)

func TestRequireRuntimeCoveragePreservesExactGate(t *testing.T) {
	evidence := &rc.Evidence{SchemaVersion: rc.RuntimeSchemaVersion, Metric: rc.RuntimeMetric, Scope: rc.RuntimeScope, Result: rc.Result{Complete: true, Covered: 4, Executable: 5}}
	if err := requireRuntimeCoverage(a.Report{RepoCoverage: evidence}); err != nil {
		t.Fatalf("exact 80 percent rejected: %v", err)
	}
	evidence.Result.Covered = 3
	if err := requireRuntimeCoverage(a.Report{RepoCoverage: evidence}); err == nil {
		t.Error("below 80 accepted")
	}
	evidence.Result.Covered = 4
	evidence.Scope = "all-owned"
	if err := requireRuntimeCoverage(a.Report{RepoCoverage: evidence}); err == nil {
		t.Error("wrong scope accepted")
	}
	if err := requireRuntimeCoverage(a.Report{}); err == nil {
		t.Error("missing evidence accepted")
	}
}
