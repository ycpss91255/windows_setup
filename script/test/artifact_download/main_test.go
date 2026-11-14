package main

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

func TestDownloadRetryAndValidation(t *testing.T) {
	data := []byte("artifact bytes")
	sum := sha256.Sum256(data)
	for _, tc := range []struct {
		name         string
		status, want int
		digest       string
		truncate     bool
		ok           bool
	}{
		{"503 then success", 503, 2, hex.EncodeToString(sum[:]), false, true},
		{"unauthorized", 401, 1, hex.EncodeToString(sum[:]), false, false},
		{"missing", 404, 1, hex.EncodeToString(sum[:]), false, false},
		{"wrong digest", 200, 1, fmt.Sprintf("%064d", 0), false, false},
		{"incomplete", 200, 1, hex.EncodeToString(sum[:]), true, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			count := 0
			s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				count++
				if count == 1 && tc.status != 200 {
					w.WriteHeader(tc.status)
					return
				}
				if tc.truncate {
					w.Header().Set("Content-Length", "100")
				}
				_, _ = w.Write(data)
			}))
			defer s.Close()
			result, err := download(context.Background(), s.Client(), s.URL, "", tc.digest, 3, time.Millisecond)
			if (err == nil) != tc.ok || count != tc.want || (tc.ok && !bytes.Equal(result, data)) {
				t.Fatalf("calls=%d err=%v", count, err)
			}
		})
	}
}

func TestDownloadDeadline(t *testing.T) {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { <-r.Context().Done() }))
	defer s.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	_, err := download(ctx, s.Client(), s.URL, "", fmt.Sprintf("%064d", 0), 3, time.Millisecond)
	if err == nil || ctx.Err() == nil {
		t.Fatalf("deadline not honored: %v", err)
	}
}

func TestArchiveRejectsUnsafeEntries(t *testing.T) {
	if err := unpack([]byte("not zip"), t.TempDir()); err == nil {
		t.Fatal("invalid archive accepted")
	}
	_ = io.EOF
}

func TestMetadataIdentity(t *testing.T) {
	const digest = "sha256:abc"
	for _, tc := range []struct {
		name, payload string
		ok            bool
	}{
		{"correct", `{"id":456,"name":"windows-test-reports-123-1","digest":"sha256:abc","size_in_bytes":100,"expired":false,"workflow_run":{"id":123}}`, true},
		{"wrong id", `{"id":457,"name":"windows-test-reports-123-1","digest":"sha256:abc","size_in_bytes":100,"expired":false,"workflow_run":{"id":123}}`, false},
		{"wrong run", `{"id":456,"name":"windows-test-reports-123-1","digest":"sha256:abc","size_in_bytes":100,"expired":false,"workflow_run":{"id":124}}`, false},
		{"wrong attempt", `{"id":456,"name":"windows-test-reports-123-2","digest":"sha256:abc","size_in_bytes":100,"expired":false,"workflow_run":{"id":123}}`, false},
		{"wrong digest", `{"id":456,"name":"windows-test-reports-123-1","digest":"sha256:def","size_in_bytes":100,"expired":false,"workflow_run":{"id":123}}`, false},
		{"expired", `{"id":456,"name":"windows-test-reports-123-1","digest":"sha256:abc","size_in_bytes":100,"expired":true,"workflow_run":{"id":123}}`, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			err := validateMetadata(strings.NewReader(tc.payload), "456", "123", 1, digest, "native")
			if (err == nil) != tc.ok {
				t.Fatalf("identity validation: %v", err)
			}
		})
	}
}

func TestArchiveRejectsTraversalAndSymlinks(t *testing.T) {
	for _, tc := range []struct {
		name string
		mode os.FileMode
	}{{"../escape", 0600}, {"dir/../../escape", 0600}, {"link", os.ModeSymlink | 0777}} {
		t.Run(tc.name, func(t *testing.T) {
			var b bytes.Buffer
			zw := zip.NewWriter(&b)
			header := &zip.FileHeader{Name: tc.name}
			header.SetMode(tc.mode)
			w, err := zw.CreateHeader(header)
			if err != nil {
				t.Fatal(err)
			}
			_, _ = w.Write([]byte("content"))
			if err = zw.Close(); err != nil {
				t.Fatal(err)
			}
			if err = unpack(b.Bytes(), t.TempDir()); err == nil {
				t.Fatal("unsafe entry accepted")
			}
		})
	}
}

func TestDownloadExhaustsBoundedAttempts(t *testing.T) {
	count := 0
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { count++; w.WriteHeader(503) }))
	defer s.Close()
	_, err := download(context.Background(), s.Client(), s.URL, "", fmt.Sprintf("%064d", 0), 3, time.Millisecond)
	if err == nil || count != 3 {
		t.Fatalf("calls=%d err=%v", count, err)
	}
}

func TestMetadataRejectsOverflowingExpectedIDs(t *testing.T) {
	const digest = "sha256:abc"
	const max = "9223372036854775807"
	const overflow = "9223372036854775808"
	for _, tc := range []struct{ name, id, run, metaID, metaRun string }{
		{"artifact", overflow, "123", max, "123"},
		{"run", "456", overflow, "456", max},
	} {
		t.Run(tc.name, func(t *testing.T) {
			payload := fmt.Sprintf(`{"id":%s,"name":"windows-test-reports-%s-1","digest":%q,"size_in_bytes":100,"expired":false,"workflow_run":{"id":%s}}`, tc.metaID, tc.run, digest, tc.metaRun)
			if err := validateMetadata(strings.NewReader(payload), tc.id, tc.run, 1, digest, "native"); err == nil {
				t.Fatal("overflowing expected identity was accepted as a different ID")
			}
		})
	}
}

func TestContainerMetadataIdentityAndBounds(t *testing.T) {
	const valid = `{"id":457,"name":"docker-test-reports-123-1","digest":"sha256:abc","size_in_bytes":100,"expired":false,"workflow_run":{"id":123}}`
	for _, tc := range []struct {
		name, payload, kind string
		ok                  bool
	}{
		{"valid", valid, "container", true},
		{"wrong kind", valid, "native", false},
		{"wrong run", strings.Replace(valid, `"id":123`, `"id":124`, 1), "container", false},
		{"wrong attempt", strings.Replace(valid, "123-1", "123-2", 1), "container", false},
		{"expired", strings.Replace(valid, `"expired":false`, `"expired":true`, 1), "container", false},
		{"oversize", strings.Replace(valid, `"size_in_bytes":100`, `"size_in_bytes":536870913`, 1), "container", false},
		{"unknown kind", valid, "other", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			err := validateMetadata(strings.NewReader(tc.payload), "457", "123", 1, "sha256:abc", tc.kind)
			if (err == nil) != tc.ok {
				t.Fatalf("identity validation: %v", err)
			}
		})
	}
}
