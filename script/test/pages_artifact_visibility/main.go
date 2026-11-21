package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"
)

type options struct {
	client                                                                                  *http.Client
	restURL, runtimeURL, token, runtimeToken, repo, runID, artifactID, name, expectedDigest string
	interval                                                                                time.Duration
}

var decimal = regexp.MustCompile(`^[1-9][0-9]*$`)
var digestPattern = regexp.MustCompile(`^sha256:[a-f0-9]{64}$`)
var repositoryPattern = regexp.MustCompile(`^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`)
var scopeID = regexp.MustCompile(`^[A-Za-z0-9-]+$`)

const maxResponse = 1 << 20

func runtimeScope(token string) (string, string, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return "", "", errors.New("invalid runtime credentials")
	}
	data, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil || len(data) > 16384 {
		return "", "", errors.New("invalid runtime credentials")
	}
	var claims struct {
		Scope string `json:"scp"`
	}
	if json.Unmarshal(data, &claims) != nil {
		return "", "", errors.New("invalid runtime credentials")
	}
	var run, job string
	for _, entry := range strings.Fields(claims.Scope) {
		if strings.HasPrefix(entry, "Actions.Results:") {
			p := strings.Split(entry, ":")
			if len(p) != 3 || run != "" || !scopeID.MatchString(p[1]) || !scopeID.MatchString(p[2]) {
				return "", "", errors.New("invalid runtime scope")
			}
			run, job = p[1], p[2]
		}
	}
	if run == "" {
		return "", "", errors.New("missing runtime scope")
	}
	return run, job, nil
}
func getJSON(ctx context.Context, o options, method, endpoint, token string, body []byte, out any) error {
	req, err := http.NewRequestWithContext(ctx, method, endpoint, bytes.NewReader(body))
	if err != nil {
		return errors.New("invalid visibility request")
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/json")
	if method == http.MethodPost {
		req.Header.Set("Content-Type", "application/json")
	}
	client := *o.client
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return errors.New("redirect rejected") }
	resp, err := client.Do(req)
	if err != nil {
		return errors.New("visibility request failed")
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("visibility HTTP %d", resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, maxResponse+1))
	if err != nil || len(data) > maxResponse {
		return errors.New("invalid visibility response size")
	}
	if trimmed := bytes.TrimSpace(data); len(trimmed) == 0 || trimmed[0] != '{' {
		return errors.New("invalid visibility response")
	}
	if err = json.Unmarshal(data, out); err != nil {
		return errors.New("invalid visibility response")
	}
	return nil
}
func restVisible(ctx context.Context, o options) (bool, error) {
	var matches []struct {
		ID       int64  `json:"id"`
		Name     string `json:"name"`
		Digest   string `json:"digest"`
		Size     int64  `json:"size_in_bytes"`
		Expired  *bool  `json:"expired"`
		Workflow struct {
			ID int64 `json:"id"`
		} `json:"workflow_run"`
	}
	for page := 1; page <= 100; page++ {
		var result struct {
			Artifacts []struct {
				ID       int64  `json:"id"`
				Name     string `json:"name"`
				Digest   string `json:"digest"`
				Size     int64  `json:"size_in_bytes"`
				Expired  *bool  `json:"expired"`
				Workflow struct {
					ID int64 `json:"id"`
				} `json:"workflow_run"`
			} `json:"artifacts"`
		}
		endpoint := fmt.Sprintf("%s/repos/%s/actions/runs/%s/artifacts?per_page=100&page=%d", o.restURL, o.repo, o.runID, page)
		if err := getJSON(ctx, o, http.MethodGet, endpoint, o.token, nil, &result); err != nil {
			return false, err
		}
		if result.Artifacts == nil {
			return false, errors.New("missing artifact list")
		}
		for _, a := range result.Artifacts {
			if a.Name == o.name {
				matches = append(matches, a)
			}
		}
		if len(result.Artifacts) < 100 {
			break
		}
		if page == 100 {
			return false, errors.New("artifact pagination limit")
		}
	}
	if len(matches) == 0 {
		return false, nil
	}
	if len(matches) != 1 {
		return false, errors.New("duplicate REST artifacts")
	}
	a := matches[0]
	size := a.Size
	if strconv.FormatInt(a.ID, 10) != o.artifactID || strconv.FormatInt(a.Workflow.ID, 10) != o.runID || a.Expired == nil || *a.Expired || !digestPattern.MatchString(a.Digest) || a.Digest != o.expectedDigest || size <= 0 || size > 1<<30 {
		return false, errors.New("REST artifact identity mismatch")
	}
	return true, nil
}
func runtimeVisible(ctx context.Context, o options, run, job string) (bool, error) {
	body, _ := json.Marshal(map[string]string{"workflow_run_backend_id": run, "workflow_job_run_backend_id": job})
	var result struct {
		Artifacts json.RawMessage `json:"artifacts"`
	}
	if err := getJSON(ctx, o, http.MethodPost, o.runtimeURL+"/twirp/github.actions.results.api.v1.ArtifactService/ListArtifacts", o.runtimeToken, body, &result); err != nil {
		return false, err
	}
	if len(result.Artifacts) == 0 {
		return false, nil
	}
	var artifacts []struct {
		ID   string `json:"database_id"`
		Name string `json:"name"`
	}
	if string(result.Artifacts) == "null" || json.Unmarshal(result.Artifacts, &artifacts) != nil {
		return false, errors.New("invalid runtime artifact list")
	}
	count, id := 0, ""
	for _, a := range artifacts {
		if a.Name == o.name {
			count++
			id = a.ID
		}
	}
	if count == 0 {
		return false, nil
	}
	if count != 1 || id != o.artifactID || !decimal.MatchString(id) {
		return false, errors.New("runtime artifact identity mismatch")
	}
	return true, nil
}
func observe(ctx context.Context, o options) error {
	if o.client == nil || o.token == "" || !repositoryPattern.MatchString(o.repo) || !decimal.MatchString(o.runID) || !decimal.MatchString(o.artifactID) || !digestPattern.MatchString(o.expectedDigest) || o.name == "" || o.interval <= 0 {
		return errors.New("invalid visibility configuration")
	}
	run, job, err := runtimeScope(o.runtimeToken)
	if err != nil {
		return err
	}
	for {
		ready, err := restVisible(ctx, o)
		if err != nil {
			return err
		}
		if ready {
			ready, err = runtimeVisible(ctx, o, run, job)
			if err != nil {
				return err
			}
			if ready {
				return nil
			}
		}
		timer := time.NewTimer(o.interval)
		select {
		case <-ctx.Done():
			timer.Stop()
			return errors.New("artifact visibility deadline exceeded")
		case <-timer.C:
		}
	}
}
func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
func run() error {
	repo, runID, attempt, id := os.Getenv("GITHUB_REPOSITORY"), os.Getenv("GITHUB_RUN_ID"), os.Getenv("GITHUB_RUN_ATTEMPT"), os.Getenv("PAGES_ARTIFACT_ID")
	if !decimal.MatchString(attempt) {
		return errors.New("invalid run attempt")
	}
	raw := os.Getenv("ACTIONS_RESULTS_URL")
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return errors.New("invalid runtime service")
	}
	runtimeURL := u.Scheme + "://" + u.Host
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	return observe(ctx, options{client: &http.Client{Timeout: 10 * time.Second}, restURL: "https://api.github.com", runtimeURL: runtimeURL, token: os.Getenv("GH_TOKEN"), runtimeToken: os.Getenv("ACTIONS_RUNTIME_TOKEN"), repo: repo, runID: runID, artifactID: id, expectedDigest: "sha256:" + os.Getenv("PAGES_ARTIFACT_DIGEST"), name: "github-pages-" + runID + "-" + attempt, interval: time.Second})
}
