package repo_coverage

import (
	"crypto/sha256"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

type Exclusion struct{ Path, Reason string }
type Inventory struct {
	Sources  []Source
	Excluded []Exclusion
	Blockers []string
}

func (inventory Inventory) Merge(reports ...Report) (Result, error) {
	r, err := Merge(inventory.Sources, reports...)
	if err != nil {
		return r, err
	}
	r.Blockers = append([]string(nil), inventory.Blockers...)
	if len(r.Blockers) > 0 {
		r.Complete = false
		r.Percent = nil
	}
	return r, nil
}

var languageExtensions = map[string]string{".go": "go", ".ps1": "powershell", ".psm1": "powershell", ".cmd": "cmd", ".bat": "cmd", ".cs": "csharp", ".js": "javascript"}
var executableExtensions = map[string]bool{".py": true, ".sh": true, ".bash": true, ".ts": true, ".tsx": true, ".jsx": true, ".rb": true, ".rs": true, ".c": true, ".cpp": true, ".cxx": true, ".fs": true, ".vbs": true, ".pl": true, ".lua": true}
var inlineLogic = regexp.MustCompile(`(?i)(\b(if|foreach|while|for|switch|try|catch|throw|function|return)\b|\$LASTEXITCODE|\bexit\s+[0-9$]|\biferrorlevel\b)`)
var addType = regexp.MustCompile(`(?im)\bAdd-Type\b([^\r\n]*)`)
var methodBody = regexp.MustCompile(`(?s)(\)\s*(\{|=>)|\b(get|set)\s*(\{|=>)|=>|=\s*new\b|=\s*[A-Za-z_]\w*\s*\()`)
var javascriptPath = regexp.MustCompile(`(?i)\.js\b`)
var externalAddType = regexp.MustCompile(`(?i)^(?:-ReferencedAssemblies\s+(?:'[^']+'|"[^"]+")(?:\s*,\s*(?:'[^']+'|"[^"]+"))*\s+)?-(?:Path|AssemblyName)\s+`)

// Embedded C# is not considered covered when PowerShell executes Add-Type.
// Only literal declaration-only snippets are classified here; unknown dynamic
// code remains a blocker, rather than being guessed to have no executable lines.
func embeddedCSharp(text string) (managed, declared bool) {
	for _, loc := range addType.FindAllStringSubmatchIndex(text, -1) {
		tail := strings.TrimSpace(text[loc[2]:loc[3]])
		if externalAddType.MatchString(tail) {
			continue
		}
		tail = regexp.MustCompile(`(?i)^-TypeDefinition\s+`).ReplaceAllString(tail, "")
		var body string
		if strings.HasPrefix(tail, `@"`) || strings.HasPrefix(tail, "@'") {
			quote := tail[1:2]
			remaining := text[loc[3]:]
			end := strings.Index(remaining, quote+"@")
			if end < 0 {
				return true, declared
			}
			body = remaining[:end]
		} else if strings.HasPrefix(tail, "'") {
			end := strings.Index(tail[1:], "'")
			if end < 0 {
				return true, declared
			}
			body = tail[1 : 1+end]
		} else {
			return true, declared
		}
		if methodBody.MatchString(body) {
			managed = true
		} else {
			declared = true
		}
	}
	return
}

func workflowHasLogic(text string) bool {
	lines := strings.Split(text, "\n")
	for i, line := range lines {
		trim := strings.TrimSpace(line)
		key := strings.TrimSpace(strings.TrimPrefix(trim, "-"))
		if !strings.HasPrefix(key, "run:") && !strings.HasPrefix(key, "script:") {
			continue
		}
		body := strings.SplitN(key, ":", 2)[1]
		indent := len(line) - len(strings.TrimLeft(line, " \t"))
		if strings.TrimSpace(body) == "|" || strings.TrimSpace(body) == ">" {
			for j := i + 1; j < len(lines); j++ {
				next := lines[j]
				if strings.TrimSpace(next) == "" {
					continue
				}
				n := len(next) - len(strings.TrimLeft(next, " \t"))
				if n <= indent {
					break
				}
				body += "\n" + next
			}
		}
		if inlineLogic.MatchString(body) {
			return true
		}
	}
	return false
}

func dockerHasLogic(text string) bool {
	lines := strings.Split(text, "\n")
	for i, line := range lines {
		if !strings.HasPrefix(strings.TrimSpace(strings.ToUpper(line)), "RUN ") {
			continue
		}
		body := line
		for j := i + 1; j < len(lines) && (strings.HasSuffix(strings.TrimSpace(line), "`") || strings.HasSuffix(strings.TrimSpace(line), `\`)); j++ {
			line = lines[j]
			body += "\n" + line
		}
		if inlineLogic.MatchString(body) {
			return true
		}
	}
	return false
}

// ScanInventory is deliberately independent of which files tests happened to
// load. It lists production and maintenance programs, retaining missing or
// unsupported collectors as blockers. Exclusions are published with reasons.
func ScanInventory(root string) (Inventory, error) {
	return scanInventory(root, false)
}

func scanInventory(root string, runtime bool) (Inventory, error) {
	var inv Inventory
	info, err := os.Stat(root)
	if err != nil {
		return inv, err
	}
	if !info.IsDir() {
		return inv, fmt.Errorf("inventory root is not a directory")
	}
	err = filepath.WalkDir(root, func(full string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		rel, e := filepath.Rel(root, full)
		if e != nil {
			return e
		}
		rel = filepath.ToSlash(rel)
		if rel == "." {
			return nil
		}
		lower := strings.ToLower(rel)
		if entry.Type()&os.ModeSymlink != 0 {
			inv.Blockers = append(inv.Blockers, rel+": source symlink requires explicit review")
			return nil
		}
		if entry.IsDir() {
			reason := ""
			switch {
			case rel == "worktree":
				reason = "local development worktrees"
			case lower == ".git":
				reason = "version-control metadata"
			case lower == "vendor" || (!runtime && strings.EqualFold(entry.Name(), "win11debloat")) || (runtime && strings.EqualFold(rel, "modules/debloat/win11debloat")):
				reason = "third-party source"
			case lower == "test":
				reason = "test fixtures and test cases"
			case lower == "doc" || lower == "docs":
				reason = "documentation"
			case lower == "reports" || lower == "coverage":
				reason = "generated per-run evidence"
			}
			if reason != "" {
				inv.Excluded = append(inv.Excluded, Exclusion{rel + "/", reason})
				return filepath.SkipDir
			}
			return nil
		}
		ext := strings.ToLower(filepath.Ext(rel))
		if strings.HasSuffix(lower, "_test.go") {
			inv.Excluded = append(inv.Excluded, Exclusion{rel, "test case"})
			return nil
		}
		if language, ok := languageExtensions[ext]; ok {
			data, e := os.ReadFile(full)
			if e != nil {
				return e
			}
			inv.Sources = append(inv.Sources, Source{Path: rel, Language: language, SHA256: fmt.Sprintf("%x", sha256.Sum256(data))})
			if language == "cmd" {
				if _, err := ParseCMDLauncher(data); err != nil {
					inv.Blockers = append(inv.Blockers, rel+": unsupported CMD executable syntax requires collector support")
				} else {
					inv.Excluded = append(inv.Excluded, Exclusion{rel + "#echo", "shell display directive @echo off has no setup executable point"})
				}
			}
			if language == "powershell" {
				data, e := os.ReadFile(full)
				if e != nil {
					return e
				}
				text := string(data)
				managed, declared := embeddedCSharp(text)
				if managed {
					inv.Blockers = append(inv.Blockers, rel+": embedded managed C# needs its own executable-line evidence")
				}
				if declared {
					inv.Excluded = append(inv.Excluded, Exclusion{rel + "#csharp", "interop declaration-only snippet has no managed executable body"})
				}
				if javascriptPath.MatchString(text) && strings.Contains(text, "WriteAllText") || regexp.MustCompile(`(?is)<script\s*>\s*[^<\s]`).MatchString(text) {
					inv.Blockers = append(inv.Blockers, rel+": embedded JavaScript needs its own executable-line evidence")
				}
			}
			return nil
		}
		if executableExtensions[ext] {
			inv.Blockers = append(inv.Blockers, rel+": unsupported executable language")
			return nil
		}
		if ext == ".yml" || ext == ".yaml" || ext == ".dockerfile" || strings.EqualFold(filepath.Base(rel), "Dockerfile") {
			data, e := os.ReadFile(full)
			if e != nil {
				return e
			}
			logic := workflowHasLogic(string(data))
			if ext == ".dockerfile" || strings.EqualFold(filepath.Base(rel), "Dockerfile") {
				logic = dockerHasLogic(string(data))
			}
			if logic {
				inv.Blockers = append(inv.Blockers, rel+": inline control flow must be extracted into measured source")
			}
			inv.Excluded = append(inv.Excluded, Exclusion{rel, "declarative build/workflow configuration; simple invocation and environment glue are not program-source lines"})
			return nil
		}
		inv.Excluded = append(inv.Excluded, Exclusion{rel, "non-executable data, documentation, or dependency artifact"})
		return nil
	})
	sort.Slice(inv.Sources, func(i, j int) bool { return inv.Sources[i].Path < inv.Sources[j].Path })
	sort.Strings(inv.Blockers)
	return inv, err
}
