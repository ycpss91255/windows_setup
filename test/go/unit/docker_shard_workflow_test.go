package unit_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// 容器測試拆成平行分片後，必要檢查名稱 docker-tests 仍是唯一的合併閘門：
// 任一分片失敗、缺少或被略過，合併工作都不能成功，ci-rollup 照樣只看 docker-tests。
func TestDockerTestsAreShardedBehindOneMergeGate(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("../../..", ".github/workflows/windows_tests.yml"))
	if err != nil {
		t.Fatal(err)
	}
	text := strings.ReplaceAll(string(data), "\r\n", "\n")

	classify := coverageJob(text, "classify")
	for _, required := range []string{
		"DOCKER_SHARDS: ${{ vars.DOCKER_SHARDS }}",
		"Get-CIContainerShardPlan -Value $env:DOCKER_SHARDS",
		"docker_shard_count: ${{ steps.docker_shards.outputs.docker_shard_count }}",
		"docker_shard_matrix: ${{ steps.docker_shards.outputs.docker_shard_matrix }}",
	} {
		if !strings.Contains(classify, required) {
			t.Fatalf("classify must derive the container shard plan from the repo variable: %s", required)
		}
	}
	if strings.Index(classify, "id: docker_shards") > strings.Index(classify, "id: classify") {
		t.Fatal("shard plan must be computed independently before the change classifier")
	}
	script, err := os.ReadFile(filepath.Join("../../..", "script/test/ci_classify.ps1"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(script), "docker_shard") || strings.Contains(string(script), "DOCKER_SHARDS") {
		t.Fatal("PR and merge_group classification logic must not change for container sharding")
	}

	shards := coverageJob(text, "docker-test-shards")
	if shards == "" {
		t.Fatal("missing container shard matrix job")
	}
	for _, required := range []string{
		"needs: [source-preflight, classify]",
		"if: needs.classify.outputs.select_docker_tests == 'true'",
		"fail-fast: false",
		"shard: ${{ fromJSON(needs.classify.outputs.docker_shard_matrix) }}",
		"SHARD_INDEX: ${{ matrix.shard }}",
		"SHARD_COUNT: ${{ needs.classify.outputs.docker_shard_count }}",
		"'-ShardIndex',$env:SHARD_INDEX,'-ShardCount',$env:SHARD_COUNT",
		"Assert-CIContainerReport -Directory $public",
		"name: docker-shard-reports-${{ github.run_id }}-${{ github.run_attempt }}-${{ matrix.shard }}",
		"${{ runner.temp }}/windows-container-results/public/\n            ${{ runner.temp }}/windows-container-results/shard.json",
		"if-no-files-found: error",
	} {
		if !strings.Contains(shards, required) {
			t.Fatalf("container shard job missing %s", required)
		}
	}

	merge := coverageJob(text, "docker-tests")
	for _, required := range []string{
		"needs: [source-preflight, classify, docker-test-shards]",
		"if: always() && needs.classify.outputs.select_docker_tests == 'true'",
		"SHARDS_RESULT: ${{ needs.docker-test-shards.result }}",
		"Assert-CIContainerShardsResult -Result $env:SHARDS_RESULT",
		"pattern: docker-shard-reports-${{ github.run_id }}-${{ github.run_attempt }}-*",
		"Merge-CIContainerShardReports",
		"-ShardCount ([int]$env:SHARD_COUNT)",
		"SHARD_COUNT: ${{ needs.classify.outputs.docker_shard_count }}",
		"name: docker-test-reports-${{ github.run_id }}-${{ github.run_attempt }}",
		"Assert-CIContainerReport -Directory $public",
		"'./script/test/requirements_gate','--tests-only'",
		"retention-days: 7",
	} {
		if !strings.Contains(merge, required) {
			t.Fatalf("docker-tests merge gate missing %s", required)
		}
	}
	if strings.Contains(merge, "'test','-count=1','./...'") || strings.Contains(merge, "create_portal_fixture.ps1") {
		t.Fatal("Go acceptance must stay inside the container (shard 0), not move to the host merge job")
	}
	gate := strings.Index(merge, "SHARDS_RESULT")
	download := strings.Index(merge, "pattern: docker-shard-reports-")
	if gate < 0 || download < 0 || gate > download {
		t.Fatal("merge gate must reject failed or skipped shards before reporting success")
	}
	for _, step := range []string{"Merge-CIContainerShardReports", "name: docker-test-reports-"} {
		idx := strings.Index(merge, step)
		head := merge[:idx]
		stepStart := strings.LastIndex(head, "\n      - name:")
		if !strings.Contains(merge[stepStart:idx], "if: always()") {
			t.Fatalf("%s must still run for diagnostics when a shard failed", step)
		}
	}

	rollup := coverageJob(text, "ci-rollup")
	if !strings.Contains(rollup, "DOCKER_RESULT: ${{ needs.docker-tests.result }}") || !strings.Contains(rollup, "docker-tests,") {
		t.Fatal("ci-rollup must keep requiring the docker-tests gate")
	}
	for _, consumer := range []string{"release", "build-portal"} {
		if consumer == "release" && !strings.Contains(coverageJob(text, consumer), "name: docker-test-reports-${{ github.run_id }}-${{ github.run_attempt }}") {
			t.Fatalf("%s must keep consuming the merged container report", consumer)
		}
		if consumer == "build-portal" && !strings.Contains(coverageJob(text, consumer), "docker-tests") {
			t.Fatalf("%s must keep waiting for the merged container report", consumer)
		}
	}
}
