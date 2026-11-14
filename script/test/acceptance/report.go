package acceptance

import (
	"bytes"
	"encoding/json"
	"encoding/xml"
	"fmt"
	"io"
	"regexp"
	"strings"
	c "windows_setup/script/test/repo_coverage"
)

func ValidateXMLNamespace(data []byte, namespace string) error {
	d := xml.NewDecoder(bytes.NewReader(data))
	depth, roots := 0, 0
	for {
		token, e := d.Token()
		if e == io.EOF {
			if roots != 1 || depth != 0 {
				return fmt.Errorf("R04/R05 XML 必須恰有一個根節點")
			}
			return nil
		}
		if e != nil {
			return e
		}
		if start, ok := token.(xml.StartElement); ok && start.Name.Space != namespace {
			return fmt.Errorf("R04/R05 XML 節點命名空間不符：%s", start.Name.Local)
		}
		switch value := token.(type) {
		case xml.StartElement:
			if depth == 0 {
				roots++
				if roots > 1 {
					return fmt.Errorf("R04/R05 XML 包含多個根節點")
				}
			}
			depth++
		case xml.EndElement:
			depth--
		case xml.CharData:
			if depth == 0 && strings.TrimSpace(string(value)) != "" {
				return fmt.Errorf("R04/R05 XML 根節點外包含資料")
			}
		}
	}
}

type Reader func(string) ([]byte, error)
type Assertion struct {
	Name   string
	Passed *bool
}
type Check struct {
	Name, Layer, Status string
	Executed            bool
	Passed              *bool
	Assertions          []Assertion
}
type Totals struct{ SuitesExecuted, AssertionsExecuted, AssertionsPassed, AssertionsFailed, UnexecutedSuites int }
type Report struct {
	RepoCoverage                                                                                              *c.Evidence
	SchemaVersion                                                                                             int
	RequestedLayer, Commit, RunUrl, SourceState, Coverage, RefType, RefName, Environment, Version, MeasuredAt string
	Success                                                                                                   bool
	Checks                                                                                                    []Check
	Totals                                                                                                    Totals
}

func decode(data []byte, v any) error {
	return json.Unmarshal([]byte(strings.TrimPrefix(string(data), "\ufeff")), v)
}
func BadgeStatus(r Report, name string) string {
	if name == "coverage" {
		if r.RepoCoverage != nil && r.RepoCoverage.Result.Complete {
			return fmt.Sprintf("%.1f%%", *r.RepoCoverage.Result.Percent)
		}
		return "not measured"
	}
	if name == "system" {
		return "not run"
	}
	status := "not run"
	for _, c := range r.Checks {
		if strings.EqualFold(c.Layer, name) && c.Executed {
			if status == "not run" {
				status = "passed"
			}
			if c.Passed == nil || !*c.Passed {
				status = "failed"
			}
		}
	}
	return status
}
func ValidateSVG(data []byte, r Report, name string) error {
	if e := ValidateXMLNamespace(data, "http://www.w3.org/2000/svg"); e != nil {
		return e
	}
	var normalizeError error
	data, normalizeError = normalizeFlatBadge(data)
	if normalizeError != nil {
		return normalizeError
	}
	var s struct {
		XMLName xml.Name
		Height  string `xml:"height,attr"`
		Width   string `xml:"width,attr"`
		Aria    string `xml:"aria-label,attr"`
		Title   string `xml:"title"`
		Rects   []struct {
			Width string `xml:"width,attr"`
			Fill  string `xml:"fill,attr"`
		} `xml:"rect"`
		Group struct {
			Font  string   `xml:"font-size,attr"`
			Texts []string `xml:"text"`
		} `xml:"g"`
	}
	if e := xml.Unmarshal(data, &s); e != nil {
		return e
	}
	label := name + " " + strings.ToLower(r.RefType)
	status := BadgeStatus(r, name)
	runtimeBadge := name == "coverage" && r.RepoCoverage != nil && r.RepoCoverage.SchemaVersion == c.RuntimeSchemaVersion
	if runtimeBadge && (len(s.Group.Texts) != 2 || s.Group.Texts[0] != "runtime PowerShell/C#") {
		return fmt.Errorf("runtime badge lacks language scope")
	}
	if name == "coverage" && len(s.Group.Texts) == 2 && (s.Group.Texts[0] == "ps coverage" || (r.SchemaVersion == 2 && s.Group.Texts[0] == "coverage") || (runtimeBadge && s.Group.Texts[0] == "runtime PowerShell/C#")) {
		label = s.Group.Texts[0]
		scope := label + " " + strings.ToLower(r.RefType) + ": " + status
		if s.Aria != scope || s.Title != scope {
			return fmt.Errorf("PowerShell badge lacks matching source scope")
		}
	}
	color := "#9f9f9f"
	if name == "coverage" && r.RepoCoverage != nil && r.RepoCoverage.Result.Complete {
		color = "#007ec6"
	}
	if status == "passed" {
		color = "#4c1"
	} else if status == "failed" {
		color = "#e05d44"
	}
	if s.XMLName.Space != "http://www.w3.org/2000/svg" || s.XMLName.Local != "svg" || s.Height != "20" || s.Width != fmt.Sprint((len(label)+len(status))*7+24) || s.Group.Font != "11" || len(s.Group.Texts) != 2 || s.Group.Texts[0] != label || s.Group.Texts[1] != status || len(s.Rects) != 2 || s.Rects[0].Fill != "#555" || s.Rects[1].Fill != color || s.Rects[0].Width != fmt.Sprint(len(label)*7+12) || s.Rects[1].Width != fmt.Sprint(len(status)*7+12) {
		return fmt.Errorf("R05 徽章幾何、配色或狀態不符：%s", name)
	}
	return nil
}
func ValidateReport(read Reader, sha, run string, main bool) (Report, error) {
	var r Report
	get := func(n string) ([]byte, error) {
		b, e := read(n)
		if e != nil {
			return nil, fmt.Errorf("R04 %s: %w", n, e)
		}
		return b, nil
	}
	data, e := get("summary.json")
	if e != nil {
		return r, e
	}
	summaryData := data
	if e = validateSchema(data); e != nil {
		return r, e
	}
	if e = decode(data, &r); e != nil {
		return r, e
	}
	fail := func(s string) (Report, error) { return r, fmt.Errorf("%s", s) }
	if (r.SchemaVersion != 1 && r.SchemaVersion != 2) || r.RequestedLayer != "All" {
		return fail("R02 缺少完整測試範圍")
	}
	if r.Commit != sha || r.RunUrl != run || r.SourceState != "Clean" {
		return fail("R03 提交、執行來源或乾淨版本不符")
	}
	if main && (r.RefType != "Branch" || r.RefName != "main") {
		return fail("R03 部署報表不是 main 分支")
	}
	if (r.Coverage != "NotMeasured" && r.Coverage != "Measured") || len(r.Checks) == 0 {
		return fail("R02 空測試或冒稱覆蓋率")
	}
	layers := map[string]bool{}
	totals := Totals{}
	success := true
	for _, c := range r.Checks {
		if c.Executed {
			layers[c.Layer] = true
			totals.SuitesExecuted++
			success = success && c.Passed != nil && *c.Passed
			for _, a := range c.Assertions {
				totals.AssertionsExecuted++
				if a.Passed != nil {
					if *a.Passed {
						totals.AssertionsPassed++
					} else {
						totals.AssertionsFailed++
					}
				}
			}
		} else {
			totals.UnexecutedSuites++
		}
		if c.Layer == "System" || c.Layer == "System E2E" {
			if c.Status != "NotRun" || c.Executed || c.Passed != nil || len(c.Assertions) != 0 {
				return fail("R02 未執行實機測試被誤標通過")
			}
			layers[c.Layer] = true
		}
	}
	requiredLayers := []string{"Unit", "Integration"}
	if r.SchemaVersion == 1 {
		requiredLayers = append(requiredLayers, "System", "System E2E")
	}
	for _, l := range requiredLayers {
		if !layers[l] {
			return fail("R02 缺少必要測試層：" + l)
		}
	}
	if r.Success != success || r.Totals != totals {
		return fail("R02 統計或整體結果與逐項證據不一致")
	}
	var junit struct {
		XMLName xml.Name
		Suites  []struct {
			Name  string `xml:"name,attr"`
			Cases []struct {
				Skipped *struct{} `xml:"skipped"`
				Failure *struct{} `xml:"failure"`
			} `xml:"testcase"`
		} `xml:"testsuite"`
	}
	data, e = get("junit.xml")
	if e != nil {
		return r, e
	}
	if e = ValidateXMLNamespace(data, ""); e != nil {
		return r, e
	}
	if e = xml.Unmarshal(data, &junit); e != nil {
		return r, e
	}
	if junit.XMLName.Local != "testsuites" || len(junit.Suites) != len(r.Checks) {
		return fail("R04 JUnit 套件數不符")
	}
	for i, s := range junit.Suites {
		c := r.Checks[i]
		if s.Name != c.Name || len(s.Cases) == 0 {
			return fail("R04 JUnit 套件與 JSON 不一致")
		}
		failed := false
		for _, tc := range s.Cases {
			failed = failed || tc.Failure != nil
			if !c.Executed && (tc.Skipped == nil || tc.Failure != nil) {
				return fail("R02 JUnit 未執行狀態不一致")
			}
		}
		if c.Executed && (c.Passed == nil || (!failed) != *c.Passed) {
			return fail("R02 JUnit 成敗不一致")
		}
	}
	data, e = get("index.html")
	if e != nil {
		return r, e
	}
	page, e := ParsePage(data)
	if e != nil {
		return r, e
	}
	for _, link := range []string{"summary.json", "summary.md", "junit.xml"} {
		if !contains(page.Links, link) {
			return fail("R04 明細缺少證據連結")
		}
	}
	title := "單元與隔離整合測試通過"
	if !r.Success {
		title = "本次測試未通過"
	}
	if !strings.Contains(page.Visible, title) || strings.Contains(page.Visible, "Unknown") {
		return fail("R02/R06 前台結論不符或包含未翻譯狀態")
	}
	data, e = get("summary.md")
	if e != nil {
		return r, e
	}
	if !strings.Contains(string(data), sha) || r.MeasuredAt == "" || !strings.Contains(string(data), r.MeasuredAt) {
		return fail("R03 摘要來源或時間不一致")
	}
	repoEvidence, err := ValidateRepoCoverageReport(read, summaryData, sha, run, false)
	if err != nil {
		return r, err
	}
	expectedCoverage := "NotMeasured"
	if repoEvidence != nil && repoEvidence.Result.Complete {
		expectedCoverage = "Measured"
	}
	if r.Coverage != expectedCoverage || (repoEvidence != nil && r.SchemaVersion != 2) {
		return fail("整體覆蓋率狀態或報告版本不符")
	}
	r.RepoCoverage = repoEvidence
	requiredBadges := []string{"unit", "integration", "coverage"}
	if r.SchemaVersion == 1 {
		requiredBadges = append(requiredBadges, "system")
	}
	for _, n := range requiredBadges {
		data, e = get(n + ".svg")
		if e != nil {
			return r, e
		}
		if e = ValidateSVG(data, r, n); e != nil {
			return r, e
		}
	}
	private := regexp.MustCompile(`(?i)(^|[^A-Za-z])([A-Za-z]:\\(Users|actions|a|Windows)\\|/home/runner/|/Users/[^/]+/)`)
	for _, n := range []string{"summary.json", "summary.md", "index.html", "junit.xml"} {
		data, e = get(n)
		if e != nil {
			return r, e
		}
		if private.Match(data) {
			return fail("R07 公開產物包含本機或 runner 絕對路徑")
		}
	}
	if e := ValidateGoCoverageReport(read, nil, sha, run, false); e != nil {
		return r, e
	}
	return r, nil
}
func contains(items []string, v string) bool {
	for _, s := range items {
		if s == v {
			return true
		}
	}
	return false
}
