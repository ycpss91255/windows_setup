package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	c "windows_setup/script/test/repo_coverage"
)

func TestRuntimeBundleReceiptWithoutGoProfile(t *testing.T) {
	tag, sha, run := "v0.2.5", strings.Repeat("a", 40), "https://github.com/example/repo/actions/runs/3"
	archive := filepath.Join(t.TempDir(), "report.zip")
	payload := []byte("archive")
	if err := os.WriteFile(archive, payload, 0600); err != nil {
		t.Fatal(err)
	}
	a := assetFromBytes("windows_setup_report_"+tag+".zip", payload)
	meta, _ := json.Marshal(map[string]any{"tag_name": tag, "draft": false, "immutable": true, "assets": []releaseAsset{a}})
	old := runReportVerifier
	defer func() { runReportVerifier = old }()
	scope := c.RuntimeScope
	runReportVerifier = func(_ string, args ...string) error {
		out := ""
		for i := range args {
			if args[i] == "--output-dir" {
				out = args[i+1]
			}
		}
		if err := os.MkdirAll(filepath.Join(out, "native"), 0700); err != nil {
			return err
		}
		summary := []byte("summary")
		if err := os.WriteFile(filepath.Join(out, "native", "summary.json"), summary, 0600); err != nil {
			return err
		}
		r := map[string]any{"archive_sha256": strings.TrimPrefix(a.Digest, "sha256:"), "archive_size": a.Size, "version": tag, "commit": sha, "run_url": run, "run_attempt": 1, "summary_sha256": strings.TrimPrefix(assetFromBytes("", summary).Digest, "sha256:"), "context_origin": "explicit", "coverage_scope": scope}
		b, _ := json.Marshal(r)
		return os.WriteFile(filepath.Join(out, "verified.json"), b, 0600)
	}
	if _, err := prepareReleaseBundle(meta, tag, sha, run, 1, "trusted", archive); err != nil {
		t.Fatalf("runtime receipt rejected: %v", err)
	}
	scope = "unknown"
	if _, err := prepareReleaseBundle(meta, tag, sha, run, 1, "trusted", archive); err == nil {
		t.Fatal("unknown scope accepted")
	}
}

func Test報表封裝驗證與外層身分(t *testing.T) {
	tag, sha, run := "v0.2.5", strings.Repeat("a", 40), "https://github.com/example/repo/actions/runs/3"
	archive := filepath.Join(t.TempDir(), "report.zip")
	payload := []byte("actual archive bytes")
	if err := os.WriteFile(archive, payload, 0600); err != nil {
		t.Fatal(err)
	}
	a := assetFromBytes("windows_setup_report_"+tag+".zip", payload)
	meta := func(assets []releaseAsset) []byte {
		b, _ := json.Marshal(map[string]any{"tag_name": tag, "draft": false, "immutable": true, "assets": assets})
		return b
	}
	summary, profile := []byte("summary"), []byte("profile")
	old := runReportVerifier
	defer func() { runReportVerifier = old }()
	calls := 0
	origin := "explicit"
	runReportVerifier = func(tool string, args ...string) error {
		calls++
		out := ""
		for i := range args {
			if args[i] == "--output-dir" {
				out = args[i+1]
			}
		}
		if err := os.MkdirAll(filepath.Join(out, "native"), 0700); err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(out, "native", "summary.json"), summary, 0600); err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(out, "native", "go_coverage.out"), profile, 0600); err != nil {
			return err
		}
		r := map[string]any{"archive_sha256": strings.TrimPrefix(a.Digest, "sha256:"), "archive_size": a.Size, "version": tag, "commit": sha, "run_url": run, "run_attempt": 2, "summary_sha256": strings.TrimPrefix(assetFromBytes("", summary).Digest, "sha256:"), "profile_sha256": strings.TrimPrefix(assetFromBytes("", profile).Digest, "sha256:"), "context_origin": origin}
		b, _ := json.Marshal(r)
		return os.WriteFile(filepath.Join(out, "verified.json"), b, 0600)
	}
	got, err := prepareReleaseBundle(meta([]releaseAsset{a}), tag, sha, run, 2, "trusted", archive)
	if err != nil || got.ArchiveDigest != a.Digest || string(got.Summary) != "summary" || calls != 1 {
		t.Fatalf("valid bundle: %v", err)
	}

	t.Run("超過讀取上限須拒絕", func(t *testing.T) {
		oldLimit := maxReportArchiveBytes
		defer func() { maxReportArchiveBytes = oldLimit }()
		maxReportArchiveBytes = 8
		if _, err := prepareReleaseBundle(meta([]releaseAsset{a}), tag, sha, run, 2, "trusted", archive); err == nil {
			t.Fatal("不得讀取超過上限的封裝")
		}
	})

	origin = "immutable_archive_manifest"
	if _, err = prepareReleaseBundle(meta([]releaseAsset{a}), tag, sha, run, 2, "trusted", archive); err == nil {
		t.Fatal("拒絕非 explicit 來源")
	}
	origin = "explicit"
	for _, tc := range []struct {
		name    string
		assets  []releaseAsset
		attempt int
		path    string
	}{
		{"混合", []releaseAsset{a, {Name: "quality.json"}}, 2, archive},
		{"重複", []releaseAsset{a, a}, 2, archive},
		{"attempt錯誤", []releaseAsset{a}, 1, archive},
		{"缺archive", []releaseAsset{a}, 2, ""},
		{"錯誤digest", []releaseAsset{{Name: a.Name, Size: a.Size, Digest: "sha256:" + strings.Repeat("b", 64)}}, 2, archive},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if _, e := prepareReleaseBundle(meta(tc.assets), tag, sha, run, tc.attempt, "trusted", tc.path); e == nil {
				t.Fatal(fmt.Sprint("應拒絕 ", tc.name))
			}
		})
	}
}
func Test真實封裝驗證器(t *testing.T) {
	root, err := filepath.Abs("../../..")
	if err != nil {
		t.Fatal(err)
	}
	fixture := filepath.Join(t.TempDir(), "fixture")
	cmd := exec.Command("go", "test", "-count=1", "-run", "^TestExportSyntheticConsumerFixture$", "./script/test/report_bundle_tool")
	cmd.Dir = root
	cmd.Env = append(os.Environ(), "WINDOWS_SETUP_BUNDLE_FIXTURE_DIR="+fixture)
	if b, e := cmd.CombinedOutput(); e != nil {
		t.Fatalf("建立測試資料: %v %s", e, b)
	}
	var f struct {
		Version, Commit, RunURL, Archive, Source, SHA256 string
		RunAttempt                                       int `json:"run_attempt"`
		Size                                             int64
	}
	data, e := os.ReadFile(filepath.Join(fixture, "fixture.json"))
	if e != nil {
		t.Fatal(e)
	}
	if e = json.Unmarshal(data, &f); e != nil {
		t.Fatal(e)
	}
	var fields map[string]any
	if e = json.Unmarshal(data, &fields); e != nil {
		t.Fatal(e)
	}
	f.RunURL = fields["run_url"].(string)
	tool := filepath.Join(t.TempDir(), "report-bundle-tool")
	if runtime.GOOS == "windows" {
		tool += ".exe"
	}
	build := exec.Command("go", "build", "-o", tool, "./script/test/report_bundle_tool")
	build.Dir = root
	if b, e := build.CombinedOutput(); e != nil {
		t.Fatalf("建置驗證器: %v %s", e, b)
	}
	archive := filepath.Join(fixture, filepath.FromSlash(f.Archive))
	a := releaseAsset{Name: "windows_setup_report_" + f.Version + ".zip", Size: f.Size, Digest: "sha256:" + f.SHA256}
	meta, _ := json.Marshal(map[string]any{"tag_name": f.Version, "draft": false, "immutable": true, "assets": []releaseAsset{a}})
	old, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	if err = os.Chdir(filepath.Join(fixture, filepath.FromSlash(f.Source))); err != nil {
		t.Fatal(err)
	}
	defer os.Chdir(old)
	got, err := prepareReleaseBundle(meta, f.Version, f.Commit, f.RunURL, f.RunAttempt, tool, archive)
	if err != nil || got == nil {
		t.Fatalf("真實封裝應通過：%v", err)
	}
	if _, err = prepareReleaseBundle(meta, f.Version, f.Commit, f.RunURL, f.RunAttempt+1, tool, archive); err == nil {
		t.Fatal("錯誤 attempt 應拒絕")
	}
	b, err := os.ReadFile(archive)
	if err != nil {
		t.Fatal(err)
	}
	b[len(b)/2] ^= 1
	if err = os.WriteFile(archive, b, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err = prepareReleaseBundle(meta, f.Version, f.Commit, f.RunURL, f.RunAttempt, tool, archive); err == nil {
		t.Fatal("封裝竄改應拒絕")
	}
}
func Test下載版本報表附件(t *testing.T) {
	tag := "v0.2.5"
	a := releaseAsset{Name: "windows_setup_report_" + tag + ".zip", Size: 1, Digest: "sha256:" + strings.Repeat("a", 64)}
	metadata := func(assets []releaseAsset) []byte {
		b, _ := json.Marshal(map[string]any{"tag_name": tag, "draft": false, "immutable": true, "assets": assets})
		return b
	}
	old := runAssetDownload
	defer func() { runAssetDownload = old }()
	calls := 0
	runAssetDownload = func(args ...string) error { calls++; return nil }
	path := filepath.Join(t.TempDir(), "new", a.Name)
	if err := downloadReportAsset(metadata([]releaseAsset{a}), tag, "example/repo", path); err != nil || calls != 1 {
		t.Fatalf("新附件應下載：%v", err)
	}
	rawPath := filepath.Join(t.TempDir(), "new", a.Name)
	if err := downloadReportAsset(metadata([]releaseAsset{{Name: "quality.json"}}), tag, "example/repo", rawPath); err != nil || calls != 1 {
		t.Fatalf("舊附件不應下載：%v", err)
	}
	if err := downloadReportAsset(metadata([]releaseAsset{a, {Name: "quality.json"}}), tag, "example/repo", filepath.Join(t.TempDir(), "new", a.Name)); err == nil {
		t.Fatal("混合格式應拒絕")
	}
	if err := downloadReportAsset(metadata([]releaseAsset{a}), tag, "bad repo", filepath.Join(t.TempDir(), "new", a.Name)); err == nil {
		t.Fatal("錯誤 repository 應拒絕")
	}
}
