package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
	"testing"
)

func TestFrozenManifestRoots(t *testing.T) {
	roots, e := frozenRoots()
	if e != nil || len(roots) != 24 || roots[0] != fixedAnchor {
		t.Fatalf("invalid roots: %d %v", len(roots), e)
	}
	saved := frozenManifest
	defer func() { frozenManifest = saved }()
	frozenManifest = append(append([]byte{}, saved...), ' ')
	if _, e = frozenRoots(); e == nil {
		t.Fatal("modified manifest accepted")
	}
}
func TestEventMetadataFailsClosed(t *testing.T) {
	sha := strings.Repeat("a", 40)
	base := strings.Repeat("b", 40)
	before := strings.Repeat("c", 40)
	pr := fmt.Sprintf(`{"repository":{"full_name":"%s"},"number":3,"pull_request":{"number":3,"base":{"sha":"%s","ref":"main","repo":{"full_name":"%s"}},"head":{"sha":"%s"}}}`, fixedRepository, base, fixedRepository, sha)
	push := fmt.Sprintf(`{"repository":{"full_name":"%s"},"ref":"refs/heads/main","before":"%s","after":"%s"}`, fixedRepository, before, sha)
	for _, tc := range []struct {
		name, kind, ref, raw string
		ok                   bool
	}{
		{"pr", "pull_request", "refs/pull/3/merge", pr, true},
		{"wrong PR ref", "pull_request", "refs/pull/4/merge", pr, false},
		{"wrong repo", "pull_request", "refs/pull/3/merge", strings.Replace(pr, fixedRepository, "other/repo", 1), false},
		{"wrong number", "pull_request", "refs/pull/3/merge", strings.Replace(pr, `"number":3,"pull_request"`, `"number":4,"pull_request"`, 1), false},
		{"push", "push", "refs/heads/main", push, true},
		{"wrong ref", "push", "refs/heads/other", push, false},
		{"tag", "push", "refs/tags/v1.0.0", fmt.Sprintf(`{"repository":{"full_name":"%s"},"ref":"refs/tags/v1.0.0","after":"%s"}`, fixedRepository, sha), true},
		{"manual", "workflow_dispatch", "refs/heads/main", fmt.Sprintf(`{"repository":{"full_name":"%s"}}`, fixedRepository), true},
		{"manual branch", "workflow_dispatch", "refs/heads/other", fmt.Sprintf(`{"repository":{"full_name":"%s"}}`, fixedRepository), false},
		{"unknown queue", "merge_group", "refs/heads/main", push, false},
		{"missing event", "push", "refs/heads/main", `{}`, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, e := parseSourceEvent(tc.kind, tc.ref, sha, base, []byte(tc.raw))
			if (e == nil) != tc.ok {
				t.Fatalf("want %v: %v", tc.ok, e)
			}
		})
	}
}

// TestCurrentMainDispatchAdoption uses a local-only temporary repository; no tag or network is created.
func TestCurrentMainDispatchAdoption(t *testing.T) {
	if os.Getenv("WINDOWS_SETUP_VERIFY_ADOPTION_GRAPH") != "1" {
		t.Skip("opt-in local full-history verification")
	}
	source, err := exec.Command("git", "rev-parse", "--show-toplevel").Output()
	if err != nil {
		t.Fatal(err)
	}
	sourceRoot := strings.TrimSpace(string(source))
	roots, err := frozenRoots()
	if err != nil {
		t.Fatal(err)
	}
	const main = "66b5b0fb7a49816f3735465a18f0ca8986219de4"
	repo := t.TempDir()
	git := func(args ...string) {
		t.Helper()
		c := exec.Command("git", args...)
		c.Dir = repo
		if out, e := c.CombinedOutput(); e != nil {
			t.Fatalf("git %v: %s: %v", args, out, e)
		}
	}
	git("init", "--quiet", repo)
	args := append([]string{"fetch", "--quiet", "--no-tags", sourceRoot, main}, roots...)
	git(args...)
	git("checkout", "--quiet", "--detach", main)
	raw := []byte(fmt.Sprintf(`{"repository":{"full_name":"%s"}}`, fixedRepository))
	if err := checkEventInRepository(repo, "workflow_dispatch", "refs/heads/main", main, main, raw, fixedAnchor, roots); err != nil {
		t.Fatalf("existing main dispatch rejected: %v", err)
	}
	push := []byte(fmt.Sprintf(`{"repository":{"full_name":"%s"},"ref":"refs/heads/main","before":"%s","after":"%s"}`, fixedRepository, fixedAnchor, main))
	if err := checkEventInRepository(repo, "push", "refs/heads/main", main, "", push, fixedAnchor, roots); err == nil {
		t.Fatal("new push incorrectly exempted historical merge")
	}

	// A new invalid descendant, and the same invalid merge as an ancestor of a
	// later valid merge, must both remain visible to historical scans.
	makeMerge := func(title string, first string) string {
		t.Helper()
		c := exec.Command("git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit-tree", main+"^{tree}", "-p", first, "-p", fixedAnchor, "-m", title)
		c.Dir = repo
		out, e := c.CombinedOutput()
		if e != nil {
			t.Fatalf("commit-tree: %s: %v", out, e)
		}
		return strings.TrimSpace(string(out))
	}
	bad := makeMerge("wrong new title", main)
	good := makeMerge("合併：後續有效", bad)
	for _, tip := range []string{bad, good} {
		for _, kind := range []string{"tag", "dispatch_main"} {
			if err := validateMergeTitlesForEvent(repo, []string{tip}, roots, kind); err == nil {
				t.Fatalf("invalid other merge accepted for %s", kind)
			}
		}
	}

}

func TestHistoricalAdoptionExceptionIsExactAndEventScoped(t *testing.T) {
	for _, kind := range []string{"tag", "dispatch_main", "pull_request", "push_main", "unknown"} {
		for _, oid := range []string{historicalAdoptionMerge, strings.Repeat("a", 40)} {
			want := oid == historicalAdoptionMerge && (kind == "tag" || kind == "dispatch_main")
			if titleException(kind, oid) != want {
				t.Fatalf("unexpected exception kind=%s oid=%s", kind, oid)
			}
		}
	}
}
