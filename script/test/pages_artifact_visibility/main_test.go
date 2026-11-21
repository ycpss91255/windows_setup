package main

import (
	"context"
	"encoding/base64"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func fixtureToken() string {
	return "e30." + base64.RawURLEncoding.EncodeToString([]byte(`{"scp":"Actions.Results:fixture-run:fixture-job"}`)) + ".sig"
}
func TestVisibilityPreflight(t *testing.T) {
	for _, tc := range []struct {
		name, restMode, runtimeMode string
		wantOK                      bool
		wantRuntime                 int
	}{
		{"visible", "valid", "valid", true, 1},
		{"runtime eventually visible", "valid", "later", true, 2},
		{"runtime omitted list then visible", "valid", "omitted", true, 2},
		{"runtime missing deadline", "valid", "missing", false, 0},
		{"runtime duplicate", "valid", "duplicate", false, 1},
		{"runtime wrong id", "valid", "wrong", false, 1},
		{"runtime unauthorized", "valid", "unauthorized", false, 1},
		{"rest duplicate", "duplicate", "valid", false, 0},
		{"rest expired", "expired", "valid", false, 0},
		{"rest wrong id", "wrong", "valid", false, 0},
		{"rest string id", "string_id", "valid", false, 0},
		{"rest wrong digest", "digest", "valid", false, 0},
		{"rest different valid digest", "different_digest", "valid", false, 0},
		{"rest unauthorized", "unauthorized", "valid", false, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var runtimeCalls, restCalls int32
			digest := "sha256:" + strings.Repeat("a", 64)
			name := "github-pages-123-2"
			rest := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				atomic.AddInt32(&restCalls, 1)
				if r.Header.Get("Authorization") != "Bearer rest-fixture" {
					t.Error("wrong REST auth")
				}
				if tc.restMode == "unauthorized" {
					w.WriteHeader(401)
					return
				}
				id, expired, d := 456, false, digest
				if tc.restMode == "wrong" {
					id = 457
				}
				if tc.restMode == "expired" {
					expired = true
				}
				if tc.restMode == "digest" {
					d = "bad"
				}
				if tc.restMode == "different_digest" {
					d = "sha256:" + strings.Repeat("b", 64)
				}
				row := fmt.Sprintf(`{"id":%d,"name":%q,"digest":%q,"size_in_bytes":100,"expired":%t,"workflow_run":{"id":123}}`, id, name, d, expired)
				if tc.restMode == "string_id" {
					row = strings.Replace(row, `"id":456`, `"id":"456"`, 1)
				}
				rows := row
				if tc.restMode == "duplicate" {
					rows += "," + row
				}
				fmt.Fprintf(w, `{"total_count":%d,"artifacts":[%s]}`, 1, rows)
			}))
			defer rest.Close()
			runtime := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				n := atomic.AddInt32(&runtimeCalls, 1)
				if tc.runtimeMode == "unauthorized" {
					w.WriteHeader(http.StatusUnauthorized)
					return
				}
				if tc.runtimeMode == "omitted" && n == 1 {
					fmt.Fprint(w, `{}`)
					return
				}
				if r.URL.Path != "/twirp/github.actions.results.api.v1.ArtifactService/ListArtifacts" {
					t.Error("wrong runtime path")
				}
				if r.Header.Get("Authorization") != "Bearer "+fixtureToken() {
					t.Error("wrong runtime auth")
				}
				row := fmt.Sprintf(`{"database_id":"456","name":%q,"size":"100"}`, name)
				if tc.runtimeMode == "wrong" {
					row = fmt.Sprintf(`{"database_id":"457","name":%q,"size":"100"}`, name)
				}
				if tc.runtimeMode == "missing" || (tc.runtimeMode == "later" && n == 1) {
					row = ""
				}
				if tc.runtimeMode == "duplicate" {
					row += "," + row
				}
				fmt.Fprintf(w, `{"artifacts":[%s]}`, row)
			}))
			defer runtime.Close()
			ctx, cancel := context.WithTimeout(context.Background(), 80*time.Millisecond)
			defer cancel()
			o := options{client: rest.Client(), restURL: rest.URL, runtimeURL: runtime.URL, token: "rest-fixture", runtimeToken: fixtureToken(), repo: "example/repo", runID: "123", artifactID: "456", expectedDigest: digest, name: name, interval: time.Millisecond}
			err := observe(ctx, o)
			calls := int(atomic.LoadInt32(&runtimeCalls))
			if (err == nil) != tc.wantOK {
				t.Errorf("success=%t err=%v", tc.wantOK, err)
			}
			if tc.wantRuntime > 0 && calls != tc.wantRuntime {
				t.Errorf("runtime calls=%d want=%d", calls, tc.wantRuntime)
			}
			if tc.wantRuntime == 0 && tc.runtimeMode != "missing" && calls != 0 {
				t.Errorf("unexpected runtime calls=%d", calls)
			}
			if tc.restMode == "unauthorized" && atomic.LoadInt32(&restCalls) != 1 {
				t.Error("401 retried")
			}
		})
	}
}

func TestConfigurationFailsClosed(t *testing.T) {
	for _, token := range []string{"", "a.b.c", "e30.e30.sig", "e30." + base64.RawURLEncoding.EncodeToString([]byte(`{"scp":"Actions.Results:r:j Actions.Results:x:y"}`)) + ".sig"} {
		if _, _, err := runtimeScope(token); err == nil {
			t.Fatal("invalid runtime scope accepted")
		}
	}
	t.Setenv("GITHUB_RUN_ATTEMPT", "0")
	if err := run(); err == nil {
		t.Fatal("zero attempt accepted")
	}
	t.Setenv("GITHUB_RUN_ATTEMPT", "1")
	t.Setenv("ACTIONS_RESULTS_URL", "http://example.com")
	if err := run(); err == nil {
		t.Fatal("insecure runtime URL accepted")
	}
	t.Setenv("ACTIONS_RESULTS_URL", "https://user@example.com")
	if err := run(); err == nil {
		t.Fatal("runtime URL userinfo accepted")
	}
	if err := observe(context.Background(), options{}); err == nil {
		t.Fatal("empty configuration accepted")
	}
}

func TestResponseSizeAndRedirectRejected(t *testing.T) {
	for _, tc := range []struct {
		name    string
		handler http.HandlerFunc
	}{
		{"oversize", func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, strings.Repeat("x", maxResponse+1)) }},
		{"redirect", func(w http.ResponseWriter, r *http.Request) {
			http.Redirect(w, r, "https://example.com", http.StatusFound)
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			server := httptest.NewServer(tc.handler)
			defer server.Close()
			err := getJSON(context.Background(), options{client: server.Client()}, http.MethodGet, server.URL, "fixture-secret", nil, &struct{}{})
			if err == nil || strings.Contains(err.Error(), "fixture-secret") {
				t.Fatalf("unsafe response result: %v", err)
			}
		})
	}
}

func TestRESTPaginationAndDuplicateAcrossPages(t *testing.T) {
	for _, duplicate := range []bool{false, true} {
		t.Run(fmt.Sprintf("duplicate=%t", duplicate), func(t *testing.T) {
			calls := 0
			name := "github-pages-123-2"
			digest := "sha256:" + strings.Repeat("a", 64)
			row := fmt.Sprintf(`{"id":456,"name":%q,"digest":%q,"size_in_bytes":100,"expired":false,"workflow_run":{"id":123}}`, name, digest)
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls++
				if r.URL.Query().Get("page") == "1" {
					rows := make([]string, 100)
					for i := range rows {
						rows[i] = `{"name":"other"}`
					}
					if duplicate {
						rows[0] = row
					}
					fmt.Fprintf(w, `{"artifacts":[%s]}`, strings.Join(rows, ","))
					return
				}
				fmt.Fprintf(w, `{"artifacts":[%s]}`, row)
			}))
			defer server.Close()
			ok, err := restVisible(context.Background(), options{client: server.Client(), restURL: server.URL, token: "fixture", repo: "example/repo", runID: "123", artifactID: "456", expectedDigest: digest, name: name})
			if calls != 2 || ok == duplicate || (err != nil) != duplicate {
				t.Fatalf("calls=%d ok=%t err=%v", calls, ok, err)
			}
		})
	}
}

func TestNullRuntimeResponseIsNotMissingArtifact(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, `null`) }))
	defer server.Close()
	_, err := runtimeVisible(context.Background(), options{client: server.Client(), runtimeURL: server.URL, runtimeToken: fixtureToken(), name: "github-pages-123-2", artifactID: "456"}, "fixture-run", "fixture-job")
	if err == nil {
		t.Fatal("null response accepted as empty artifact list")
	}
}
