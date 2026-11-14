package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	c "windows_setup/script/test/repo_coverage"
)

func TestPublishedRuntimeInventoryUsesRuntimeScope(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "core", "sample.ps1")
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("Write-Output 1"), 0600); err != nil {
		t.Fatal(err)
	}
	inv, err := c.ScanRuntimeInventory(root)
	if err != nil {
		t.Fatal(err)
	}
	data, err := json.Marshal(inv)
	if err != nil {
		t.Fatal(err)
	}
	evidence := &c.Evidence{SchemaVersion: c.RuntimeSchemaVersion, Metric: c.RuntimeMetric, Scope: c.RuntimeScope}
	if err := validatePublishedInventory(evidence, root, data); err != nil {
		t.Fatalf("runtime inventory rejected: %v", err)
	}
	if err := os.WriteFile(path, []byte("Write-Output 2"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := validatePublishedInventory(evidence, root, data); err == nil {
		t.Fatal("changed source accepted")
	}
}

func TestReleaseProfileRequirementMatchesValidatedScope(t *testing.T) {
	runtime := &c.Evidence{SchemaVersion: c.RuntimeSchemaVersion, Metric: c.RuntimeMetric, Scope: c.RuntimeScope}
	if required, err := releaseRequiresGoProfile(runtime, &verifiedBundle{CoverageScope: c.RuntimeScope}); err != nil || required {
		t.Fatalf("runtime bundle: %v %v", required, err)
	}
	if _, err := releaseRequiresGoProfile(runtime, &verifiedBundle{}); err == nil {
		t.Fatal("legacy receipt accepted as runtime")
	}
	if _, err := releaseRequiresGoProfile(runtime, nil); err == nil {
		t.Fatal("raw release accepted as runtime")
	}
	if required, err := releaseRequiresGoProfile(&c.Evidence{}, &verifiedBundle{}); err != nil || !required {
		t.Fatalf("legacy bundle: %v %v", required, err)
	}
	if _, err := releaseRequiresGoProfile(&c.Evidence{}, &verifiedBundle{CoverageScope: c.RuntimeScope}); err == nil {
		t.Fatal("runtime receipt accepted as legacy")
	}
}

func TestCurrentDeploymentRequiresRuntimeScope(t *testing.T) {
	if err := requireCurrentRuntimeCoverage(&c.Evidence{SchemaVersion: c.RuntimeSchemaVersion, Metric: c.RuntimeMetric, Scope: c.RuntimeScope}); err != nil {
		t.Fatal(err)
	}
	for _, e := range []*c.Evidence{nil, {SchemaVersion: 1, Metric: c.Metric}, {SchemaVersion: c.RuntimeSchemaVersion, Metric: c.RuntimeMetric, Scope: "other"}} {
		if err := requireCurrentRuntimeCoverage(e); err == nil {
			t.Fatal("non-runtime current coverage accepted")
		}
	}
}

func TestRuntimeReleaseDoesNotRequireGoCoverageInventory(t *testing.T) {
	root := t.TempDir()
	if _, err := releaseGoFiles(root, &verifiedBundle{CoverageScope: c.RuntimeScope}); err != nil {
		t.Fatalf("runtime release required Go coverage inventory: %v", err)
	}
	if _, err := releaseGoFiles(root, &verifiedBundle{}); err == nil {
		t.Fatal("legacy release skipped Go inventory")
	}
}
