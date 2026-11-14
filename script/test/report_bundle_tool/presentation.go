package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"html"
	"sort"
	"strings"
	a "windows_setup/script/test/acceptance"
	c "windows_setup/script/test/repo_coverage"
)

func overviewRootDocuments(version string, native, container map[string][]byte) ([]byte, []byte) {
	_, scope := legacyRootDocuments(version, native, container)
	reports := make([]a.Report, 2)
	for i, m := range []map[string][]byte{native, container} {
		_ = json.Unmarshal(bytes.TrimPrefix(m["summary.json"], []byte{0xef, 0xbb, 0xbf}), &reports[i])
	}
	n := reports[0]
	passed := n.Success && reports[1].Success && n.Totals.UnexecutedSuites == 0 && reports[1].Totals.UnexecutedSuites == 0
	status, tag := "程式檢查未通過", "tag failed"
	if passed {
		status, tag = "程式檢查通過", "tag"
	}
	coverage := "尚未完整量測"
	if n.RepoCoverage != nil && n.RepoCoverage.Result.Complete {
		q := n.RepoCoverage.Result
		label := "整體覆蓋率"
		if n.RepoCoverage.SchemaVersion == c.RuntimeSchemaVersion && n.RepoCoverage.Scope == c.RuntimeScope {
			label = "PowerShell/C# runtime 覆蓋率"
		}
		coverage = fmt.Sprintf("%s：%.1f%%（%d/%d 可執行行）", label, 100*float64(q.Covered)/float64(q.Executable), q.Covered, q.Executable)
	}
	var body strings.Builder
	fmt.Fprintf(&body, `<section class="hero"><span class="%s">%s</span><h2>這份版本的自動檢查結果</h2><p>來源：版本 %s · 提交 <code>%s</code><br>量測時間（UTC）：%s</p><div class="nav"><a class="btn" href="https://github.com/ycpss91255/windows_setup/blob/%s/readme.md">查看本次來源的使用說明</a><a class="secondary" href="%s">查看執行紀錄</a></div></section>`, tag, status, html.EscapeString(version), html.EscapeString(n.Commit), html.EscapeString(n.MeasuredAt), html.EscapeString(n.Commit), html.EscapeString(n.RunUrl))
	fmt.Fprintf(&body, `<div class="grid"><article class="card"><h3>測試狀態</h3><div class="big">%s</div><p class="muted">靜態、單元及隔離整合測試</p></article><article class="card"><h3>原生檢查項目（斷言）</h3><div class="big">%d / %d</div><p class="muted">%d 組測試 · 失敗 %d</p></article><article class="card"><h3>原生整體覆蓋率</h3><div class="big">%s</div><p class="muted">容器未量測，不合併分母。</p></article></div><section class="section"><h2>分環境查看</h2><div class="envs">`, status, n.Totals.AssertionsPassed, n.Totals.AssertionsExecuted, n.Totals.SuitesExecuted, n.Totals.AssertionsFailed, html.EscapeString(coverage))
	var details strings.Builder
	type detailRow struct {
		label string
		check a.Check
	}
	var rows []detailRow
	for i, r := range reports {
		label, path, measure := "Windows 原生", "native", coverage
		if i == 1 {
			label, path, measure = "Windows 容器", "windows_container", "容器未量測"
		}
		state, class := "測試未通過", "tag failed"
		if r.Success && r.Totals.UnexecutedSuites == 0 {
			state, class = "測試通過", "tag"
		}
		coverageLinks := ""
		if i == 0 && native["repo_coverage.json"] != nil && native["coverage_inventory.json"] != nil && native["coverage.xml"] != nil {
			coverageLinks = `<p><a href="native/repo_coverage.json">整體量測證據</a> · <a href="native/coverage_inventory.json">來源清單</a> · <a href="native/coverage.xml">逐行結果</a></p>`
		}
		if i == 0 && native["go_coverage.out"] != nil {
			coverageLinks += `<p><a href="native/go_coverage.out">原始 Go 覆蓋率</a></p>`
		}
		fmt.Fprintf(&body, `<article class="env"><span class="%s">%s</span><h3>%s</h3><div class="row"><span>測試組數</span><strong>%d 組測試</strong></div><div class="row"><span>檢查項目（斷言）</span><strong>%d / %d · 失敗 %d</strong></div><div class="row"><span>覆蓋率</span><strong>%s</strong></div><p class="muted">%s</p><p><a href="%s/index.html">查看完整報表與證據</a></p><p><a href="%s/summary.json">JSON</a> · <a href="%s/junit.xml">JUnit</a> · <a href="%s/summary.md">文字摘要</a></p>%s</article>`, class, state, label, r.Totals.SuitesExecuted, r.Totals.AssertionsPassed, r.Totals.AssertionsExecuted, r.Totals.AssertionsFailed, html.EscapeString(measure), html.EscapeString(r.Environment), path, path, path, path, coverageLinks)
		for _, check := range r.Checks {
			rows = append(rows, detailRow{label, check})
		}
	}
	rank := func(c a.Check) int {
		if c.Status == "Failed" {
			return 0
		}
		if c.Status == "NotRun" {
			return 1
		}
		return 2
	}
	sort.SliceStable(rows, func(i, j int) bool { return rank(rows[i].check) < rank(rows[j].check) })
	for _, row := range rows {
		check := row.check
		state := "通過"
		if check.Status == "Failed" {
			state = "失敗"
		} else if check.Status == "NotRun" {
			state = "未執行"
		}
		fmt.Fprintf(&details, "<details><summary>%s · %s · %s · %s</summary><ul>", row.label, html.EscapeString(check.Layer), html.EscapeString(check.Name), state)
		for _, item := range check.Assertions {
			state := "未執行"
			if check.Executed && item.Passed != nil {
				if *item.Passed {
					state = "通過"
				} else {
					state = "失敗"
				}
			}
			fmt.Fprintf(&details, "<li>%s · %s</li>", html.EscapeString(item.Name), state)
		}
		details.WriteString(`</ul></details>`)
	}
	body.WriteString(`</div></section><section class="section"><h2>這次檢查了什麼</h2>`)
	body.WriteString(details.String())
	body.WriteString(`</section><p><a href="report_scope.md">測試說明</a></p>`)
	page := strings.ReplaceAll(strings.ReplaceAll(overviewTemplate, "{{TITLE}}", html.EscapeString(version)+" 測試結果"), "{{BODY}}", body.String())
	return []byte(strings.TrimPrefix(page, "\ufeff")), scope
}
