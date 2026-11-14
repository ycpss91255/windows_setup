package main

import (
	"archive/zip"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	htmlparser "golang.org/x/net/html"
	"html"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
	a "windows_setup/script/test/acceptance"
	c "windows_setup/script/test/repo_coverage"
)

var nativeNames = []string{"index.html", "summary.json", "summary.md", "junit.xml", "unit.svg", "integration.svg", "coverage.svg", "repo_coverage.json", "coverage_inventory.json", "coverage.xml", "go_coverage.json", "go_coverage.out", "go_coverage.svg"}
var nativeRuntimeNames = []string{"index.html", "summary.json", "summary.md", "junit.xml", "unit.svg", "integration.svg", "coverage.svg", "repo_coverage.json", "coverage_inventory.json", "coverage.xml"}
var containerNames = []string{"index.html", "summary.json", "summary.md", "junit.xml", "unit.svg", "integration.svg", "coverage.svg"}

const provenanceNote = "CI selects exact run and attempt artifacts; this manifest records supplied context and is not an independent provenance attestation."
const maxFile = 64 << 20

var maxArchive = 256 << 20

type fileRecord struct {
	Path   string `json:"path"`
	Size   int64  `json:"size"`
	SHA256 string `json:"sha256"`
}
type bundleManifest struct {
	SchemaVersion int          `json:"schema_version"`
	Scope         string       `json:"scope,omitempty"`
	Version       string       `json:"version"`
	Commit        string       `json:"commit"`
	RunURL        string       `json:"run_url"`
	RunAttempt    int          `json:"run_attempt"`
	Provenance    string       `json:"provenance"`
	Files         []fileRecord `json:"files"`
}
type options struct {
	native, container, source, version, commit, run, output string
	attempt                                                 int
}

func parseOptions(args []string) (options, error) {
	var o options
	f := flag.NewFlagSet("export", flag.ContinueOnError)
	f.SetOutput(io.Discard)
	f.StringVar(&o.native, "native-dir", "", "")
	f.StringVar(&o.container, "container-dir", "", "")
	f.StringVar(&o.source, "source-root", "", "")
	f.StringVar(&o.version, "version", "", "")
	f.StringVar(&o.commit, "commit", "", "")
	f.StringVar(&o.run, "run-url", "", "")
	f.IntVar(&o.attempt, "run-attempt", 0, "")
	f.StringVar(&o.output, "output", "", "")
	if err := f.Parse(args); err != nil {
		return o, err
	}
	if f.NArg() != 0 {
		return o, errors.New("unexpected argument")
	}
	return o, nil
}
func validateIdentity(o options) (string, error) {
	if !regexp.MustCompile(`^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-rc[1-9][0-9]*)?$`).MatchString(o.version) || !regexp.MustCompile(`^[a-f0-9]{40}$`).MatchString(o.commit) || o.attempt < 1 {
		return "", errors.New("invalid version, commit or attempt")
	}
	m := regexp.MustCompile(`^https://github\.com/[^/]+/[^/]+/actions/runs/([1-9][0-9]*)$`).FindStringSubmatch(o.run)
	if len(m) != 2 {
		return "", errors.New("invalid run URL")
	}
	return m[1], nil
}
func loadReport(dir string, names []string) (map[string][]byte, error) {
	info, e := os.Lstat(dir)
	if e != nil {
		return nil, e
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return nil, errors.New("report directory must be a real directory")
	}
	entries, e := os.ReadDir(dir)
	if e != nil {
		return nil, e
	}
	if len(entries) != len(names) {
		return nil, errors.New("report file set mismatch")
	}
	allowed := map[string]bool{}
	for _, n := range names {
		allowed[n] = true
	}
	out := map[string][]byte{}
	for _, entry := range entries {
		if !allowed[entry.Name()] {
			return nil, fmt.Errorf("unexpected report file: %s", entry.Name())
		}
		p := filepath.Join(dir, entry.Name())
		st, e := os.Lstat(p)
		if e != nil {
			return nil, e
		}
		if !st.Mode().IsRegular() || st.Size() < 0 || st.Size() > maxFile {
			return nil, errors.New("invalid report file type or size")
		}
		data, e := os.ReadFile(p)
		if e != nil {
			return nil, e
		}
		if int64(len(data)) != st.Size() {
			return nil, errors.New("report changed during read")
		}
		out[entry.Name()] = data
	}
	return out, nil
}
func reportReader(m map[string][]byte) a.Reader {
	return func(name string) ([]byte, error) {
		b, ok := m[name]
		if !ok {
			return nil, fmt.Errorf("missing report %s", name)
		}
		return b, nil
	}
}
func validatePublicDocuments(files map[string][]byte) error {
	for name, data := range files {
		if !strings.HasSuffix(name, ".html") && !strings.HasSuffix(name, ".svg") {
			continue
		}
		if !utf8.Valid(data) {
			return errors.New("public document is not UTF-8")
		}
		root, err := htmlparser.Parse(strings.NewReader(string(data)))
		if err != nil {
			return err
		}
		var walk func(*htmlparser.Node) error
		walk = func(node *htmlparser.Node) error {
			if node.Type == htmlparser.ElementNode {
				switch node.Data {
				case "script", "iframe", "object", "embed", "form":
					return errors.New("active content in public report")
				}
				for _, attr := range node.Attr {
					key := strings.ToLower(attr.Key)
					if strings.HasPrefix(key, "on") {
						return errors.New("event handler in public report")
					}
					value := strings.Map(func(r rune) rune {
						if unicode.IsSpace(r) || unicode.IsControl(r) {
							return -1
						}
						return unicode.ToLower(r)
					}, attr.Val)
					if strings.Contains(value, "javascript:") || strings.Contains(value, "vbscript:") || strings.Contains(value, "data:text/html") || (key == "style" && (strings.Contains(value, "url(") || strings.Contains(value, "expression(") || strings.Contains(value, "@import"))) {
						return errors.New("active URL or style in public report")
					}
				}
				if node.Data == "style" {
					for child := node.FirstChild; child != nil; child = child.NextSibling {
						v := strings.ToLower(child.Data)
						if strings.Contains(v, "url(") || strings.Contains(v, "@import") || strings.Contains(v, "expression(") {
							return errors.New("active stylesheet in public report")
						}
					}
				}
			}
			for child := node.FirstChild; child != nil; child = child.NextSibling {
				if err := walk(child); err != nil {
					return err
				}
			}
			return nil
		}
		if err = walk(root); err != nil {
			return fmt.Errorf("%s: %w", name, err)
		}
	}
	return nil
}

func validateReports(o options, native, container map[string][]byte) error {
	for i, m := range []map[string][]byte{native, container} {
		if e := validatePublicDocuments(m); e != nil {
			return e
		}
		r, e := a.ValidateReport(reportReader(m), o.commit, o.run, false)
		if e != nil {
			return e
		}
		if r.SchemaVersion != 2 || r.RefType != "Release" || r.RefName != o.version || r.Version != o.version || r.RequestedLayer != "All" || !r.Success || r.Totals.UnexecutedSuites != 0 {
			return errors.New("report release identity or execution state mismatch")
		}
		isContainer := strings.HasPrefix(r.Environment, "Windows container / Windows ")
		if !strings.HasPrefix(r.Environment, "Windows ") || (i == 1) != isContainer || (i == 0 && strings.HasPrefix(r.Environment, "Windows container / ")) {
			return errors.New("report environment mismatch")
		}
		for _, check := range r.Checks {
			if check.Layer != "Static" && check.Layer != "Unit" && check.Layer != "Integration" {
				return errors.New("unexpected report scope")
			}
			if check.Name == "" || !check.Executed || check.Passed == nil || !*check.Passed || check.Status != "Passed" {
				return errors.New("report execution state mismatch")
			}
			if check.Layer == "Unit" || check.Layer == "Integration" {
				if len(check.Assertions) == 0 {
					return errors.New("executed test suite has no assertions")
				}
				for _, assertion := range check.Assertions {
					if assertion.Name == "" || assertion.Passed == nil || !*assertion.Passed {
						return errors.New("test assertion mismatch")
					}
				}
			}
		}
		if i == 1 && (r.Coverage != "NotMeasured" || r.RepoCoverage != nil) {
			return errors.New("container coverage must remain unmeasured")
		}
	}
	r := reportReader(native)
	repo, e := a.ValidateRepoCoverageReport(r, native["summary.json"], o.commit, o.run, true)
	if e != nil {
		return e
	}
	if repo.SchemaVersion == c.RuntimeSchemaVersion {
		return c.ValidateRuntimeInventory(o.source, native["coverage_inventory.json"])
	}
	if e := c.ValidateInventory(o.source, native["coverage_inventory.json"]); e != nil {
		return e
	}
	files, e := a.OwnedGoFiles(o.source)
	if e != nil {
		return e
	}
	if e = a.ValidateGoCoverageReport(r, files, o.commit, o.run, true); e != nil {
		return e
	}
	return nil
}
func sourceClean(o options) error {
	head, e := exec.Command("git", "-C", o.source, "rev-parse", "HEAD").Output()
	if e != nil || strings.TrimSpace(string(head)) != o.commit {
		return errors.New("source commit mismatch")
	}
	status, e := exec.Command("git", "-C", o.source, "status", "--porcelain").Output()
	if e != nil || len(strings.TrimSpace(string(status))) != 0 {
		return errors.New("source must be clean")
	}
	return nil
}
func rootDocuments(version string, native, container map[string][]byte) ([]byte, []byte) {
	var scope strings.Builder
	fmt.Fprintf(&scope, "# 版本測試報表\n\n版本：%s\n\n同次 Windows 原生與容器執行；CI 選取指定執行與重試的工件，這不是獨立來源認證。\n", version)
	for i, m := range []map[string][]byte{native, container} {
		var r a.Report
		_ = json.Unmarshal(bytes.TrimPrefix(m["summary.json"], []byte{0xef, 0xbb, 0xbf}), &r)
		label := "Windows 原生"
		link := "native/index.html"
		if i == 1 {
			label = "Windows 容器"
			link = "windows_container/index.html"
		}
		fmt.Fprintf(&scope, "\n## %s\n\n- 版本：%s\n- Commit：%s\n- 執行：%s\n- 量測時間：%s\n- 環境：%s\n- Coverage：%s\n- 測試套件：%d；斷言：%d（通過 %d，失敗 %d）\n- [完整原始報表](%s)\n", label, strconv.Quote(r.Version), strconv.Quote(r.Commit), strconv.Quote(r.RunUrl), strconv.Quote(r.MeasuredAt), strconv.Quote(r.Environment), strconv.Quote(r.Coverage), r.Totals.SuitesExecuted, r.Totals.AssertionsExecuted, r.Totals.AssertionsPassed, r.Totals.AssertionsFailed, link)
		if r.RepoCoverage != nil && r.RepoCoverage.SchemaVersion == c.RuntimeSchemaVersion {
			fmt.Fprintln(&scope, "- 覆蓋範圍：PowerShell/C# runtime 可執行行（不含 CMD 與 Go）")
		}
		for _, check := range r.Checks {
			if check.Layer != "Unit" && check.Layer != "Integration" {
				continue
			}
			fmt.Fprintf(&scope, "\n- %s：%s（%d 個斷言）\n", check.Layer, strconv.Quote(check.Name), len(check.Assertions))
			for _, assertion := range check.Assertions {
				fmt.Fprintf(&scope, "  - %s\n", strconv.Quote(assertion.Name))
			}
		}
	}
	scopeText := scope.String()
	return []byte("<!doctype html><html lang=\"zh-Hant\"><meta charset=\"utf-8\"><title>版本測試報表</title><h1>" + html.EscapeString(version) + " 測試報表</h1><p>包含實際執行的單元與隔離整合測試。</p><a href=\"native/index.html\">Windows 原生報表</a> · <a href=\"windows_container/index.html\">Windows 容器報表</a> · <a href=\"report_scope.md\">測試說明</a></html>\n"), []byte(scopeText)
}

func readUniqueJSONValue(d *json.Decoder, depth int) error {
	if depth > 32 {
		return errors.New("manifest nesting limit")
	}
	token, err := d.Token()
	if err != nil {
		return err
	}
	delimiter, ok := token.(json.Delim)
	if !ok {
		return nil
	}
	switch delimiter {
	case '{':
		keys := []string{}
		for d.More() {
			key, err := d.Token()
			if err != nil {
				return err
			}
			name, ok := key.(string)
			if !ok {
				return errors.New("invalid manifest key")
			}
			for _, prior := range keys {
				if strings.EqualFold(prior, name) {
					return errors.New("duplicate or aliased manifest key")
				}
			}
			keys = append(keys, name)
			if err = readUniqueJSONValue(d, depth+1); err != nil {
				return err
			}
		}
		end, err := d.Token()
		if err != nil || end != json.Delim('}') {
			return errors.New("invalid manifest object")
		}
	case '[':
		for d.More() {
			if err := readUniqueJSONValue(d, depth+1); err != nil {
				return err
			}
		}
		end, err := d.Token()
		if err != nil || end != json.Delim(']') {
			return errors.New("invalid manifest array")
		}
	default:
		return errors.New("invalid manifest delimiter")
	}
	return nil
}
func uniqueJSON(data []byte) error {
	d := json.NewDecoder(strings.NewReader(string(data)))
	d.UseNumber()
	if err := readUniqueJSONValue(d, 0); err != nil {
		return err
	}
	if _, err := d.Token(); err != io.EOF {
		return errors.New("trailing manifest data")
	}
	return nil
}

func export(o options) error {
	return exportWithScope(o, false)
}

func exportWithScope(o options, current bool) error {
	runID, e := validateIdentity(o)
	if e != nil {
		return e
	}
	if o.native == "" || o.container == "" || o.source == "" || o.output == "" {
		return errors.New("missing export input")
	}
	if filepath.Base(filepath.Clean(o.native)) != "windows-test-reports-"+runID+"-"+strconv.Itoa(o.attempt) || filepath.Base(filepath.Clean(o.container)) != "docker-test-reports-"+runID+"-"+strconv.Itoa(o.attempt) {
		return errors.New("artifact selection context mismatch")
	}
	source, e := filepath.Abs(o.source)
	if e != nil {
		return e
	}
	out, e := filepath.Abs(o.output)
	if e != nil {
		return e
	}
	rel, e := filepath.Rel(source, out)
	if e != nil {
		return e
	}
	if rel == "." || (rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))) {
		return errors.New("output must be outside source")
	}
	if filepath.Base(out) != "windows_setup_report_"+o.version+".zip" {
		return errors.New("invalid archive name")
	}
	o.source = source
	if e = sourceClean(o); e != nil {
		return e
	}
	entries, e := os.ReadDir(o.native)
	if e != nil {
		return e
	}
	namesForNative := nativeNames
	if len(entries) == len(nativeRuntimeNames) {
		namesForNative = nativeRuntimeNames
	}
	native, e := loadReport(o.native, namesForNative)
	if e != nil {
		return e
	}
	var header struct{ RepoCoverage struct{ SchemaVersion int } }
	if e = json.Unmarshal(native["summary.json"], &header); e != nil {
		return e
	}
	if (header.RepoCoverage.SchemaVersion == c.RuntimeSchemaVersion) != (len(namesForNative) == len(nativeRuntimeNames)) {
		return errors.New("native report scope and file set differ")
	}
	if current && header.RepoCoverage.SchemaVersion != c.RuntimeSchemaVersion {
		return errors.New("current export requires runtime coverage scope")
	}
	container, e := loadReport(o.container, containerNames)
	if e != nil {
		return e
	}
	if e = validateReports(o, native, container); e != nil {
		return e
	}
	files := map[string][]byte{}
	for n, b := range native {
		files["native/"+n] = b
	}
	for n, b := range container {
		files["windows_container/"+n] = b
	}
	files["index.html"], files["report_scope.md"] = rootDocuments(o.version, native, container)
	names := make([]string, 0, len(files))
	for n := range files {
		names = append(names, n)
	}
	sort.Strings(names)
	m := bundleManifest{SchemaVersion: 1, Version: o.version, Commit: o.commit, RunURL: o.run, RunAttempt: o.attempt, Provenance: provenanceNote}
	if header.RepoCoverage.SchemaVersion == c.RuntimeSchemaVersion {
		m.SchemaVersion = 2
		m.Scope = c.RuntimeScope
	}
	for _, n := range names {
		sum := sha256.Sum256(files[n])
		m.Files = append(m.Files, fileRecord{Path: n, Size: int64(len(files[n])), SHA256: hex.EncodeToString(sum[:])})
	}
	manifest, e := json.MarshalIndent(m, "", "  ")
	if e != nil {
		return e
	}
	files["manifest.json"] = append(manifest, '\n')
	var expanded int64
	for _, data := range files {
		if len(data) > maxFile {
			return errors.New("archive entry size limit")
		}
		expanded += int64(len(data))
	}
	if expanded > int64(maxArchive) {
		return errors.New("archive expanded size limit")
	}
	names = append(names, "manifest.json")
	sort.Strings(names)
	f, e := os.OpenFile(out, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if e != nil {
		return e
	}
	ok := false
	defer func() {
		f.Close()
		if !ok {
			os.Remove(out)
		}
	}()
	z := zip.NewWriter(f)
	for _, n := range names {
		h := &zip.FileHeader{Name: n, Method: zip.Deflate}
		h.SetModTime(time.Date(2000, 1, 1, 0, 0, 0, 0, time.UTC))
		w, e := z.CreateHeader(h)
		if e != nil {
			z.Close()
			return e
		}
		if _, e = w.Write(files[n]); e != nil {
			z.Close()
			return e
		}
	}
	if e = z.Close(); e != nil {
		return e
	}
	info, e := f.Stat()
	if e != nil {
		return e
	}
	if info.Size() > int64(maxArchive) {
		return errors.New("archive size limit")
	}
	if e = f.Close(); e != nil {
		return e
	}
	ok = true
	return nil
}
func verify(args []string) error {
	var o options
	f := flag.NewFlagSet("verify", flag.ContinueOnError)
	f.SetOutput(io.Discard)
	var archive, outputDir, expectedDigest string
	var expectedSize int64
	var historical bool
	f.BoolVar(&historical, "historical", false, "")
	f.StringVar(&expectedDigest, "archive-sha256", "", "")
	f.Int64Var(&expectedSize, "archive-size", 0, "")
	f.StringVar(&archive, "archive", "", "")
	f.StringVar(&outputDir, "output-dir", "", "")
	f.StringVar(&o.source, "source-root", "", "")
	f.StringVar(&o.version, "version", "", "")
	f.StringVar(&o.commit, "commit", "", "")
	f.StringVar(&o.run, "run-url", "", "")
	f.IntVar(&o.attempt, "run-attempt", 0, "")
	if e := f.Parse(args); e != nil {
		return e
	}
	if f.NArg() != 0 || archive == "" || o.source == "" {
		return errors.New("missing verify input")
	}
	provided := map[string]bool{}
	f.Visit(func(v *flag.Flag) { provided[v.Name] = true })
	if historical {
		if provided["run-url"] || provided["run-attempt"] || !regexp.MustCompile(`^[a-f0-9]{64}$`).MatchString(expectedDigest) || expectedSize <= 0 {
			return errors.New("invalid historical arguments")
		}
	} else {
		if provided["archive-sha256"] || provided["archive-size"] {
			return errors.New("historical digest arguments require historical mode")
		}
		if _, e := validateIdentity(o); e != nil {
			return e
		}
	}
	if e := sourceClean(o); e != nil {
		return e
	}
	st, e := os.Lstat(archive)
	if e != nil {
		return e
	}
	if !st.Mode().IsRegular() || st.Size() > int64(maxArchive) {
		return errors.New("invalid archive file")
	}
	input, e := os.Open(archive)
	if e != nil {
		return e
	}
	opened, e := input.Stat()
	if e != nil || !opened.Mode().IsRegular() || !os.SameFile(st, opened) {
		input.Close()
		return errors.New("archive changed or is not regular")
	}
	archiveBytes, e := io.ReadAll(io.LimitReader(input, int64(maxArchive)+1))
	closeErr := input.Close()
	if e != nil {
		return e
	}
	if closeErr != nil {
		return closeErr
	}
	if len(archiveBytes) > maxArchive {
		return errors.New("archive size limit")
	}
	if historical {
		sum := sha256.Sum256(archiveBytes)
		if int64(len(archiveBytes)) != expectedSize || hex.EncodeToString(sum[:]) != expectedDigest {
			return errors.New("immutable archive digest or size mismatch")
		}
	}
	z, e := zip.NewReader(bytes.NewReader(archiveBytes), int64(len(archiveBytes)))
	if e != nil {
		return e
	}
	allowed := map[string]bool{"index.html": true, "report_scope.md": true, "manifest.json": true}
	namesForNative := nativeNames
	if len(z.File) == 3+len(nativeRuntimeNames)+len(containerNames) {
		namesForNative = nativeRuntimeNames
	}
	for _, n := range namesForNative {
		allowed["native/"+n] = true
	}
	for _, n := range containerNames {
		allowed["windows_container/"+n] = true
	}
	if len(z.File) != len(allowed) {
		return errors.New("archive entry count mismatch")
	}
	files := map[string][]byte{}
	seen := map[string]bool{}
	var total uint64
	for _, entry := range z.File {
		key := strings.ToLower(entry.Name)
		if !allowed[entry.Name] || seen[key] || !entry.Mode().IsRegular() || entry.UncompressedSize64 > maxFile {
			return errors.New("invalid archive entry")
		}
		seen[key] = true
		total += entry.UncompressedSize64
		if total > uint64(maxArchive) {
			return errors.New("archive expanded size limit")
		}
		r, e := entry.Open()
		if e != nil {
			return e
		}
		data, e := io.ReadAll(io.LimitReader(r, maxFile+1))
		closeErr := r.Close()
		if e != nil {
			return e
		}
		if closeErr != nil {
			return closeErr
		}
		if len(data) > maxFile || uint64(len(data)) != entry.UncompressedSize64 {
			return errors.New("archive entry size mismatch")
		}
		files[entry.Name] = data
	}
	if e = uniqueJSON(files["manifest.json"]); e != nil {
		return e
	}
	var m bundleManifest
	dec := json.NewDecoder(strings.NewReader(string(files["manifest.json"])))
	dec.DisallowUnknownFields()
	if e = dec.Decode(&m); e != nil {
		return e
	}
	if e = dec.Decode(new(any)); e != io.EOF {
		return errors.New("trailing manifest data")
	}
	if historical {
		o.run, o.attempt = m.RunURL, m.RunAttempt
		if _, e = validateIdentity(o); e != nil {
			return e
		}
	}
	validScope := m.SchemaVersion == 1 && m.Scope == "" && len(namesForNative) == len(nativeNames) || m.SchemaVersion == 2 && m.Scope == c.RuntimeScope && len(namesForNative) == len(nativeRuntimeNames)
	if !validScope || m.Version != o.version || m.Commit != o.commit || m.RunURL != o.run || m.RunAttempt != o.attempt || m.Provenance != provenanceNote || len(m.Files) != len(allowed)-1 {
		return errors.New("manifest identity mismatch")
	}
	manifestSeen := map[string]bool{}
	for _, item := range m.Files {
		data, ok := files[item.Path]
		if !ok || item.Path == "manifest.json" || manifestSeen[item.Path] {
			return errors.New("invalid manifest file entry")
		}
		manifestSeen[item.Path] = true
		sum := sha256.Sum256(data)
		if item.Size != int64(len(data)) || item.SHA256 != hex.EncodeToString(sum[:]) {
			return errors.New("manifest digest or size mismatch")
		}
	}
	native, container := map[string][]byte{}, map[string][]byte{}
	for _, n := range namesForNative {
		native[n] = files["native/"+n]
	}
	for _, n := range containerNames {
		container[n] = files["windows_container/"+n]
	}
	var reportHeader struct{ RepoCoverage struct{ SchemaVersion int } }
	if e = json.Unmarshal(native["summary.json"], &reportHeader); e != nil {
		return e
	}
	if (m.SchemaVersion == 2) != (reportHeader.RepoCoverage.SchemaVersion == c.RuntimeSchemaVersion) {
		return errors.New("manifest and report scope differ")
	}
	if e = validateReports(o, native, container); e != nil {
		return e
	}
	index, scope := rootDocuments(o.version, native, container)
	if string(files["index.html"]) != string(index) || string(files["report_scope.md"]) != string(scope) {
		return errors.New("archive index or scope mismatch")
	}
	if outputDir != "" {
		origin := "explicit"
		if historical {
			origin = "immutable_archive_manifest"
		}
		return writeVerifiedOutput(outputDir, archiveBytes, files, o, origin, m.Scope)
	}
	return nil
}

func sameOutputParent(parent, resolved, platform string) bool {
	parent, resolved = filepath.Clean(parent), filepath.Clean(resolved)
	if platform == "windows" {
		return strings.EqualFold(parent, resolved)
	}
	return parent == resolved
}

// writeVerifiedOutput only publishes bytes after every archive and report check passes.
func writeVerifiedOutput(output string, archive []byte, files map[string][]byte, o options, origin, scope string) error {
	if _, err := os.Lstat(output); err == nil || !os.IsNotExist(err) {
		return errors.New("output must not exist")
	}
	parent, err := canonicalSafeParent(filepath.Dir(output))
	if err != nil {
		return err
	}
	output = filepath.Join(parent, filepath.Base(output))
	entries, err := os.ReadDir(parent)
	if err != nil {
		return err
	}
	if len(entries) != 0 {
		return errors.New("output parent must be a dedicated empty private directory")
	}
	// The caller owns this private parent and must prevent concurrent writers.
	staging, err := os.MkdirTemp(parent, ".report-verified-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(staging)
	for name, data := range files {
		path := filepath.Join(staging, filepath.FromSlash(name))
		if err = os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			return err
		}
		if err = os.WriteFile(path, data, 0600); err != nil {
			return err
		}
	}
	digest := sha256.Sum256(archive)
	summary := sha256.Sum256(files["native/summary.json"])
	profileHash := ""
	if profileBytes, ok := files["native/go_coverage.out"]; ok {
		profile := sha256.Sum256(profileBytes)
		profileHash = hex.EncodeToString(profile[:])
	}
	metadata := struct {
		ContextOrigin string `json:"context_origin"`
		ArchiveSHA256 string `json:"archive_sha256"`
		ArchiveSize   int64  `json:"archive_size"`
		Version       string `json:"version"`
		Commit        string `json:"commit"`
		RunURL        string `json:"run_url"`
		RunAttempt    int    `json:"run_attempt"`
		SummarySHA256 string `json:"summary_sha256"`
		ProfileSHA256 string `json:"profile_sha256,omitempty"`
		CoverageScope string `json:"coverage_scope,omitempty"`
	}{origin, hex.EncodeToString(digest[:]), int64(len(archive)), o.version, o.commit, o.run, o.attempt, hex.EncodeToString(summary[:]), profileHash, scope}
	data, err := json.Marshal(metadata)
	if err != nil {
		return err
	}
	if err = os.WriteFile(filepath.Join(staging, "verified.json"), data, 0600); err != nil {
		return err
	}
	return os.Rename(staging, output)
}
func run() error {
	if len(os.Args) < 2 {
		return errors.New("expected export or verify command")
	}
	if os.Args[1] == "verify" {
		return verify(os.Args[2:])
	}
	if os.Args[1] != "export" {
		return errors.New("expected export or verify command")
	}
	o, e := parseOptions(os.Args[2:])
	if e != nil {
		return e
	}
	return exportWithScope(o, true)
}
func main() {
	if e := run(); e != nil {
		fmt.Fprintln(os.Stderr, "report bundle:", e)
		os.Exit(1)
	}
}
