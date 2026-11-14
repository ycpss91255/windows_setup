package main

import (
	"archive/zip"
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	a "windows_setup/script/test/acceptance"
	c "windows_setup/script/test/repo_coverage"
)

func syntheticNativeReport(t *testing.T, source string) (map[string][]byte, string, string) {
	t.Helper()
	name := "script/test/example/value.go"
	p := filepath.Join(source, filepath.FromSlash(name))
	if err := os.MkdirAll(filepath.Dir(p), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte("package example\nfunc Value() int { return 1 }\n"), 0600); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{{"init", "-q"}, {"config", "--local", "core.longpaths", "true"}, {"add", "--", name}} {
		cmd := exec.Command("git", append([]string{"-c", "core.longpaths=true", "-C", source}, args...)...)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("synthetic tracked source: %v %s", err, out)
		}
	}
	commitCmd := exec.Command("git", "-c", "core.longpaths=true", "-C", source, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture")
	if out, err := commitCmd.CombinedOutput(); err != nil {
		t.Fatalf("commit fixture: %v %s", err, out)
	}
	commitBytes, err := exec.Command("git", "-c", "core.longpaths=true", "-C", source, "rev-parse", "HEAD").Output()
	if err != nil {
		t.Fatal(err)
	}
	inv, err := c.ScanInventory(source)
	if err != nil {
		t.Fatal(err)
	}
	if len(inv.Sources) != 1 {
		t.Fatalf("unexpected fixture inventory: %+v", inv)
	}
	inv.Sources[0].ExpectedLines = []int{2}
	sha, runURL := strings.TrimSpace(string(commitBytes)), "https://github.com/example/windows_setup/actions/runs/1"
	stamp := "2026-01-01T00:00:00Z"
	art, err := c.CreateEvidence(inv, []c.Report{{SchemaVersion: 1, Metric: c.Metric, Files: map[string]map[int]bool{name: {2: true}}}}, c.Identity{Commit: sha, RunUrl: runURL, MeasuredAt: stamp, SourceState: "Clean"})
	if err != nil {
		t.Fatal(err)
	}
	var evidence c.Evidence
	if err = json.Unmarshal(art.Summary, &evidence); err != nil {
		t.Fatal(err)
	}
	yes := true
	r := a.Report{SchemaVersion: 2, RequestedLayer: "All", Commit: sha, RunUrl: runURL, SourceState: "Clean", Coverage: "Measured", RefType: "Branch", RefName: "main", Environment: "Synthetic command validation fixture", Version: "v0.1.0", MeasuredAt: stamp, Success: true, RepoCoverage: &evidence, Totals: a.Totals{SuitesExecuted: 2, AssertionsExecuted: 2, AssertionsPassed: 2}}
	for _, layer := range []string{"Unit", "Integration"} {
		r.Checks = append(r.Checks, a.Check{Name: layer, Layer: layer, Status: "Passed", Executed: true, Passed: &yes, Assertions: []a.Assertion{{Name: "synthetic contract", Passed: &yes}}})
	}
	data, err := json.Marshal(r)
	if err != nil {
		t.Fatal(err)
	}
	m := map[string][]byte{"main/summary.json": data, "main/repo_coverage.json": art.Summary, "main/coverage_inventory.json": art.Inventory, "main/coverage.xml": art.XML, "main/junit.xml": []byte(`<testsuites><testsuite name="Unit"><testcase/></testsuite><testsuite name="Integration"><testcase/></testsuite></testsuites>`), "main/summary.md": []byte(sha + " " + stamp), "main/index.html": []byte(`<h2>單元與隔離整合測試通過</h2><a href="summary.json">JSON</a><a href="summary.md">MD</a><a href="junit.xml">JUnit</a>`), "versions.json": []byte(`[]`), "index.html": []byte(`<h1>目前程式檢查通過</h1><h2>整體覆蓋率</h2><p>100.0%（1/1 可執行行）</p><p>aaaaaaa 2026-01-01 00:00:00 UTC</p><a href="main/index.html">結果</a><a href="https://github.com/example/windows_setup/blob/main/readme.md">說明</a>`)}
	for _, n := range []string{"unit", "integration", "coverage"} {
		label, status, color := n+" branch", "passed", "#4c1"
		if n == "coverage" {
			status = "100.0%"
			color = "#007ec6"
		}
		l, q := len(label)*7+12, len(status)*7+12
		m["main/"+n+".svg"] = []byte(fmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" height="20" width="%d"><rect width="%d" fill="#555"/><rect width="%d" fill="%s"/><g font-size="11"><text>%s</text><text>%s</text></g></svg>`, l+q, l, q, color, label, status))
	}
	return m, sha, runURL
}

func TestReportBundleExportPreservesValidatedReports(t *testing.T) {
	source := t.TempDir()
	original, sha, runURL := syntheticNativeReport(t, source)
	version := "v0.1.0"
	native := map[string][]byte{}
	for name, data := range original {
		if strings.HasPrefix(name, "main/") {
			native[strings.TrimPrefix(name, "main/")] = append([]byte(nil), data...)
		}
	}
	var summary map[string]any
	if err := json.Unmarshal(native["summary.json"], &summary); err != nil {
		t.Fatal(err)
	}
	summary["RefType"] = "Release"
	summary["RefName"] = version
	summary["Version"] = version
	summary["Environment"] = "Windows synthetic native fixture"
	owned := []string{"windows_setup/script/test/example/value.go"}
	goEvidence, profile, err := a.CreateCoverageEvidence([][]byte{[]byte("mode: set\n" + owned[0] + ":2.1,2.27 1 1\n")}, owned, a.CoverageProvenance{Commit: sha, RunUrl: runURL, MeasuredAt: "2026-01-01T00:00:00Z", SourceState: "Clean", GoVersion: "go1.27.3", Environment: "Synthetic Go fixture"})
	if err != nil {
		t.Fatal(err)
	}
	summary["GoCoverage"] = goEvidence
	native["summary.json"], _ = json.Marshal(summary)
	native["go_coverage.json"], _ = json.Marshal(goEvidence)
	native["go_coverage.out"] = profile
	for _, name := range []string{"unit", "integration", "coverage"} {
		value, color := "passed", "#4c1"
		if name == "coverage" {
			value, color = "100.0%", "#007ec6"
		}
		label := name + " release"
		l, q := len(label)*7+12, len(value)*7+12
		native[name+".svg"] = []byte(fmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" height="20" width="%d"><rect width="%d" fill="#555"/><rect width="%d" fill="%s"/><g font-size="11"><text>%s</text><text>%s</text></g></svg>`, l+q, l, q, color, label, value))
	}
	label, value := "go coverage release", "100.0%"
	l, q := len(label)*7+12, len(value)*7+12
	native["go_coverage.svg"] = []byte(fmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" height="20" width="%d"><rect width="%d" fill="#555"/><rect width="%d" fill="#4c1"/><g font-size="11"><text>%s</text><text>%s</text></g></svg>`, l+q, l, q, label, value))
	native["index.html"] = append(native["index.html"], []byte(`<details><summary>分項量測明細</summary><p>Go 程式敘述覆蓋率：100.0% · 1/1 statements；全部自有 Go 工具（含 CLI），不含 PowerShell 或第三方程式，不等於整體覆蓋率。</p><a href="go_coverage.json">Go JSON</a><a href="go_coverage.out">Go profile</a></details>`)...)
	native["summary.md"] = append(native["summary.md"], []byte("\nGo 程式敘述覆蓋率（分項）：100.0%；1/1 statements；全部自有 Go 工具含 CLI，不含 PowerShell 或第三方程式，不等於整體覆蓋率。")...)
	container := map[string][]byte{}
	for _, name := range []string{"index.html", "summary.json", "summary.md", "junit.xml", "unit.svg", "integration.svg", "coverage.svg"} {
		container[name] = append([]byte(nil), native[name]...)
	}
	delete(summary, "GoCoverage")
	delete(summary, "RepoCoverage")
	summary["Coverage"] = "NotMeasured"
	summary["Environment"] = "Windows container / Windows synthetic fixture"
	container["summary.json"], _ = json.Marshal(summary)
	container["index.html"] = original["main/index.html"]
	container["summary.md"] = original["main/summary.md"]
	label, value = "coverage release", "not measured"
	l, q = len(label)*7+12, len(value)*7+12
	container["coverage.svg"] = []byte(fmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" height="20" width="%d"><rect width="%d" fill="#555"/><rect width="%d" fill="#9f9f9f"/><g font-size="11"><text>%s</text><text>%s</text></g></svg>`, l+q, l, q, label, value))
	reader := func(m map[string][]byte) a.Reader {
		return func(name string) ([]byte, error) {
			b, ok := m[name]
			if !ok {
				return nil, fmt.Errorf("missing %s", name)
			}
			return b, nil
		}
	}
	for _, m := range []map[string][]byte{native, container} {
		if _, err := a.ValidateReport(reader(m), sha, runURL, false); err != nil {
			t.Fatalf("fixture report invalid: %v", err)
		}
	}
	if _, err := a.ValidateRepoCoverageReport(reader(native), native["summary.json"], sha, runURL, true); err != nil {
		t.Fatal(err)
	}
	if err := a.ValidateGoCoverageReport(reader(native), owned, sha, runURL, true); err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	nativeDir := filepath.Join(root, "windows-test-reports-1-1")
	containerDir := filepath.Join(root, "docker-test-reports-1-1")
	for _, pair := range []struct {
		dir   string
		files map[string][]byte
	}{{nativeDir, native}, {containerDir, container}} {
		if err := os.MkdirAll(pair.dir, 0700); err != nil {
			t.Fatal(err)
		}
		for name, data := range pair.files {
			if err := os.WriteFile(filepath.Join(pair.dir, name), data, 0600); err != nil {
				t.Fatal(err)
			}
		}
	}
	out := filepath.Join(root, "windows_setup_report_v0.1.0.zip")
	cmd := exec.Command("go", "run", ".", "export", "--native-dir", nativeDir, "--container-dir", containerDir, "--source-root", source, "--version", version, "--commit", sha, "--run-url", runURL, "--run-attempt", "1", "--output", out)
	if data, err := cmd.CombinedOutput(); err == nil {
		t.Fatalf("current exporter accepted legacy coverage: %s", data)
	}
	optionsFor := func(nativePath, containerPath, outputPath string, attempt int) options {
		return options{native: nativePath, container: containerPath, source: source, version: version, commit: sha, run: runURL, attempt: attempt, output: outputPath}
	}
	if err := export(optionsFor(nativeDir, containerDir, out, 1)); err != nil {
		t.Fatalf("historical fixture export: %v", err)
	}
	t.Run("reject_expanded_archive_over_limit", func(t *testing.T) {
		oldLimit := maxArchive
		defer func() { maxArchive = oldLimit }()
		total := 0
		for _, report := range []map[string][]byte{native, container} {
			for _, data := range report {
				total += len(data)
			}
		}
		maxArchive = total - 1
		output := filepath.Join(t.TempDir(), "windows_setup_report_v0.1.0.zip")
		if err := export(optionsFor(nativeDir, containerDir, output, 1)); err == nil {
			t.Fatal("export accepted validated reports whose expanded bytes exceed the verify limit")
		}
		if _, err := os.Stat(output); !os.IsNotExist(err) {
			t.Fatal("failed export must not leave an archive")
		}
	})
	inProcess := filepath.Join(t.TempDir(), "windows_setup_report_v0.1.0.zip")
	if err := export(optionsFor(nativeDir, containerDir, inProcess, 1)); err != nil {
		t.Fatalf("in-process export: %v", err)
	}
	t.Run("historical_context", func(t *testing.T) {
		archive, err := os.ReadFile(inProcess)
		if err != nil {
			t.Fatal(err)
		}
		sum := sha256.Sum256(archive)
		base := []string{"--historical", "--archive", inProcess, "--source-root", source, "--version", version, "--commit", sha, "--archive-sha256", fmt.Sprintf("%x", sum), "--archive-size", fmt.Sprint(len(archive))}
		output := filepath.Join(t.TempDir(), "verified")
		if err := verify(append(append([]string{}, base...), "--output-dir", output)); err != nil {
			t.Fatalf("historical: %v", err)
		}
		b, err := os.ReadFile(filepath.Join(output, "verified.json"))
		if err != nil {
			t.Fatal(err)
		}
		var m struct {
			Origin  string `json:"context_origin"`
			Run     string `json:"run_url"`
			Attempt int    `json:"run_attempt"`
		}
		if err := json.Unmarshal(b, &m); err != nil || m.Origin != "immutable_archive_manifest" || m.Run != runURL || m.Attempt != 1 {
			t.Fatalf("incorrect context: %s %v", b, err)
		}
		for name, args := range map[string][]string{
			"wrong digest":  append(append([]string{}, base...), "--archive-sha256", strings.Repeat("0", 64)),
			"wrong size":    append(append([]string{}, base...), "--archive-size", "1"),
			"mixed context": append(append([]string{}, base...), "--run-url", runURL),
			"mixed attempt": append(append([]string{}, base...), "--run-attempt", "1"),
			"wrong source":  append(append([]string{}, base...), "--commit", strings.Repeat("a", 40)),
		} {
			t.Run(name, func(t *testing.T) {
				if err := verify(args); err == nil {
					t.Fatal("invalid historical input accepted")
				}
			})
		}
	})
	t.Run("verified_output_ordinary_short_name", func(t *testing.T) {
		root := t.TempDir()
		long := filepath.Join(root, "ordinary_report_output_directory_long_name")
		if err := os.Mkdir(long, 0700); err != nil {
			t.Fatal(err)
		}
		short := shortTestPath(t, long)
		args := []string{"--archive", inProcess, "--source-root", source, "--version", version, "--commit", sha, "--run-url", runURL, "--run-attempt", "1", "--output-dir", filepath.Join(short, "verified")}
		if err := verify(args); err != nil {
			t.Fatalf("ordinary 8.3 parent rejected: %v", err)
		}
		got, err := os.ReadFile(filepath.Join(long, "verified", "native", "summary.json"))
		if err != nil || !bytes.Equal(got, native["summary.json"]) {
			t.Fatalf("verified bytes differ: %v", err)
		}
	})
	t.Run("verified_output", func(t *testing.T) {
		target := filepath.Join(t.TempDir(), "verified")
		args := []string{"--archive", inProcess, "--source-root", source, "--version", version, "--commit", sha, "--run-url", runURL, "--run-attempt", "1", "--output-dir", target}
		if err := verify(args); err != nil {
			t.Fatalf("verified output: %v", err)
		}
		got, err := os.ReadFile(filepath.Join(target, "native", "summary.json"))
		if err != nil || !bytes.Equal(got, native["summary.json"]) {
			t.Fatalf("summary differs: %v", err)
		}
		b, err := os.ReadFile(filepath.Join(target, "verified.json"))
		if err != nil {
			t.Fatal(err)
		}
		var meta struct {
			ArchiveSHA256 string `json:"archive_sha256"`
			ArchiveSize   int64  `json:"archive_size"`
		}
		if err := json.Unmarshal(b, &meta); err != nil {
			t.Fatal(err)
		}
		archive, err := os.ReadFile(inProcess)
		if err != nil {
			t.Fatal(err)
		}
		sum := sha256.Sum256(archive)
		if meta.ArchiveSHA256 != fmt.Sprintf("%x", sum) || meta.ArchiveSize != int64(len(archive)) {
			t.Fatal("archive metadata differs from verified bytes")
		}
		if err := verify(args); err == nil {
			t.Fatal("existing output accepted")
		}
	})
	t.Run("reject_symlink_output_parent", func(t *testing.T) {
		real := t.TempDir()
		link := filepath.Join(t.TempDir(), "link")
		if err := os.Symlink(real, link); err != nil {
			t.Skipf("symlink unavailable: %v", err)
		}
		target := filepath.Join(link, "verified")
		args := []string{"--archive", inProcess, "--source-root", source, "--version", version, "--commit", sha, "--run-url", runURL, "--run-attempt", "1", "--output-dir", target}
		if err := verify(args); err == nil {
			t.Fatal("symlink output parent accepted")
		}
		if _, err := os.Lstat(filepath.Join(real, "verified")); !os.IsNotExist(err) {
			t.Fatal("output written through symlink")
		}
	})
	t.Run("reject_case_distinct_symlink_parent", func(t *testing.T) {
		if runtime.GOOS == "windows" {
			t.Skip("requires case-sensitive filesystem")
		}
		root := t.TempDir()
		real := filepath.Join(root, "a")
		if err := os.Mkdir(real, 0700); err != nil {
			t.Fatal(err)
		}
		link := filepath.Join(root, "A")
		if err := os.Symlink(real, link); err != nil {
			t.Fatal(err)
		}
		target := filepath.Join(link, "verified")
		args := []string{"--archive", inProcess, "--source-root", source, "--version", version, "--commit", sha, "--run-url", runURL, "--run-attempt", "1", "--output-dir", target}
		if err := verify(args); err == nil {
			t.Fatal("case-distinct symlink output parent accepted")
		}
		if _, err := os.Lstat(filepath.Join(real, "verified")); !os.IsNotExist(err) {
			t.Fatal("output written through symlink")
		}
	})
	t.Run("invalid_archive_leaves_no_output", func(t *testing.T) {
		target := filepath.Join(t.TempDir(), "verified")
		args := []string{"--archive", inProcess, "--source-root", source, "--version", version, "--commit", sha, "--run-url", runURL, "--run-attempt", "2", "--output-dir", target}
		if err := verify(args); err == nil {
			t.Fatal("wrong attempt accepted")
		}
		if _, err := os.Lstat(target); !os.IsNotExist(err) {
			t.Fatal("failed verification left output")
		}
	})
	t.Run("scope_summarizes_executed_reports", func(t *testing.T) {
		z, err := zip.OpenReader(out)
		if err != nil {
			t.Fatal(err)
		}
		defer z.Close()
		for _, f := range z.File {
			if f.Name != "report_scope.md" {
				continue
			}
			r, err := f.Open()
			if err != nil {
				t.Fatal(err)
			}
			data, err := io.ReadAll(r)
			r.Close()
			if err != nil {
				t.Fatal(err)
			}
			for _, want := range []string{version, sha, runURL, "2026-01-01", "Windows container / Windows synthetic fixture", "NotMeasured", "synthetic contract", "Unit", "Integration"} {
				if !strings.Contains(string(data), want) {
					t.Errorf("scope missing verified report detail %q", want)
				}
			}
			return
		}
		t.Fatal("missing scope")
	})
	cliBytes, err := os.ReadFile(out)
	if err != nil {
		t.Fatal(err)
	}
	inProcessBytes, err := os.ReadFile(inProcess)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(cliBytes, inProcessBytes) {
		t.Fatal("identical inputs must yield deterministic archive bytes")
	}
	t.Run("command_dispatch_and_flags", func(t *testing.T) {
		oldArgs := os.Args
		defer func() { os.Args = oldArgs }()
		for _, args := range [][]string{{"tool"}, {"tool", "unknown"}, {"tool", "export", "--unknown"}, {"tool", "verify", "--unknown"}, {"tool", "verify"}} {
			os.Args = args
			if e := run(); e == nil {
				t.Fatalf("invalid command accepted: %v", args)
			}
		}
		output := filepath.Join(t.TempDir(), "windows_setup_report_v0.1.0.zip")
		os.Args = []string{"tool", "export", "--native-dir", nativeDir, "--container-dir", containerDir, "--source-root", source, "--version", version, "--commit", sha, "--run-url", runURL, "--run-attempt", "1", "--output", output}
		if e := run(); e == nil {
			t.Fatal("current command accepted historical scope")
		}
		os.Args = []string{"tool", "verify", "--archive", inProcess, "--source-root", source, "--version", version, "--commit", sha, "--run-url", runURL, "--run-attempt", "1"}
		if e := run(); e != nil {
			t.Fatal(e)
		}
	})
	for _, kind := range []string{"version", "commit", "run", "attempt", "artifact_names", "output_name", "inside_source", "missing_source", "dirty_source", "missing_report", "extra_file", "container_as_native", "native_environment"} {
		t.Run("invalid_export_"+kind, func(t *testing.T) {
			output := filepath.Join(t.TempDir(), "windows_setup_report_v0.1.0.zip")
			o := optionsFor(nativeDir, containerDir, output, 1)
			switch kind {
			case "version":
				o.version = "../bad"
			case "commit":
				o.commit = strings.Repeat("b", 40)
			case "run":
				o.run = "http://invalid"
			case "attempt":
				o.attempt = 0
			case "artifact_names":
				o.attempt = 2
			case "output_name":
				o.output = filepath.Join(t.TempDir(), "wrong.zip")
			case "inside_source":
				o.output = filepath.Join(source, "windows_setup_report_v0.1.0.zip")
			case "missing_source":
				o.source = filepath.Join(t.TempDir(), "missing")
			case "dirty_source":
				p := filepath.Join(source, "untracked.txt")
				os.WriteFile(p, []byte("fixture"), 0600)
				defer os.Remove(p)
			case "missing_report":
				o.native = filepath.Join(t.TempDir(), "windows-test-reports-1-1")
			case "extra_file":
				dir := filepath.Join(t.TempDir(), "windows-test-reports-1-1")
				os.MkdirAll(dir, 0700)
				for name, data := range native {
					os.WriteFile(filepath.Join(dir, name), data, 0600)
				}
				os.WriteFile(filepath.Join(dir, "secret.txt"), []byte("fixture"), 0600)
				o.native = dir
			case "native_environment":
				dir := filepath.Join(t.TempDir(), "windows-test-reports-1-1")
				os.MkdirAll(dir, 0700)
				for name, data := range native {
					if name == "summary.json" {
						var raw map[string]any
						json.Unmarshal(data, &raw)
						raw["Environment"] = "Linux synthetic"
						data, _ = json.Marshal(raw)
					}
					os.WriteFile(filepath.Join(dir, name), data, 0600)
				}
				o.native = dir
			case "container_as_native":
				dir := filepath.Join(t.TempDir(), "windows-test-reports-1-1")
				os.MkdirAll(dir, 0700)
				for name, data := range native {
					if name == "summary.json" {
						data = container[name]
					}
					os.WriteFile(filepath.Join(dir, name), data, 0600)
				}
				o.native = dir
			}
			if e := export(o); e == nil {
				t.Fatalf("invalid export accepted: %s", kind)
			}
			if _, e := os.Stat(output); !os.IsNotExist(e) {
				t.Fatalf("failed export created output: %s", kind)
			}
		})
	}
	z, err := zip.OpenReader(out)
	if err != nil {
		t.Fatal(err)
	}
	defer z.Close()
	files := map[string][]byte{}
	for _, f := range z.File {
		r, e := f.Open()
		if e != nil {
			t.Fatal(e)
		}
		var b bytes.Buffer
		_, e = b.ReadFrom(r)
		r.Close()
		if e != nil {
			t.Fatal(e)
		}
		if _, ok := files[f.Name]; ok {
			t.Fatalf("duplicate ZIP entry %s", f.Name)
		}
		files[f.Name] = b.Bytes()
	}
	legacyPage, err := a.ParsePage(files["index.html"])
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"整體覆蓋率", "100.0%", "1/1 可執行行"} {
		if !strings.Contains(legacyPage.Visible, want) {
			t.Errorf("historical coverage missing visible %q", want)
		}
	}
	if strings.Contains(legacyPage.Visible, "PowerShell/C# runtime 覆蓋率") {
		t.Fatal("schema 1 A overview mislabels historical coverage")
	}
	for _, entry := range []struct {
		prefix string
		files  map[string][]byte
	}{{"native/", native}, {"windows_container/", container}} {
		for name, want := range entry.files {
			if !bytes.Equal(files[entry.prefix+name], want) {
				t.Fatalf("original bytes changed: %s%s", entry.prefix, name)
			}
		}
	}
	for _, name := range []string{"index.html", "report_scope.md", "manifest.json"} {
		if len(files[name]) == 0 {
			t.Fatalf("missing %s", name)
		}
	}
	var manifest struct {
		SchemaVersion int    `json:"schema_version"`
		Version       string `json:"version"`
		Commit        string `json:"commit"`
		RunURL        string `json:"run_url"`
		RunAttempt    int    `json:"run_attempt"`
		Provenance    string `json:"provenance"`
		Files         []struct {
			Path   string `json:"path"`
			Size   int64  `json:"size"`
			SHA256 string `json:"sha256"`
		} `json:"files"`
	}
	if err := json.Unmarshal(files["manifest.json"], &manifest); err != nil {
		t.Fatal(err)
	}
	if manifest.SchemaVersion != 1 || manifest.Version != version || manifest.Commit != sha || manifest.RunURL != runURL || manifest.RunAttempt != 1 || !strings.Contains(manifest.Provenance, "not an independent provenance attestation") {
		t.Fatal("manifest identity or trust boundary mismatch")
	}
	seen := map[string]bool{}
	for _, entry := range manifest.Files {
		data, ok := files[entry.Path]
		if !ok || seen[entry.Path] || entry.Path == "manifest.json" {
			t.Fatalf("invalid manifest entry %s", entry.Path)
		}
		seen[entry.Path] = true
		sum := sha256.Sum256(data)
		if entry.Size != int64(len(data)) || entry.SHA256 != fmt.Sprintf("%x", sum) {
			t.Fatalf("digest mismatch %s", entry.Path)
		}
	}
	if len(seen) != len(files)-1 {
		t.Fatal("manifest does not cover every non-manifest ZIP file")
	}
	for _, kind := range []string{"empty_assertions", "contradictory_status"} {
		t.Run("container_execution_"+kind, func(t *testing.T) {
			dir := filepath.Join(t.TempDir(), "docker-test-reports-1-1")
			if err := os.MkdirAll(dir, 0700); err != nil {
				t.Fatal(err)
			}
			for name, data := range container {
				if name == "summary.json" {
					var raw map[string]any
					if err := json.Unmarshal(data, &raw); err != nil {
						t.Fatal(err)
					}
					checks := raw["Checks"].([]any)
					for _, value := range checks {
						check := value.(map[string]any)
						if kind == "empty_assertions" {
							check["Assertions"] = []any{}
						} else {
							check["Status"] = "Failed"
						}
					}
					if kind == "empty_assertions" {
						totals := raw["Totals"].(map[string]any)
						totals["AssertionsExecuted"] = 0
						totals["AssertionsPassed"] = 0
					}
					data, _ = json.Marshal(raw)
				}
				if err := os.WriteFile(filepath.Join(dir, name), data, 0600); err != nil {
					t.Fatal(err)
				}
			}
			output := filepath.Join(t.TempDir(), "windows_setup_report_v0.1.0.zip")
			if err := export(optionsFor(nativeDir, dir, output, 1)); err == nil {
				t.Fatalf("invalid actual execution accepted: %s", kind)
			}
		})
	}
	t.Run("container_must_not_claim_unmeasured_go", func(t *testing.T) {
		dir := filepath.Join(t.TempDir(), "docker-test-reports-1-1")
		if err := os.MkdirAll(dir, 0700); err != nil {
			t.Fatal(err)
		}
		for name, data := range container {
			if name == "summary.json" {
				var raw map[string]any
				if err := json.Unmarshal(data, &raw); err != nil {
					t.Fatal(err)
				}
				raw["GoCoverage"] = goEvidence
				data, _ = json.Marshal(raw)
			}
			if err := os.WriteFile(filepath.Join(dir, name), data, 0600); err != nil {
				t.Fatal(err)
			}
		}
		output := filepath.Join(t.TempDir(), "windows_setup_report_v0.1.0.zip")
		if err := export(optionsFor(nativeDir, dir, output, 1)); err == nil || !strings.Contains(err.Error(), "go_coverage.json") {
			t.Fatalf("container unmeasured Go must be rejected for missing sidecar: %v", err)
		}
	})
	for _, malicious := range []string{`<script>alert(1)</script>`, `<a href="javascript:alert(1)">x</a>`, `<p onclick="alert(1)">x</p>`, `<iframe src="https://untrusted.invalid"></iframe>`} {
		t.Run("unsafe_public_html", func(t *testing.T) {
			dir := filepath.Join(t.TempDir(), "windows-test-reports-1-1")
			if err := os.MkdirAll(dir, 0700); err != nil {
				t.Fatal(err)
			}
			for name, data := range native {
				if name == "index.html" {
					data = append(append([]byte(nil), data...), []byte(malicious)...)
				}
				if err := os.WriteFile(filepath.Join(dir, name), data, 0600); err != nil {
					t.Fatal(err)
				}
			}
			output := filepath.Join(t.TempDir(), "windows_setup_report_v0.1.0.zip")
			if err := export(optionsFor(dir, containerDir, output, 1)); err == nil {
				t.Fatal("unsafe public report accepted")
			}
			if _, err := os.Stat(output); !os.IsNotExist(err) {
				t.Fatal("unsafe report created output")
			}
		})
	}
	verifyArchive := func(path string, attempt string) error {
		t.Helper()
		return verify([]string{"--archive", path, "--source-root", source, "--version", version, "--commit", sha, "--run-url", runURL, "--run-attempt", attempt})
	}

	if err := verifyArchive(out, "1"); err != nil {
		t.Fatalf("valid archive must verify: %v", err)
	}
	for _, kind := range []string{"tampered", "missing", "extra", "traversal", "duplicate", "wrong_attempt", "rehashed_scope", "rehashed_index", "rehashed_summary", "duplicate_manifest_key", "duplicate_manifest_case", "presentation_missing", "presentation_null", "presentation_empty", "presentation_type", "presentation_case", "legacy_body"} {
		t.Run(kind, func(t *testing.T) {
			if kind == "wrong_attempt" {
				if err := verifyArchive(out, "2"); err == nil {
					t.Fatal("wrong attempt accepted")
				}
				return
			}
			changed := map[string][]byte{}
			for name, data := range files {
				changed[name] = append([]byte(nil), data...)
			}
			var changedPath string
			switch kind {
			case "rehashed_scope":
				changedPath = "report_scope.md"
				changed[changedPath] = []byte("System was executed and passed")
			case "rehashed_index":
				changedPath = "index.html"
				changed[changedPath] = []byte("<html><a href=\"https://untrusted.invalid\">wrong report</a></html>")
			case "rehashed_summary":
				changedPath = "native/summary.json"
				var raw map[string]any
				json.Unmarshal(changed[changedPath], &raw)
				raw["Commit"] = strings.Repeat("b", 40)
				changed[changedPath], _ = json.Marshal(raw)
			case "presentation_missing", "presentation_null", "presentation_empty", "presentation_type", "presentation_case":
				var m map[string]any
				if err := json.Unmarshal(changed["manifest.json"], &m); err != nil {
					t.Fatal(err)
				}
				switch kind {
				case "presentation_missing":
					delete(m, "presentation")
				case "presentation_null":
					m["presentation"] = nil
				case "presentation_empty":
					m["presentation"] = ""
				case "presentation_type":
					m["presentation"] = float64(1)
				case "presentation_case":
					delete(m, "presentation")
					m["Presentation"] = overviewPresentation
				}
				changed["manifest.json"], _ = json.Marshal(m)
			case "legacy_body":
				changedPath = "index.html"
				native := map[string][]byte{}
				container := map[string][]byte{}
				for _, n := range nativeNames {
					native[n] = changed["native/"+n]
				}
				for _, n := range containerNames {
					container[n] = changed["windows_container/"+n]
				}
				changed[changedPath], _ = legacyRootDocuments(version, native, container)
			case "duplicate_manifest_key":
				changed["manifest.json"] = bytes.Replace(changed["manifest.json"], []byte("{\n"), []byte("{\n  \"schema_version\": 1,\n"), 1)
			case "duplicate_manifest_case":
				changed["manifest.json"] = bytes.Replace(changed["manifest.json"], []byte("{\n"), []byte("{\n  \"SCHEMA_VERSION\": 1,\n"), 1)
			}
			if changedPath != "" {
				var m map[string]any
				if e := json.Unmarshal(changed["manifest.json"], &m); e != nil {
					t.Fatal(e)
				}
				for _, entry := range m["files"].([]any) {
					item := entry.(map[string]any)
					if item["path"] == changedPath {
						sum := sha256.Sum256(changed[changedPath])
						item["size"] = len(changed[changedPath])
						item["sha256"] = fmt.Sprintf("%x", sum)
					}
				}
				changed["manifest.json"], _ = json.Marshal(m)
			}
			p := filepath.Join(t.TempDir(), "candidate.zip")
			f, e := os.Create(p)
			if e != nil {
				t.Fatal(e)
			}
			w := zip.NewWriter(f)
			for name, data := range changed {
				if kind == "missing" && name == "native/summary.json" {
					continue
				}
				if kind == "tampered" && name == "native/summary.json" {
					data = append(append([]byte(nil), data...), ' ')
				}
				entry, e := w.Create(name)
				if e != nil {
					t.Fatal(e)
				}
				if _, e = entry.Write(data); e != nil {
					t.Fatal(e)
				}
			}
			if kind == "extra" || kind == "traversal" || kind == "duplicate" {
				name := "extra.txt"
				if kind == "traversal" {
					name = "../escape"
				}
				if kind == "duplicate" {
					name = "native/summary.json"
				}
				entry, e := w.Create(name)
				if e != nil {
					t.Fatal(e)
				}
				entry.Write([]byte("unexpected"))
			}
			if e = w.Close(); e != nil {
				t.Fatal(e)
			}
			f.Close()
			if err := verifyArchive(p, "1"); err == nil {
				t.Fatalf("invalid archive accepted: %s", kind)
			}
			archiveBytes, err := os.ReadFile(p)
			if err != nil {
				t.Fatal(err)
			}
			sum := sha256.Sum256(archiveBytes)
			historical := []string{"--historical", "--archive", p, "--source-root", source, "--version", version, "--commit", sha, "--archive-sha256", fmt.Sprintf("%x", sum), "--archive-size", fmt.Sprint(len(archiveBytes))}
			if err := verify(historical); err == nil {
				t.Fatalf("historical mode accepted invalid archive: %s", kind)
			}
		})
	}
}

func TestRuntimeReleaseReportDoesNotRequireGoCoverage(t *testing.T) {
	base := t.TempDir()
	if requested := os.Getenv("WINDOWS_SETUP_RUNTIME_BUNDLE_FIXTURE_DIR"); requested != "" {
		if !filepath.IsAbs(requested) {
			t.Fatal("fixture destination must be absolute")
		}
		parent, err := canonicalSafeParent(filepath.Dir(filepath.Clean(requested)))
		if err != nil {
			t.Fatal(err)
		}
		base = filepath.Join(parent, filepath.Base(filepath.Clean(requested)))
		if err := os.Mkdir(base, 0700); err != nil {
			t.Fatal(err)
		}
	}
	source := filepath.Join(base, "source")
	if err := os.Mkdir(source, 0700); err != nil {
		t.Fatal(err)
	}
	original, oldSHA, runURL := syntheticNativeReport(t, source)
	ps := filepath.Join(source, "core", "sample.ps1")
	if err := os.MkdirAll(filepath.Dir(ps), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(ps, []byte("Write-Output 'fixture'\n"), 0600); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{{"add", "core/sample.ps1"}, {"-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "runtime fixture"}} {
		if out, err := exec.Command("git", append([]string{"-C", source}, args...)...).CombinedOutput(); err != nil {
			t.Fatalf("fixture git: %s %v", out, err)
		}
	}
	commit, err := exec.Command("git", "-C", source, "rev-parse", "HEAD").Output()
	if err != nil {
		t.Fatal(err)
	}
	sha := strings.TrimSpace(string(commit))
	inv, err := c.ScanRuntimeInventory(source)
	if err != nil || len(inv.Sources) != 1 {
		t.Fatalf("runtime inventory: %+v %v", inv, err)
	}
	inv.Sources[0].ExpectedLines = []int{1}
	art, err := c.CreateRuntimeEvidence(inv, []c.Report{{SchemaVersion: 1, Metric: c.Metric, Files: map[string]map[int]bool{"core/sample.ps1": {1: true}}}}, c.Identity{Commit: sha, RunUrl: runURL, MeasuredAt: "2026-01-01T00:00:00Z", SourceState: "Clean"})
	if err != nil {
		t.Fatal(err)
	}
	native := map[string][]byte{}
	for name, data := range original {
		if strings.HasPrefix(name, "main/") {
			native[strings.TrimPrefix(name, "main/")] = bytes.ReplaceAll(data, []byte(oldSHA), []byte(sha))
		}
	}
	var summary map[string]any
	if err = json.Unmarshal(native["summary.json"], &summary); err != nil {
		t.Fatal(err)
	}
	summary["RepoCoverage"], summary["RefType"], summary["RefName"], summary["Version"], summary["Environment"] = json.RawMessage(art.Summary), "Release", "v0.1.0", "v0.1.0", "Windows synthetic native fixture"
	summary["Changes"] = []string{"Synthetic fixture"}
	for _, check := range summary["Checks"].([]any) {
		check.(map[string]any)["ExitCode"] = 0
	}
	native["summary.json"], _ = json.Marshal(summary)
	native["repo_coverage.json"], native["coverage_inventory.json"], native["coverage.xml"] = art.Summary, art.Inventory, art.XML
	for _, name := range []string{"unit", "integration", "coverage"} {
		label, value, color := name+" release", "passed", "#4c1"
		if name == "coverage" {
			label, value, color = "runtime PowerShell/C#", "100.0%", "#007ec6"
		}
		l, q := len(label)*7+12, len(value)*7+12
		aria := ""
		if name == "coverage" {
			aria = fmt.Sprintf(` aria-label="%s release: %s"><title>%s release: %s</title`, label, value, label, value)
		}
		if name == "coverage" {
			native[name+".svg"] = []byte(fmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" height="20" width="%d"%s><rect width="%d" fill="#555"/><rect width="%d" fill="%s"/><g font-size="11"><text>%s</text><text>%s</text></g></svg>`, l+q, aria, l, q, color, label, value))
		} else {
			native[name+".svg"] = []byte(fmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" height="20" width="%d"><rect width="%d" fill="#555"/><rect width="%d" fill="%s"/><g font-size="11"><text>%s</text><text>%s</text></g></svg>`, l+q, l, q, color, label, value))
		}
	}
	container := map[string][]byte{}
	for _, n := range containerNames {
		container[n] = append([]byte(nil), native[n]...)
	}
	delete(summary, "RepoCoverage")
	summary["Coverage"] = "NotMeasured"
	summary["Environment"] = "Windows container / Windows synthetic fixture"
	container["summary.json"], _ = json.Marshal(summary)
	label, value := "coverage release", "not measured"
	l, q := len(label)*7+12, len(value)*7+12
	container["coverage.svg"] = []byte(fmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" height="20" width="%d"><rect width="%d" fill="#555"/><rect width="%d" fill="#9f9f9f"/><g font-size="11"><text>%s</text><text>%s</text></g></svg>`, l+q, l, q, label, value))
	if err := validateReports(options{source: source, version: "v0.1.0", commit: sha, run: runURL, attempt: 1}, native, container); err != nil {
		t.Fatalf("runtime release without Go coverage rejected: %v", err)
	}
	nativeDir, containerDir := filepath.Join(base, "windows-test-reports-1-1"), filepath.Join(base, "docker-test-reports-1-1")
	for _, pair := range []struct {
		dir   string
		files map[string][]byte
	}{{nativeDir, native}, {containerDir, container}} {
		if err := os.Mkdir(pair.dir, 0700); err != nil {
			t.Fatal(err)
		}
		for name, data := range pair.files {
			if err := os.WriteFile(filepath.Join(pair.dir, name), data, 0600); err != nil {
				t.Fatal(err)
			}
		}
	}
	archive := filepath.Join(base, "windows_setup_report_v0.1.0.zip")
	if err := exportWithScope(options{native: nativeDir, container: containerDir, source: source, version: "v0.1.0", commit: sha, run: runURL, attempt: 1, output: archive}, true); err != nil {
		t.Fatalf("runtime bundle export: %v", err)
	}
	z, err := zip.OpenReader(archive)
	if err != nil {
		t.Fatal(err)
	}
	scopeFound, runtimePageFound := false, false
	for _, f := range z.File {
		if f.Name == "index.html" {
			r, e := f.Open()
			if e != nil {
				t.Fatal(e)
			}
			data, e := io.ReadAll(r)
			r.Close()
			if e != nil {
				t.Fatal(e)
			}
			page, e := a.ParsePage(data)
			if e != nil {
				t.Fatal(e)
			}
			runtimePageFound = strings.Contains(page.Visible, "PowerShell/C# runtime 覆蓋率") && strings.Contains(page.Visible, "100.0%") && strings.Contains(page.Visible, "1/1 可執行行")
		}
		if strings.HasPrefix(f.Name, "native/go_coverage.") {
			t.Errorf("runtime bundle includes Go coverage: %s", f.Name)
		}
		if f.Name == "report_scope.md" {
			r, e := f.Open()
			if e != nil {
				t.Fatal(e)
			}
			data, e := io.ReadAll(r)
			r.Close()
			if e != nil {
				t.Fatal(e)
			}
			scopeFound = strings.Contains(string(data), "PowerShell/C# runtime")
		}
	}
	if !runtimePageFound {
		t.Error("runtime A overview must retain runtime scope and exact counts")
	}
	if !scopeFound {
		t.Error("runtime bundle scope document lacks language scope")
	}
	if err = z.Close(); err != nil {
		t.Fatal(err)
	}
	verified := filepath.Join(t.TempDir(), "verified")
	if err := verify([]string{"--archive", archive, "--source-root", source, "--version", "v0.1.0", "--commit", sha, "--run-url", runURL, "--run-attempt", "1", "--output-dir", verified}); err != nil {
		t.Fatalf("runtime bundle verify: %v", err)
	}
	receipt, err := os.ReadFile(filepath.Join(verified, "verified.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fields map[string]any
	if err := json.Unmarshal(receipt, &fields); err != nil {
		t.Fatal(err)
	}
	if fields["coverage_scope"] != c.RuntimeScope || fields["profile_sha256"] != nil {
		t.Fatalf("runtime receipt must identify its scope and omit Go profile: %s", receipt)
	}
	if os.Getenv("WINDOWS_SETUP_RUNTIME_BUNDLE_FIXTURE_DIR") != "" {
		data, err := os.ReadFile(archive)
		if err != nil {
			t.Fatal(err)
		}
		hash := sha256.Sum256(data)
		metadata, err := json.Marshal(map[string]any{"kind": "Synthetic", "version": "v0.1.0", "commit": sha, "run_url": runURL, "run_attempt": 1, "source": "source", "archive": filepath.Base(archive), "sha256": fmt.Sprintf("%x", hash), "size": len(data)})
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(base, "fixture.json"), metadata, 0600); err != nil {
			t.Fatal(err)
		}
	}
}
func TestOutputParentComparisonRespectsPlatform(t *testing.T) {
	if sameOutputParent("/tmp/A", "/tmp/a", "linux") {
		t.Fatal("case-distinct Linux paths accepted as identical")
	}
	if !sameOutputParent("C:/Temp/A", "c:/temp/a", "windows") {
		t.Fatal("Windows paths should ignore case")
	}
}
