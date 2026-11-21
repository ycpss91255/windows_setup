package main

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"

	"os"
	"path"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const maxArchive = 512 << 20

func download(ctx context.Context, client *http.Client, endpoint, token, digest string, attempts int, delay time.Duration) ([]byte, error) {
	for n := 0; n < attempts; n++ {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
		if err != nil {
			return nil, err
		}
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		req.Header.Set("Accept", "application/vnd.github+json")
		req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
		resp, err := client.Do(req)
		transportError := err != nil
		if err == nil {
			if resp.StatusCode == http.StatusOK {
				body, readErr := io.ReadAll(io.LimitReader(resp.Body, maxArchive+1))
				_ = resp.Body.Close()
				if readErr != nil {
					return nil, fmt.Errorf("incomplete artifact response: %w", readErr)
				}
				if len(body) > maxArchive {
					return nil, errors.New("artifact too large")
				}
				sum := sha256.Sum256(body)
				if hex.EncodeToString(sum[:]) != digest {
					return nil, errors.New("artifact digest mismatch")
				}
				return body, nil
			}
			_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
			_ = resp.Body.Close()
			if resp.StatusCode != 429 && resp.StatusCode != 500 && resp.StatusCode != 502 && resp.StatusCode != 503 && resp.StatusCode != 504 {
				return nil, fmt.Errorf("artifact GET HTTP %d", resp.StatusCode)
			}
			err = fmt.Errorf("artifact GET HTTP %d", resp.StatusCode)
		}
		if transportError {
			var netErr net.Error
			if !errors.As(err, &netErr) || (!netErr.Timeout() && !netErr.Temporary()) {
				return nil, errors.New("artifact GET transport failed")
			}
			err = errors.New("transient artifact transport failure")
		}
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		if n+1 == attempts {
			return nil, fmt.Errorf("artifact GET attempts exhausted: %w", err)
		}
		timer := time.NewTimer(delay)
		select {
		case <-ctx.Done():
			timer.Stop()
			return nil, ctx.Err()
		case <-timer.C:
		}
	}
	return nil, errors.New("artifact GET failed")
}

func unpack(data []byte, dest string) error {
	z, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return err
	}
	seen := map[string]bool{}
	var total uint64
	for _, f := range z.File {
		name := f.Name
		if name == "" || !filepath.IsLocal(filepath.FromSlash(name)) || strings.Contains(name, "\\") || strings.HasPrefix(name, "/") || path.Clean(name) != strings.TrimSuffix(name, "/") || strings.Contains(name, ":") {
			return errors.New("unsafe archive path")
		}
		key := strings.ToLower(strings.TrimSuffix(name, "/"))
		if seen[key] {
			return errors.New("duplicate archive path")
		}
		seen[key] = true
		if f.Mode()&os.ModeSymlink != 0 || (!f.FileInfo().IsDir() && !f.Mode().IsRegular()) {
			return errors.New("unsafe archive type")
		}
		if f.UncompressedSize64 > (1<<30)-total {
			return errors.New("archive expands too large")
		}
		total += f.UncompressedSize64
	}
	for _, f := range z.File {
		target := filepath.Join(dest, filepath.FromSlash(f.Name))
		if f.FileInfo().IsDir() {
			if err := os.MkdirAll(target, 0700); err != nil {
				return err
			}
			continue
		}
		if err := os.MkdirAll(filepath.Dir(target), 0700); err != nil {
			return err
		}
		out, err := os.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if err != nil {
			return err
		}
		in, err := f.Open()
		if err != nil {
			out.Close()
			return err
		}
		_, err = io.Copy(out, io.LimitReader(in, int64(f.UncompressedSize64)+1))
		closeErr := out.Close()
		_ = in.Close()
		if err != nil {
			return err
		}
		if closeErr != nil {
			return closeErr
		}
	}
	return nil
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
func run() error {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	return runContext(ctx)
}
func runContext(ctx context.Context) error {
	repo := flag.String("repo", "", "repository")
	runID := flag.String("run", "", "run ID")
	attempt := flag.Int("attempt", 0, "run attempt")
	id := flag.String("id", "", "artifact ID")
	digest := flag.String("digest", "", "sha256 digest")
	kind := flag.String("kind", "native", "artifact kind: native or container")
	dest := flag.String("dest", "", "new output directory")
	flag.Parse()
	if !regexp.MustCompile(`^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`).MatchString(*repo) || !regexp.MustCompile(`^[1-9][0-9]*$`).MatchString(*runID) || !regexp.MustCompile(`^[1-9][0-9]*$`).MatchString(*id) || *attempt < 1 || !regexp.MustCompile(`^sha256:[a-f0-9]{64}$`).MatchString(*digest) || (*kind != "native" && *kind != "container") || *dest == "" {
		return errors.New("invalid artifact identity")
	}
	token := os.Getenv("GH_TOKEN")
	if token == "" {
		token = os.Getenv("GITHUB_TOKEN")
	}
	if token == "" {
		return errors.New("GitHub token unavailable")
	}
	client := &http.Client{CheckRedirect: func(req *http.Request, via []*http.Request) error {
		if len(via) > 5 || !strings.HasSuffix(via[0].URL.Path, "/zip") || req.URL.Scheme != "https" || req.URL.User != nil || req.URL.Hostname() == "" {
			return errors.New("unsafe artifact redirect")
		}
		req.Header.Del("Authorization")
		return nil
	}}
	base := "https://api.github.com/repos/" + *repo + "/actions/artifacts/" + *id
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, base, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	resp, err := client.Do(req)
	if err != nil {
		return errors.New("artifact metadata request failed")
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("artifact metadata HTTP %d", resp.StatusCode)
	}
	if err := validateMetadata(resp.Body, *id, *runID, *attempt, *digest, *kind); err != nil {
		return err
	}
	data, err := download(ctx, client, base+"/zip", token, strings.TrimPrefix(*digest, "sha256:"), 3, time.Second)
	if err != nil {
		return err
	}
	if _, err = os.Lstat(*dest); !os.IsNotExist(err) {
		return errors.New("artifact destination must not exist")
	}
	parent := filepath.Dir(*dest)
	tmp, err := os.MkdirTemp(parent, "artifact-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmp)
	if err := unpack(data, tmp); err != nil {
		return err
	}
	return os.Rename(tmp, *dest)
}

func validateMetadata(body io.Reader, id, runID string, attempt int, digest, kind string) error {
	var meta struct {
		ID       int64  `json:"id"`
		Name     string `json:"name"`
		Digest   string `json:"digest"`
		Size     *int64 `json:"size_in_bytes"`
		Expired  *bool  `json:"expired"`
		Workflow struct {
			ID int64 `json:"id"`
		} `json:"workflow_run"`
	}
	if err := json.NewDecoder(io.LimitReader(body, 1<<20)).Decode(&meta); err != nil {
		return errors.New("invalid artifact metadata")
	}
	expectedID, err := strconv.ParseInt(id, 10, 64)
	if err != nil {
		return errors.New("invalid artifact ID")
	}
	expectedRun, err := strconv.ParseInt(runID, 10, 64)
	if err != nil {
		return errors.New("invalid run ID")
	}
	prefix := "windows-test-reports-"
	if kind == "container" {
		prefix = "docker-test-reports-"
	} else if kind != "native" {
		return errors.New("invalid artifact kind")
	}
	if meta.ID != expectedID || meta.Workflow.ID != expectedRun || meta.Name != prefix+runID+"-"+strconv.Itoa(attempt) || meta.Expired == nil || *meta.Expired || meta.Digest != digest || meta.Size == nil || *meta.Size <= 0 || *meta.Size > maxArchive {
		return errors.New("artifact source or digest mismatch")
	}
	return nil
}
