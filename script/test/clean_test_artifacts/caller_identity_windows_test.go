//go:build windows

package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestCallerIdentityLifecycle(t *testing.T) {
	root := filepath.Join(t.TempDir(), "root")
	now := time.Date(2026, 1, 3, 0, 0, 0, 0, time.UTC)
	var out bytes.Buffer
	if err := run([]string{"init", root}, &out, now); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{"create", root, "item", "--print-identity"}, &out, now); err != nil {
		t.Fatalf("create with caller identity: %v", err)
	}
	id := strings.TrimSpace(out.String())
	if id == "" {
		t.Fatal("missing identity from create")
	}
	p := filepath.Join(root, "item")
	m, err := readMetadata(p)
	if err != nil || !strings.HasPrefix(id, m.ID+"/") {
		t.Fatalf("create identity mismatch: %q %q %v", id, m.ID, err)
	}
	if err := os.WriteFile(filepath.Join(p, "data"), []byte("fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{"finish", root, "item", "2026-01-02T00:00:00Z", "--expected-identity", id}, &out, now); err != nil {
		t.Fatalf("finish: %v", err)
	}
	if err := run([]string{"clean", root, "item", "--expected-identity", id}, &out, now); err != nil {
		t.Fatalf("preview: %v", err)
	}
	if _, err := os.Stat(filepath.Join(p, "data")); err != nil {
		t.Fatalf("preview removed data: %v", err)
	}
	if err := run([]string{"clean", root, "item", "--expected-identity", id, "--delete"}, &out, now); err != nil {
		t.Fatalf("clean: %v", err)
	}
	if _, err := os.Stat(p); !os.IsNotExist(err) {
		t.Fatalf("item retained: %v", err)
	}
}

func TestCallerIdentityRejectsLegitimateReplacement(t *testing.T) {
	root := filepath.Join(t.TempDir(), "root")
	now := time.Date(2026, 1, 3, 0, 0, 0, 0, time.UTC)
	var out bytes.Buffer
	if err := run([]string{"init", root}, &out, now); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{"create", root, "item", "--print-identity"}, &out, now); err != nil {
		t.Fatalf("create with caller identity: %v", err)
	}
	id := strings.TrimSpace(out.String())
	p := filepath.Join(root, "item")
	if err := os.Rename(p, filepath.Join(root, "original")); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{"create", root, "item"}, &out, now); err != nil {
		t.Fatal(err)
	}
	canary := filepath.Join(p, "canary")
	if err := os.WriteFile(canary, []byte("replacement"), 0600); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{{"finish", root, "item", "2026-01-02T00:00:00Z", "--expected-identity", id}, {"clean", root, "item", "--expected-identity", id}, {"clean", root, "item", "--expected-identity", id, "--delete"}} {
		if err := run(args, &out, now); err == nil {
			t.Fatalf("accepted replacement: %v", args)
		}
		if data, err := os.ReadFile(canary); err != nil || string(data) != "replacement" {
			t.Fatalf("replacement lost: %q %v", data, err)
		}
	}
	if _, err := os.Stat(filepath.Join(root, "original", itemMarker)); err != nil {
		t.Fatalf("original lost: %v", err)
	}
}

func TestCallerIdentityRejectsSwapBeforeLock(t *testing.T) {
	for _, operation := range []string{"finish", "preview", "delete"} {
		t.Run(operation, func(t *testing.T) {
			parent := t.TempDir()
			root := filepath.Join(parent, "root")
			other := filepath.Join(parent, "other")
			now := time.Date(2026, 1, 3, 0, 0, 0, 0, time.UTC)
			var out bytes.Buffer
			for _, r := range []string{root, other} {
				if err := run([]string{"init", r}, &out, now); err != nil {
					t.Fatal(err)
				}
			}
			out.Reset()
			if err := run([]string{"create", root, "item", "--print-identity"}, &out, now); err != nil {
				t.Fatal(err)
			}
			id := strings.TrimSpace(out.String())
			if err := run([]string{"create", other, "item"}, &out, now); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(other, "item", "canary"), []byte("replacement"), 0600); err != nil {
				t.Fatal(err)
			}
			if operation != "finish" {
				for _, r := range []string{root, other} {
					if err := run([]string{"finish", r, "item", "2026-01-02T00:00:00Z"}, &out, now); err != nil {
						t.Fatal(err)
					}
				}
			}
			var swapErr error
			called := false
			beforeProcessLockHook = func() {
				called = true
				swapErr = os.Rename(filepath.Join(root, "item"), filepath.Join(root, "original"))
				if swapErr == nil {
					swapErr = os.Rename(filepath.Join(other, "item"), filepath.Join(root, "item"))
				}
			}
			defer func() { beforeProcessLockHook = nil }()
			args := []string{"clean", root, "item", "--expected-identity", id}
			if operation == "finish" {
				args = []string{"finish", root, "item", "2026-01-02T00:00:00Z", "--expected-identity", id}
			}
			if operation == "delete" {
				args = append(args, "--delete")
			}
			err := run(args, &out, now)
			if !called || swapErr != nil || err == nil {
				t.Fatalf("swap not rejected: called=%v swap=%v run=%v", called, swapErr, err)
			}
			if data, e := os.ReadFile(filepath.Join(root, "item", "canary")); e != nil || string(data) != "replacement" {
				t.Fatalf("replacement lost: %q %v", data, e)
			}
			if _, e := os.Stat(filepath.Join(root, "original", itemMarker)); e != nil {
				t.Fatalf("original lost: %v", e)
			}
		})
	}
}

func TestCallerIdentityInvalidArgumentsPreserveItem(t *testing.T) {
	root := filepath.Join(t.TempDir(), "root")
	now := time.Now()
	var out bytes.Buffer
	for _, args := range [][]string{{"init", root}, {"create", root, "item"}} {
		if err := run(args, &out, now); err != nil {
			t.Fatal(err)
		}
	}
	for _, args := range [][]string{
		{"create", root, "other", "--print-identity", "extra"},
		{"finish", root, "item", "2000-01-01T00:00:00Z", "--expected-identity", ""},
		{"finish", root, "item", "2000-01-01T00:00:00Z", "--expected-identity", "bad"},
		{"finish", root, "item", "2000-01-01T00:00:00Z", "--expected-identity"},
		{"clean", root, "item", "--expected-identity", ""},
		{"clean", root, "item", "--expected-identity", "bad", "--delete"},
		{"clean", root, "item", "--expected-identity"},
	} {
		if err := run(args, &out, now); err == nil {
			t.Errorf("accepted invalid args: %v", args)
		}
	}
	if _, err := os.Stat(filepath.Join(root, "item", itemMarker)); err != nil {
		t.Fatalf("item lost: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, "other")); !os.IsNotExist(err) {
		t.Fatalf("unexpected item: %v", err)
	}
}

func TestCallerIdentityLockedDeleteAndReceipt(t *testing.T) {
	root := filepath.Join(t.TempDir(), "root")
	now := time.Date(2026, 1, 3, 0, 0, 0, 0, time.UTC)
	var out bytes.Buffer
	if err := run([]string{"init", root}, &out, now); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{"create", root, "item", "--print-identity"}, &out, now); err != nil {
		t.Fatal(err)
	}
	id := strings.TrimSpace(out.String())
	p := filepath.Join(root, "item")
	if err := os.WriteFile(filepath.Join(p, "data"), []byte("fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{"finish", root, "item", "2026-01-02T00:00:00Z", "--expected-identity", id}, &out, now); err != nil {
		t.Fatal(err)
	}
	var renameErr, createErr error
	called := false
	beforeDeleteHook = func() {
		called = true
		renameErr = os.Rename(p, filepath.Join(root, "moved"))
		createErr = os.WriteFile(filepath.Join(p, "new"), []byte("unknown"), 0600)
	}
	defer func() { beforeDeleteHook = nil }()
	err := run([]string{"clean", root, "item", "--expected-identity", id, "--delete"}, &out, now)
	if !called || renameErr == nil {
		t.Fatalf("locked directory moved: called=%v rename=%v clean=%v", called, renameErr, err)
	}
	if createErr == nil {
		if err == nil {
			t.Fatal("unknown entry accepted")
		}
		if data, e := os.ReadFile(filepath.Join(p, "new")); e != nil || string(data) != "unknown" {
			t.Fatalf("new data lost: %q %v", data, e)
		}
		receipts, e := filepath.Glob(filepath.Join(root, ".windows_setup_cleanup_recovery_*"))
		if e != nil || len(receipts) != 1 {
			t.Fatalf("missing receipt: %v %v", receipts, e)
		}
		var receipt metadata
		b, e := os.ReadFile(receipts[0])
		if e != nil {
			t.Fatal(e)
		}
		if e = json.Unmarshal(b, &receipt); e != nil || receipt.CreateToken != strings.Split(id, "/")[1] || len(receipt.Nonce) != 64 || receipt.CreateToken == receipt.Nonce {
			t.Fatalf("invalid receipt identity: %v", e)
		}
	} else if err != nil {
		t.Fatalf("unexpected clean failure: %v", err)
	}
}

type failingRandom struct{}

func (failingRandom) Read([]byte) (int, error) { return 0, errors.New("injected random failure") }

func TestCallerIdentityRandomFailureDoesNotCreate(t *testing.T) {
	root := filepath.Join(t.TempDir(), "root")
	var out bytes.Buffer
	now := time.Now()
	if err := run([]string{"init", root}, &out, now); err != nil {
		t.Fatal(err)
	}
	old := createTokenRandom
	createTokenRandom = failingRandom{}
	defer func() { createTokenRandom = old }()
	if err := run([]string{"create", root, "item", "--print-identity"}, &out, now); err == nil || !strings.Contains(err.Error(), "injected random failure") {
		t.Fatalf("expected random failure: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, "item")); !os.IsNotExist(err) {
		t.Fatalf("item created: %v", err)
	}
}

func TestCallerIdentityRejectsReusedIDWithDifferentToken(t *testing.T) {
	root := filepath.Join(t.TempDir(), "root")
	var out bytes.Buffer
	now := time.Date(2026, 1, 3, 0, 0, 0, 0, time.UTC)
	if err := run([]string{"init", root}, &out, now); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{"create", root, "item", "--print-identity"}, &out, now); err != nil {
		t.Fatal(err)
	}
	old := strings.Split(strings.TrimSpace(out.String()), "/")
	if len(old) != 2 || len(old[1]) != 64 {
		t.Fatalf("missing create token: %q", out.String())
	}
	if err := os.Rename(filepath.Join(root, "item"), filepath.Join(root, "original")); err != nil {
		t.Fatal(err)
	}
	out.Reset()
	if err := run([]string{"create", root, "item", "--print-identity"}, &out, now); err != nil {
		t.Fatal(err)
	}
	replacement := strings.Split(strings.TrimSpace(out.String()), "/")
	if len(replacement) != 2 || replacement[1] == old[1] {
		t.Fatalf("new token missing or repeated: %q", out.String())
	}
	simulated := replacement[0] + "/" + old[1]
	if err := run([]string{"finish", root, "item", "2026-01-02T00:00:00Z", "--expected-identity", simulated}, &out, now); err == nil {
		t.Fatal("reused ID accepted with old token")
	}
	if _, err := os.Stat(filepath.Join(root, "item", itemMarker)); err != nil {
		t.Fatalf("replacement lost: %v", err)
	}
}

func TestCallerIdentityPreviewReadOnlyAndManifest(t *testing.T) {
	root := filepath.Join(t.TempDir(), "root")
	now := time.Date(2026, 1, 3, 0, 0, 0, 0, time.UTC)
	var out bytes.Buffer
	if err := run([]string{"init", root}, &out, now); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{"create", root, "item", "--print-identity"}, &out, now); err != nil {
		t.Fatal(err)
	}
	identity := strings.TrimSpace(out.String())
	token := strings.Split(identity, "/")[1]
	p := filepath.Join(root, "item")
	data := filepath.Join(p, "data")
	if err := os.WriteFile(data, []byte("original"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{"finish", root, "item", "2026-01-02T00:00:00Z", "--expected-identity", identity}, &out, now); err != nil {
		t.Fatal(err)
	}
	originalMarker, e := os.ReadFile(filepath.Join(p, itemMarker))
	if e != nil {
		t.Fatal(e)
	}
	originalFinish, e := os.ReadFile(filepath.Join(p, finishMarker))
	if e != nil {
		t.Fatal(e)
	}
	if !bytes.Contains(originalMarker, []byte(token)) || !bytes.Contains(originalFinish, []byte(token)) {
		t.Fatal("create token missing from markers")
	}
	if err := run([]string{"clean", root, "item", "--expected-identity", identity}, &out, now); err != nil {
		t.Fatal(err)
	}
	for path, want := range map[string][]byte{filepath.Join(p, itemMarker): originalMarker, filepath.Join(p, finishMarker): originalFinish, data: []byte("original")} {
		got, e := os.ReadFile(path)
		if e != nil || !bytes.Equal(got, want) {
			t.Fatalf("preview changed %s: %v", path, e)
		}
	}
	receipts, e := filepath.Glob(filepath.Join(root, ".windows_setup_cleanup_recovery_*"))
	if e != nil || len(receipts) != 0 {
		t.Fatalf("preview receipt: %v %v", receipts, e)
	}
	if err := os.WriteFile(data, []byte("changed"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{"clean", root, "item", "--expected-identity", identity}, &out, now); err == nil {
		t.Fatal("preview accepted changed content")
	}
	if got, e := os.ReadFile(data); e != nil || string(got) != "changed" {
		t.Fatalf("changed data lost: %q %v", got, e)
	}
	receipts, e = filepath.Glob(filepath.Join(root, ".windows_setup_cleanup_recovery_*"))
	if e != nil || len(receipts) != 0 {
		t.Fatalf("failed preview receipt: %v %v", receipts, e)
	}
}

func TestCallerIdentityRejectsMissingOrNullFinishedToken(t *testing.T) {
	for _, variant := range []string{"missing", "null"} {
		for _, operation := range []string{"preview", "delete"} {
			t.Run(variant+"/"+operation, func(t *testing.T) {
				root := filepath.Join(t.TempDir(), "root")
				now := time.Date(2026, 1, 3, 0, 0, 0, 0, time.UTC)
				var out bytes.Buffer
				if err := run([]string{"init", root}, &out, now); err != nil {
					t.Fatal(err)
				}
				if err := run([]string{"create", root, "item", "--print-identity"}, &out, now); err != nil {
					t.Fatal(err)
				}
				identity := strings.TrimSpace(out.String())
				data := filepath.Join(root, "item", "canary")
				if err := os.WriteFile(data, []byte("owned fixture"), 0600); err != nil {
					t.Fatal(err)
				}
				if err := run([]string{"finish", root, "item", "2026-01-02T00:00:00Z", "--expected-identity", identity}, &out, now); err != nil {
					t.Fatal(err)
				}
				finished := filepath.Join(root, "item", finishMarker)
				raw, err := os.ReadFile(finished)
				if err != nil {
					t.Fatal(err)
				}
				var fields map[string]json.RawMessage
				if err := json.Unmarshal(raw, &fields); err != nil {
					t.Fatal(err)
				}
				if variant == "missing" {
					delete(fields, "create_token")
				} else {
					fields["create_token"] = json.RawMessage("null")
				}
				raw, err = json.Marshal(fields)
				if err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(finished, raw, 0600); err != nil {
					t.Fatal(err)
				}
				args := []string{"clean", root, "item", "--expected-identity", identity}
				if operation == "delete" {
					args = append(args, "--delete")
				}
				out.Reset()
				if err := run(args, &out, now); err == nil {
					t.Errorf("accepted %s finished token for %s", variant, operation)
				}
				if strings.Contains(out.String(), "已核對身分") {
					t.Error("reported verified identity after rejection")
				}
				if got, err := os.ReadFile(data); err != nil || string(got) != "owned fixture" {
					t.Errorf("canary changed: %q %v", got, err)
				}
				if got, err := os.ReadFile(finished); err != nil || !bytes.Equal(got, raw) {
					t.Errorf("finished marker changed: %v", err)
				}
				if _, err := os.Stat(filepath.Join(root, "item", itemMarker)); err != nil {
					t.Errorf("item marker lost: %v", err)
				}
				receipts, err := filepath.Glob(filepath.Join(root, ".windows_setup_cleanup_recovery_*"))
				if err != nil || len(receipts) != 0 {
					t.Errorf("unexpected receipt: %v %v", receipts, err)
				}
			})
		}
	}
}

func TestCallerIdentityTokenCheckedAfterLock(t *testing.T) {
	root := filepath.Join(t.TempDir(), "root")
	now := time.Now()
	var out bytes.Buffer
	if err := run([]string{"init", root}, &out, now); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{"create", root, "item", "--print-identity"}, &out, now); err != nil {
		t.Fatal(err)
	}
	identity := strings.TrimSpace(out.String())
	marker := filepath.Join(root, "item", itemMarker)
	var changeErr error
	called := false
	beforeProcessLockHook = func() {
		called = true
		var m metadata
		m, changeErr = readMetadataFile(marker)
		if changeErr == nil {
			m.CreateToken = strings.Repeat("f", 64)
			changeErr = writeMetadata(filepath.Dir(marker), m)
		}
	}
	defer func() { beforeProcessLockHook = nil }()
	err := run([]string{"finish", root, "item", "2000-01-01T00:00:00Z", "--expected-identity", identity}, &out, now)
	if !called || changeErr != nil || err == nil {
		t.Fatalf("changed token accepted: called=%v change=%v run=%v", called, changeErr, err)
	}
	if _, e := os.Stat(filepath.Join(root, "item", finishMarker)); !os.IsNotExist(e) {
		t.Fatalf("finished despite changed token: %v", e)
	}
}

func TestCallerIdentityReceiptPreservesCreateToken(t *testing.T) {
	root := filepath.Join(t.TempDir(), "root")
	now := time.Date(2026, 1, 3, 0, 0, 0, 0, time.UTC)
	var out bytes.Buffer
	if err := run([]string{"init", root}, &out, now); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{"create", root, "item", "--print-identity"}, &out, now); err != nil {
		t.Fatal(err)
	}
	identity := strings.TrimSpace(out.String())
	token := strings.Split(identity, "/")[1]
	if err := run([]string{"finish", root, "item", "2026-01-02T00:00:00Z", "--expected-identity", identity}, &out, now); err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(root, "item")
	var createErr error
	beforeDeleteHook = func() { createErr = os.WriteFile(filepath.Join(p, "new"), []byte("unknown"), 0600) }
	defer func() { beforeDeleteHook = nil }()
	err := run([]string{"clean", root, "item", "--expected-identity", identity, "--delete"}, &out, now)
	if createErr != nil || err == nil {
		t.Fatalf("expected partial failure: create=%v clean=%v", createErr, err)
	}
	receipts, e := filepath.Glob(filepath.Join(root, ".windows_setup_cleanup_recovery_*"))
	if e != nil || len(receipts) != 1 {
		t.Fatalf("missing receipt: %v %v", receipts, e)
	}
	var receipt metadata
	b, e := os.ReadFile(receipts[0])
	if e != nil {
		t.Fatal(e)
	}
	if e = json.Unmarshal(b, &receipt); e != nil || receipt.CreateToken != token || len(receipt.Nonce) != 64 || receipt.Nonce == token {
		t.Fatalf("invalid receipt: %+v %v", receipt, e)
	}
	if got, e := os.ReadFile(filepath.Join(p, "new")); e != nil || string(got) != "unknown" {
		t.Fatalf("unknown data lost: %q %v", got, e)
	}
}

type failingOutput struct{}

func (failingOutput) Write([]byte) (int, error) { return 0, errors.New("injected output failure") }

func TestCallerIdentityRejectsInvalidEncodingAndOutputFailure(t *testing.T) {
	root := filepath.Join(t.TempDir(), "root")
	now := time.Now()
	var out bytes.Buffer
	if err := run([]string{"init", root}, &out, now); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{"create", root, "item", "--print-identity"}, &out, now); err != nil {
		t.Fatal(err)
	}
	identity := strings.TrimSpace(out.String())
	parts := strings.Split(identity, "/")
	for _, bad := range []string{parts[0], parts[0] + "/" + strings.Repeat("z", 64), parts[0] + "/" + strings.Repeat("A", 64), "bad/" + parts[1], strings.Repeat("z", 8) + parts[0][8:] + "/" + parts[1]} {
		if err := run([]string{"finish", root, "item", "2000-01-01T00:00:00Z", "--expected-identity", bad}, &out, now); err == nil {
			t.Errorf("accepted invalid identity %q", bad)
		}
	}
	if err := run([]string{"create", root, "output_failure", "--print-identity"}, failingOutput{}, now); err == nil || !strings.Contains(err.Error(), "injected output failure") {
		t.Fatalf("output failure hidden: %v", err)
	}
	m, err := readMetadata(filepath.Join(root, "output_failure"))
	if err != nil || len(m.CreateToken) != 64 {
		t.Fatalf("created item marker not retained: %+v %v", m, err)
	}
}
