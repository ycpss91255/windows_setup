package main

import (
	"os"
	"strings"
	"testing"
)

func TestPagesVisibilityPrecedesSingleDeployment(t *testing.T) {
	b, err := os.ReadFile("../../../.github/workflows/windows_tests.yml")
	if err != nil {
		t.Fatal(err)
	}
	s := string(b)
	start := strings.Index(s, "  publish-reports:")
	end := strings.Index(s, "  verify-deployment:")
	if start < 0 || end <= start {
		t.Fatal("missing Pages job")
	}
	job := s[start:end]
	upload := strings.Index(job, "id: pages_artifact")
	observe := strings.Index(job, "./script/test/pages_artifact_visibility")
	deploy := strings.Index(job, "uses: actions/deploy-pages@")
	if upload < 0 || observe <= upload || deploy <= observe {
		t.Fatal("same-job producer, visibility preflight and deploy must run in that order")
	}
	for _, required := range []string{"name: github-pages-${{ github.run_id }}-${{ github.run_attempt }}", "PAGES_ARTIFACT_ID: ${{ steps.pages_artifact.outputs.artifact-id }}", "PAGES_ARTIFACT_DIGEST: ${{ steps.pages_artifact.outputs.artifact-digest }}", "artifact_name: github-pages-${{ github.run_id }}-${{ github.run_attempt }}", "actions/github-script@f28e40c7f34bde8b3046d885e986cb6290c5673b"} {
		if !strings.Contains(job, required) {
			t.Errorf("missing %s", required)
		}
	}
	if strings.Count(job, "uses: actions/deploy-pages@") != 1 {
		t.Fatal("expected a single deploy action")
	}
	for _, required := range []string{
		`tar --dereference --hard-dereference --directory portal -cvf "$RUNNER_TEMP/artifact.tar" --exclude=.git --exclude=.github .`,
		"actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02",
		"path: ${{ runner.temp }}/artifact.tar",
		"if-no-files-found: error",
	} {
		if !strings.Contains(job, required) {
			t.Errorf("missing archive/upload contract %s", required)
		}
	}
}
