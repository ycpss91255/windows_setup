package integration_test

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
	a "windows_setup/script/test/acceptance"
	c "windows_setup/script/test/repo_coverage"
)

const base = "https://example.github.io/windows_setup/"

var names = []string{"unit", "integration", "system", "coverage"}

func readme() string {
	s := ""
	for _, n := range []string{"coverage"} {
		s += fmt.Sprintf("![%s](%smain/%s.svg?style=fixture)\n", n, base, n)
	}
	return s
}
func files(t *testing.T, dir string) map[string][]byte {
	t.Helper()
	if dir == "" {
		t.Fatal("actual artifact/portal fixture environment is required")
	}
	m := map[string][]byte{}
	e := filepath.WalkDir(dir, func(p string, d os.DirEntry, e error) error {
		if e != nil {
			return e
		}
		if !d.IsDir() {
			r, _ := filepath.Rel(dir, p)
			b, e := os.ReadFile(p)
			if e != nil {
				return e
			}
			m[filepath.ToSlash(r)] = b
		}
		return nil
	})
	if e != nil {
		t.Fatal(e)
	}
	return m
}
func reader(m map[string][]byte) a.Reader {
	return func(p string) ([]byte, error) {
		b, ok := m[strings.Split(p, "?")[0]]
		if !ok {
			return nil, fmt.Errorf("missing fixture %s", p)
		}
		return b, nil
	}
}
func decode(t *testing.T, m map[string][]byte) a.Report {
	t.Helper()
	var r a.Report
	if e := json.Unmarshal([]byte(strings.TrimPrefix(string(m["summary.json"]), "\ufeff")), &r); e != nil {
		t.Fatal(e)
	}
	return r
}
func save(m map[string][]byte, r a.Report) { m["summary.json"], _ = json.Marshal(r) }
func copyFiles(m map[string][]byte) map[string][]byte {
	n := map[string][]byte{}
	for k, v := range m {
		n[k] = append([]byte(nil), v...)
	}
	return n
}
func flag(b bool) *bool { return &b }
func badge(r a.Report, n string) []byte {
	value := a.BadgeStatus(r, n)
	label := n + " " + strings.ToLower(r.RefType)
	attrs := ""
	if n == "coverage" && r.RepoCoverage != nil && r.RepoCoverage.SchemaVersion == c.RuntimeSchemaVersion {
		label = "runtime PowerShell/C#"
		scope := label + " " + strings.ToLower(r.RefType) + ": " + value
		attrs = fmt.Sprintf(` aria-label="%s"><title>%s</title`, scope, scope)
	}
	l, q := len(label)*7+12, len(value)*7+12
	color := "#9f9f9f"
	if n == "coverage" && r.RepoCoverage != nil && r.RepoCoverage.Result.Complete {
		color = "#007ec6"
	} else if value == "passed" {
		color = "#4c1"
	} else if value == "failed" {
		color = "#e05d44"
	}
	return []byte(fmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" height="20" width="%d"%s><rect width="%d" fill="#555"/><rect width="%d" fill="%s"/><g font-size="11"><text>%s</text><text>%s</text></g></svg>`, l+q, attrs, l, q, color, label, value))
}
func synthetic(t *testing.T, original map[string][]byte, passed bool, ref string) map[string][]byte {
	t.Helper()
	m := copyFiles(original)
	r := decode(t, m)
	r.RefType = ref
	r.RefName = "main"
	if ref == "Release" {
		r.RefName = r.Version
	}
	r.Environment = "Synthetic acceptance fixture"
	r.Success = passed
	r.Totals = a.Totals{}
	failed := false
	x := "<testsuites>"
	for i := range r.Checks {
		c := &r.Checks[i]
		if c.Executed {
			r.Totals.SuitesExecuted++
			c.Passed = flag(true)
			c.Status = "Passed"
			for j := range c.Assertions {
				c.Assertions[j].Passed = flag(true)
			}
			if !passed && !failed && c.Layer == "Unit" && len(c.Assertions) > 0 {
				failed = true
				c.Passed = flag(false)
				c.Status = "Failed"
				c.Assertions[0].Passed = flag(false)
			}
		} else {
			r.Totals.UnexecutedSuites++
		}
		x += fmt.Sprintf(`<testsuite name="%s">`, c.Name)
		items := c.Assertions
		if len(items) == 0 {
			items = []a.Assertion{{Name: c.Name, Passed: c.Passed}}
		}
		for _, it := range items {
			x += `<testcase>`
			if !c.Executed {
				x += `<skipped/>`
			} else if it.Passed != nil && !*it.Passed {
				x += `<failure/>`
			}
			x += `</testcase>`
		}
		x += `</testsuite>`
		if c.Executed {
			for _, it := range c.Assertions {
				r.Totals.AssertionsExecuted++
				if it.Passed != nil && *it.Passed {
					r.Totals.AssertionsPassed++
				} else {
					r.Totals.AssertionsFailed++
				}
			}
		}
	}
	x += "</testsuites>"
	save(m, r)
	m["junit.xml"] = []byte(x)
	title := "單元與隔離整合測試通過"
	if !passed {
		title = "本次測試未通過"
	}
	m["index.html"] = []byte(`<h2>` + title + `</h2><a href="summary.json">JSON</a><a href="summary.md">MD</a><a href="junit.xml">JUnit</a>`)
	for _, n := range names {
		m[n+".svg"] = badge(r, n)
	}
	return m
}
func portal(t *testing.T, m map[string][]byte) map[string][]byte {
	t.Helper()
	p := map[string][]byte{}
	for k, v := range m {
		p["main/"+k] = v
	}
	r := decode(t, m)
	title := "目前程式檢查通過"
	if !r.Success {
		title = "目前程式檢查未通過"
	}
	stamp, e := time.Parse(time.RFC3339Nano, r.MeasuredAt)
	if e != nil {
		t.Fatal(e)
	}
	identity := "提交 <code>" + r.Commit[:7] + "</code> 檢查時間：" + stamp.UTC().Format("2006-01-02 15:04:05") + " UTC"
	coverageLabel := "整體覆蓋率"
	if r.RepoCoverage != nil && r.RepoCoverage.SchemaVersion == c.RuntimeSchemaVersion {
		coverageLabel = "PowerShell/C# runtime 覆蓋率"
	}
	overview := "<h2>" + coverageLabel + "</h2><p>尚未提供完整量測。</p>"
	if r.RepoCoverage != nil && r.RepoCoverage.Result.Complete {
		c := r.RepoCoverage.Result
		overview = fmt.Sprintf("<h2>%s</h2><p>%.1f%%（%d/%d 可執行行）</p>", coverageLabel, *c.Percent, c.Covered, c.Executable)
	}
	p["index.html"] = []byte(overview + `<h1>` + title + `</h1><a href="main/index.html">結果</a><a href="https://github.com/example/windows_setup/blob/main/readme.md">說明</a>` + identity)
	p["versions.json"] = []byte(`[]`)
	return p
}

func TestRequirementsParity(t *testing.T) {
	original := files(t, os.Getenv("WINDOWS_SETUP_ARTIFACT_DIR"))
	r := decode(t, original)
	valid := func(t *testing.T, m map[string][]byte) {
		t.Helper()
		if _, e := a.ValidateReport(reader(m), r.Commit, r.RunUrl, false); e != nil {
			t.Fatal(e)
		}
	}
	reject := func(t *testing.T, m map[string][]byte) {
		t.Helper()
		if _, e := a.ValidateReport(reader(m), r.Commit, r.RunUrl, false); e == nil {
			t.Fatal("invalid evidence accepted")
		}
	}
	t.Run("real_ps51_artifact", func(t *testing.T) { valid(t, original) })
	t.Run("wrong_sha_rejected", func(t *testing.T) {
		if _, e := a.ValidateReport(reader(original), strings.Repeat("0", 40), r.RunUrl, false); e == nil {
			t.Fatal("stale SHA accepted")
		}
	})
	t.Run("wrong_run_rejected", func(t *testing.T) {
		if _, e := a.ValidateReport(reader(original), r.Commit, r.RunUrl+"0", false); e == nil {
			t.Fatal("wrong run accepted")
		}
	})
	t.Run("inconsistent_total_rejected", func(t *testing.T) {
		m := copyFiles(original)
		q := decode(t, m)
		q.Totals.AssertionsPassed++
		save(m, q)
		reject(t, m)
	})
	t.Run("system_false_pass_rejected", func(t *testing.T) {
		m := copyFiles(original)
		q := decode(t, m)
		for i := range q.Checks {
			if !q.Checks[i].Executed {
				q.Checks[i].Passed = flag(true)
			}
		}
		if q.SchemaVersion == 2 {
			q.Checks = append(q.Checks, a.Check{Name: "removed", Layer: "System", Status: "Passed", Passed: flag(true)})
		}
		save(m, q)
		reject(t, m)
	})
	t.Run("old_badge_geometry_rejected", func(t *testing.T) {
		m := copyFiles(original)
		m["unit.svg"] = []byte(strings.ReplaceAll(string(m["unit.svg"]), `height="20"`, `height="24"`))
		reject(t, m)
	})
	t.Run("badge_false_failure_rejected", func(t *testing.T) {
		m := copyFiles(original)
		s := string(m["unit.svg"])
		if strings.Contains(s, ">passed<") {
			s = strings.ReplaceAll(s, ">passed<", ">failed<")
		} else {
			s = strings.ReplaceAll(s, ">failed<", ">passed<")
		}
		m["unit.svg"] = []byte(s)
		reject(t, m)
	})
	t.Run("missing_evidence_link_rejected", func(t *testing.T) {
		m := copyFiles(original)
		m["index.html"] = []byte(strings.ReplaceAll(string(m["index.html"]), `href="junit.xml"`, `href="missing.xml"`))
		reject(t, m)
	})
	t.Run("raw_unknown_rejected", func(t *testing.T) {
		m := copyFiles(original)
		m["index.html"] = append(m["index.html"], []byte(`<p>Unknown</p>`)...)
		reject(t, m)
	})
	t.Run("technical_unknown_inside_closed_details_allowed", func(t *testing.T) {
		m := copyFiles(original)
		m["index.html"] = append(m["index.html"], []byte(`<details><summary>Technical</summary>Unknown</details>`)...)
		valid(t, m)
	})
	t.Run("unknown_inside_open_details_rejected", func(t *testing.T) {
		m := copyFiles(original)
		m["index.html"] = append(m["index.html"], []byte(`<details open><summary>Technical</summary>Unknown</details>`)...)
		reject(t, m)
	})
	t.Run("private_path_rejected", func(t *testing.T) {
		m := copyFiles(original)
		m["summary.md"] = append(m["summary.md"], []byte(` C:\Users\fixture_person\secret`)...)
		reject(t, m)
	})
	main := synthetic(t, original, r.Success, "Branch")
	p := portal(t, main)
	checkPortal := func(m map[string][]byte, doc string) (a.Report, error) {
		return a.ValidatePortal(reader(m), doc, r.Commit, r.RunUrl, base)
	}
	t.Run("synthetic_main_portal_contract", func(t *testing.T) {
		q, e := checkPortal(p, readme())
		if e != nil || q.Environment != "Synthetic acceptance fixture" {
			t.Fatalf("%+v %v", q, e)
		}
	})
	t.Run("broken_primary_link_rejected", func(t *testing.T) {
		m := copyFiles(p)
		m["index.html"] = []byte(strings.ReplaceAll(string(m["index.html"]), "main/index.html", "missing.html"))
		if _, e := checkPortal(m, readme()); e == nil {
			t.Fatal("broken link accepted")
		}
	})
	t.Run("missing_readme_badge_rejected", func(t *testing.T) {
		if _, e := checkPortal(p, ""); e == nil {
			t.Fatal("missing badges accepted")
		}
	})
	t.Run("missing_history_real_wording_contract", func(t *testing.T) {
		m := copyFiles(p)
		m["versions.json"] = []byte(`[{"Version":"v0.1.0","Status":"Unknown","Path":"versions/v0.1.0/index.html"}]`)
		m["versions/v0.1.0/index.html"] = []byte(`<h1>這個版本未保存可用的測試紀錄</h1>`)
		m["comparisons/v0.1.0--v0.1.0.json"] = []byte(`{"Status":"Unknown"}`)
		if _, e := checkPortal(m, readme()); e != nil {
			t.Fatal(e)
		}
	})
	t.Run("actual_generated_portal_with_missing_history", func(t *testing.T) {
		m := files(t, os.Getenv("WINDOWS_SETUP_PORTAL_FIXTURE_DIR"))
		q := decode(t, map[string][]byte{"summary.json": m["main/summary.json"]})
		if !strings.Contains(q.Environment, "Synthetic acceptance fixture") {
			t.Fatal("not synthetic fixture")
		}
		if _, e := a.ValidatePortal(reader(m), readme(), q.Commit, q.RunUrl, base); e != nil {
			t.Fatal(e)
		}
	})
	t.Run("truthful_failed_branch_report_is_valid_evidence", func(t *testing.T) { m := synthetic(t, original, false, "Branch"); valid(t, m) })
	t.Run("passing_branch_and_release_shapes", func(t *testing.T) {
		for _, ref := range []string{"Branch", "Release"} {
			valid(t, synthetic(t, original, true, ref))
		}
	})
	t.Run("pr_not_relabelled_as_main", func(t *testing.T) {
		m := copyFiles(p)
		q := decode(t, main)
		q.RefName = "5/merge"
		m["main/summary.json"], _ = json.Marshal(q)
		if _, e := checkPortal(m, readme()); e == nil {
			t.Fatal("PR accepted as main")
		}
	})
	t.Run("finite_retry_does_not_accept_stale_sha", func(t *testing.T) {
		calls, sleeps := 0, 0
		read := func(path string) ([]byte, error) { calls++; return reader(p)(path) }
		_, e := a.VerifyWithRetry(read, readme(), strings.Repeat("0", 40), r.RunUrl, base, 3, func() { sleeps++ })
		if e == nil || calls != 3 || sleeps != 2 {
			t.Fatalf("retry contract: calls=%d sleeps=%d err=%v", calls, sleeps, e)
		}
	})
}

func TestActualReadmeCoverageBadgeLinks(t *testing.T) {
	raw, e := os.ReadFile(filepath.Join("..", "..", "..", "readme.md"))
	if e != nil {
		t.Fatal(e)
	}
	doc := strings.ReplaceAll(string(raw), "https://ycpss91255.github.io/windows_setup/", base)
	original := files(t, os.Getenv("WINDOWS_SETUP_ARTIFACT_DIR"))
	p := portal(t, synthetic(t, original, true, "Branch"))
	r := decode(t, original)
	checkPortal := func(p map[string][]byte, doc string) (a.Report, error) {
		return a.ValidatePortal(reader(p), doc, r.Commit, r.RunUrl, base)
	}
	if _, e := checkPortal(p, doc); e != nil {
		t.Fatalf("actual README coverage links rejected: %v", e)
	}
	if _, e := checkPortal(p, strings.ReplaceAll(doc, "main/coverage.svg", "main/missing.svg")); e == nil {
		t.Fatal("missing actual PS coverage URL accepted")
	}
	if _, e := checkPortal(p, doc+"\n![duplicate]("+base+"main/coverage.svg)"); e == nil {
		t.Fatal("duplicate actual coverage URL accepted")
	}
}
