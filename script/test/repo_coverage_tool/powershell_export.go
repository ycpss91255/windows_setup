package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	rc "windows_setup/script/test/repo_coverage"
)

func exportPowerShell(args []string, out io.Writer) error {
	f := flag.NewFlagSet("export-powershell", flag.ContinueOnError)
	f.SetOutput(out)
	runtime := f.Bool("runtime", false, "restrict inventory to runtime coverage")
	source := f.String("source-root", "", "original source root")
	input := f.String("evidence-dir", "", "completed PowerShell collector directory")
	destination := f.String("output-dir", "", "new external safe export directory")
	if err := f.Parse(args); err != nil {
		return err
	}
	if *source == "" || *input == "" || *destination == "" || f.NArg() != 0 {
		return fmt.Errorf("source, evidence and new output directories are required")
	}
	output, err := filepath.Abs(*destination)
	if err != nil {
		return fmt.Errorf("invalid output directory")
	}
	for _, base := range []string{*source, *input} {
		absolute, err := filepath.Abs(base)
		if err != nil {
			return fmt.Errorf("invalid evidence directory")
		}
		relative, err := filepath.Rel(absolute, output)
		if err != nil && !strings.EqualFold(filepath.VolumeName(absolute), filepath.VolumeName(output)) {
			continue // Different absolute volumes cannot place output inside this input.
		}
		if err != nil || relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
			return fmt.Errorf("raw output must be outside source and input")
		}
	}
	if _, err := os.Lstat(output); !os.IsNotExist(err) {
		return fmt.Errorf("raw output already exists or cannot be inspected")
	}
	var inventory rc.Inventory
	if *runtime {
		inventory, err = rc.ScanRuntimeInventory(*source)
	} else {
		inventory, err = rc.ScanInventory(*source)
	}
	if err != nil {
		return fmt.Errorf("cannot inspect original source")
	}
	read := func(name string) ([]byte, error) {
		if name != "evidence.json" && name != "coverage.xml" && !regexp.MustCompile(`^worker_[0-9]+\.json$`).MatchString(name) {
			return nil, fmt.Errorf("unapproved raw evidence name")
		}
		path := filepath.Join(*input, name)
		info, err := os.Lstat(path)
		if err != nil || !info.Mode().IsRegular() || info.Size() > 536870912 {
			return nil, fmt.Errorf("invalid raw evidence file")
		}
		return os.ReadFile(path)
	}
	proof, err := read("evidence.json")
	if err != nil {
		return err
	}
	files, err := rc.ExportPowerShellRawEvidence(proof, read, inventory)
	if err != nil {
		return fmt.Errorf("raw PowerShell identity or executable evidence is invalid")
	}
	if err := os.Mkdir(output, 0700); err != nil {
		return fmt.Errorf("cannot create fresh raw output")
	}
	for name, bytes := range files {
		if err := os.WriteFile(filepath.Join(output, name), bytes, 0600); err != nil {
			return fmt.Errorf("cannot write safe raw evidence")
		}
	}
	fmt.Fprintf(out, "Exported %d validated relative-path PowerShell JSON/XML files; no logs or collection manifests.\n", len(files))
	return nil
}
