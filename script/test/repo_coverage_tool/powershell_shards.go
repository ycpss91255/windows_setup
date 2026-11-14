package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"regexp"
	"sort"
	"strings"

	rc "windows_setup/script/test/repo_coverage"
)

type shardCLIOptions struct {
	source, manifest, output, evidence, input, commit, runURL string
	attempt, index, count                                     int
	runtime                                                   bool
}
type shardCollectionManifest struct {
	SourceRoot     string
	Sources, Tests []string
	TestEngines    map[string]string
	Wrapper        string
	ShardContext   *shardCollectionContext `json:",omitempty"`
}

type shardCollectionContext struct {
	Commit, RunUrl                     string
	RunAttempt, ShardIndex, ShardCount int
	GlobalIndices                      []int
}

func parseShardOptions(name string, args []string, out io.Writer) (shardCLIOptions, error) {
	var o shardCLIOptions
	f := flag.NewFlagSet(name, flag.ContinueOnError)
	f.SetOutput(out)
	f.BoolVar(&o.runtime, "runtime", false, "restrict inventory to runtime coverage")
	f.StringVar(&o.source, "source-root", "", "original clean source")
	f.StringVar(&o.manifest, "manifest", "", "canonical collection manifest")
	f.StringVar(&o.commit, "expected-sha", "", "actual source commit")
	f.StringVar(&o.runURL, "expected-run-url", "", "same GitHub run")
	f.IntVar(&o.attempt, "run-attempt", 0, "same workflow attempt")
	f.IntVar(&o.count, "shard-count", 0, "complete matrix size")
	if name != "powershell-shard-merge" {
		f.IntVar(&o.index, "shard-index", -1, "zero based matrix index")
	}
	if name != "powershell-shard-pack" {
		f.StringVar(&o.output, "output-dir", "", "fresh external output")
	}
	if name == "powershell-shard-pack" {
		f.StringVar(&o.evidence, "evidence-dir", "", "validated safe raw export")
	}
	if name == "powershell-shard-merge" {
		f.StringVar(&o.input, "input-dir", "", "complete matrix artifacts")
	}
	if err := f.Parse(args); err != nil {
		return o, err
	}
	if f.NArg() != 0 || o.source == "" || o.manifest == "" || !regexp.MustCompile(`^[a-f0-9]{40}$`).MatchString(o.commit) || !regexp.MustCompile(`^https://github\.com/[A-Za-z0-9_-][A-Za-z0-9_.-]*/[A-Za-z0-9_-][A-Za-z0-9_.-]*/actions/runs/[1-9][0-9]*$`).MatchString(o.runURL) || o.attempt < 1 || o.count < 1 || o.count > 4 || name != "powershell-shard-merge" && (o.index < 0 || o.index >= o.count) || name == "powershell-shard-pack" && o.evidence == "" || name != "powershell-shard-pack" && o.output == "" || name == "powershell-shard-merge" && o.input == "" {
		return o, fmt.Errorf("complete source, manifest, matrix and workflow identity are required")
	}
	return o, nil
}

// Only a small explicit file set is read. Raw worker logs, arbitrary siblings
// and absolute paths are never reconstructed into public artifacts.
func readShardFile(dir, name string) ([]byte, error) {
	if name != "evidence.json" && name != "coverage.xml" && name != "shard.json" && !regexp.MustCompile(`^worker_[0-9]+\.json$`).MatchString(name) {
		return nil, fmt.Errorf("unapproved shard evidence file")
	}
	return readShardRegular(filepath.Join(dir, name))
}
func readShardRegular(path string) ([]byte, error) {
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Size() > 536870912 {
		return nil, fmt.Errorf("evidence must be a bounded regular file")
	}
	return os.ReadFile(path)
}
func decodeShardManifest(data []byte, target any) error {
	d := json.NewDecoder(bytes.NewReader(data))
	d.DisallowUnknownFields()
	if err := d.Decode(target); err != nil {
		return err
	}
	if err := d.Decode(new(any)); err != io.EOF {
		return fmt.Errorf("trailing manifest content")
	}
	return nil
}

func trustedShardCatalog(o shardCLIOptions) (string, rc.Inventory, rc.PowerShellShardCatalog, error) {
	var inv rc.Inventory
	var catalog rc.PowerShellShardCatalog
	root, err := filepath.Abs(o.source)
	if err != nil {
		return "", inv, catalog, err
	}
	root = filepath.Clean(root)
	git := func(args ...string) (string, error) {
		b, e := exec.Command("git", append([]string{"-C", root}, args...)...).Output()
		return strings.TrimSpace(string(b)), e
	}
	head, err := git("rev-parse", "HEAD")
	if err != nil || head != o.commit {
		return "", inv, catalog, fmt.Errorf("source commit does not match workflow")
	}
	status, err := git("status", "--porcelain", "--untracked-files=all")
	if err != nil || status != "" {
		return "", inv, catalog, fmt.Errorf("source must remain clean")
	}
	if o.runtime {
		inv, err = rc.ScanRuntimeInventory(root)
	} else {
		inv, err = rc.ScanInventory(root)
	}
	if err != nil {
		return "", inv, catalog, err
	}
	if len(inv.Blockers) > 0 {
		return "", inv, catalog, fmt.Errorf("source inventory contains unsupported executable inputs")
	}
	tracked, err := git("ls-files", "*.ps1", "*.psm1")
	if err != nil {
		return "", inv, catalog, err
	}
	trackedSet := map[string]bool{}
	for _, s := range strings.Split(tracked, "\n") {
		trackedSet[filepath.ToSlash(s)] = true
	}
	for _, s := range inv.Sources {
		if s.Language == "powershell" {
			if !trackedSet[s.Path] || !regexp.MustCompile(`^(core|modules|script)/`).MatchString(s.Path) {
				return "", inv, catalog, fmt.Errorf("PowerShell source is outside canonical tracked scope")
			}
			catalog.Sources = append(catalog.Sources, rc.PowerShellShardSource{File: s.Path, SHA256: s.SHA256})
		}
	}
	testPattern := regexp.MustCompile(`^[a-z0-9_]+_tests\.ps1$`)
	for _, layer := range []string{"unit", "integration"} {
		directory := filepath.Join(root, "test/powershell", layer)
		entries, e := os.ReadDir(directory)
		if e != nil {
			return "", inv, catalog, e
		}
		for _, entry := range entries {
			if entry.IsDir() || !testPattern.MatchString(entry.Name()) {
				continue
			}
			name := "test/powershell/" + layer + "/" + entry.Name()
			if !trackedSet[name] {
				return "", inv, catalog, fmt.Errorf("canonical suite is not tracked")
			}
			b, e := readShardRegular(filepath.Join(root, filepath.FromSlash(name)))
			if e != nil {
				return "", inv, catalog, e
			}
			engine := "powershell"
			if name == "test/powershell/integration/managed_catalog_tests.ps1" {
				engine = "pwsh"
			}
			catalog.Tests = append(catalog.Tests, rc.PowerShellShardTest{File: name, SHA256: fmt.Sprintf("%x", sha256.Sum256(b)), Engine: engine})
		}
	}
	sort.Slice(catalog.Sources, func(i, j int) bool { return catalog.Sources[i].File < catalog.Sources[j].File })
	sort.Slice(catalog.Tests, func(i, j int) bool { return catalog.Tests[i].File < catalog.Tests[j].File })
	wrapper := "test/powershell/coverage/safe_suite.ps1"
	if !trackedSet[wrapper] {
		return "", inv, catalog, fmt.Errorf("canonical wrapper is not tracked")
	}
	b, err := readShardRegular(filepath.Join(root, filepath.FromSlash(wrapper)))
	if err != nil {
		return "", inv, catalog, err
	}
	catalog.Wrapper = rc.PowerShellShardSource{File: wrapper, SHA256: fmt.Sprintf("%x", sha256.Sum256(b))}
	if len(catalog.Sources) == 0 || len(catalog.Tests) < o.count {
		return "", inv, catalog, fmt.Errorf("empty source or incomplete matrix test scope")
	}
	b, err = readShardRegular(o.manifest)
	if err != nil {
		return "", inv, catalog, err
	}
	// json.Decoder's normal matching is case insensitive. Explicitly inspect the
	// object to reject duplicate names and case aliases before typed decoding.
	d := json.NewDecoder(bytes.NewReader(b))
	token, e := d.Token()
	if e != nil || token != json.Delim('{') {
		return "", inv, catalog, fmt.Errorf("invalid canonical manifest")
	}
	keys := map[string]bool{}
	allowed := map[string]bool{"SourceRoot": true, "Sources": true, "Tests": true, "TestEngines": true, "Wrapper": true}
	for d.More() {
		key, e := d.Token()
		if e != nil {
			return "", inv, catalog, e
		}
		name, ok := key.(string)
		if !ok || !allowed[name] || keys[name] {
			return "", inv, catalog, fmt.Errorf("unknown or duplicate canonical manifest field")
		}
		keys[name] = true
		var value json.RawMessage
		if e = d.Decode(&value); e != nil {
			return "", inv, catalog, e
		}
	}
	var m shardCollectionManifest
	if len(keys) != len(allowed) || decodeShardManifest(b, &m) != nil {
		return "", inv, catalog, fmt.Errorf("incomplete canonical manifest")
	}
	manifestRoot, err := filepath.Abs(m.SourceRoot)
	if err != nil || !strings.EqualFold(filepath.Clean(manifestRoot), root) {
		return "", inv, catalog, fmt.Errorf("canonical root differs from original source")
	}
	sources, tests := []string{}, []string{}
	engines := map[string]string{}
	for _, s := range catalog.Sources {
		sources = append(sources, s.File)
	}
	for _, test := range catalog.Tests {
		tests = append(tests, test.File)
		if test.Engine != "powershell" {
			engines[test.File] = test.Engine
		}
	}
	if !reflect.DeepEqual(m.Sources, sources) || !reflect.DeepEqual(m.Tests, tests) || !reflect.DeepEqual(m.TestEngines, engines) || m.Wrapper != catalog.Wrapper.File {
		return "", inv, catalog, fmt.Errorf("manifest does not retain complete canonical source, suite, wrapper or engine scope")
	}
	return root, inv, catalog, nil
}

func freshShardOutput(output string, inputs ...string) (string, error) {
	full, err := filepath.Abs(output)
	if err != nil {
		return "", err
	}
	if _, err = os.Lstat(full); !os.IsNotExist(err) {
		return "", fmt.Errorf("output must be fresh")
	}
	for _, input := range inputs {
		base, e := filepath.Abs(input)
		if e != nil {
			return "", e
		}
		rel, e := filepath.Rel(base, full)
		if e != nil && !strings.EqualFold(filepath.VolumeName(base), filepath.VolumeName(full)) {
			continue
		}
		if e != nil || rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
			return "", fmt.Errorf("output must be outside source and input")
		}
	}
	return full, nil
}
func writeShardJSON(path string, value any) error {
	b, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	_, err = f.Write(b)
	closed := f.Close()
	if err != nil {
		return err
	}
	return closed
}

func powershellShardPlan(args []string, out io.Writer) error {
	o, err := parseShardOptions("powershell-shard-plan", args, out)
	if err != nil {
		return err
	}
	root, _, catalog, err := trustedShardCatalog(o)
	if err != nil {
		return err
	}
	destination, err := freshShardOutput(o.output, root)
	if err != nil {
		return err
	}
	m := shardCollectionManifest{SourceRoot: root, Sources: []string{}, Tests: []string{}, TestEngines: map[string]string{}, Wrapper: catalog.Wrapper.File, ShardContext: &shardCollectionContext{Commit: o.commit, RunUrl: o.runURL, RunAttempt: o.attempt, ShardIndex: o.index, ShardCount: o.count, GlobalIndices: []int{}}}
	for _, s := range catalog.Sources {
		m.Sources = append(m.Sources, s.File)
	}
	for i, test := range catalog.Tests {
		if i%o.count == o.index {
			m.ShardContext.GlobalIndices = append(m.ShardContext.GlobalIndices, i)
			m.Tests = append(m.Tests, test.File)
			if test.Engine != "powershell" {
				m.TestEngines[test.File] = test.Engine
			}
		}
	}
	if err = os.Mkdir(destination, 0700); err != nil {
		return err
	}
	if err = writeShardJSON(filepath.Join(destination, "privatecollection_manifest.json"), m); err != nil {
		return err
	}
	fmt.Fprintf(out, "Prepared shard %d/%d with %d of %d suites and all %d sources.\n", o.index, o.count, len(m.Tests), len(catalog.Tests), len(m.Sources))
	return nil
}

func powershellShardPack(args []string, out io.Writer) error {
	o, err := parseShardOptions("powershell-shard-pack", args, out)
	if err != nil {
		return err
	}
	_, inv, catalog, err := trustedShardCatalog(o)
	if err != nil {
		return err
	}
	if _, err = os.Lstat(filepath.Join(o.evidence, "shard.json")); !os.IsNotExist(err) {
		return fmt.Errorf("shard envelope already exists")
	}
	proof, err := readShardFile(o.evidence, "evidence.json")
	if err != nil {
		return err
	}
	cache := map[string][]byte{"evidence.json": proof}
	read := func(name string) ([]byte, error) {
		if b, ok := cache[name]; ok {
			return b, nil
		}
		b, err := readShardFile(o.evidence, name)
		if err == nil {
			cache[name] = b
		}
		return b, err
	}
	validated, err := rc.ExportPowerShellRawEvidence(proof, read, inv)
	if err != nil {
		return fmt.Errorf("shard raw commands or denominator are invalid: %w", err)
	}
	entries, err := os.ReadDir(o.evidence)
	if err != nil || len(entries) != len(validated) {
		return fmt.Errorf("safe shard export contains unexpected files")
	}
	for _, entry := range entries {
		safe, ok := validated[entry.Name()]
		if !ok || entry.IsDir() {
			return fmt.Errorf("safe shard export contains an unapproved file")
		}
		actual, readErr := read(entry.Name())
		if readErr != nil || !bytes.Equal(actual, safe) {
			return fmt.Errorf("shard must retain exactly the validated typed safe-export bytes")
		}
	}
	var raw struct {
		Workers []struct {
			Index            int
			Evidence, Engine string
		}
	}
	if err = json.Unmarshal(proof, &raw); err != nil {
		return err
	}
	manifest := rc.PowerShellShardManifest{SchemaVersion: 1, Commit: o.commit, RunUrl: o.runURL, RunAttempt: o.attempt, ShardIndex: o.index, ShardCount: o.count, Sources: catalog.Sources, Tests: catalog.Tests, Wrapper: catalog.Wrapper}
	local := 0
	for global, test := range catalog.Tests {
		if global%o.count != o.index {
			continue
		}
		if local >= len(raw.Workers) {
			return fmt.Errorf("shard omitted a canonical suite")
		}
		worker := raw.Workers[local]
		name := fmt.Sprintf("worker_%d.json", local)
		if worker.Index != local || worker.Evidence != name || worker.Engine != test.Engine {
			return fmt.Errorf("worker order or engine does not match selected suite")
		}
		b, e := read(name)
		if e != nil {
			return e
		}
		var native struct {
			ProcessId int
			Context   *rc.PowerShellWorkerContext
		}
		if err = json.Unmarshal(b, &native); err != nil {
			return err
		}
		expectedContext := rc.PowerShellWorkerContext{Commit: o.commit, RunUrl: o.runURL, RunAttempt: o.attempt, ShardIndex: o.index, ShardCount: o.count, GlobalIndex: global, ProcessId: native.ProcessId, TestFile: test.File, TestSHA256: test.SHA256, WrapperFile: catalog.Wrapper.File, WrapperSHA256: catalog.Wrapper.SHA256}
		if native.Context == nil || *native.Context != expectedContext {
			return fmt.Errorf("native worker context does not match actual selected suite and workflow")
		}
		manifest.Workers = append(manifest.Workers, rc.PowerShellShardWorker{GlobalIndex: global, TestFile: test.File, TestSHA256: test.SHA256, Evidence: name, SHA256: fmt.Sprintf("%x", sha256.Sum256(b))})
		local++
	}
	if local != len(raw.Workers) {
		return fmt.Errorf("shard contains extra workers")
	}
	if _, _, _, err = trustedShardCatalog(o); err != nil {
		return err
	}
	for name, captured := range cache {
		actual, readErr := readShardFile(o.evidence, name)
		if readErr != nil || !bytes.Equal(actual, captured) {
			return fmt.Errorf("raw shard changed during validation")
		}
	}
	if err = writeShardJSON(filepath.Join(o.evidence, "shard.json"), manifest); err != nil {
		return err
	}
	fmt.Fprintf(out, "Packed validated shard %d/%d; only relative typed evidence is public.\n", o.index, o.count)
	return nil
}

func powershellShardMerge(args []string, out io.Writer) error {
	o, err := parseShardOptions("powershell-shard-merge", args, out)
	if err != nil {
		return err
	}
	root, inv, catalog, err := trustedShardCatalog(o)
	if err != nil {
		return err
	}
	destination, err := freshShardOutput(o.output, root, o.input)
	if err != nil {
		return err
	}
	entries, err := os.ReadDir(o.input)
	if err != nil || len(entries) != o.count {
		return fmt.Errorf("matrix artifact count is incomplete")
	}
	inputs := []rc.PowerShellShardInput{}
	for _, entry := range entries {
		dir := filepath.Join(o.input, entry.Name())
		info, e := os.Lstat(dir)
		if e != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("matrix inputs must be regular artifact directories")
		}
		data, e := readShardFile(dir, "shard.json")
		if e != nil {
			return e
		}
		captured := dir
		inputs = append(inputs, rc.PowerShellShardInput{Manifest: data, Read: func(name string) ([]byte, error) { return readShardFile(captured, name) }})
	}
	files, err := rc.MergePowerShellShards(rc.PowerShellShardIdentity{Commit: o.commit, RunUrl: o.runURL, RunAttempt: o.attempt, ShardCount: o.count}, catalog, inputs, inv)
	if err != nil {
		return err
	}
	if _, _, _, err = trustedShardCatalog(o); err != nil {
		return err
	}
	names := []string{}
	for name := range files {
		if name != "evidence.json" && name != "coverage.xml" && !regexp.MustCompile(`^worker_[0-9]+\.json$`).MatchString(name) {
			return fmt.Errorf("unexpected merged evidence output")
		}
		if name != "evidence.json" {
			names = append(names, name)
		}
	}
	sort.Strings(names)
	names = append(names, "evidence.json") // A complete proof is published last.
	if err = os.Mkdir(destination, 0700); err != nil {
		return err
	}
	for _, name := range names {
		if err = os.WriteFile(filepath.Join(destination, name), files[name], 0600); err != nil {
			return err
		}
	}
	fmt.Fprintf(out, "Merged %d same-attempt shards with all %d suites and %d PowerShell sources.\n", o.count, len(catalog.Tests), len(catalog.Sources))
	return nil
}
