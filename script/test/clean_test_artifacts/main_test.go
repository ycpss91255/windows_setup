//go:build windows

package main

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
	"unsafe"
)

func TestNativeCreateRejectsIncompleteResults(t *testing.T) {
	for _, tc := range []struct {
		name                          string
		status, ioStatus, information uintptr
		valid                         bool
	}{
		{"pending", 0x103, 0x103, 0, false},
		{"invalid handle", 0, 0, 2, false},
		{"incomplete io", 0, 0x103, 2, true},
		{"not created", 0, 0, 1, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var held lockedEntry
			if tc.valid {
				var e error
				held, _, e = openLocked(t.TempDir(), false)
				if e != nil {
					t.Fatal(e)
				}
			}
			ntCreateFileTestHook = func(h *syscall.Handle, ios *ioStatusBlock) uintptr {
				*h = syscall.InvalidHandle
				if tc.valid {
					*h = held.h
				}
				ios.Status, ios.Information = tc.ioStatus, tc.information
				return tc.status
			}
			defer func() { ntCreateFileTestHook = nil }()
			h, err := createRelativeDirectory(0, "child")
			if err == nil {
				if tc.valid {
					syscall.CloseHandle(h)
				}
				t.Fatalf("accepted incomplete native result: %#x", tc.status)
			}
		})
	}
}

func TestFinishWriteFailurePreservesOwnership(t *testing.T) {
	root := filepath.Join(t.TempDir(), "owned")
	now := time.Now()
	var out bytes.Buffer
	for _, a := range [][]string{{"init", root}, {"create", root, "item"}} {
		if e := run(a, &out, now); e != nil {
			t.Fatal(e)
		}
	}
	marker := filepath.Join(root, "item", itemMarker)
	before, e := os.ReadFile(marker)
	if e != nil {
		t.Fatal(e)
	}
	finishWriteTestHook = func() error { return errors.New("injected write failure") }
	defer func() { finishWriteTestHook = nil }()
	if e := run([]string{"finish", root, "item", "2026-01-02T00:00:00Z"}, &out, now); e == nil || !strings.Contains(e.Error(), "injected") {
		t.Fatalf("expected injected failure: %v", e)
	}
	after, e := os.ReadFile(marker)
	if e != nil || !bytes.Equal(after, before) {
		t.Fatalf("ownership marker lost: %q %v", after, e)
	}
	if e := run([]string{"clean", root, "item", "--delete"}, &out, now); e == nil {
		t.Fatal("incomplete finish accepted")
	}
}

func TestCreateWithoutNewDirectoryAPI(t *testing.T) {
	root := filepath.Join(t.TempDir(), "owned")
	called := 0
	nativeCreateTestHook = func() { called++ }
	defer func() { nativeCreateTestHook = nil }()
	var out bytes.Buffer
	if e := run([]string{"init", root}, &out, time.Now()); e != nil {
		t.Fatalf("safe creation requires newer optional API: %v", e)
	}
	if e := run([]string{"create", root, "item"}, &out, time.Now()); e != nil {
		t.Fatalf("safe item creation requires newer optional API: %v", e)
	}
	if called != 2 {
		t.Fatalf("expected native relative creation twice, got %d", called)
	}
}

func TestInitRejectsOutsideConfiguredTemp(t *testing.T) {
	parent := t.TempDir()
	temp := filepath.Join(parent, "temp")
	if e := os.Mkdir(temp, 0700); e != nil {
		t.Fatal(e)
	}
	t.Setenv("TEMP", temp)
	t.Setenv("TMP", temp)
	outside := filepath.Join(parent, "outside")
	var out bytes.Buffer
	if e := run([]string{"init", outside}, &out, time.Now()); e == nil {
		t.Fatal("outside configured TEMP accepted")
	}
	if _, e := os.Stat(outside); !os.IsNotExist(e) {
		t.Fatalf("outside path created: %v", e)
	}
}

func TestConfiguredTempShortAliasSupportsOwnedRoot(t *testing.T) {
	parent := t.TempDir()
	base := filepath.Join(parent, "long temporary directory")
	if err := os.Mkdir(base, 0700); err != nil {
		t.Fatal(err)
	}
	ptr, err := syscall.UTF16PtrFromString(base)
	if err != nil {
		t.Fatal(err)
	}
	buffer := make([]uint16, 32768)
	proc := syscall.NewLazyDLL("kernel32.dll").NewProc("GetShortPathNameW")
	n, _, callErr := proc.Call(uintptr(unsafe.Pointer(ptr)), uintptr(unsafe.Pointer(&buffer[0])), uintptr(len(buffer)))
	if n == 0 || n >= uintptr(len(buffer)) {
		t.Fatalf("short path query failed: %v", callErr)
	}
	short := syscall.UTF16ToString(buffer[:n])
	if strings.EqualFold(short, base) {
		t.Skip("volume does not provide a distinct short alias")
	}
	// Preserve a long leaf while shortening its ancestor: Windows can return
	// a different mixture of aliases for the same directory.
	parentPtr, err := syscall.UTF16PtrFromString(parent)
	if err != nil {
		t.Fatal(err)
	}
	n, _, callErr = proc.Call(uintptr(unsafe.Pointer(parentPtr)), uintptr(unsafe.Pointer(&buffer[0])), uintptr(len(buffer)))
	if n == 0 || n >= uintptr(len(buffer)) {
		t.Fatalf("short parent query failed: %v", callErr)
	}
	partial := filepath.Join(syscall.UTF16ToString(buffer[:n]), filepath.Base(base))
	t.Setenv("TMP", short)
	t.Setenv("TEMP", short)
	var out bytes.Buffer
	now := time.Date(2026, 1, 3, 0, 0, 0, 0, time.UTC)
	for _, root := range []string{filepath.Join(base, "long_root"), filepath.Join(short, "short_root"), filepath.Join(partial, "partial_root")} {
		for _, args := range [][]string{{"init", root}, {"create", root, "item"}, {"finish", root, "item", "2026-01-02T00:00:00Z"}, {"clean", root, "item", "--delete"}} {
			if err := run(args, &out, now); err != nil {
				t.Fatalf("%s failed under short TEMP: %v", args[0], err)
			}
		}
	}
}

func TestConfiguredTempAliasMatrixAndNestedRoot(t *testing.T) {
	parent := t.TempDir()
	base := filepath.Join(parent, "long temporary directory")
	nested := filepath.Join(base, "long nested directory")
	if err := os.MkdirAll(nested, 0700); err != nil {
		t.Fatal(err)
	}
	shortPath := func(path string) string {
		ptr, err := syscall.UTF16PtrFromString(path)
		if err != nil {
			t.Fatal(err)
		}
		buf := make([]uint16, 32768)
		n, _, callErr := syscall.NewLazyDLL("kernel32.dll").NewProc("GetShortPathNameW").Call(uintptr(unsafe.Pointer(ptr)), uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
		if n == 0 || n >= uintptr(len(buf)) {
			t.Fatalf("short path query: %v", callErr)
		}
		return syscall.UTF16ToString(buf[:n])
	}
	shortBase, shortNested := shortPath(base), shortPath(nested)
	if strings.EqualFold(shortBase, base) || strings.EqualFold(shortNested, nested) {
		t.Skip("volume does not provide distinct aliases")
	}
	partial := filepath.Join(shortPath(parent), filepath.Base(base), filepath.Base(nested))
	now := time.Date(2026, 1, 3, 0, 0, 0, 0, time.UTC)
	for i, temp := range []string{base, shortBase} {
		t.Setenv("TMP", temp)
		t.Setenv("TEMP", temp)
		for j, dir := range []string{nested, partial, shortNested} {
			root := filepath.Join(dir, fmt.Sprintf("long owned root %d %d", i, j))
			var out bytes.Buffer
			if err := run([]string{"init", root}, &out, now); err != nil {
				t.Fatalf("init %s: %v", root, err)
			}
			shortRoot := shortPath(root)
			for _, args := range [][]string{{"create", shortRoot, "item"}, {"finish", root, "item", "2026-01-02T00:00:00Z"}, {"clean", shortRoot, "item", "--delete"}} {
				if err := run(args, &out, now); err != nil {
					t.Fatalf("%s %s: %v", args[0], args[1], err)
				}
			}
		}
	}
}

func TestConfiguredTempReparseIsRejected(t *testing.T) {
	parent := t.TempDir()
	target, alias := filepath.Join(parent, "target"), filepath.Join(parent, "alias")
	if err := os.Mkdir(target, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, alias); err != nil {
		t.Skipf("symlink unavailable: %v", err)
	}
	t.Setenv("TMP", alias)
	t.Setenv("TEMP", alias)
	var out bytes.Buffer
	if err := run([]string{"init", filepath.Join(alias, "owned")}, &out, time.Now()); err == nil {
		t.Fatal("reparse TEMP accepted")
	}
	if _, err := os.Stat(filepath.Join(target, "owned")); !os.IsNotExist(err) {
		t.Fatalf("created through reparse: %v", err)
	}
}

func TestTempReplacementBeforeAncestorLockRejected(t *testing.T) {
	parent := t.TempDir()
	base := filepath.Join(parent, "base")
	if err := os.Mkdir(base, 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("TMP", base)
	t.Setenv("TEMP", base)
	var out bytes.Buffer
	var swapErr error
	called := false
	beforeTempLockTestHook = func() {
		called = true
		swapErr = os.Rename(base, filepath.Join(parent, "moved"))
		if swapErr == nil {
			swapErr = os.Mkdir(base, 0700)
		}
	}
	defer func() { beforeTempLockTestHook = nil }()
	err := run([]string{"init", filepath.Join(base, "owned")}, &out, time.Now())
	if !called || swapErr != nil {
		t.Fatalf("swap not performed: %v %v", called, swapErr)
	}
	if err == nil {
		t.Fatal("replacement TEMP accepted")
	}
	if _, statErr := os.Stat(filepath.Join(base, "owned")); !os.IsNotExist(statErr) {
		t.Fatalf("created inside replaced TEMP: %v", statErr)
	}
}

func TestOwnedArtifactsRequireSelectionCompletionAndExpiry(t *testing.T) {
	parent := t.TempDir()
	root := filepath.Join(parent, "owned")
	now := time.Date(2026, 1, 3, 0, 0, 0, 0, time.UTC)
	var out bytes.Buffer
	if err := run([]string{"init", root}, &out, now); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{"create", root, "done"}, &out, now); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "done", "payload"), []byte("fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{"finish", root, "done", "2026-01-02T00:00:00Z"}, &out, now); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{"create", root, "active"}, &out, now); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(root, "unknown"), 0700); err != nil {
		t.Fatal(err)
	}
	out.Reset()
	if err := run([]string{"clean", root, "done"}, &out, now); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "done") {
		t.Fatalf("preview missing selection: %q", out.String())
	}
	if !strings.Contains(out.String(), "候選") {
		t.Fatalf("preview does not distinguish candidate from verified deletion: %q", out.String())
	}
	if _, err := os.Stat(filepath.Join(root, "done", "payload")); err != nil {
		t.Fatal("dry run deleted fixture", err)
	}
	if err := run([]string{"clean", root, "active", "--delete"}, &out, now); err == nil {
		t.Fatal("active artifact accepted")
	}
	if err := run([]string{"clean", root, "unknown", "--delete"}, &out, now); err == nil {
		t.Fatal("unknown artifact accepted")
	}
	if err := run([]string{"clean", root, "done", "--delete"}, &out, now); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, "done")); !os.IsNotExist(err) {
		t.Fatal("completed selected fixture remains", err)
	}
	if _, err := os.Stat(filepath.Join(root, "active")); err != nil {
		t.Fatal("active fixture removed", err)
	}
	if receipts, err := filepath.Glob(filepath.Join(root, ".windows_setup_cleanup_recovery_*")); err != nil || len(receipts) != 0 {
		t.Fatalf("receipt remains after successful deletion: %v %v", receipts, err)
	}
}

func TestCreatedDirectoryReplacementDoesNotOverwriteMarker(t *testing.T) {
	for _, action := range []string{"init", "create"} {
		t.Run(action, func(t *testing.T) {
			parent := t.TempDir()
			root := filepath.Join(parent, "owned")
			now := time.Now()
			var out bytes.Buffer
			if action == "create" {
				if e := run([]string{"init", root}, &out, now); e != nil {
					t.Fatal(e)
				}
			}
			path, marker := root, rootMarker
			args := []string{"init", root}
			if action == "create" {
				path, marker = filepath.Join(root, "item"), itemMarker
				args = []string{"create", root, "item"}
			}
			var swapErr error
			called := false
			afterCreateDirectoryHook = func(p string) {
				called = true
				swapErr = os.Rename(p, p+"-moved")
				if swapErr == nil {
					swapErr = os.Mkdir(p, 0700)
				}
				if swapErr == nil {
					swapErr = os.WriteFile(filepath.Join(p, marker), []byte("unowned"), 0600)
				}
			}
			defer func() { afterCreateDirectoryHook = nil }()
			err := run(args, &out, now)
			if !called {
				t.Fatalf("hook not reached: %v", err)
			}
			if swapErr == nil {
				if err == nil {
					t.Error("replacement accepted")
				}
				if b, e := os.ReadFile(filepath.Join(path, marker)); e != nil || string(b) != "unowned" {
					t.Errorf("unowned marker changed: %q %v", b, e)
				}
			}
		})
	}
}

func TestCreationLocksAncestorAgainstReplacement(t *testing.T) {
	parent := t.TempDir()
	ancestor := filepath.Join(parent, "ancestor")
	if e := os.Mkdir(ancestor, 0700); e != nil {
		t.Fatal(e)
	}
	root := filepath.Join(ancestor, "owned")
	var out bytes.Buffer
	called := false
	var renameErr error
	afterCreateDirectoryHook = func(string) { called = true; renameErr = os.Rename(ancestor, filepath.Join(parent, "moved")) }
	defer func() { afterCreateDirectoryHook = nil }()
	if e := run([]string{"init", root}, &out, time.Now()); e != nil {
		t.Fatal(e)
	}
	if !called || renameErr == nil {
		t.Fatalf("ancestor replacement was not blocked: called=%v error=%v", called, renameErr)
	}
	if b, e := os.ReadFile(filepath.Join(root, rootMarker)); e != nil || string(b) != rootContent {
		t.Fatalf("root marker invalid: %q %v", b, e)
	}
}

func TestRejectExistingRootTraversalAndFutureExpiry(t *testing.T) {
	parent := t.TempDir()
	root := filepath.Join(parent, "owned")
	var out bytes.Buffer
	now := time.Date(2026, 1, 3, 0, 0, 0, 0, time.UTC)
	if err := run([]string{"init", parent}, &out, now); err == nil {
		t.Fatal("existing root accepted")
	}
	if err := run([]string{"init", root}, &out, now); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{"create", root, "../escape"}, &out, now); err == nil {
		t.Fatal("traversal accepted")
	}
	if err := run([]string{"create", root, "future"}, &out, now); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{"finish", root, "future", "2026-02-01T00:00:00Z"}, &out, now); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{"clean", root, "future", "--delete"}, &out, now); err == nil {
		t.Fatal("unexpired artifact accepted")
	}
}

func TestRejectReparseWithinSelectedArtifact(t *testing.T) {
	parent := t.TempDir()
	root := filepath.Join(parent, "owned")
	outside := filepath.Join(parent, "outside")
	var out bytes.Buffer
	now := time.Date(2026, 1, 3, 0, 0, 0, 0, time.UTC)
	if err := os.Mkdir(outside, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(outside, "keep"), []byte("fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{"init", root}, &out, now); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{"create", root, "linked"}, &out, now); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(root, "linked", "link")); err != nil {
		t.Skipf("symlink unavailable: %v", err)
	}
	if err := run([]string{"finish", root, "linked", "2026-01-02T00:00:00Z"}, &out, now); err == nil {
		t.Fatal("finish accepted reparse")
	}
	if err := run([]string{"clean", root, "linked", "--delete"}, &out, now); err == nil {
		t.Fatal("reparse accepted")
	}
	if _, err := os.Stat(filepath.Join(outside, "keep")); err != nil {
		t.Fatal(err)
	}
}

func TestCopiedMarkerDoesNotAuthorizeAnotherDirectory(t *testing.T) {
	parent := t.TempDir()
	root := filepath.Join(parent, "owned")
	now := time.Date(2026, 1, 3, 0, 0, 0, 0, time.UTC)
	var out bytes.Buffer
	for _, args := range [][]string{{"init", root}, {"create", root, "original"}, {"finish", root, "original", "2026-01-02T00:00:00Z"}} {
		if err := run(args, &out, now); err != nil {
			t.Fatal(err)
		}
	}
	copied := filepath.Join(root, "unowned")
	if err := os.Mkdir(copied, 0700); err != nil {
		t.Fatal(err)
	}
	marker, err := os.ReadFile(filepath.Join(root, "original", itemMarker))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(copied, itemMarker), marker, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(copied, "keep"), []byte("fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{"clean", root, "unowned", "--delete"}, &out, now); err == nil {
		t.Fatal("copied marker authorized an unowned directory")
	}
	if _, err := os.Stat(filepath.Join(copied, "keep")); err != nil {
		t.Fatal("unowned data removed", err)
	}
}

func TestReplacedItemWithSameNameDoesNotInheritOwnership(t *testing.T) {
	parent := t.TempDir()
	root := filepath.Join(parent, "owned")
	now := time.Date(2026, 1, 3, 0, 0, 0, 0, time.UTC)
	var out bytes.Buffer
	for _, a := range [][]string{{"init", root}, {"create", root, "item"}, {"finish", root, "item", "2026-01-02T00:00:00Z"}} {
		if err := run(a, &out, now); err != nil {
			t.Fatal(err)
		}
	}
	original := filepath.Join(root, "item")
	marker, err := os.ReadFile(filepath.Join(original, itemMarker))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(original, filepath.Join(root, "moved")); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(original, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(original, itemMarker), marker, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(original, "keep"), []byte("fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := run([]string{"clean", root, "item", "--delete"}, &out, now); err == nil {
		t.Fatal("replacement inherited ownership")
	}
	if _, err := os.Stat(filepath.Join(original, "keep")); err != nil {
		t.Fatal("replacement removed", err)
	}
}

func TestDeleteRejectsReplacementAfterValidation(t *testing.T) {
	parent := t.TempDir()
	root := filepath.Join(parent, "owned")
	now := time.Date(2026, 1, 3, 0, 0, 0, 0, time.UTC)
	var out bytes.Buffer
	for _, a := range [][]string{{"init", root}, {"create", root, "item"}, {"finish", root, "item", "2026-01-02T00:00:00Z"}} {
		if err := run(a, &out, now); err != nil {
			t.Fatal(err)
		}
	}
	path := filepath.Join(root, "item")
	replacement := filepath.Join(root, "replacement")
	if err := os.Mkdir(replacement, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(replacement, "keep"), []byte("fixture"), 0600); err != nil {
		t.Fatal(err)
	}
	var swapErr error
	called := false
	beforeDeleteHook = func() {
		called = true
		if swapErr = os.Rename(path, filepath.Join(root, "moved")); swapErr != nil {
			return
		}
		swapErr = os.Rename(replacement, path)
	}
	defer func() { beforeDeleteHook = nil }()
	err := run([]string{"clean", root, "item", "--delete"}, &out, now)
	if !called {
		t.Fatalf("delete hook not reached: %v", err)
	}
	if swapErr == nil {
		if err == nil {
			t.Error("replacement accepted during deletion")
		}
		if _, e := os.Stat(filepath.Join(path, "keep")); e != nil {
			t.Errorf("replacement data removed: %v", e)
		}
	} else if _, e := os.Stat(filepath.Join(replacement, "keep")); e != nil {
		t.Errorf("unmoved replacement data removed: %v", e)
	}
}

func TestConcurrentChildCreationPreservesNewData(t *testing.T) {
	parent := t.TempDir()
	root := filepath.Join(parent, "owned")
	now := time.Date(2026, 1, 3, 0, 0, 0, 0, time.UTC)
	var out bytes.Buffer
	for _, a := range [][]string{{"init", root}, {"create", root, "item"}, {"finish", root, "item", "2026-01-02T00:00:00Z"}} {
		if e := run(a, &out, now); e != nil {
			t.Fatal(e)
		}
	}
	path := filepath.Join(root, "item", "new")
	var createErr error
	called := false
	beforeDeleteHook = func() { called = true; createErr = os.WriteFile(path, []byte("fixture"), 0600) }
	defer func() { beforeDeleteHook = nil }()
	err := run([]string{"clean", root, "item", "--delete"}, &out, now)
	if !called {
		t.Fatalf("hook not reached: %v", err)
	}
	if createErr == nil {
		if err == nil {
			t.Error("accepted concurrent new child")
		}
		if _, e := os.Stat(path); e != nil {
			t.Errorf("concurrent child lost: %v", e)
		}
		if _, e := os.Stat(filepath.Join(root, "item", itemMarker)); e != nil {
			t.Errorf("ownership marker lost after partial deletion: %v", e)
		}
		matches, e := filepath.Glob(filepath.Join(root, ".windows_setup_cleanup_recovery_*"))
		if e != nil || len(matches) != 1 {
			t.Errorf("missing persistent recovery receipt: %v %v", matches, e)
		} else if data, readErr := os.ReadFile(matches[0]); readErr != nil || !bytes.Contains(data, []byte(`"name":"item"`)) || !bytes.Contains(data, []byte(`"nonce":`)) {
			t.Errorf("invalid recovery receipt: %s %v", data, readErr)
		}
	}
}

func TestReceiptSurvivesMarkerRestoreFailure(t *testing.T) {
	root := filepath.Join(t.TempDir(), "owned")
	now := time.Date(2026, 1, 3, 0, 0, 0, 0, time.UTC)
	var out bytes.Buffer
	for _, a := range [][]string{{"init", root}, {"create", root, "item"}, {"finish", root, "item", "2026-01-02T00:00:00Z"}} {
		if e := run(a, &out, now); e != nil {
			t.Fatal(e)
		}
	}
	p := filepath.Join(root, "item")
	var newErr, restoreErr error
	beforeDeleteHook = func() { newErr = os.WriteFile(filepath.Join(p, "new"), []byte("new"), 0600) }
	beforeRestoreHook = func() { restoreErr = os.WriteFile(filepath.Join(p, itemMarker), []byte("unknown"), 0600) }
	defer func() { beforeDeleteHook = nil; beforeRestoreHook = nil }()
	err := run([]string{"clean", root, "item", "--delete"}, &out, now)
	if newErr != nil || restoreErr != nil || err == nil || !strings.Contains(err.Error(), "restore ownership marker") {
		t.Fatalf("fixture or expected restore failure: new=%v replacement=%v clean=%v", newErr, restoreErr, err)
	}
	receipts, e := filepath.Glob(filepath.Join(root, ".windows_setup_cleanup_recovery_*"))
	if e != nil || len(receipts) != 1 {
		t.Fatalf("missing receipt: %v %v", receipts, e)
	}
	data, e := os.ReadFile(receipts[0])
	if e != nil || !bytes.Contains(data, []byte(`"name":"item"`)) {
		t.Fatalf("invalid receipt: %s %v", data, e)
	}
	if data, e = os.ReadFile(filepath.Join(p, "new")); e != nil || string(data) != "new" {
		t.Fatalf("new data lost: %q %v", data, e)
	}
	if data, e = os.ReadFile(filepath.Join(p, itemMarker)); e != nil || string(data) != "unknown" {
		t.Fatalf("unknown marker overwritten: %q %v", data, e)
	}
}

func TestEnumeratedChildReplacementIsNotDeleted(t *testing.T) {
	parent := t.TempDir()
	root := filepath.Join(parent, "owned")
	now := time.Date(2026, 1, 3, 0, 0, 0, 0, time.UTC)
	var out bytes.Buffer
	for _, a := range [][]string{{"init", root}, {"create", root, "item"}, {"finish", root, "item", "2026-01-02T00:00:00Z"}} {
		if e := run(a, &out, now); e != nil {
			t.Fatal(e)
		}
	}
	child := filepath.Join(root, "item", "child")
	if e := os.WriteFile(child, []byte("original"), 0600); e != nil {
		t.Fatal(e)
	}
	var swapErr error
	called := false
	afterEnumerateHook = func() {
		if called {
			return
		}
		called = true
		swapErr = os.Rename(child, filepath.Join(root, "moved"))
		if swapErr == nil {
			swapErr = os.WriteFile(child, []byte("replacement"), 0600)
		}
	}
	defer func() { afterEnumerateHook = nil }()
	err := run([]string{"clean", root, "item", "--delete"}, &out, now)
	if !called || swapErr != nil {
		t.Fatalf("swap not performed: called=%v error=%v clean=%v", called, swapErr, err)
	}
	if err == nil {
		t.Error("replacement accepted")
	}
	if b, e := os.ReadFile(child); e != nil || string(b) != "replacement" {
		t.Errorf("replacement lost: %q %v", b, e)
	}
}

func TestFinishedManifestRejectsChangedAndUnknownFiles(t *testing.T) {
	for _, change := range []string{"changed", "unknown"} {
		t.Run(change, func(t *testing.T) {
			root := filepath.Join(t.TempDir(), "owned")
			now := time.Date(2026, 1, 3, 0, 0, 0, 0, time.UTC)
			var out bytes.Buffer
			for _, a := range [][]string{{"init", root}, {"create", root, "item"}} {
				if e := run(a, &out, now); e != nil {
					t.Fatal(e)
				}
			}
			p := filepath.Join(root, "item")
			if e := os.WriteFile(filepath.Join(p, "original"), []byte("original"), 0600); e != nil {
				t.Fatal(e)
			}
			if e := run([]string{"finish", root, "item", "2026-01-02T00:00:00Z"}, &out, now); e != nil {
				t.Fatal(e)
			}
			name := "original"
			if change == "unknown" {
				name = "new"
			}
			if e := os.WriteFile(filepath.Join(p, name), []byte("new data"), 0600); e != nil {
				t.Fatal(e)
			}
			if e := run([]string{"clean", root, "item", "--delete"}, &out, now); e == nil {
				t.Error("changed or unknown data accepted")
			}
			if b, e := os.ReadFile(filepath.Join(p, name)); e != nil || string(b) != "new data" {
				t.Errorf("new data lost: %q %v", b, e)
			}
		})
	}
}

func TestManifestRejectsReplacementWithSimulatedReusedID(t *testing.T) {
	root := strings.ToUpper(filepath.Join(t.TempDir(), "owned"))
	now := time.Date(2026, 1, 3, 0, 0, 0, 0, time.UTC)
	var out bytes.Buffer
	for _, a := range [][]string{{"init", root}, {"create", root, "item"}} {
		if e := run(a, &out, now); e != nil {
			t.Fatal(e)
		}
	}
	child := filepath.Join(root, "item", "child")
	if e := os.WriteFile(child, []byte("original"), 0600); e != nil {
		t.Fatal(e)
	}
	if e := run([]string{"finish", root, "item", "2026-01-02T00:00:00Z"}, &out, now); e != nil {
		t.Fatal(e)
	}
	meta, e := readMetadataFile(filepath.Join(root, "item", finishMarker))
	if e != nil || len(meta.Manifest) != 1 {
		t.Fatalf("manifest: %v %v", meta, e)
	}
	originalID := meta.Manifest[0].ID
	canonicalRoot, _, e := normalizeTempRoot(root)
	if e != nil {
		t.Fatal(e)
	}
	canonicalChild := filepath.Join(canonicalRoot, "item", "child")
	called := false
	hookMatched := false
	var replacementID string
	var swapErr error
	afterEnumerateHook = func() {
		if called {
			return
		}
		called = true
		swapErr = os.Rename(child, filepath.Join(root, "moved"))
		if swapErr == nil {
			swapErr = os.WriteFile(child, []byte("new data"), 0600)
		}
	}
	identityTestHook = func(path, actual string) string {
		if path == canonicalChild {
			hookMatched = true
			replacementID = actual
			return originalID
		}
		return actual
	}
	defer func() { afterEnumerateHook = nil; identityTestHook = nil }()
	err := run([]string{"clean", root, "item", "--delete"}, &out, now)
	if !called || swapErr != nil {
		t.Fatalf("replacement failed: %v %v", called, swapErr)
	}
	if !hookMatched || replacementID == "" || replacementID == originalID {
		t.Fatalf("replacement identity was not simulated: matched=%v changed=%v", hookMatched, replacementID != "" && replacementID != originalID)
	}
	if err == nil || !strings.Contains(err.Error(), "manifest entry changed") {
		t.Fatalf("expected manifest content rejection with simulated reused ID: %v", err)
	}
	if b, e := os.ReadFile(child); e != nil || string(b) != "new data" {
		t.Fatalf("replacement lost: %q %v", b, e)
	}
}

func TestFinishRejectsAlternateDataStream(t *testing.T) {
	root := filepath.Join(t.TempDir(), "owned")
	now := time.Date(2026, 1, 3, 0, 0, 0, 0, time.UTC)
	var out bytes.Buffer
	for _, a := range [][]string{{"init", root}, {"create", root, "item"}} {
		if e := run(a, &out, now); e != nil {
			t.Fatal(e)
		}
	}
	child := filepath.Join(root, "item", "child")
	if e := os.WriteFile(child, []byte("data"), 0600); e != nil {
		t.Fatal(e)
	}
	if e := os.WriteFile(child+":extra", []byte("secret fixture"), 0600); e != nil {
		t.Skipf("alternate streams unavailable: %v", e)
	}
	if e := run([]string{"finish", root, "item", "2026-01-02T00:00:00Z"}, &out, now); e == nil {
		t.Fatal("finish accepted unmanifested alternate stream")
	}
	if b, e := os.ReadFile(child + ":extra"); e != nil || string(b) != "secret fixture" {
		t.Fatalf("stream lost: %q %v", b, e)
	}
}

func TestConcurrentAlternateStreamIsNotDeleted(t *testing.T) {
	root := filepath.Join(t.TempDir(), "owned")
	now := time.Date(2026, 1, 3, 0, 0, 0, 0, time.UTC)
	var out bytes.Buffer
	for _, a := range [][]string{{"init", root}, {"create", root, "item"}} {
		if e := run(a, &out, now); e != nil {
			t.Fatal(e)
		}
	}
	child := filepath.Join(root, "item", "child")
	if e := os.WriteFile(child, []byte("data"), 0600); e != nil {
		t.Fatal(e)
	}
	if e := run([]string{"finish", root, "item", "2026-01-02T00:00:00Z"}, &out, now); e != nil {
		t.Fatal(e)
	}
	called := false
	var createErr error
	beforeDeleteHook = func() { called = true; createErr = os.WriteFile(child+":extra", []byte("new stream"), 0600) }
	defer func() { beforeDeleteHook = nil }()
	err := run([]string{"clean", root, "item", "--delete"}, &out, now)
	if !called {
		t.Fatalf("hook not reached: %v", err)
	}
	t.Logf("concurrent stream creation: %v; clean: %v", createErr, err)
	if createErr == nil {
		if err == nil {
			t.Error("accepted concurrent alternate stream")
		}
		if b, e := os.ReadFile(child + ":extra"); e != nil || string(b) != "new stream" {
			t.Errorf("stream lost: %q %v", b, e)
		}
	}
}

func TestConcurrentChildReplacementCannotEscape(t *testing.T) {
	parent := t.TempDir()
	root := filepath.Join(parent, "owned")
	outside := filepath.Join(parent, "outside")
	now := time.Date(2026, 1, 3, 0, 0, 0, 0, time.UTC)
	var out bytes.Buffer
	if e := os.Mkdir(outside, 0700); e != nil {
		t.Fatal(e)
	}
	if e := os.WriteFile(filepath.Join(outside, "keep"), []byte("fixture"), 0600); e != nil {
		t.Fatal(e)
	}
	for _, a := range [][]string{{"init", root}, {"create", root, "item"}} {
		if e := run(a, &out, now); e != nil {
			t.Fatal(e)
		}
	}
	child := filepath.Join(root, "item", "child")
	if e := os.Mkdir(child, 0700); e != nil {
		t.Fatal(e)
	}
	if e := run([]string{"finish", root, "item", "2026-01-02T00:00:00Z"}, &out, now); e != nil {
		t.Fatal(e)
	}
	var swapErr error
	called := false
	beforeDeleteHook = func() {
		called = true
		swapErr = os.Rename(child, filepath.Join(root, "moved"))
		if swapErr == nil {
			swapErr = os.Symlink(outside, child)
		}
	}
	defer func() { beforeDeleteHook = nil }()
	err := run([]string{"clean", root, "item", "--delete"}, &out, now)
	if !called {
		t.Fatalf("hook not reached: %v", err)
	}
	if swapErr == nil && err == nil {
		t.Error("accepted child reparse replacement")
	}
	if _, e := os.Stat(filepath.Join(outside, "keep")); e != nil {
		t.Fatalf("outside fixture changed: %v", e)
	}
}

func TestMarkerChangeAfterReadCannotAuthorizeDelete(t *testing.T) {
	parent := t.TempDir()
	root := filepath.Join(parent, "owned")
	now := time.Date(2026, 1, 3, 0, 0, 0, 0, time.UTC)
	var out bytes.Buffer
	for _, a := range [][]string{{"init", root}, {"create", root, "item"}, {"finish", root, "item", "2026-01-02T00:00:00Z"}} {
		if e := run(a, &out, now); e != nil {
			t.Fatal(e)
		}
	}
	p := filepath.Join(root, "item")
	if e := os.WriteFile(filepath.Join(p, "keep"), []byte("fixture"), 0600); e != nil {
		t.Fatal(e)
	}
	var changeErr error
	called := false
	afterMarkerReadHook = func() { called = true; changeErr = os.WriteFile(filepath.Join(p, itemMarker), []byte("changed"), 0600) }
	defer func() { afterMarkerReadHook = nil }()
	err := run([]string{"clean", root, "item", "--delete"}, &out, now)
	if !called {
		t.Fatalf("hook not reached: %v", err)
	}
	if changeErr == nil {
		if err == nil {
			t.Error("changed marker authorized deletion")
		}
		if _, e := os.Stat(filepath.Join(p, "keep")); e != nil {
			t.Errorf("fixture removed: %v", e)
		}
	}
}
