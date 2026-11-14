package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestRuntimeReleaseTagUsesVerifiedBundle(t *testing.T) {
	root, err := filepath.Abs("../../..")
	if err != nil {
		t.Fatal(err)
	}
	fixture := filepath.Join(t.TempDir(), "fixture")
	makeFixture := exec.Command("go", "test", "-count=1", "-run", "^TestRuntimeReleaseReportDoesNotRequireGoCoverage$", "./script/test/report_bundle_tool")
	makeFixture.Dir = root
	makeFixture.Env = append(os.Environ(), "WINDOWS_SETUP_RUNTIME_BUNDLE_FIXTURE_DIR="+fixture)
	if b, e := makeFixture.CombinedOutput(); e != nil {
		t.Fatalf("runtime fixture: %v %s", e, b)
	}
	var f struct {
		Version, Commit, Archive, Source, SHA256 string
		RunURL                                   string `json:"run_url"`
		RunAttempt                               int    `json:"run_attempt"`
		Size                                     int64
	}
	b, err := os.ReadFile(filepath.Join(fixture, "fixture.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err = json.Unmarshal(b, &f); err != nil {
		t.Fatal(err)
	}
	tool := filepath.Join(t.TempDir(), "report_bundle_tool.exe")
	build := exec.Command("go", "build", "-o", tool, "./script/test/report_bundle_tool")
	build.Dir = root
	if b, e := build.CombinedOutput(); e != nil {
		t.Fatalf("build verifier: %v %s", e, b)
	}
	asset := releaseAsset{Name: f.Archive, Size: f.Size, Digest: "sha256:" + f.SHA256}
	url := "https://github.com/example/windows_setup/releases/tag/" + f.Version
	meta, _ := json.Marshal(map[string]any{"tag_name": f.Version, "html_url": url, "draft": false, "immutable": true, "assets": []releaseAsset{asset}})
	old, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	if err = os.Chdir(filepath.Join(fixture, f.Source)); err != nil {
		t.Fatal(err)
	}
	defer os.Chdir(old)
	bundle, err := prepareReleaseBundle(meta, f.Version, f.Commit, f.RunURL, f.RunAttempt, tool, filepath.Join(fixture, f.Archive))
	if err != nil {
		t.Fatal(err)
	}
	if bundle.CoverageScope == "" || len(bundle.Profile) != 0 {
		t.Fatal("runtime bundle identity lost")
	}
	prefix := "versions/" + f.Version + "/"
	pages := map[string][]byte{}
	for _, name := range []string{"index.html", "summary.json", "summary.md", "junit.xml", "unit.svg", "integration.svg", "coverage.svg", "repo_coverage.json", "coverage_inventory.json", "coverage.xml"} {
		data, e := os.ReadFile(filepath.Join(fixture, "windows-test-reports-1-1", name))
		if e != nil {
			t.Fatal(e)
		}
		pages[prefix+name] = data
	}
	pages[prefix+"index.html"] = append(pages[prefix+"index.html"], []byte(`<p>版本 `+f.Version+` · 提交 <code>`+f.Commit+`</code><br>量測時間（UTC）：2026-01-01T00:00:00Z</p><p><a href="`+f.RunURL+`">GitHub Actions 執行紀錄</a></p>`)...)
	pages["versions.json"], _ = json.Marshal([]map[string]any{{"Version": f.Version, "Status": "Verified", "Path": prefix + "index.html", "Commit": f.Commit, "ReleaseUrl": url, "MeasuredAt": "2026-01-01T00:00:00Z", "Digest": assetFromBytes("", bundle.Summary).Digest, "ArchiveDigest": asset.Digest}})
	read := func(name string) ([]byte, error) {
		data, ok := pages[name]
		if !ok {
			return nil, fmt.Errorf("missing %s", name)
		}
		return data, nil
	}
	if err := verifyTag(read, meta, f.Version, f.Commit, f.RunURL, nil, bundle, true); err != nil {
		t.Fatalf("runtime tag: %v", err)
	}
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		data, ok := pages[strings.TrimPrefix(r.URL.Path, "/")]
		if !ok {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write(data)
	}))
	defer server.Close()
	previousTransport := http.DefaultTransport
	http.DefaultTransport = server.Client().Transport
	defer func() { http.DefaultTransport = previousTransport }()
	metadataPath := filepath.Join(t.TempDir(), "release.json")
	if err = os.WriteFile(metadataPath, meta, 0600); err != nil {
		t.Fatal(err)
	}
	doc := filepath.Join(t.TempDir(), "readme.md")
	if err = os.WriteFile(doc, []byte("synthetic fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	previousFlags, previousArgs := flag.CommandLine, os.Args
	defer func() { flag.CommandLine, os.Args = previousFlags, previousArgs }()
	flag.CommandLine = flag.NewFlagSet("deployment", flag.ContinueOnError)
	flag.CommandLine.SetOutput(io.Discard)
	os.Args = []string{"verify_deployment", "--mode", "release", "--require-runtime", "--base-url", server.URL, "--readme", doc, "--expected-sha", f.Commit, "--expected-run-url", f.RunURL, "--tag", f.Version, "--release-metadata", metadataPath, "--report-bundle-tool", tool, "--report-archive", filepath.Join(fixture, f.Archive), "--run-attempt", "1"}
	if err := run(); err != nil {
		t.Fatalf("current runtime CLI rejected verified synthetic ZIP: %v", err)
	}
	wrongScope := *bundle
	wrongScope.CoverageScope = ""
	if err := verifyTag(read, meta, f.Version, f.Commit, f.RunURL, nil, &wrongScope, true); err == nil || !strings.Contains(err.Error(), "runtime bundle") {
		t.Fatalf("wrong runtime receipt accepted: %v", err)
	}
	pages[prefix+"summary.json"] = append(pages[prefix+"summary.json"], ' ')
	if err := verifyTag(read, meta, f.Version, f.Commit, f.RunURL, nil, bundle, true); err == nil || !strings.Contains(err.Error(), "immutable release") {
		t.Fatalf("changed summary accepted: %v", err)
	}
}
