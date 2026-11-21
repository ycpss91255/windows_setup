package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestSimulatorRejectsNonFourShards(t *testing.T) {
	for count := 1; count <= 3; count++ {
		t.Run(fmt.Sprint(count), func(t *testing.T) {
			root, manifest, sha, old, timing := simulatorFixture(t)
			parts := t.TempDir()
			var receipts []timingReceipt
			for shard := 0; shard < count; shard++ {
				dir := filepath.Join(parts, fmt.Sprint(shard))
				if e := os.MkdirAll(dir, 0700); e != nil {
					t.Fatal(e)
				}
				template := filepath.Join(old, fmt.Sprint(shard))
				for _, n := range []string{"evidence.json", "coverage.xml"} {
					b, e := os.ReadFile(filepath.Join(template, n))
					if e != nil {
						t.Fatal(e)
					}
					if e = os.WriteFile(filepath.Join(dir, n), b, 0600); e != nil {
						t.Fatal(e)
					}
				}
				b, err := os.ReadFile(filepath.Join(dir, "evidence.json"))
				if err != nil {
					t.Fatal(err)
				}
				var proof map[string]any
				if err = json.Unmarshal(b, &proof); err != nil {
					t.Fatal(err)
				}
				d0 := proof["Workers"].([]any)[0].(map[string]any)
				workers := []any{}
				for local := 0; shard+local*count < 8; local++ {
					global := shard + local*count
					source := filepath.Join(old, fmt.Sprint(global%4), fmt.Sprintf("worker_%d.json", global/4))
					b, e := os.ReadFile(source)
					if e != nil {
						t.Fatal(e)
					}
					var w map[string]any
					if err = json.Unmarshal(b, &w); err != nil {
						t.Fatal(err)
					}
					ctx := w["Context"].(map[string]any)
					ctx["ShardCount"] = count
					ctx["ShardIndex"] = shard
					ctx["GlobalIndex"] = global
					pid := 300 + global
					ctx["ProcessId"] = pid
					w["ProcessId"] = pid
					b, err = json.Marshal(w)
					if err != nil {
						t.Fatal(err)
					}
					if err = os.WriteFile(filepath.Join(dir, fmt.Sprintf("worker_%d.json", local)), b, 0600); err != nil {
						t.Fatal(err)
					}
					var parsed struct{ Context json.RawMessage }
					if err = json.Unmarshal(b, &parsed); err != nil {
						t.Fatal(err)
					}
					var rec timingReceipt
					if err = json.Unmarshal(parsed.Context, &rec.Context); err != nil {
						t.Fatal(err)
					}
					rec.SchemaVersion = 1
					rec.Phases = []timingPhase{{"worker_setup", int64(global + 1)}, {"pester_instrumentation_and_test", 0}, {"serialization", 0}}
					receipts = append(receipts, rec)
					desc := map[string]any{}
					for k, v := range d0 {
						desc[k] = v
					}
					desc["Index"] = local
					desc["ProcessId"] = pid
					desc["Evidence"] = fmt.Sprintf("worker_%d.json", local)
					workers = append(workers, desc)
				}
				proof["Workers"] = workers
				b, err = json.Marshal(proof)
				if err != nil {
					t.Fatal(err)
				}
				if err = os.WriteFile(filepath.Join(dir, "evidence.json"), b, 0600); err != nil {
					t.Fatal(err)
				}
				if e := canonicalizeShardCLIProof(root, dir); e != nil {
					t.Fatal(e)
				}
				args := append(shardCLIArgs(root, manifest, sha), "--runtime", "--shard-count", fmt.Sprint(count), "--shard-index", fmt.Sprint(shard), "--evidence-dir", dir)
				if e := powershellShardPack(args, os.Stdout); e != nil {
					t.Fatal(e)
				}
			}
			b, err := json.Marshal(receipts)
			if err != nil {
				t.Fatal(err)
			}
			if err = os.WriteFile(timing, b, 0600); err != nil {
				t.Fatal(err)
			}
			mergeArgs := append(shardCLIArgs(root, manifest, sha), "--runtime", "--shard-count", fmt.Sprint(count), "--input-dir", parts, "--output-dir", filepath.Join(t.TempDir(), "merged"))
			if err = powershellShardMerge(mergeArgs, os.Stdout); err != nil {
				t.Fatalf("valid %d-shard general merge failed: %v", count, err)
			}
			exe := filepath.Join(t.TempDir(), "tool.exe")
			build := exec.Command("go", "build", "-mod=vendor", "-o", exe, "./script/test/repo_coverage_tool")
			build.Dir = "../../.."
			if b, e := build.CombinedOutput(); e != nil {
				t.Fatalf("build %v %s", e, b)
			}
			args := append([]string{"powershell-timing-simulate"}, shardCLIArgs(root, manifest, sha)...)
			args = append(args, "--runtime", "--shard-count", fmt.Sprint(count), "--input-dir", parts, "--timing-file", timing)
			out, e := exec.Command(exe, args...).CombinedOutput()
			if e == nil {
				t.Fatalf("simulator accepted valid %d-shard input: %s", count, out)
			}
			if !strings.Contains(string(out), "exactly four source shards required") {
				t.Fatalf("wrong failure for %d shards: %v %s", count, e, out)
			}
		})
	}
}
