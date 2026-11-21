package main

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type fixtureTransport struct {
	target *url.URL
	base   http.RoundTripper
}

func (f fixtureTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	c := r.Clone(r.Context())
	u := *r.URL
	u.Scheme = f.target.Scheme
	u.Host = f.target.Host
	c.URL = &u
	return f.base.RoundTrip(c)
}

func TestRunDownloadsOfficialRedirectWithoutToken(t *testing.T) {
	var b bytes.Buffer
	z := zip.NewWriter(&b)
	w, _ := z.Create("summary.json")
	_, _ = w.Write([]byte(`{}`))
	if err := z.Close(); err != nil {
		t.Fatal(err)
	}
	data := b.Bytes()
	sum := sha256.Sum256(data)
	digest := fmt.Sprintf("sha256:%x", sum)
	calls := 0
	leaked := false
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		switch r.URL.Path {
		case "/repos/example/repo/actions/artifacts/456":
			fmt.Fprintf(w, `{"id":456,"name":"windows-test-reports-123-1","digest":%q,"size_in_bytes":100,"expired":false,"workflow_run":{"id":123}}`, digest)
		case "/repos/example/repo/actions/artifacts/456/zip":
			if calls == 2 {
				w.WriteHeader(http.StatusServiceUnavailable)
				return
			}
			http.Redirect(w, r, "https://storage.example.test/content", http.StatusFound)
		case "/content":
			leaked = r.Header.Get("Authorization") != ""
			_, _ = w.Write(data)
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	u, _ := url.Parse(server.URL)
	oldTransport := http.DefaultTransport
	http.DefaultTransport = fixtureTransport{u, server.Client().Transport}
	defer func() { http.DefaultTransport = oldTransport }()
	oldFlags, oldArgs := flag.CommandLine, os.Args
	defer func() { flag.CommandLine = oldFlags; os.Args = oldArgs }()
	flag.CommandLine = flag.NewFlagSet("test", flag.ContinueOnError)
	flag.CommandLine.SetOutput(io.Discard)
	dest := filepath.Join(t.TempDir(), "result")
	os.Args = []string{"artifact_download", "--repo", "example/repo", "--run", "123", "--attempt", "1", "--id", "456", "--digest", digest, "--dest", dest}
	t.Setenv("GH_TOKEN", "fixture-token")
	if err := run(); err != nil {
		t.Fatalf("production run rejected redirect: %v", err)
	}
	if leaked || calls != 4 {
		t.Fatalf("calls=%d leaked=%v", calls, leaked)
	}
	if got, err := os.ReadFile(filepath.Join(dest, "summary.json")); err != nil || strings.TrimSpace(string(got)) != "{}" {
		t.Fatalf("output invalid: %v", err)
	}
}

func TestRunDownloadsContainerWithBoundedRetry(t *testing.T) {
	var b bytes.Buffer
	z := zip.NewWriter(&b)
	w, _ := z.Create("summary.json")
	_, _ = w.Write([]byte(`{}`))
	if err := z.Close(); err != nil {
		t.Fatal(err)
	}
	data := b.Bytes()
	sum := sha256.Sum256(data)
	digest := fmt.Sprintf("sha256:%x", sum)
	calls := 0
	leaked := false
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		switch r.URL.Path {
		case "/repos/example/repo/actions/artifacts/456":
			fmt.Fprintf(w, `{"id":456,"name":"docker-test-reports-123-1","digest":%q,"size_in_bytes":100,"expired":false,"workflow_run":{"id":123}}`, digest)
		case "/repos/example/repo/actions/artifacts/456/zip":
			if calls == 2 {
				w.WriteHeader(http.StatusServiceUnavailable)
				return
			}
			http.Redirect(w, r, "https://storage.example.test/content", http.StatusFound)
		case "/content":
			leaked = r.Header.Get("Authorization") != ""
			_, _ = w.Write(data)
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	u, _ := url.Parse(server.URL)
	oldTransport := http.DefaultTransport
	http.DefaultTransport = fixtureTransport{u, server.Client().Transport}
	defer func() { http.DefaultTransport = oldTransport }()
	oldFlags, oldArgs := flag.CommandLine, os.Args
	defer func() { flag.CommandLine = oldFlags; os.Args = oldArgs }()
	flag.CommandLine = flag.NewFlagSet("test", flag.ContinueOnError)
	flag.CommandLine.SetOutput(io.Discard)
	dest := filepath.Join(t.TempDir(), "result")
	os.Args = []string{"artifact_download", "--repo", "example/repo", "--run", "123", "--attempt", "1", "--id", "456", "--digest", digest, "--kind", "container", "--dest", dest}
	t.Setenv("GH_TOKEN", "fixture-token")
	if err := run(); err != nil {
		t.Fatalf("production run rejected redirect: %v", err)
	}
	if leaked || calls != 4 {
		t.Fatalf("calls=%d leaked=%v", calls, leaked)
	}
	if got, err := os.ReadFile(filepath.Join(dest, "summary.json")); err != nil || strings.TrimSpace(string(got)) != "{}" {
		t.Fatalf("output invalid: %v", err)
	}
}

func TestRunRejectsOversizeMetadataBeforeDownload(t *testing.T) {
	digest := "sha256:" + strings.Repeat("a", 64)
	zipCalls := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/zip") {
			zipCalls++
			w.WriteHeader(500)
			return
		}
		fmt.Fprintf(w, `{"id":456,"name":"windows-test-reports-123-1","digest":%q,"size_in_bytes":%d,"expired":false,"workflow_run":{"id":123}}`, digest, maxArchive+1)
	}))
	defer server.Close()
	u, _ := url.Parse(server.URL)
	oldTransport := http.DefaultTransport
	http.DefaultTransport = fixtureTransport{u, server.Client().Transport}
	defer func() { http.DefaultTransport = oldTransport }()
	oldFlags, oldArgs := flag.CommandLine, os.Args
	defer func() { flag.CommandLine = oldFlags; os.Args = oldArgs }()
	flag.CommandLine = flag.NewFlagSet("test", flag.ContinueOnError)
	flag.CommandLine.SetOutput(io.Discard)
	os.Args = []string{"artifact_download", "--repo", "example/repo", "--run", "123", "--attempt", "1", "--id", "456", "--digest", digest, "--dest", filepath.Join(t.TempDir(), "result")}
	t.Setenv("GH_TOKEN", "fixture-token")
	err := run()
	if err == nil || zipCalls != 0 {
		t.Fatalf("expected metadata size rejection before download; calls=%d err=%v", zipCalls, err)
	}
}

func TestRunRejectsInvalidIdentityAndTerminalDownloadErrors(t *testing.T) {
	for _, tc := range []struct {
		name      string
		id        int
		nameValue string
		expired   bool
		status    int
		wantCalls int
	}{
		{"wrong id", 457, "windows-test-reports-123-1", false, 200, 0},
		{"wrong run", 456, "windows-test-reports-123-1", false, 200, 0},
		{"wrong digest", 456, "windows-test-reports-123-1", false, 200, 0},
		{"wrong attempt", 456, "windows-test-reports-123-2", false, 200, 0},
		{"expired", 456, "windows-test-reports-123-1", true, 200, 0},
		{"unauthorized", 456, "windows-test-reports-123-1", false, 401, 1},
		{"missing", 456, "windows-test-reports-123-1", false, 404, 1},
		{"retry bounded", 456, "windows-test-reports-123-1", false, 503, 3},
	} {
		t.Run(tc.name, func(t *testing.T) {
			digest := "sha256:" + strings.Repeat("a", 64)
			calls := 0
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if strings.HasSuffix(r.URL.Path, "/zip") {
					calls++
					w.WriteHeader(tc.status)
					return
				}
				metaRun, metaDigest := 123, digest
				if tc.name == "wrong run" {
					metaRun = 124
				}
				if tc.name == "wrong digest" {
					metaDigest = "sha256:" + strings.Repeat("b", 64)
				}
				fmt.Fprintf(w, `{"id":%d,"name":%q,"digest":%q,"size_in_bytes":100,"expired":%t,"workflow_run":{"id":%d}}`, tc.id, tc.nameValue, metaDigest, tc.expired, metaRun)
			}))
			defer server.Close()
			u, _ := url.Parse(server.URL)
			oldTransport := http.DefaultTransport
			http.DefaultTransport = fixtureTransport{u, server.Client().Transport}
			defer func() { http.DefaultTransport = oldTransport }()
			oldFlags, oldArgs := flag.CommandLine, os.Args
			defer func() { flag.CommandLine = oldFlags; os.Args = oldArgs }()
			flag.CommandLine = flag.NewFlagSet("test", flag.ContinueOnError)
			flag.CommandLine.SetOutput(io.Discard)
			os.Args = []string{"artifact_download", "--repo", "example/repo", "--run", "123", "--attempt", "1", "--id", "456", "--digest", digest, "--dest", filepath.Join(t.TempDir(), "result")}
			t.Setenv("GH_TOKEN", "fixture-token")
			err := run()
			if err == nil || calls != tc.wantCalls {
				t.Fatalf("calls=%d err=%v", calls, err)
			}
		})
	}
}

func TestRunRejectsUnsafeZIP(t *testing.T) {
	var b bytes.Buffer
	z := zip.NewWriter(&b)
	w, _ := z.Create("../escape")
	_, _ = w.Write([]byte("unsafe"))
	if err := z.Close(); err != nil {
		t.Fatal(err)
	}
	data := b.Bytes()
	sum := sha256.Sum256(data)
	digest := fmt.Sprintf("sha256:%x", sum)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/zip") {
			_, _ = w.Write(data)
			return
		}
		fmt.Fprintf(w, `{"id":456,"name":"windows-test-reports-123-1","digest":%q,"size_in_bytes":%d,"expired":false,"workflow_run":{"id":123}}`, digest, len(data))
	}))
	defer server.Close()
	u, _ := url.Parse(server.URL)
	oldTransport := http.DefaultTransport
	http.DefaultTransport = fixtureTransport{u, server.Client().Transport}
	defer func() { http.DefaultTransport = oldTransport }()
	oldFlags, oldArgs := flag.CommandLine, os.Args
	defer func() { flag.CommandLine = oldFlags; os.Args = oldArgs }()
	flag.CommandLine = flag.NewFlagSet("test", flag.ContinueOnError)
	flag.CommandLine.SetOutput(io.Discard)
	parent := t.TempDir()
	dest := filepath.Join(parent, "result")
	os.Args = []string{"artifact_download", "--repo", "example/repo", "--run", "123", "--attempt", "1", "--id", "456", "--digest", digest, "--dest", dest}
	t.Setenv("GH_TOKEN", "fixture-token")
	if err := run(); err == nil {
		t.Fatal("unsafe archive accepted")
	}
	if _, err := os.Stat(dest); !os.IsNotExist(err) {
		t.Fatalf("destination exists: %v", err)
	}
	if _, err := os.Stat(filepath.Join(parent, "escape")); !os.IsNotExist(err) {
		t.Fatalf("escape exists: %v", err)
	}
}

func TestRunRejectsInvalidArgumentsAndMissingToken(t *testing.T) {
	for _, tc := range []struct {
		name  string
		args  []string
		token string
	}{
		{"invalid identity", []string{"--repo", "invalid"}, "token"},
		{"missing token", []string{"--repo", "example/repo", "--run", "123", "--attempt", "1", "--id", "456", "--digest", "sha256:" + strings.Repeat("a", 64), "--dest", "out"}, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			oldFlags, oldArgs := flag.CommandLine, os.Args
			defer func() { flag.CommandLine = oldFlags; os.Args = oldArgs }()
			flag.CommandLine = flag.NewFlagSet("test", flag.ContinueOnError)
			flag.CommandLine.SetOutput(io.Discard)
			os.Args = append([]string{"artifact_download"}, tc.args...)
			t.Setenv("GH_TOKEN", tc.token)
			t.Setenv("GITHUB_TOKEN", "")
			if err := run(); err == nil {
				t.Fatal("invalid request accepted")
			}
		})
	}
}

func TestRunContextBoundsTotalRetryTime(t *testing.T) {
	digest := "sha256:" + strings.Repeat("a", 64)
	calls := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/zip") {
			calls++
			w.WriteHeader(503)
			return
		}
		fmt.Fprintf(w, `{"id":456,"name":"windows-test-reports-123-1","digest":%q,"size_in_bytes":100,"expired":false,"workflow_run":{"id":123}}`, digest)
	}))
	defer server.Close()
	u, _ := url.Parse(server.URL)
	oldTransport := http.DefaultTransport
	http.DefaultTransport = fixtureTransport{u, server.Client().Transport}
	defer func() { http.DefaultTransport = oldTransport }()
	oldFlags, oldArgs := flag.CommandLine, os.Args
	defer func() { flag.CommandLine = oldFlags; os.Args = oldArgs }()
	flag.CommandLine = flag.NewFlagSet("test", flag.ContinueOnError)
	flag.CommandLine.SetOutput(io.Discard)
	os.Args = []string{"artifact_download", "--repo", "example/repo", "--run", "123", "--attempt", "1", "--id", "456", "--digest", digest, "--dest", filepath.Join(t.TempDir(), "result")}
	t.Setenv("GH_TOKEN", "fixture-token")
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	start := time.Now()
	err := runContext(ctx)
	if err == nil || ctx.Err() != context.DeadlineExceeded || calls != 1 || time.Since(start) > time.Second {
		t.Fatalf("deadline not honored: calls=%d err=%v context=%v", calls, err, ctx.Err())
	}
}
