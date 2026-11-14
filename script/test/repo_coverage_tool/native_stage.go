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
	"regexp"
	"sort"
	"strings"

	a "windows_setup/script/test/acceptance"
)

type nativeStageFile struct {
	Path   string
	Bytes  int64
	SHA256 string
}
type nativeStageMetadata struct {
	SchemaVersion    int
	Kind             string
	Complete         bool
	Publishable      bool
	Commit           string
	RunUrl           string
	RunAttempt       int
	NativeChecks     int
	NativeAssertions int
	Files            []nativeStageFile
}
type nativeStageOptions struct {
	source, report, goDir, input, output, commit, run string
	attempt                                           int
	runtime                                           bool
}

var nativeReportFiles = []string{"coverage.svg", "index.html", "integration.svg", "junit.xml", "summary.json", "summary.md", "unit.svg"}
var nativeGoFiles = []string{"go_coverage.json", "go_coverage.out"}

func nativeStage(command string, args []string, out io.Writer) error {
	o := nativeStageOptions{}
	f := flag.NewFlagSet(command, flag.ContinueOnError)
	f.SetOutput(out)
	f.StringVar(&o.source, "source-root", "", "same clean source")
	f.StringVar(&o.commit, "expected-sha", "", "same source commit")
	f.StringVar(&o.run, "expected-run-url", "", "same workflow run")
	f.IntVar(&o.attempt, "run-attempt", 0, "same workflow attempt")
	f.BoolVar(&o.runtime, "runtime", false, "native stage without Go coverage")
	f.StringVar(&o.output, "output-dir", "", "fresh external output")
	if command == "native-stage-pack" {
		f.StringVar(&o.report, "report-dir", "", "fresh native All report")
		f.StringVar(&o.goDir, "go-dir", "", "original Go evidence")
	} else {
		f.StringVar(&o.input, "input-dir", "", "incomplete native stage")
	}
	if err := f.Parse(args); err != nil {
		return err
	}
	if o.runtime && o.goDir != "" {
		return fmt.Errorf("runtime stage does not accept Go coverage input")
	}
	if f.NArg() != 0 || o.source == "" || o.output == "" || o.attempt < 1 || !regexp.MustCompile(`^[a-f0-9]{40}$`).MatchString(o.commit) || !regexp.MustCompile(`^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/actions/runs/[1-9][0-9]*$`).MatchString(o.run) {
		return fmt.Errorf("complete native stage source and workflow identity are required")
	}
	source, err := nativeStageDirectory(o.source)
	if err != nil {
		return err
	}
	o.source = source
	head, err := exec.Command("git", "-C", source, "rev-parse", "HEAD").Output()
	if err != nil || strings.TrimSpace(string(head)) != o.commit {
		return fmt.Errorf("native stage source commit differs")
	}
	status, err := exec.Command("git", "-C", source, "status", "--porcelain", "--untracked-files=all").Output()
	if err != nil || len(bytes.TrimSpace(status)) != 0 {
		return fmt.Errorf("native stage requires clean source")
	}
	data := map[string][]byte{}
	metadata := nativeStageMetadata{SchemaVersion: 1, Kind: "NativeAndGoStage", Commit: o.commit, RunUrl: o.run, RunAttempt: o.attempt}
	if o.runtime {
		metadata.SchemaVersion = 2
		metadata.Kind = "NativeRuntimeStage"
	}
	inputs := []string{source}
	if command == "native-stage-pack" {
		groups := []struct {
			path, prefix string
			files        []string
		}{{o.report, "report", nativeReportFiles}}
		if !o.runtime {
			groups = append(groups, struct {
				path, prefix string
				files        []string
			}{o.goDir, "go", nativeGoFiles})
		}
		for _, group := range groups {
			dir, e := nativeStageDirectory(group.path)
			if e != nil {
				return e
			}
			inputs = append(inputs, dir)
			if nativeStageOverlaps(dir, source) {
				return fmt.Errorf("native stage inputs must remain outside source")
			}
			if e = readNativeStageGroup(dir, group.prefix, group.files, data); e != nil {
				return e
			}
		}
	} else {
		input, e := nativeStageDirectory(o.input)
		if e != nil {
			return e
		}
		inputs = append(inputs, input)
		entries, e := os.ReadDir(input)
		count := 3
		if o.runtime {
			count = 2
		}
		if e != nil || len(entries) != count {
			return fmt.Errorf("native stage must contain only its exact three roots")
		}
		for _, entry := range entries {
			if entry.Name() != "stage.json" && entry.Name() != "report" && !(!o.runtime && entry.Name() == "go") {
				return fmt.Errorf("unknown native stage entry")
			}
		}
		raw, e := readNativeStageFile(filepath.Join(input, "stage.json"))
		if e != nil {
			return e
		}
		if e = decodeShardManifest(raw, &metadata); e != nil {
			return fmt.Errorf("invalid typed native stage metadata")
		}
		canonical, _ := json.MarshalIndent(metadata, "", "  ")
		version, kind := 1, "NativeAndGoStage"
		if o.runtime {
			version, kind = 2, "NativeRuntimeStage"
		}
		if !bytes.Equal(raw, canonical) || metadata.SchemaVersion != version || metadata.Kind != kind || metadata.Complete || metadata.Publishable || metadata.Commit != o.commit || metadata.RunUrl != o.run || metadata.RunAttempt != o.attempt {
			return fmt.Errorf("native stage identity, canonical fields or partial state differs")
		}
		groups := []struct {
			prefix string
			files  []string
		}{{"report", nativeReportFiles}}
		if !o.runtime {
			groups = append(groups, struct {
				prefix string
				files  []string
			}{"go", nativeGoFiles})
		}
		for _, group := range groups {
			dir, e := nativeStageDirectory(filepath.Join(input, group.prefix))
			if e != nil {
				return e
			}
			if e = readNativeStageGroup(dir, group.prefix, group.files, data); e != nil {
				return e
			}
		}
		files := nativeStageHashes(data)
		encoded, _ := json.Marshal(files)
		expected, _ := json.Marshal(metadata.Files)
		if !bytes.Equal(encoded, expected) {
			return fmt.Errorf("native stage file set, sizes or original hashes differ")
		}
	}
	r, err := validateNativeStageEvidence(o, data)
	if err != nil {
		return err
	}
	if command != "native-stage-pack" && (metadata.NativeChecks != len(r.Checks) || metadata.NativeAssertions != r.Totals.AssertionsExecuted) {
		return fmt.Errorf("native stage counters differ from original evidence")
	}
	output, err := nativeStageOutput(o.output, inputs)
	if err != nil {
		return err
	}
	if err = os.Mkdir(output, 0700); err != nil {
		return fmt.Errorf("cannot create fresh native stage output")
	}
	groups := []string{"report"}
	if !o.runtime {
		groups = append(groups, "go")
	}
	for _, group := range groups {
		if err = os.Mkdir(filepath.Join(output, group), 0700); err != nil {
			return fmt.Errorf("cannot create native stage group")
		}
	}
	for name, original := range data {
		file, e := os.OpenFile(filepath.Join(output, filepath.FromSlash(name)), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if e != nil {
			return fmt.Errorf("cannot create native stage evidence")
		}
		_, writeErr := file.Write(original)
		closeErr := file.Close()
		if writeErr != nil || closeErr != nil {
			return fmt.Errorf("cannot preserve native stage evidence bytes")
		}
	}
	if command == "native-stage-pack" {
		metadata.NativeChecks, metadata.NativeAssertions, metadata.Files = len(r.Checks), r.Totals.AssertionsExecuted, nativeStageHashes(data)
		if err = writeShardJSON(filepath.Join(output, "stage.json"), metadata); err != nil {
			return fmt.Errorf("cannot write native stage metadata")
		}
	}
	if o.runtime {
		fmt.Fprintf(out, "Native All runtime stage verified: checks=%d assertions=%d; coverage incomplete, not publishable.\n", len(r.Checks), r.Totals.AssertionsExecuted)
	} else {
		fmt.Fprintf(out, "Native All and Go stage verified: checks=%d assertions=%d; whole coverage incomplete, not publishable.\n", len(r.Checks), r.Totals.AssertionsExecuted)
	}
	return nil
}

func nativeStageDirectory(path string) (string, error) {
	if path == "" {
		return "", fmt.Errorf("native stage directory is required")
	}
	full, err := filepath.Abs(path)
	if err != nil {
		return "", fmt.Errorf("invalid native stage directory")
	}
	for current := full; ; current = filepath.Dir(current) {
		info, e := os.Lstat(current)
		if e != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			return "", fmt.Errorf("native stage directory cannot be missing or cross a link")
		}
		if filepath.Dir(current) == current {
			break
		}
	}
	canonical, err := filepath.EvalSymlinks(full)
	if err != nil {
		return "", fmt.Errorf("cannot resolve native stage directory")
	}
	return canonical, nil
}
func nativeStageOverlaps(first, second string) bool {
	for _, pair := range [][2]string{{first, second}, {second, first}} {
		rel, err := filepath.Rel(pair[0], pair[1])
		if err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
			return true
		}
	}
	return false
}
func nativeStageOutput(path string, inputs []string) (string, error) {
	full, err := filepath.Abs(path)
	if err != nil {
		return "", fmt.Errorf("invalid native stage output")
	}
	if _, err = os.Lstat(full); !os.IsNotExist(err) {
		return "", fmt.Errorf("native stage output must be fresh")
	}
	parent, err := nativeStageDirectory(filepath.Dir(full))
	if err != nil {
		return "", err
	}
	full = filepath.Join(parent, filepath.Base(full))
	for _, input := range inputs {
		if nativeStageOverlaps(full, input) {
			return "", fmt.Errorf("native stage output overlaps source or evidence")
		}
	}
	return full, nil
}
func readNativeStageFile(path string) ([]byte, error) {
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Size() <= 0 || info.Size() > 33554432 {
		return nil, fmt.Errorf("native stage evidence must be a bounded regular file")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("cannot read fixed native stage evidence")
	}
	return data, nil
}
func readNativeStageGroup(dir, prefix string, allowed []string, data map[string][]byte) error {
	entries, err := os.ReadDir(dir)
	if err != nil || len(entries) != len(allowed) {
		return fmt.Errorf("native stage group file set is incomplete or contains extras")
	}
	for i, entry := range entries {
		if entry.Name() != allowed[i] {
			return fmt.Errorf("native stage group has an unknown or aliased file")
		}
		original, e := readNativeStageFile(filepath.Join(dir, entry.Name()))
		if e != nil {
			return e
		}
		data[prefix+"/"+entry.Name()] = original
	}
	return nil
}
func nativeStageHashes(data map[string][]byte) []nativeStageFile {
	files := make([]nativeStageFile, 0, len(data))
	for name, original := range data {
		files = append(files, nativeStageFile{Path: name, Bytes: int64(len(original)), SHA256: fmt.Sprintf("%x", sha256.Sum256(original))})
	}
	sort.Slice(files, func(i, j int) bool { return files[i].Path < files[j].Path })
	return files
}
func validateNativeStageEvidence(o nativeStageOptions, data map[string][]byte) (a.Report, error) {
	read := func(name string) ([]byte, error) {
		b, ok := data["report/"+name]
		if !ok {
			return nil, fmt.Errorf("missing fixed native report file")
		}
		return b, nil
	}
	r, err := a.ValidateReport(read, o.commit, o.run, false)
	if err != nil {
		return r, err
	}
	var summary map[string]json.RawMessage
	if err = json.Unmarshal(data["report/summary.json"], &summary); err != nil {
		return r, err
	}
	_, hasGo := summary["GoCoverage"]
	_, hasRepo := summary["RepoCoverage"]
	if r.SchemaVersion != 2 || !r.Success || r.Coverage != "NotMeasured" || hasGo || hasRepo || r.Totals.UnexecutedSuites != 0 || r.Totals.AssertionsExecuted < 1 || r.RefType != "Branch" && r.RefType != "Release" {
		return r, fmt.Errorf("native stage must be fresh successful All evidence without coverage attachments")
	}
	tracked, err := exec.Command("git", "-C", o.source, "ls-files").Output()
	if err != nil {
		return r, fmt.Errorf("cannot verify native source roster")
	}
	expected := map[string]string{"PowerShell 5.1 語法": "Static"}
	pattern := regexp.MustCompile(`^test/powershell/(unit|integration)/([a-z0-9_]+)_tests\.ps1$`)
	for _, path := range strings.Split(strings.ReplaceAll(string(tracked), "\r\n", "\n"), "\n") {
		match := pattern.FindStringSubmatch(path)
		if match != nil {
			layer := "Unit"
			if match[1] == "integration" {
				layer = "Integration"
			}
			expected[layer+"."+match[2]] = layer
		}
	}
	if len(expected) != len(r.Checks) {
		return r, fmt.Errorf("native All report does not match complete source roster")
	}
	for _, check := range r.Checks {
		if expected[check.Name] != check.Layer || !check.Executed || check.Passed == nil || !*check.Passed || check.Status != "Passed" {
			return r, fmt.Errorf("native source roster contains missing, duplicate or unsuccessful suite")
		}
		delete(expected, check.Name)
	}
	if o.runtime {
		return r, nil
	}
	files, err := a.OwnedGoFiles(o.source)
	if err != nil {
		return r, err
	}
	if _, err = a.ValidateCoverageEvidence(data["go/go_coverage.json"], data["go/go_coverage.out"], files, o.commit, o.run); err != nil {
		return r, err
	}
	return r, nil
}
