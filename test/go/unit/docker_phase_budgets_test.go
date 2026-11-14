package unit_test

import (
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

func TestDockerBuildAndFullTestHaveIndependentBoundedBudgets(t *testing.T) {
	b, err := os.ReadFile(filepath.Join("../../..", ".github/workflows/windows_tests.yml"))
	if err != nil {
		t.Fatal(err)
	}
	w := string(b)
	start := strings.Index(w, "  docker-tests:")
	if start < 0 {
		t.Fatal("required Docker job was removed")
	}
	end := strings.Index(w[start:], "\n  ci-rollup:")
	if start < 0 || end < 0 {
		t.Fatal("Docker job and required rollup must remain")
	}
	job := w[start : start+end]
	ready := strings.Index(job, "script\\docker\\runner_daemon.ps1")
	doctor := strings.Index(job, "'-Action','doctor'")
	if ready < 0 || doctor < ready || !strings.Contains(job[:doctor], "timeout-minutes: 3") {
		t.Fatal("bounded hosted-daemon readiness must run before the unchanged real Windows Docker doctor")
	}
	health := strings.Index(job, "Invoke-CIContainerHealthVerification -ImageId $image")
	build := strings.Index(job, "'-Action','build'")
	fullTest := strings.Index(job, "'-Action','test-built'")
	if build < 0 || health < build || fullTest < health || !strings.Contains(job[build:health], "timeout-minutes: 4") {
		t.Fatal("bounded health verification must follow image build and precede the full test")
	}
	budget := regexp.MustCompile(`timeout-minutes:\s*([0-9]+)`)
	limits := budget.FindAllStringSubmatch(job, -1)
	if len(limits) < 5 {
		t.Fatal("build, full tests, native failure probe and evidence each need their own bounded phase")
	}
	n := func(s string) int {
		v, e := strconv.Atoi(s)
		if e != nil {
			t.Fatal(e)
		}
		return v
	}
	total := 10 // checkout/tool setup, upload and process cleanup headroom
	for _, m := range limits[1:] {
		if n(m[1]) <= 0 {
			t.Fatal("unbounded phase")
		}
		total += n(m[1])
	}
	if n(limits[0][1]) < total {
		t.Fatal("whole-job timeout can cancel normally progressing bounded phases")
	}
	if !strings.Contains(job, "'-Action','build'") || !strings.Contains(job, "'-Action','test-built'") || strings.Count(job, "windows-container-image.json") != 4 {
		t.Fatal("separate full-test phase must consume the exact build receipt without rebuilding or skipping image identity")
	}
	for _, required := range []string{"Assert-CIDockerFailure", "Assert-CIContainerReport", "requirements_gate", "retention-days: 7"} {
		if !strings.Contains(job, required) {
			t.Fatalf("original Docker gate removed: %s", required)
		}
	}
}
