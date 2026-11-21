package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestMergeTitleGraphBoundary(t *testing.T) {
	repo := t.TempDir()
	git := func(args ...string) string {
		t.Helper()
		c := exec.Command("git", args...)
		c.Dir = repo
		c.Env = append(os.Environ(), "GIT_AUTHOR_NAME=Fixture", "GIT_AUTHOR_EMAIL=fixture@example.invalid", "GIT_COMMITTER_NAME=Fixture", "GIT_COMMITTER_EMAIL=fixture@example.invalid")
		b, e := c.CombinedOutput()
		if e != nil {
			t.Fatalf("git %v: %s: %v", args, b, e)
		}
		return strings.TrimSpace(string(b))
	}
	git("init", "--quiet", repo)
	tree := git("mktree")
	commit := func(title string, parents ...string) string {
		args := []string{"commit-tree", tree}
		for _, p := range parents {
			args = append(args, "-p", p)
		}
		args = append(args, "-m", title)
		return git(args...)
	}
	root := commit("起點")
	left := commit("左側", root)
	right := commit("右側", root)
	old := commit("舊歷史合併", left, right)
	newer := commit("後續單親", old)
	good := commit("合併：正確同步", newer, right)
	bad := commit("整合：錯誤同步", newer, right)
	english := commit("合併：English", newer, right)
	leadingSpace := commit(" 合併：有效中文", newer, right)
	leadingBOM := commit("\ufeff合併：有效中文", newer, right)
	for _, tc := range []struct {
		name, tip string
		frozen    []string
		want      bool
	}{
		{"old frozen", newer, []string{old}, true},
		{"new proper merge", good, []string{old}, true},
		{"new wrong merge", bad, []string{old}, false},
		{"merge needs Chinese result", english, []string{old}, false},
		{"leading space is not a valid prefix", leadingSpace, []string{old}, false},
		{"leading BOM is not a valid prefix", leadingBOM, []string{old}, false},
		{"missing frozen object", good, []string{strings.Repeat("f", 40)}, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := validateMergeTitles(filepath.Clean(repo), []string{tc.tip}, tc.frozen)
			if (e == nil) != tc.want {
				t.Fatalf("want pass=%v, got %v", tc.want, e)
			}
		})
	}
	// A previously published PR graph remains exempt after a normal main merge;
	// the merge created after adoption still has to meet the title rule.
	mainGood := commit("合併：納入舊分支", root, old)
	mainBad := commit("整合：納入舊分支", root, old)
	if err := validateMergeTitles(repo, []string{mainGood}, []string{root, old}); err != nil {
		t.Fatalf("grandfathered PR rejected after main merge: %v", err)
	}
	if err := validateMergeTitles(repo, []string{mainBad}, []string{root, old}); err == nil {
		t.Fatal("new main merge was grandfathered")
	}
	// Test the real event-to-graph pipeline, including GitHub's synthetic merge exclusion.
	syntheticCheck := commit("GitHub synthetic", old, good)
	git("checkout", "--quiet", "--detach", syntheticCheck)
	raw := []byte(fmt.Sprintf(`{"repository":{"full_name":"%s"},"number":3,"pull_request":{"number":3,"base":{"sha":"%s","ref":"main","repo":{"full_name":"%s"}},"head":{"sha":"%s"}}}`, fixedRepository, old, fixedRepository, good))
	if err := checkEventInRepository(repo, "pull_request", "refs/pull/3/merge", syntheticCheck, "", raw, old, []string{old}); err != nil {
		t.Fatalf("valid synthetic checkout rejected: %v", err)
	}
	if err := checkEventInRepository(repo, "pull_request", "refs/pull/3/merge", good, "", raw, old, []string{old}); err == nil {
		t.Fatal("mismatched checkout accepted")
	}
	badSynthetic := commit("GitHub synthetic", old, bad)
	git("checkout", "--quiet", "--detach", badSynthetic)
	badPR := []byte(fmt.Sprintf(`{"repository":{"full_name":"%s"},"number":3,"pull_request":{"number":3,"base":{"sha":"%s","ref":"main","repo":{"full_name":"%s"}},"head":{"sha":"%s"}}}`, fixedRepository, old, fixedRepository, bad))
	if err := checkEventInRepository(repo, "pull_request", "refs/pull/3/merge", badSynthetic, "", badPR, old, []string{old}); err == nil {
		t.Fatal("new wrong merge in PR head accepted")
	}
	git("checkout", "--quiet", "--detach", mainGood)
	goodPush := []byte(fmt.Sprintf(`{"repository":{"full_name":"%s"},"ref":"refs/heads/main","before":"%s","after":"%s"}`, fixedRepository, root, mainGood))
	if err := checkEventInRepository(repo, "push", "refs/heads/main", mainGood, "", goodPush, root, []string{root, old}); err != nil {
		t.Fatalf("new correct main merge rejected: %v", err)
	}
	git("checkout", "--quiet", "--detach", mainBad)
	badPush := []byte(fmt.Sprintf(`{"repository":{"full_name":"%s"},"ref":"refs/heads/main","before":"%s","after":"%s"}`, fixedRepository, root, mainBad))
	if err := checkEventInRepository(repo, "push", "refs/heads/main", mainBad, "", badPush, root, []string{root, old}); err == nil {
		t.Fatal("new wrong main merge accepted")
	}
	// An annotated tag must peel to the checked out commit and be on eligible main.
	git("checkout", "--quiet", "--detach", good)
	git("tag", "-a", "v1.0.0", good, "-m", "fixture")
	tagObject := git("rev-parse", "refs/tags/v1.0.0")
	tagRaw := []byte(fmt.Sprintf(`{"repository":{"full_name":"%s"},"ref":"refs/tags/v1.0.0","after":"%s"}`, fixedRepository, tagObject))
	if err := checkEventInRepository(repo, "push", "refs/tags/v1.0.0", good, good, tagRaw, old, []string{old}); err != nil {
		t.Fatalf("valid annotated tag rejected: %v", err)
	}
	wrongTag := []byte(fmt.Sprintf(`{"repository":{"full_name":"%s"},"ref":"refs/tags/v1.0.0","after":"%s"}`, fixedRepository, old))
	if err := checkEventInRepository(repo, "push", "refs/tags/v1.0.0", good, good, wrongTag, old, []string{old}); err == nil {
		t.Fatal("tag target mismatch accepted")
	}
	git("tag", "-a", "v0.1.0", root, "-m", "historical")
	git("checkout", "--quiet", "--detach", root)
	oldTag := git("rev-parse", "refs/tags/v0.1.0")
	oldRaw := []byte(fmt.Sprintf(`{"repository":{"full_name":"%s"},"ref":"refs/tags/v0.1.0","after":"%s"}`, fixedRepository, oldTag))
	if err := checkEventInRepository(repo, "push", "refs/tags/v0.1.0", root, good, oldRaw, old, []string{old}); err == nil {
		t.Fatal("tag preceding anchor accepted")
	}
	shallowFile := filepath.Join(repo, ".git", "shallow")
	if err := os.WriteFile(shallowFile, []byte(root+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := validateMergeTitles(repo, []string{good}, []string{old}); err == nil {
		t.Fatal("shallow graph accepted")
	}
	if err := os.Remove(shallowFile); err != nil {
		t.Fatal(err)
	}
	synthetic := commit("GitHub synthetic", old, good)
	cases := []struct {
		name  string
		event sourceEvent
		pass  bool
	}{
		{"PR synthetic excluded", sourceEvent{Kind: "pull_request", Checkout: synthetic, RunSHA: synthetic, Base: old, Head: good}, true},
		{"PR mismatched head", sourceEvent{Kind: "pull_request", Checkout: synthetic, RunSHA: synthetic, Base: old, Head: bad}, false},
		{"push descendant", sourceEvent{Kind: "push_main", Checkout: good, RunSHA: good, Before: old, After: good}, true},
		{"push nonancestor", sourceEvent{Kind: "push_main", Checkout: good, RunSHA: good, Before: bad, After: good}, false},
		{"tag descendant", sourceEvent{Kind: "tag", Checkout: good, RunSHA: good, Main: good}, true},
		{"historical tag", sourceEvent{Kind: "tag", Checkout: root, RunSHA: root, Main: good}, false},
		{"unknown event", sourceEvent{Kind: "unknown", Checkout: good, RunSHA: good}, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			tips, excluded, err := deriveEventScope(repo, tc.event, old)
			if err == nil {
				err = validateMergeTitles(repo, tips, append(excluded, old))
			}
			if (err == nil) != tc.pass {
				t.Fatalf("want pass=%v got %v", tc.pass, err)
			}
		})
	}
}

// TestHistoricalScanRejectsOtherMerges needs only a synthetic local graph.
func TestHistoricalScanRejectsOtherMerges(t *testing.T) {
	repo := t.TempDir()
	git := func(args ...string) string {
		t.Helper()
		c := exec.Command("git", args...)
		c.Dir = repo
		c.Env = append(os.Environ(), "GIT_AUTHOR_NAME=Fixture", "GIT_AUTHOR_EMAIL=fixture@example.invalid", "GIT_COMMITTER_NAME=Fixture", "GIT_COMMITTER_EMAIL=fixture@example.invalid")
		out, err := c.CombinedOutput()
		if err != nil {
			t.Fatalf("git %v: %s: %v", args, out, err)
		}
		return strings.TrimSpace(string(out))
	}
	git("init", "--quiet", repo)
	tree := git("mktree")
	base := git("commit-tree", tree, "-m", "base")
	other := git("commit-tree", tree, "-p", base, "-m", "other")
	bad := git("commit-tree", tree, "-p", base, "-p", other, "-m", "wrong title")
	later := git("commit-tree", tree, "-p", bad, "-p", other, "-m", "合併：後續有效")
	for _, kind := range []string{"tag", "dispatch_main", "pull_request", "push_main"} {
		for _, tip := range []string{bad, later} {
			if err := validateMergeTitlesForEvent(repo, []string{tip}, []string{base}, kind); err == nil {
				t.Fatalf("invalid other merge accepted kind=%s", kind)
			}
		}
	}
}
