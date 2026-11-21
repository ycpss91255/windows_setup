package main

import (
	"crypto/sha256"
	_ "embed"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"
)

//go:embed grandfather.json
var frozenManifest []byte

const frozenDigest = "d91f075b3cf1ba17c2c35b0e1173deecd64ef651abd92432934114217250531a"
const fixedRepository = "ycpss91255/windows_setup"
const fixedAnchor = "242d21a56c6b645ab8f5767aa27c36e8490a48a4"
const fixedRemote = "https://github.com/ycpss91255/windows_setup.git"

type frozenConfig struct {
	Repository   string `json:"repository"`
	Anchor       string `json:"anchor"`
	PullRequests []struct {
		Number  int    `json:"number"`
		HeadSHA string `json:"head_sha"`
	} `json:"pull_requests"`
}

func frozenRoots() ([]string, error) {
	if fmt.Sprintf("%x", sha256.Sum256(frozenManifest)) != frozenDigest {
		return nil, fmt.Errorf("frozen manifest digest mismatch")
	}
	var c frozenConfig
	if err := json.Unmarshal(frozenManifest, &c); err != nil {
		return nil, err
	}
	if c.Repository != fixedRepository || c.Anchor != fixedAnchor || len(c.PullRequests) != 23 {
		return nil, fmt.Errorf("invalid frozen manifest")
	}
	roots := []string{c.Anchor}
	seen := map[int]bool{}
	for _, p := range c.PullRequests {
		if p.Number < 1 || seen[p.Number] || !commitOID.MatchString(p.HeadSHA) {
			return nil, fmt.Errorf("invalid frozen head")
		}
		seen[p.Number] = true
		roots = append(roots, p.HeadSHA)
	}
	return roots, nil
}

type githubEvent struct {
	Ref        string `json:"ref"`
	Before     string `json:"before"`
	After      string `json:"after"`
	Deleted    bool   `json:"deleted"`
	Number     int    `json:"number"`
	Repository struct {
		FullName string `json:"full_name"`
	} `json:"repository"`
	PullRequest *struct {
		Number int `json:"number"`
		Base   struct {
			SHA  string `json:"sha"`
			Ref  string `json:"ref"`
			Repo struct {
				FullName string `json:"full_name"`
			} `json:"repo"`
		} `json:"base"`
		Head struct {
			SHA string `json:"sha"`
		} `json:"head"`
	} `json:"pull_request"`
}

func parseSourceEvent(kind, ref, sha, main string, raw []byte) (sourceEvent, error) {
	var e githubEvent
	if err := json.Unmarshal(raw, &e); err != nil {
		return sourceEvent{}, err
	}
	if e.Repository.FullName != fixedRepository || !commitOID.MatchString(sha) {
		return sourceEvent{}, fmt.Errorf("invalid event repository or SHA")
	}
	v := sourceEvent{Checkout: sha, RunSHA: sha, Main: main}
	switch kind {
	case "pull_request":
		if e.PullRequest == nil || e.Number < 1 || e.Number != e.PullRequest.Number || ref != fmt.Sprintf("refs/pull/%d/merge", e.Number) || e.PullRequest.Base.Ref != "main" || e.PullRequest.Base.Repo.FullName != fixedRepository {
			return v, fmt.Errorf("invalid PR metadata")
		}
		v.Kind = "pull_request"
		v.Base = e.PullRequest.Base.SHA
		v.Head = e.PullRequest.Head.SHA
	case "push":
		if e.Deleted || e.Ref != ref {
			return v, fmt.Errorf("invalid push metadata")
		}
		if ref == "refs/heads/main" {
			v.Kind = "push_main"
			v.Before = e.Before
			v.After = e.After
		} else if strings.HasPrefix(ref, "refs/tags/v") && len(ref) > len("refs/tags/v") {
			v.Kind = "tag"
			v.After = e.After
		} else {
			return v, fmt.Errorf("unsupported push ref")
		}
	case "workflow_dispatch":
		if ref != "refs/heads/main" {
			return v, fmt.Errorf("unsupported manual ref")
		}
		v.Kind = "dispatch_main"
	default:
		return v, fmt.Errorf("unsupported event")
	}
	return v, nil
}
func fetchRoots(repo string, roots []string) error {
	args := []string{"-C", repo, "fetch", "--no-tags", "--no-write-fetch-head", fixedRemote}
	args = append(args, roots...)
	c := exec.Command("git", args...)
	if err := c.Run(); err != nil {
		return fmt.Errorf("cannot fetch frozen graph")
	}
	return nil
}
func verifyGraphObjects(repo string, roots []string) error {
	args := append([]string{"rev-list", "--objects", "--missing=print"}, roots...)
	out, err := graphGit(repo, args...)
	if err != nil {
		return err
	}
	for _, line := range strings.Split(out, "\n") {
		if strings.HasPrefix(line, "?") {
			return fmt.Errorf("frozen graph contains missing object")
		}
	}
	return nil
}
func currentMain(repo string) (string, error) {
	out, err := graphGit(repo, "ls-remote", fixedRemote, "refs/heads/main")
	if err != nil {
		return "", err
	}
	fields := strings.Fields(out)
	if len(fields) != 2 || fields[1] != "refs/heads/main" || !commitOID.MatchString(fields[0]) {
		return "", fmt.Errorf("cannot verify current main")
	}
	if err = fetchRoots(repo, []string{fields[0]}); err != nil {
		return "", err
	}
	return fields[0], nil
}
func checkGitHubEvent(repo string) error {
	if os.Getenv("GITHUB_REPOSITORY") != fixedRepository {
		return fmt.Errorf("unexpected repository")
	}
	kind := os.Getenv("GITHUB_EVENT_NAME")
	if kind == "merge_group" {
		return fmt.Errorf("merge_group input is not yet supported")
	}
	roots, err := frozenRoots()
	if err != nil {
		return err
	}
	if err = fetchRoots(repo, roots); err != nil {
		return err
	}
	if err = verifyGraphObjects(repo, roots); err != nil {
		return err
	}
	main := ""
	ref := os.Getenv("GITHUB_REF")
	if strings.HasPrefix(ref, "refs/tags/") || kind == "workflow_dispatch" {
		main, err = currentMain(repo)
		if err != nil {
			return err
		}
	}
	raw, err := os.ReadFile(os.Getenv("GITHUB_EVENT_PATH"))
	if err != nil {
		return err
	}
	return checkEventInRepository(repo, kind, ref, os.Getenv("GITHUB_SHA"), main, raw, fixedAnchor, roots)
}
func checkEventInRepository(repo, kind, ref, sha, main string, raw []byte, anchor string, roots []string) error {
	v, err := parseSourceEvent(kind, ref, sha, main, raw)
	if err != nil {
		return err
	}
	actual, err := graphGit(repo, "rev-parse", "HEAD^{commit}")
	if err != nil || actual != v.Checkout {
		return fmt.Errorf("actual checkout mismatch")
	}
	if v.Kind == "tag" {
		if !commitOID.MatchString(v.After) {
			return fmt.Errorf("invalid tag object identity")
		}
		target, err := graphGit(repo, "rev-parse", v.After+"^{commit}")
		if err != nil || target != v.Checkout {
			return fmt.Errorf("tag target mismatch")
		}
		tagTarget, err := graphGit(repo, "rev-parse", ref+"^{commit}")
		if err != nil || tagTarget != v.Checkout {
			return fmt.Errorf("tag ref mismatch")
		}
	}
	tips, excluded, err := deriveEventScope(repo, v, anchor)
	if err != nil {
		return err
	}
	excluded = append(excluded, roots...)
	return validateMergeTitlesForEvent(repo, tips, excluded, v.Kind)
}

func main() {
	if err := checkGitHubEvent("."); err != nil {
		fmt.Fprintln(os.Stderr, "合併標題檢查失敗:", err)
		os.Exit(1)
	}
	fmt.Println("合併標題與事件範圍已核對")
}
