package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
	a "windows_setup/script/test/acceptance"
	rc "windows_setup/script/test/repo_coverage"
)

func collect(args []string, out io.Writer) error {
	f := flag.NewFlagSet("collect", flag.ContinueOnError)
	f.SetOutput(out)
	root := f.String("source-root", "", "乾淨來源目錄")
	dest := f.String("output-dir", "", "外部全新產物目錄")
	sha := f.String("expected-sha", "", "預期提交")
	runURL := f.String("expected-run-url", "", "預期執行 URL")
	ge := f.String("go-evidence", "", "Go 身分與計數證據")
	gp := f.String("go-profile", "", "已合併 Go profile")
	pe := f.String("powershell-evidence", "", "PowerShell 原始 worker 證據")
	ce := f.String("cmd-evidence", "", "CMD 原始 probe 證據")
	me := f.String("managed-evidence", "", "Microsoft managed 原生合併證據")
	runtimeScope := f.Bool("runtime", false, "產生 PowerShell／C# runtime 範圍證據")
	if err := f.Parse(args); err != nil {
		return err
	}
	if *root == "" || *dest == "" || *sha == "" || f.NArg() != 0 || (*ge == "") != (*gp == "") || (*ge == "" && *pe == "" && *ce == "" && *me == "") {
		return fmt.Errorf("需要來源、全新輸出、提交與至少一組完整收集證據")
	}
	source, err := filepath.Abs(*root)
	if err != nil {
		return err
	}
	output, err := filepath.Abs(*dest)
	if err != nil {
		return err
	}
	relative, err := filepath.Rel(source, output)
	if err != nil {
		return err
	}
	if relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return fmt.Errorf("產物必須置於來源樹之外")
	}
	if _, err := os.Stat(output); !os.IsNotExist(err) {
		return fmt.Errorf("產物目錄已存在或無法存取")
	}
	git := func(args ...string) (string, error) {
		b, e := exec.Command("git", append([]string{"-C", source}, args...)...).Output()
		return strings.TrimSpace(string(b)), e
	}
	head, err := git("rev-parse", "HEAD")
	if err != nil {
		return err
	}
	if head != *sha {
		return fmt.Errorf("來源提交與預期不符")
	}
	status, err := git("status", "--porcelain", "--untracked-files=all")
	if err != nil {
		return err
	}
	if status != "" {
		return fmt.Errorf("來源必須乾淨，不能混入未提交變更")
	}
	inv, err := rc.ScanInventory(source)
	if err != nil {
		return err
	}
	var target rc.Inventory
	if *runtimeScope {
		target, err = rc.ScanRuntimeInventory(source)
		if err != nil {
			return err
		}
		if len(target.Blockers) != 0 {
			return fmt.Errorf("runtime source inventory blocked: %v", target.Blockers)
		}
		for _, s := range target.Sources {
			if s.Language == "powershell" && *pe == "" {
				return fmt.Errorf("runtime PowerShell evidence required")
			}
			if s.Language == "csharp" && *me == "" {
				return fmt.Errorf("runtime C# evidence required")
			}
		}
	}
	reports := []rc.Report{}
	catalogs := []rc.Catalog{}
	if *ge != "" {
		evidence, err := os.ReadFile(*ge)
		if err != nil {
			return err
		}
		profile, err := os.ReadFile(*gp)
		if err != nil {
			return err
		}
		files, err := a.OwnedGoFiles(source)
		if err != nil {
			return err
		}
		if _, err := a.ValidateCoverageEvidence(evidence, profile, files, *sha, *runURL); err != nil {
			return err
		}
		originals := map[string][]byte{}
		for _, s := range inv.Sources {
			if s.Language == "go" {
				b, e := os.ReadFile(filepath.Join(source, filepath.FromSlash(s.Path)))
				if e != nil {
					return e
				}
				originals[s.Path] = b
			}
		}
		report, lines, err := rc.NormalizeGo([][]byte{profile}, originals, "windows_setup")
		if err != nil {
			return err
		}
		reports = append(reports, report)
		catalogs = append(catalogs, lines...)
	}
	if *pe != "" {
		evidence, err := os.ReadFile(*pe)
		if err != nil {
			return err
		}
		psInventory := inv
		if *runtimeScope {
			psInventory = target
		}
		report, lines, err := rc.NormalizePowerShell(evidence, func(name string) ([]byte, error) {
			return os.ReadFile(filepath.Join(filepath.Dir(*pe), filepath.FromSlash(name)))
		}, psInventory)
		if err != nil {
			return err
		}
		reports = append(reports, report)
		catalogs = append(catalogs, lines...)
	}
	if *ce != "" {
		data, err := os.ReadFile(*ce)
		if err != nil {
			return err
		}
		evidence, err := rc.DecodeCMDEvidence(data)
		if err != nil {
			return err
		}
		originals := map[string][]byte{}
		for _, s := range inv.Sources {
			if s.Language == "cmd" {
				b, e := os.ReadFile(filepath.Join(source, filepath.FromSlash(s.Path)))
				if e != nil {
					return e
				}
				originals[s.Path] = b
			}
		}
		report, lines, err := rc.NormalizeCMD(evidence, originals)
		if err != nil {
			return err
		}
		reports = append(reports, report)
		catalogs = append(catalogs, lines...)
	}
	if *me != "" {
		data, err := os.ReadFile(*me)
		if err != nil {
			return err
		}
		originals := map[string][]byte{}
		managedInventory := inv
		if *runtimeScope {
			managedInventory = target
		}
		for _, s := range managedInventory.Sources {
			if s.Language == "csharp" {
				b, e := os.ReadFile(filepath.Join(source, filepath.FromSlash(s.Path)))
				if e != nil {
					return e
				}
				originals[s.Path] = b
			}
		}
		report, lines, err := rc.NormalizeManaged(data, func(name string) ([]byte, error) {
			return os.ReadFile(filepath.Join(filepath.Dir(*me), filepath.FromSlash(name)))
		}, originals)
		if err != nil {
			return err
		}
		reports = append(reports, report)
		catalogs = append(catalogs, lines...)
	}
	if *runtimeScope {
		allowed := map[string]bool{}
		for _, s := range target.Sources {
			allowed[s.Path] = true
		}
		for i := range reports {
			for name := range reports[i].Files {
				if !allowed[name] {
					delete(reports[i].Files, name)
				}
			}
		}
		kept := catalogs[:0]
		for _, c := range catalogs {
			if allowed[c.Path] {
				kept = append(kept, c)
			}
		}
		catalogs = kept
		inv = target
	}
	inv, err = rc.BindCatalogs(inv, catalogs)
	if err != nil {
		return err
	}
	identity := rc.Identity{Commit: *sha, RunUrl: *runURL, MeasuredAt: time.Now().UTC().Format(time.RFC3339), SourceState: "Clean"}
	var artifacts rc.Artifacts
	if *runtimeScope {
		artifacts, err = rc.CreateRuntimeEvidence(inv, reports, identity)
	} else {
		artifacts, err = rc.CreateEvidence(inv, reports, identity)
	}
	if err != nil {
		return err
	}
	// Recheck the live source roster after reading raw evidence, before publishing.
	if *runtimeScope {
		err = rc.ValidateRuntimeInventory(source, artifacts.Inventory)
	} else {
		err = rc.ValidateInventory(source, artifacts.Inventory)
	}
	if err != nil {
		return err
	}
	if err := os.Mkdir(output, 0700); err != nil {
		return err
	}
	for name, data := range map[string][]byte{"repo_coverage.json": artifacts.Summary, "coverage_inventory.json": artifacts.Inventory, "coverage.xml": artifacts.XML} {
		if err := os.WriteFile(filepath.Join(output, name), data, 0600); err != nil {
			return err
		}
	}
	fmt.Fprintln(out, "已產生三檔證據；發布前請執行 verify --require-complete --minimum-percent 80")
	return nil
}
