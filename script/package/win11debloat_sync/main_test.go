package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

func TestFixedPinMatchesDebloatProfile(t *testing.T) {
	b, e := os.ReadFile("../../../modules/debloat/debloat_profile.json")
	if e != nil {
		t.Fatal(e)
	}
	var p struct{ Source, Commit string }
	if e = json.Unmarshal(bytes.TrimPrefix(b, []byte{0xef, 0xbb, 0xbf}), &p); e != nil {
		t.Fatal(e)
	}
	if p.Source != "https://github.com/Raphire/Win11Debloat" || p.Commit != upstream.commit {
		t.Fatal("profile source differs from fixed upstream pin")
	}
}

func TestReviewedLockPreservesRuntimeAndLicense(t *testing.T) {
	l, e := loadLock("upstream.lock.json", upstream)
	if e != nil {
		t.Fatal(e)
	}
	files := map[string]bool{}
	for _, f := range l.Files {
		files[f.Path] = f.Retain
	}
	for _, name := range []string{"Win11Debloat.ps1", "LICENSE", "README.md", ".gitignore", "Config/Features.json", "Config/Languages/en-US/Chrome.json", "Config/Languages/zh-TW/Chrome.json", "Assets/Start/start2.bin"} {
		if !files[name] {
			t.Fatalf("required file omitted: %s", name)
		}
	}
}

func TestBundledVendorMatchesReviewedLock(t *testing.T) {
	l, e := loadLock("upstream.lock.json", upstream)
	if e != nil {
		t.Fatal(e)
	}
	if e = verify("../../../modules/debloat/win11debloat", l); e != nil {
		t.Fatal(e)
	}
	mainScript, e := os.ReadFile("../../../modules/debloat/win11debloat/Win11Debloat.ps1")
	if e != nil {
		t.Fatal(e)
	}
	refs := regexp.MustCompile(`(?m)^\.\s+"\$PSScriptRoot/(Scripts/[^"\r\n]+\.ps1)"`).FindAllSubmatch(mainScript, -1)
	if len(refs) != 80 {
		t.Fatalf("unexpected upstream startup script count: %d", len(refs))
	}
	retainedPaths := map[string]bool{}
	for _, f := range l.Files {
		if f.Retain {
			retainedPaths[f.Path] = true
		}
	}
	for _, ref := range refs {
		if !retainedPaths[string(ref[1])] {
			t.Fatalf("startup script omitted: %s", ref[1])
		}
	}
}

func syncFixture(t *testing.T) (string, pin) {
	t.Helper()
	root := t.TempDir()
	for name, content := range map[string]string{"Win11Debloat.ps1": "# fixed upstream\n", "LICENSE": "fixture license\n", ".gitignore": "Backups/*\n", "Tests/example.ps1": "# not runtime\n", "Scripts/Get.ps1": "# retained\n", "Scripts/Build-Release.ps1": "# development\n", "Scripts/Run-Tests.ps1": "# development\n", ".github/workflows/test.yml": "# development\n"} {
		p := filepath.Join(root, filepath.FromSlash(name))
		if e := os.MkdirAll(filepath.Dir(p), 0700); e != nil {
			t.Fatal(e)
		}
		if e := os.WriteFile(p, []byte(content), 0600); e != nil {
			t.Fatal(e)
		}
	}
	git := func(args ...string) string {
		t.Helper()
		cmd := exec.Command("git", append([]string{"-C", root}, args...)...)
		b, e := cmd.CombinedOutput()
		if e != nil {
			t.Fatalf("fixture git: %v %s", e, b)
		}
		return strings.TrimSpace(string(b))
	}
	git("init", "-q")
	git("add", ".")
	git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture")
	return root, pin{git("rev-parse", "HEAD"), git("rev-parse", "HEAD^{tree}"), 8, 3, ""}
}

func TestSourceGitBoundary(t *testing.T) {
	source, expected := syncFixture(t)
	nested := filepath.Join(source, "nested")
	if e := os.Mkdir(nested, 0700); e != nil {
		t.Fatal(e)
	}
	external := t.TempDir()
	lock := filepath.Join(external, "lock.json")
	if e := run([]string{"lock", "--source", source, "--output", lock}, &bytes.Buffer{}, expected); e != nil {
		t.Fatal(e)
	}
	data, e := os.ReadFile(lock)
	if e != nil {
		t.Fatal(e)
	}
	expected.lockSHA256 = fmt.Sprintf("%x", sha256.Sum256(data))
	good := filepath.Join(external, "external-stage")
	if e := run([]string{"stage", "--source", nested, "--lock", lock, "--output", good}, &bytes.Buffer{}, expected); e != nil {
		t.Fatalf("rejected external output for nested source: %v", e)
	}
	for _, tc := range []struct{ name, command, output string }{
		{"stage in worktree", "stage", filepath.Join(source, "staged_inside_worktree")},
		{"lock in worktree", "lock", filepath.Join(source, "lock_inside_worktree.json")},
		{"stage in control directory", "stage", filepath.Join(source, ".git", "staged_inside_control")},
	} {
		t.Run(tc.name, func(t *testing.T) {
			args := []string{tc.command, "--source", nested, "--output", tc.output}
			if tc.command == "stage" {
				args = append(args, "--lock", lock)
			}
			if e := run(args, &bytes.Buffer{}, expected); e == nil {
				t.Fatalf("accepted output inside source Git boundary: %s", tc.output)
			}
			if _, e := os.Lstat(tc.output); !os.IsNotExist(e) {
				t.Fatalf("invalid output was created: %s", tc.output)
			}
		})
	}
	t.Run("linked worktree common control directory", func(t *testing.T) {
		linked := filepath.Join(external, "linked")
		cmd := exec.Command("git", "-C", source, "worktree", "add", "--detach", linked, "HEAD")
		if b, e := cmd.CombinedOutput(); e != nil {
			t.Fatalf("linked worktree fixture: %v %s", e, b)
		}
		nestedLinked := filepath.Join(linked, "nested")
		if e := os.Mkdir(nestedLinked, 0700); e != nil {
			t.Fatal(e)
		}
		dest := filepath.Join(source, ".git", "linked-output")
		if e := run([]string{"stage", "--source", nestedLinked, "--lock", lock, "--output", dest}, &bytes.Buffer{}, expected); e == nil {
			t.Fatal("accepted output inside shared Git control directory")
		}
		if _, e := os.Lstat(dest); !os.IsNotExist(e) {
			t.Fatal("created output inside shared Git control directory")
		}
		alias := filepath.Join(external, "common-link")
		if e := os.Symlink(filepath.Join(source, ".git"), alias); e != nil {
			t.Fatalf("Git control alias fixture: %v", e)
		}
		aliasDest := filepath.Join(alias, "aliased-output")
		if e := run([]string{"stage", "--source", nestedLinked, "--lock", lock, "--output", aliasDest}, &bytes.Buffer{}, expected); e == nil {
			t.Fatal("accepted alias to shared Git control directory")
		}
		if _, e := os.Lstat(aliasDest); !os.IsNotExist(e) {
			t.Fatal("created output through shared Git control alias")
		}
	})
	t.Run("bare repository subdirectory", func(t *testing.T) {
		bare := filepath.Join(external, "bare.git")
		cmd := exec.Command("git", "clone", "--bare", "--quiet", source, bare)
		if b, e := cmd.CombinedOutput(); e != nil {
			t.Fatalf("bare fixture: %v %s", e, b)
		}
		dest := filepath.Join(bare, "staged-inside-bare")
		if e := run([]string{"stage", "--source", filepath.Join(bare, "objects"), "--lock", lock, "--output", dest}, &bytes.Buffer{}, expected); e == nil {
			t.Fatal("accepted output inside bare repository")
		}
		if _, e := os.Lstat(dest); !os.IsNotExist(e) {
			t.Fatal("created output inside bare repository")
		}
	})
}

func TestSafeOutputDifferentWorkspace(t *testing.T) {
	source, _ := syncFixture(t)
	working, e := os.Getwd()
	if e != nil {
		t.Fatal(e)
	}
	dest := filepath.Join(working, "external-probe-not-created")
	if _, e = os.Lstat(dest); !os.IsNotExist(e) {
		t.Fatal("probe destination must not exist")
	}
	if !safeOutput(source, dest) {
		t.Fatalf("rejected external destination: source volume %q output volume %q", filepath.VolumeName(source), filepath.VolumeName(dest))
	}
	t.Logf("source volume %q; output volume %q", filepath.VolumeName(source), filepath.VolumeName(dest))
}

func TestWriteNewDoesNotOverwrite(t *testing.T) {
	p := filepath.Join(t.TempDir(), "existing")
	if e := os.WriteFile(p, []byte("original"), 0600); e != nil {
		t.Fatal(e)
	}
	if e := writeNew(p, []byte("replacement"), 0600); e == nil {
		t.Fatal("accepted existing output file")
	}
	b, e := os.ReadFile(p)
	if e != nil || string(b) != "original" {
		t.Fatal("existing output was changed")
	}
}
func TestSyncStageAndVerify(t *testing.T) {
	source, expected := syncFixture(t)
	root := t.TempDir()
	one := filepath.Join(root, "one")
	two := filepath.Join(root, "two")
	lock := filepath.Join(root, "lock.json")
	call := func(args ...string) error { return run(args, &bytes.Buffer{}, expected) }
	if e := call("lock", "--source", source, "--output", lock); e != nil {
		t.Fatalf("locked snapshot: %v", e)
	}
	lockData, e := os.ReadFile(lock)
	if e != nil {
		t.Fatal(e)
	}
	expected.lockSHA256 = fmt.Sprintf("%x", sha256.Sum256(lockData))
	if e = call("lock", "--source", source, "--output", lock); e == nil {
		t.Fatal("overwrote existing lock")
	}
	unchanged, e := os.ReadFile(lock)
	if e != nil || !bytes.Equal(unchanged, lockData) {
		t.Fatal("existing lock was changed")
	}
	for _, dest := range []string{one, two} {
		if e := call("stage", "--source", source, "--lock", lock, "--output", dest); e != nil {
			t.Fatalf("stage: %v", e)
		}
		if e := call("verify", "--lock", lock, "--vendor", dest); e != nil {
			t.Fatalf("verify: %v", e)
		}
	}
	if _, e := os.Stat(filepath.Join(one, "Tests/example.ps1")); !os.IsNotExist(e) {
		t.Fatal("development test retained")
	}
	if _, e := os.Stat(filepath.Join(one, "Scripts/Get.ps1")); !os.IsNotExist(e) {
		t.Fatal("unused upstream downloader retained")
	}
	if _, e := os.Stat(filepath.Join(one, ".gitignore")); e != nil {
		t.Fatal("privacy ignore rules omitted")
	}
	for _, name := range []string{"Scripts/Build-Release.ps1", "Scripts/Run-Tests.ps1", ".github/workflows/test.yml"} {
		if _, e := os.Stat(filepath.Join(one, filepath.FromSlash(name))); !os.IsNotExist(e) {
			t.Fatalf("development file retained: %s", name)
		}
	}
	a, _ := os.ReadFile(filepath.Join(one, "Win11Debloat.ps1"))
	b, _ := os.ReadFile(filepath.Join(two, "Win11Debloat.ps1"))
	if !bytes.Equal(a, b) {
		t.Fatal("nonreproducible bytes")
	}
	if e := call("stage", "--source", source, "--lock", lock, "--output", one); e == nil {
		t.Fatal("overwrote existing destination")
	}
	t.Run("matching tampered lock and vendor", func(t *testing.T) {
		dest := filepath.Join(root, "forged-vendor")
		if e := call("stage", "--source", source, "--lock", lock, "--output", dest); e != nil {
			t.Fatal(e)
		}
		changed := []byte("modified license\n")
		if e := os.WriteFile(filepath.Join(dest, "LICENSE"), changed, 0600); e != nil {
			t.Fatal(e)
		}
		l, e := loadLock(lock, expected)
		if e != nil {
			t.Fatal(e)
		}
		for i := range l.Files {
			if l.Files[i].Path == "LICENSE" {
				l.Files[i].SHA256 = fmt.Sprintf("%x", sha256.Sum256(changed))
			}
		}
		data, e := encodeLock(l)
		if e != nil {
			t.Fatal(e)
		}
		forged := filepath.Join(root, "forged.lock")
		if e = os.WriteFile(forged, data, 0600); e != nil {
			t.Fatal(e)
		}
		if e = call("verify", "--lock", forged, "--vendor", dest); e == nil {
			t.Fatal("accepted altered lock matching altered vendor")
		}
	})
	if e := call("stage", "--source", source, "--lock", lock, "--output", filepath.Join(source, "inside")); e == nil {
		t.Fatal("accepted destination inside source")
	}
	t.Run("source alias", func(t *testing.T) {
		alias := filepath.Join(t.TempDir(), "source-link")
		if e := os.Symlink(source, alias); e != nil {
			t.Fatalf("directory symlink fixture: %v", e)
		}
		if e := call("stage", "--source", source, "--lock", lock, "--output", filepath.Join(alias, "inside")); e == nil {
			t.Fatal("accepted destination inside source via symlink")
		}
	})
	for _, kind := range []string{"missing", "changed", "extra"} {
		t.Run(kind, func(t *testing.T) {
			dest := filepath.Join(root, kind)
			if e := call("stage", "--source", source, "--lock", lock, "--output", dest); e != nil {
				t.Fatal(e)
			}
			p := filepath.Join(dest, "LICENSE")
			switch kind {
			case "missing":
				if e := os.Remove(p); e != nil {
					t.Fatal(e)
				}
			case "changed":
				if e := os.WriteFile(p, []byte("changed"), 0600); e != nil {
					t.Fatal(e)
				}
			case "extra":
				if e := os.WriteFile(filepath.Join(dest, "extra"), []byte("extra"), 0600); e != nil {
					t.Fatal(e)
				}
			}
			if e := call("verify", "--lock", lock, "--vendor", dest); e == nil {
				t.Fatalf("accepted %s", kind)
			}
		})
	}
	if e := run([]string{"lock", "--source", source, "--output", filepath.Join(root, "bad.json")}, &bytes.Buffer{}, pin{strings.Repeat("0", 40), expected.tree, expected.files, expected.keep, expected.lockSHA256}); e == nil {
		t.Fatal("accepted wrong commit")
	}
	if e := run([]string{"lock", "--source", source, "--output", filepath.Join(root, "bad-tree.json")}, &bytes.Buffer{}, pin{expected.commit, strings.Repeat("0", 40), expected.files, expected.keep, expected.lockSHA256}); e == nil {
		t.Fatal("accepted wrong tree")
	}
	lockBytes, e := os.ReadFile(lock)
	if e != nil {
		t.Fatal(e)
	}
	badLock := filepath.Join(root, "bad-lock.json")
	if e = os.WriteFile(badLock, bytes.Replace(lockBytes, []byte(`"retain": true`), []byte(`"retain": false`), 1), 0600); e != nil {
		t.Fatal(e)
	}
	if e = call("stage", "--source", source, "--lock", badLock, "--output", filepath.Join(root, "bad-stage")); e == nil {
		t.Fatal("accepted modified exclusion policy")
	}
}

func TestFixedProfileRetainsOnlyRequiredLanguageCatalogs(t *testing.T) {
	l, err := loadLock("upstream.lock.json", upstream)
	if err != nil {
		t.Fatal(err)
	}
	catalogs := map[string]bool{}
	for _, f := range l.Files {
		if !strings.HasPrefix(f.Path, "Config/Languages/") {
			continue
		}
		parts := strings.Split(f.Path, "/")
		if len(parts) != 4 {
			t.Fatalf("unexpected language path: %s", f.Path)
		}
		required := parts[2] == "zh-TW" || parts[2] == "en-US"
		if f.Retain != required {
			t.Errorf("language retention %s = %v, want %v", f.Path, f.Retain, required)
		}
		if required {
			catalogs[parts[2]+"/"+parts[3]] = true
		}
	}
	for _, lang := range []string{"zh-TW", "en-US"} {
		for _, name := range []string{"Apps.json", "Categories.json", "Chrome.json", "Features.json"} {
			if !catalogs[lang+"/"+name] {
				t.Errorf("missing fixed or fallback catalog %s/%s", lang, name)
			}
		}
	}
}

func TestFixedProfileOmitsUpstreamLaunchers(t *testing.T) {
	l, err := loadLock("upstream.lock.json", upstream)
	if err != nil {
		t.Fatal(err)
	}
	seen := map[string]bool{}
	for _, f := range l.Files {
		if f.Path == "Run.bat" || f.Path == "Scripts/Get.ps1" {
			seen[f.Path] = true
			if f.Retain {
				t.Errorf("unused upstream launcher retained: %s", f.Path)
			}
		}
	}
	for _, name := range []string{"Run.bat", "Scripts/Get.ps1"} {
		if !seen[name] {
			t.Errorf("missing upstream inventory for %s", name)
		}
	}
}
