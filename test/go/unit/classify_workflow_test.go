package unit_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPullRequestClassifyGatesOnlyDeclaredHeavyJobs(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("../../..", ".github/workflows/windows_tests.yml"))
	if err != nil {
		t.Fatal(err)
	}
	text := strings.ReplaceAll(string(data), "\r\n", "\n")
	classify := coverageJob(text, "classify")
	for _, required := range []string{"fetch-depth: 0", "ci_classify.ps1", "continue-on-error: true", "steps.classify.outcome != 'success'", "path: base-source", "ref: ${{ github.event.pull_request.base.sha || github.sha }}", "& ./base-source/script/test/ci_classify.ps1", "test_scope=full", "select_doc_checks", "doc_tests"} {
		if !strings.Contains(classify, required) {
			t.Fatalf("classify missing %s", required)
		}
	}
	gated := map[string]string{
		"isolated-tests":          "select_tests",
		"powershell-coverage":     "select_powershell_coverage",
		"coverage-aggregation":    "select_coverage_aggregation",
		"managed-coverage":        "select_coverage_aggregation",
		"requirements-gate":       "select_requirements_gate",
		"docker-tests":            "select_docker_tests",
		"docker-test-shards":      "select_docker_tests",
		"go-tests":            "select_go_tests",
		"oobe_payload_inspection": "select_oobe_payload",
	}
	for job, key := range gated {
		body := coverageJob(text, job)
		if !strings.Contains(body, "needs.classify.outputs."+key+" == 'true'") {
			t.Fatalf("%s is not gated by classify output %s", job, key)
		}
		if !strings.Contains(body, "classify") || !strings.Contains(body, "needs: [") {
			t.Fatalf("%s does not wait for classify", job)
		}
		for _, line := range strings.Split(body, "\n") {
			if strings.HasPrefix(line, "    if:") && strings.Contains(line, "github.event") {
				t.Fatalf("%s must be selected by classify, not by an event condition", job)
			}
		}
	}
	docs := coverageJob(text, "doc-checks")
	for _, required := range []string{"needs.classify.outputs.select_doc_checks == 'true'", "run_ci.ps1", "-Suite", "needs.classify.outputs.doc_tests"} {
		if !strings.Contains(docs, required) {
			t.Fatalf("doc-checks missing %s", required)
		}
	}
	if !strings.Contains(docs, "-Layer All") {
		t.Fatal("doc-checks must keep the complete inventory check before selecting suites")
	}
	rollup := coverageJob(text, "ci-rollup")
	for _, required := range []string{"if: always()", "needs: [classify, doc-checks,", "needs.classify.result", "needs.doc-checks.result", "Resolve-CIRollupStates", "select_tests", "select_docker_tests", "select_coverage_aggregation", "select_doc_checks", "Assert-CIResults"} {
		if !strings.Contains(rollup, required) {
			t.Fatalf("ci-rollup missing %s", required)
		}
	}
	if !strings.Contains(coverageJob(text, "requirements-gate"), "always() && needs.classify.outputs.select_requirements_gate == 'true' && needs.coverage-aggregation.result != 'cancelled'") {
		t.Fatal("requirements-gate must not run when classify did not select it, and must still report cancelled aggregation")
	}
}

func TestClassifyScriptPrefixesStayInWorkflowOutputs(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("../../..", ".github/workflows/windows_tests.yml"))
	if err != nil {
		t.Fatal(err)
	}
	script, err := os.ReadFile(filepath.Join("../../..", "script/test/ci_classify.ps1"))
	if err != nil {
		t.Fatal(err)
	}
	classify := coverageJob(strings.ReplaceAll(string(data), "\r\n", "\n"), "classify")
	for _, key := range []string{"tests", "powershell_coverage", "coverage_aggregation", "requirements_gate", "docker_tests", "oobe_payload"} {
		if !strings.Contains(string(script), "'"+key+"'") {
			t.Fatalf("classifier does not emit %s", key)
		}
		if !strings.Contains(classify, "select_"+key+": ${{ steps.classify.outputs.select_"+key) {
			t.Fatalf("classify does not export select_%s", key)
		}
	}
}

func TestScopedPullRequestKeepsFullGateForOtherEvents(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("../../..", ".github/workflows/windows_tests.yml"))
	if err != nil {
		t.Fatal(err)
	}
	text := strings.ReplaceAll(string(data), "\r\n", "\n")
	classify := coverageJob(text, "classify")
	for _, required := range []string{"test_scope: ${{ steps.classify.outputs.test_scope || steps.fallback.outputs.test_scope }}", "affected_tests: ${{ steps.classify.outputs.affected_tests }}"} {
		if !strings.Contains(classify, required) {
			t.Fatalf("classify missing %s", required)
		}
	}
	isolated := coverageJob(text, "isolated-tests")
	for _, required := range []string{"needs.classify.outputs.test_scope == 'scoped'", "-Parallelism 2 -ShardIndex ([int]$env:SHARD_INDEX) -ShardCount ([int]$env:SHARD_COUNT) -Suite ($env:AFFECTED_TESTS -split ',')", "AFFECTED_TESTS: ${{ needs.classify.outputs.affected_tests }}"} {
		if !strings.Contains(isolated, required) {
			t.Fatalf("isolated-tests missing %s", required)
		}
	}
	fullOnly := []string{"執行 Windows PowerShell 5.1 隔離測試", "執行全部 Go 維護工具測試", "驗證手機與桌面報表明細排版", "封裝尚未完成 runtime 覆蓋率的原生證據", "僅保留不可發布的同次原生中介證據七天"}
	for _, name := range fullOnly {
		start := strings.Index(isolated, "- name: "+name)
		if start < 0 {
			t.Fatalf("isolated-tests lost step %s", name)
		}
		rest := isolated[start+1:]
		end := strings.Index(rest, "\n      - name: ")
		if end < 0 {
			end = len(rest)
		}
		if !strings.Contains(rest[:end], "needs.classify.outputs.test_scope != 'scoped'") {
			t.Fatalf("step %s must run unless the PR is explicitly scoped", name)
		}
	}
	mergecheck := strings.Index(isolated, "mergecheck")
	if mergecheck < 0 {
		t.Fatal("merge title check must stay in isolated-tests")
	}
	stepStart := strings.LastIndex(isolated[:mergecheck], "- name: ")
	if strings.Contains(isolated[stepStart:mergecheck], "test_scope") {
		t.Fatal("merge title check must run for every scope")
	}
	rollup := coverageJob(text, "ci-rollup")
	for _, required := range []string{"EVENT_NAME: ${{ github.event_name }}", "-EventName $env:EVENT_NAME"} {
		if !strings.Contains(rollup, required) {
			t.Fatalf("ci-rollup missing %s", required)
		}
	}
}

func TestClassifyRunsBaseVersionRulesAndFallsBackWithoutScript(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("../../..", ".github/workflows/windows_tests.yml"))
	if err != nil {
		t.Fatal(err)
	}
	classify := coverageJob(strings.ReplaceAll(string(data), "\r\n", "\n"), "classify")
	if strings.Contains(classify, "& ./script/test/ci_classify.ps1") {
		t.Fatal("a pull request must not classify itself with its own rules")
	}
	idx := strings.Index(classify, "id: fallback")
	if idx < 0 {
		t.Fatal("classify has no fallback")
	}
	fallback := classify[idx:]
	if strings.Contains(fallback, "ci_classify.ps1") {
		t.Fatal("fallback must not depend on any script a pull request can change")
	}
	for _, required := range []string{"select_tests=true", "select_docker_tests=true", "select_powershell_coverage=true", "select_coverage_aggregation=true", "select_requirements_gate=true", "select_oobe_payload=true", "select_doc_checks=false", "test_scope=full"} {
		if !strings.Contains(fallback, required) {
			t.Fatalf("fallback missing %s", required)
		}
	}
}

func TestPullRequestShardsIsolatedTestsAndRunsGoTestsSeparately(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("../../..", ".github/workflows/windows_tests.yml"))
	if err != nil {
		t.Fatal(err)
	}
	text := strings.ReplaceAll(string(data), "\r\n", "\n")
	classify := coverageJob(text, "classify")
	for _, required := range []string{
		"select_go_tests: ${{ steps.classify.outputs.select_go_tests || steps.fallback.outputs.select_go_tests || 'false' }}",
		"shard_count: ${{ steps.classify.outputs.shard_count || steps.fallback.outputs.shard_count || '1' }}",
		"shard_matrix: ${{ steps.classify.outputs.shard_matrix || steps.fallback.outputs.shard_matrix || '[0]' }}",
	} {
		if !strings.Contains(classify, required) {
			t.Fatalf("classify missing %s; an older base classifier without these outputs must still produce one full shard", required)
		}
	}
	fallback := classify[strings.Index(classify, "id: fallback"):]
	for _, required := range []string{"select_go_tests=false", "shard_count=1", "shard_matrix=[0]", "pr_full=false"} {
		if !strings.Contains(fallback, required) {
			t.Fatalf("fallback missing %s", required)
		}
	}
	isolated := coverageJob(text, "isolated-tests")
	for _, required := range []string{"fail-fast: false", "shard: ${{ fromJSON(needs.classify.outputs.shard_matrix) }}", "SHARD_INDEX: ${{ matrix.shard }}", "SHARD_COUNT: ${{ needs.classify.outputs.shard_count }}"} {
		if !strings.Contains(isolated, required) {
			t.Fatalf("isolated-tests missing %s", required)
		}
	}
	goJob := coverageJob(text, "go-tests")
	for _, required := range []string{"Invoke-CIGoUnitTests", "needs: [source-preflight, classify]"} {
		if !strings.Contains(goJob, required) {
			t.Fatalf("go-tests missing %s", required)
		}
	}
	if strings.Contains(goJob, "test/go/integration") || strings.Contains(goJob, "go.exe") {
		t.Fatal("go-tests must call the shared helper, not inline go commands or the integration package")
	}
	rollup := coverageJob(text, "ci-rollup")
	for _, required := range []string{"go-tests", "GO_TESTS_RESULT: ${{ needs.go-tests.result }}", "SELECT_GO_TESTS: ${{ needs.classify.outputs.select_go_tests }}", "GoTests="} {
		if !strings.Contains(rollup, required) {
			t.Fatalf("ci-rollup missing %s", required)
		}
	}
}

// 分類工作在 Linux 執行：必須真實跑分類器 smoke，且退回完整套件時 summary 與 rollup 明確標示。
func TestClassifyRunsSmokeAndSurfacesFallback(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("../../..", ".github/workflows/windows_tests.yml"))
	if err != nil {
		t.Fatal(err)
	}
	text := strings.ReplaceAll(string(data), "\r\n", "\n")
	classify := coverageJob(text, "classify")
	rollup := coverageJob(text, "ci-rollup")
	if !strings.Contains(classify, "runs-on: ubuntu-latest") {
		t.Fatal("classify is expected to run on Linux")
	}
	if !strings.Contains(classify, "Invoke-CIClassifierSmoke") || !strings.Contains(classify, "./script/test/ci_classify_smoke.ps1") {
		t.Fatal("classify must run the classifier smoke on the pull request's own source")
	}
	if !strings.Contains(classify, "classify_fallback: ${{ steps.classify.outputs.classify_fallback || steps.fallback.outputs.classify_fallback") {
		t.Fatal("classify must expose whether it fell back to the full suite")
	}
	idx := strings.Index(classify, "id: fallback")
	if idx < 0 || !strings.Contains(classify[idx:], "classify_fallback=true") {
		t.Fatal("the workflow fallback must mark classify_fallback=true")
	}
	if !strings.Contains(rollup, "CLASSIFY_FALLBACK: ${{ needs.classify.outputs.classify_fallback }}") || !strings.Contains(rollup, "Write-CIClassifyFallbackNotice") {
		t.Fatal("ci-rollup must surface a classification fallback in its summary")
	}
}
