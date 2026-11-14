package unit_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func coverageJob(text, name string) string {
	lines := strings.Split(text, "\n")
	active := false
	out := []string{}
	for _, line := range lines {
		if strings.TrimSpace(line) == name+":" && strings.HasPrefix(line, "  ") && !strings.HasPrefix(line, "   ") {
			active = true
			continue
		}
		if active && strings.HasPrefix(line, "  ") && !strings.HasPrefix(line, "   ") && strings.HasSuffix(strings.TrimSpace(line), ":") {
			break
		}
		if active {
			out = append(out, line)
		}
	}
	return strings.Join(out, "\n")
}

func TestCIRuntimeCoverageKeepsGoAndCMDTests(t *testing.T) {
	b, err := os.ReadFile(filepath.Join("../../..", ".github/workflows/windows_tests.yml"))
	if err != nil {
		t.Fatal(err)
	}
	text := string(b)
	native, aggregate, gate := coverageJob(text, "isolated-tests"), coverageJob(text, "coverage-aggregation"), coverageJob(text, "requirements-gate")
	if !strings.Contains(native, "'test','-mod=vendor','-count=1','./...'") {
		t.Fatal("native Go tests must run and fail CI on error")
	}
	if strings.Contains(native, "measure_go_coverage.ps1") || strings.Contains(aggregate, "attach_go_coverage.ps1") {
		t.Fatal("Go coverage still gates runtime publication")
	}
	if !strings.Contains(native, "'native-stage-pack','--runtime'") || !strings.Contains(aggregate, "'native-stage-restore','--runtime'") {
		t.Fatal("native runtime stage missing")
	}
	if !strings.Contains(gate, "--require-runtime") || !strings.Contains(gate, "verify --runtime") {
		t.Fatal("runtime evidence is not mandatory in CI")
	}
	if !strings.Contains(coverageJob(text, "verify-deployment"), "verify_deployment --mode release --require-runtime") {
		t.Fatal("current tag deployment must require a verified runtime bundle")
	}
	docker := coverageJob(text, "docker-tests")
	if !strings.Contains(docker, "'./script/test/requirements_gate','--tests-only'") {
		t.Fatal("container host report must use tests-only validation")
	}
	container, err := os.ReadFile(filepath.Join("../../..", "script/docker/container_test.ps1"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(container), "'./script/test/requirements_gate','--tests-only'") {
		t.Fatal("container inner report must use tests-only validation")
	}
}
func TestCIWholeCoverageHasProducerAndStrictConsumers(t *testing.T) {
	b, err := os.ReadFile(filepath.Join("../../..", ".github/workflows/windows_tests.yml"))
	if err != nil {
		t.Fatal(err)
	}
	text := string(b)
	producer := coverageJob(text, "coverage-aggregation")
	for _, required := range []string{"actions/setup-dotnet@", "dotnet-version: '10.0.300'", "DOTNET_INSTALL_DIR:", "managed_coverage.ps1", "run_repo_coverage.ps1", "-ManagedEvidencePath", "repo-coverage-evidence", "Export-CIPowerShellRawEvidence", "powershell-raw-evidence", "retention-days: 7"} {
		if !strings.Contains(producer, required) {
			t.Fatalf("producer missing %s", required)
		}
	}
	gate := coverageJob(text, "requirements-gate")
	for _, required := range []string{"repo_coverage_tool verify", "--require-complete", "--minimum-percent 80", "--expected-sha", "--expected-run-url"} {
		if !strings.Contains(gate, required) {
			t.Fatalf("strict artifact gate missing %s", required)
		}
	}
	for _, job := range []string{"release", "build-portal"} {
		body := coverageJob(text, job)
		if !strings.Contains(body, "WINDOWS_SETUP_COVERAGE_TOOL:") || !strings.Contains(body, "actions/setup-go@") || !strings.Contains(body, "./script/test/repo_coverage_tool") {
			t.Fatalf("%s cannot execute mandatory coverage verifier", job)
		}
	}
	if !strings.Contains(coverageJob(text, "ci-rollup"), "oobe_payload_inspection") {
		t.Fatal("payload requirement removed")
	}
}
