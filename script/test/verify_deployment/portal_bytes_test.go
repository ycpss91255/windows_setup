package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPortalArtifactPublicBytes(t *testing.T) {
	const catalog = `[{"Version":"v0.2.5","Status":"Verified","Path":"versions/v0.2.5/index.html"},{"Version":"v0.2.0","Status":"Unknown","Path":"versions/v0.2.0/index.html"}]`
	for _, kind := range []string{"valid", "required_verified", "required_missing", "required_unknown", "stale_catalog", "stale_page", "stale_summary", "stale_profile", "missing_public", "missing_local", "duplicate", "bad_version", "bad_path", "bad_status", "symlink"} {
		t.Run(kind, func(t *testing.T) {
			root := t.TempDir()
			files := map[string][]byte{"versions.json": []byte(catalog), "versions/v0.2.5/index.html": []byte("verified version page"), "versions/v0.2.5/summary.json": []byte("tag report summary"), "versions/v0.2.5/go_coverage.out": []byte("tag profile")}
			if kind == "duplicate" {
				files["versions.json"] = []byte(`[{"Version":"v0.2.5","Status":"Verified","Path":"versions/v0.2.5/index.html"},{"Version":"v0.2.5","Status":"Unknown","Path":"versions/v0.2.5/index.html"}]`)
			}
			if kind == "bad_version" {
				files["versions.json"] = []byte(`[{"Version":"../private","Status":"Verified","Path":"versions/../private/index.html"}]`)
			}
			if kind == "bad_path" {
				files["versions.json"] = []byte(`[{"Version":"v0.2.5","Status":"Verified","Path":"versions/v0.2.4/index.html"}]`)
			}
			if kind == "required_unknown" {
				files["versions.json"] = []byte(`[{"Version":"v0.2.5","Status":"Unknown","Path":"versions/v0.2.5/index.html"}]`)
			}
			if kind == "bad_status" {
				files["versions.json"] = []byte(`[{"Version":"v0.2.5","Status":"Unexpected","Path":"versions/v0.2.5/index.html"}]`)
			}
			for name, data := range files {
				path := filepath.Join(root, filepath.FromSlash(name))
				if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(path, data, 0600); err != nil {
					t.Fatal(err)
				}
			}
			if kind == "missing_local" {
				if err := os.Remove(filepath.Join(root, "versions", "v0.2.5", "go_coverage.out")); err != nil {
					t.Fatal(err)
				}
			}
			if kind == "symlink" {
				p := filepath.Join(root, "versions", "v0.2.5", "summary.json")
				if err := os.Remove(p); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(filepath.Join(root, "versions.json"), p); err != nil {
					t.Skipf("symlink unavailable: %v", err)
				}
			}
			read := func(name string) ([]byte, error) {
				if kind == "missing_public" && strings.HasSuffix(name, "summary.json") {
					return nil, fmt.Errorf("404")
				}
				b, ok := files[name]
				if !ok {
					return nil, fmt.Errorf("404")
				}
				if (kind == "stale_catalog" && name == "versions.json") || (kind == "stale_page" && strings.HasSuffix(name, "index.html")) || (kind == "stale_summary" && strings.HasSuffix(name, "summary.json")) || (kind == "stale_profile" && strings.HasSuffix(name, "go_coverage.out")) {
					return []byte("stale"), nil
				}
				return b, nil
			}
			required := ""
			if strings.HasPrefix(kind, "required_") {
				required = "v0.2.5"
			}
			if kind == "required_missing" {
				required = "v0.2.6"
			}
			err := verifyPortalBytes(read, root, required)
			if (err == nil) != (kind == "valid" || kind == "required_verified") {
				t.Fatalf("kind=%s error=%v", kind, err)
			}
		})
	}
}

func TestRuntimePortalBytesDoNotRequireLegacyProfile(t *testing.T) {
	root := t.TempDir()
	files := map[string][]byte{
		"versions.json":                []byte(`[{"Version":"v0.2.5","Status":"Verified","Path":"versions/v0.2.5/index.html"}]`),
		"versions/v0.2.5/index.html":   []byte("page"),
		"versions/v0.2.5/summary.json": []byte(`{"RepoCoverage":{"SchemaVersion":2,"Metric":"runtime-powershell-csharp-executable-lines-v2","Scope":"core-modules-powershell-and-modules-native-csharp"}}`),
	}
	for name, b := range files {
		p := filepath.Join(root, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(p), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, b, 0600); err != nil {
			t.Fatal(err)
		}
	}
	read := func(name string) ([]byte, error) {
		b, ok := files[name]
		if !ok {
			return nil, fmt.Errorf("missing %s", name)
		}
		return b, nil
	}
	if err := verifyPortalBytes(read, root, "v0.2.5"); err != nil {
		t.Fatalf("runtime page rejected: %v", err)
	}
	files["versions/v0.2.5/index.html"] = []byte("stale")
	if err := verifyPortalBytes(read, root, "v0.2.5"); err == nil {
		t.Fatal("stale runtime page accepted")
	}
}
