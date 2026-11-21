package main

import (
	"crypto/sha256"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"runtime/debug"
	"sort"
	rc "windows_setup/script/test/repo_coverage"
)

type simulatorToolIdentity struct {
	Name          string `json:"name"`
	SchemaVersion int    `json:"schema_version"`
	BinarySHA256  string `json:"binary_sha256"`
	Revision      string `json:"revision"`
	Modified      string `json:"modified"`
}

func simulatorIdentity() (simulatorToolIdentity, error) {
	id := simulatorToolIdentity{Name: "repo_coverage_tool", SchemaVersion: 1, Revision: "unavailable", Modified: "unavailable"}
	path, err := os.Executable()
	if err != nil {
		return id, err
	}
	f, err := os.Open(path)
	if err != nil {
		return id, err
	}
	defer f.Close()
	h := sha256.New()
	if _, err = io.Copy(h, f); err != nil {
		return id, err
	}
	id.BinarySHA256 = fmt.Sprintf("%x", h.Sum(nil))
	if info, ok := debug.ReadBuildInfo(); ok {
		for _, setting := range info.Settings {
			switch setting.Key {
			case "vcs.revision":
				id.Revision = setting.Value
			case "vcs.modified":
				id.Modified = setting.Value
			}
		}
	}
	return id, nil
}

type simulationShard struct {
	Suites            []int `json:"suites"`
	Milliseconds      int64 `json:"work_milliseconds"`
	BatchMilliseconds int64 `json:"batch_milliseconds"`
}
type simulationPlan struct {
	Shards                   []simulationShard `json:"shards"`
	MaximumMilliseconds      int64             `json:"maximum_work_milliseconds"`
	TotalMilliseconds        int64             `json:"total_work_milliseconds"`
	MaximumBatchMilliseconds int64             `json:"maximum_batch_milliseconds"`
}

func powershellTimingSimulate(args []string, out io.Writer) error {
	var o shardCLIOptions
	var timing string
	f := flag.NewFlagSet("powershell-timing-simulate", flag.ContinueOnError)
	f.SetOutput(out)
	f.BoolVar(&o.runtime, "runtime", false, "restrict measurement inventory to runtime coverage")
	f.StringVar(&o.source, "source-root", "", "measurement checkout")
	f.StringVar(&o.manifest, "manifest", "", "measurement manifest")
	f.StringVar(&o.commit, "expected-sha", "", "measurement source commit")
	f.StringVar(&o.runURL, "expected-run-url", "", "measurement run")
	f.IntVar(&o.attempt, "run-attempt", 0, "measurement attempt")
	f.IntVar(&o.count, "shard-count", 0, "measurement shard count")
	f.StringVar(&o.input, "input-dir", "", "measurement shards")
	f.StringVar(&timing, "timing-file", "", "merged timing")
	if err := f.Parse(args); err != nil {
		return err
	}
	if f.NArg() != 0 || timing == "" {
		return fmt.Errorf("timing file required")
	}
	if o.count != 4 {
		return fmt.Errorf("exactly four source shards required")
	}
	// Reuse the production argument validation without creating its nominal output.
	check := []string{"--source-root", o.source, "--manifest", o.manifest, "--expected-sha", o.commit, "--expected-run-url", o.runURL, "--run-attempt", fmt.Sprint(o.attempt), "--shard-count", fmt.Sprint(o.count), "--input-dir", o.input, "--output-dir", "unused"}
	if o.runtime {
		check = append(check, "--runtime")
	}
	if _, err := parseShardOptions("powershell-shard-merge", check, io.Discard); err != nil {
		return err
	}
	_, inv, catalog, err := trustedShardCatalog(o)
	if err != nil {
		return err
	}
	if len(catalog.Tests) < 8 {
		return fmt.Errorf("at least eight suites required")
	}
	entries, err := os.ReadDir(o.input)
	if err != nil || len(entries) != o.count {
		return fmt.Errorf("incomplete shard inputs")
	}
	inputs := make([]rc.PowerShellShardInput, 0, len(entries))
	dirs := make([]string, 0, len(entries))
	for _, entry := range entries {
		dir := filepath.Join(o.input, entry.Name())
		info, e := os.Lstat(dir)
		if e != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("invalid shard directory")
		}
		b, e := readShardFile(dir, "shard.json")
		if e != nil {
			return e
		}
		captured := dir
		inputs = append(inputs, rc.PowerShellShardInput{Manifest: b, Read: func(name string) ([]byte, error) { return readShardFile(captured, name) }})
		dirs = append(dirs, dir)
	}
	_, err = rc.MergePowerShellShards(rc.PowerShellShardIdentity{Commit: o.commit, RunUrl: o.runURL, RunAttempt: o.attempt, ShardCount: o.count}, catalog, inputs, inv)
	if err != nil {
		return err
	}
	contexts := []rc.PowerShellWorkerContext{}
	for i, dir := range dirs {
		_, shardContexts, e := verifiedShardContexts(inputs[i], dir)
		if e != nil {
			return e
		}
		contexts = append(contexts, shardContexts...)
	}
	if _, _, _, err = trustedShardCatalog(o); err != nil {
		return err
	}
	limit, err := timingShardLimit(len(contexts))
	if err != nil {
		return err
	}
	data, err := readTimingRegular(timing, limit)
	if err != nil {
		return err
	}
	var receipts []timingReceipt
	if err = decodeTiming(data, &receipts); err != nil {
		return err
	}
	if err = validateTimingRoster(contexts, receipts); err != nil {
		return err
	}
	type task struct {
		index    int
		duration int64
	}
	tasks := make([]task, 0, len(receipts))
	durations := make([]int64, len(catalog.Tests))
	var total int64
	for _, r := range receipts {
		var d int64
		for _, p := range r.Phases {
			if p.Milliseconds > math.MaxInt64-d {
				return fmt.Errorf("duration overflow")
			}
			d += p.Milliseconds
		}
		if d > math.MaxInt64-total {
			return fmt.Errorf("total overflow")
		}
		total += d
		durations[r.Context.GlobalIndex] = d
		tasks = append(tasks, task{r.Context.GlobalIndex, d})
	}
	sort.Slice(tasks, func(i, j int) bool {
		if tasks[i].duration != tasks[j].duration {
			return tasks[i].duration > tasks[j].duration
		}
		return tasks[i].index < tasks[j].index
	})
	finish := func(p *simulationPlan) {
		for i := range p.Shards {
			s := &p.Shards[i]
			for j := 0; j < len(s.Suites); j += 2 {
				batch := durations[s.Suites[j]]
				if j+1 < len(s.Suites) && durations[s.Suites[j+1]] > batch {
					batch = durations[s.Suites[j+1]]
				}
				s.BatchMilliseconds += batch
			}
			if s.BatchMilliseconds > p.MaximumBatchMilliseconds {
				p.MaximumBatchMilliseconds = s.BatchMilliseconds
			}
		}
	}
	baseline := simulationPlan{Shards: make([]simulationShard, 4), TotalMilliseconds: total}
	for i := range baseline.Shards {
		baseline.Shards[i].Suites = []int{}
	}
	for i, duration := range durations {
		s := &baseline.Shards[i%4]
		s.Suites = append(s.Suites, i)
		s.Milliseconds += duration
		if s.Milliseconds > baseline.MaximumMilliseconds {
			baseline.MaximumMilliseconds = s.Milliseconds
		}
	}
	finish(&baseline)
	plans := []simulationPlan{}
	for _, count := range []int{4, 8} {
		p := simulationPlan{Shards: make([]simulationShard, count), TotalMilliseconds: total}
		for i := range p.Shards {
			p.Shards[i].Suites = []int{}
		}
		for _, task := range tasks {
			index := 0
			for i := 1; i < count; i++ {
				if p.Shards[i].Milliseconds < p.Shards[index].Milliseconds {
					index = i
				}
			}
			p.Shards[index].Suites = append(p.Shards[index].Suites, task.index)
			p.Shards[index].Milliseconds += task.duration
			if p.Shards[index].Milliseconds > p.MaximumMilliseconds {
				p.MaximumMilliseconds = p.Shards[index].Milliseconds
			}
		}
		finish(&p)
		plans = append(plans, p)
	}
	tool, err := simulatorIdentity()
	if err != nil {
		return err
	}
	return json.NewEncoder(out).Encode(struct {
		Tool              simulatorToolIdentity    `json:"tool"`
		MeasurementCommit string                   `json:"measurement_commit"`
		RunURL            string                   `json:"run_url"`
		RunAttempt        int                      `json:"run_attempt"`
		CriticalPath      string                   `json:"critical_path"`
		Model             string                   `json:"model"`
		Catalog           []rc.PowerShellShardTest `json:"catalog"`
		Baseline          simulationPlan           `json:"baseline"`
		Plans             []simulationPlan         `json:"plans"`
	}{tool, o.commit, o.runURL, o.attempt, "unavailable", "phase-only; sequential batches of up to two with a barrier; excludes process and job overhead and queue", catalog.Tests, baseline, plans})
}
