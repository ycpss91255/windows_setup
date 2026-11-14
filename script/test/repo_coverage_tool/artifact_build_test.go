package main

import (
	"os"
	"strings"
	"testing"
)

func TestArtifactDownloadBuildUsesCINative(t *testing.T) {
	data, err := os.ReadFile("../../../.github/workflows/windows_tests.yml")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), "Invoke-CINative -File go.exe -Arguments @('build','-o',(Join-Path $env:RUNNER_TEMP 'artifact_download.exe'),'./script/test/artifact_download')") {
		t.Fatal("artifact download build must use the existing checked native command wrapper")
	}
}
