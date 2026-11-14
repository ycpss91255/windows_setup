//go:build windows

package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const rootMarker = ".windows_setup_cleanup_root_v1"
const itemMarker = ".windows_setup_cleanup_item_v1"
const finishMarker = ".windows_setup_cleanup_finished_v1"
const rootContent = "windows_setup disposable artifacts root v1\n"

type metadata struct {
	Kind     string          `json:"kind"`
	Name     string          `json:"name"`
	ID       string          `json:"id"`
	Expires  string          `json:"expires"`
	Nonce    string          `json:"nonce,omitempty"`
	Manifest []manifestEntry `json:"manifest,omitempty"`
}

type manifestEntry struct {
	Path   string `json:"path"`
	ID     string `json:"id"`
	Dir    bool   `json:"dir"`
	Size   int64  `json:"size,omitempty"`
	SHA256 string `json:"sha256,omitempty"`
}

func plainPath(p string) (string, error) {
	a, err := filepath.Abs(p)
	if err != nil {
		return "", err
	}
	a = filepath.Clean(a)
	resolved, err := filepath.EvalSymlinks(a)
	if err != nil {
		return "", err
	}
	if !strings.EqualFold(filepath.Clean(resolved), a) {
		return "", errors.New("path contains a link or reparse point")
	}
	return a, nil
}
func safeName(s string) bool {
	return s != "" && s != "." && s != ".." && filepath.Base(s) == s && !strings.ContainsAny(s, `/\:`)
}

type tempAnchor struct{ path, id string }

func normalizeTempRoot(path string) (string, tempAnchor, error) {
	var anchor tempAnchor
	raw, err := filepath.Abs(os.TempDir())
	if err != nil {
		return "", anchor, err
	}
	anchor.path, anchor.id, err = canonicalTemp(raw)
	if err != nil {
		return "", anchor, fmt.Errorf("invalid TEMP: %w", err)
	}
	path, err = filepath.Abs(path)
	if err != nil {
		return "", anchor, err
	}
	// Resolve existing directories through the same locked, reparse-rejecting
	// path as TEMP, including mixtures of long and 8.3 names. An init target
	// may not exist yet, but its parent must already exist.
	resolved, _, err := canonicalTemp(path)
	if os.IsNotExist(err) {
		parent, _, parentErr := canonicalTemp(filepath.Dir(path))
		if parentErr != nil {
			return "", anchor, parentErr
		}
		resolved = filepath.Join(parent, filepath.Base(path))
	} else if err != nil {
		return "", anchor, err
	}
	rel, e := filepath.Rel(anchor.path, resolved)
	if e == nil && rel != "." && rel != ".." && !filepath.IsAbs(rel) && !strings.HasPrefix(rel, ".."+string(os.PathSeparator)) {
		return filepath.Join(anchor.path, rel), anchor, nil
	}
	return "", anchor, errors.New("root outside TEMP")
}
func regular(path string) error {
	i, e := os.Lstat(path)
	if e != nil {
		return e
	}
	if !i.Mode().IsRegular() {
		return errors.New("not a regular file")
	}
	return nil
}
func validateRoot(p string) (string, tempAnchor, error) {
	root, anchor, e := normalizeTempRoot(p)
	if e != nil {
		return "", anchor, e
	}
	root, e = plainPath(root)
	if e != nil {
		return "", anchor, e
	}
	i, e := os.Lstat(root)
	if e != nil {
		return "", anchor, e
	}
	if !i.IsDir() || i.Mode()&os.ModeSymlink != 0 {
		return "", anchor, errors.New("invalid root")
	}
	m := filepath.Join(root, rootMarker)
	if e = regular(m); e != nil {
		return "", anchor, e
	}
	b, e := os.ReadFile(m)
	if e != nil || string(b) != rootContent {
		return "", anchor, errors.New("invalid root marker")
	}
	return root, anchor, nil
}
func item(root, name string) (string, error) {
	if !safeName(name) {
		return "", errors.New("invalid item name")
	}
	p := filepath.Join(root, name)
	rel, e := filepath.Rel(root, p)
	if e != nil || rel != name {
		return "", errors.New("item outside root")
	}
	resolved, e := plainPath(p)
	if e != nil {
		return "", e
	}
	if !strings.EqualFold(resolved, p) {
		return "", errors.New("item outside root")
	}
	i, e := os.Lstat(p)
	if e != nil {
		return "", e
	}
	if !i.IsDir() || i.Mode()&os.ModeSymlink != 0 {
		return "", errors.New("invalid item")
	}
	return p, nil
}
func readMetadata(p string) (metadata, error) {
	return readMetadataFile(filepath.Join(p, itemMarker))
}
func readMetadataFile(f string) (metadata, error) {
	var m metadata
	if e := regular(f); e != nil {
		return m, e
	}
	b, e := os.ReadFile(f)
	if e != nil {
		return m, e
	}
	e = json.Unmarshal(b, &m)
	if e != nil || m.Kind != "windows_setup_disposable_v1" {
		return m, errors.New("invalid item marker")
	}
	return m, nil
}
func writeMetadata(p string, m metadata) error {
	b, e := json.Marshal(m)
	if e != nil {
		return e
	}
	return os.WriteFile(filepath.Join(p, itemMarker), b, 0600)
}

var beforeDeleteHook func()
var afterMarkerReadHook func()
var afterEnumerateHook func()
var identityTestHook func(string, string) string
var beforeRestoreHook func()
var afterCreateDirectoryHook func(string)
var finishWriteTestHook func() error
var nativeCreateTestHook func()
var beforeTempLockTestHook func()

func run(args []string, out io.Writer, now time.Time) error {
	if len(args) < 2 {
		return errors.New("usage: init ROOT | create ROOT NAME | finish ROOT NAME EXPIRY | clean ROOT NAME [--delete]")
	}
	if args[0] == "init" {
		if len(args) != 2 {
			return errors.New("invalid init arguments")
		}
		abs, anchor, e := normalizeTempRoot(args[1])
		if e != nil {
			return e
		}
		parent, e := plainPath(filepath.Dir(abs))
		if e != nil {
			return e
		}
		abs = filepath.Join(parent, filepath.Base(abs))
		if beforeTempLockTestHook != nil {
			beforeTempLockTestHook()
		}
		return createOwnedDirectory(abs, "", true, anchor)
	}
	root, anchor, e := validateRoot(args[1])
	if e != nil {
		return e
	}
	if len(args) < 3 {
		return errors.New("item name required")
	}
	name := args[2]
	if !safeName(name) {
		return errors.New("invalid item name")
	}
	if args[0] == "create" {
		if len(args) != 3 {
			return errors.New("invalid create arguments")
		}
		return createOwnedDirectory(filepath.Join(root, name), name, false, anchor)
	}
	p, e := item(root, name)
	if e != nil {
		return e
	}
	m, e := readMetadata(p)
	if e != nil {
		return e
	}
	id, err := directoryIdentity(p)
	if err != nil {
		return err
	}
	if m.ID == "" || m.ID != id {
		return errors.New("item identity mismatch")
	}
	if m.Name != name {
		return errors.New("item marker name mismatch")
	}
	switch args[0] {
	case "finish":
		if len(args) != 4 || m.Expires != "" {
			return errors.New("invalid finish arguments or already finished")
		}
		expiry, e := time.Parse(time.RFC3339, args[3])
		if e != nil {
			return e
		}
		return safeFinish(root, name, id, expiry.UTC().Format(time.RFC3339), anchor)
	case "clean":
		if len(args) != 3 && !(len(args) == 4 && args[3] == "--delete") {
			return errors.New("invalid clean arguments")
		}
		finished, e := readMetadataFile(filepath.Join(p, finishMarker))
		if e != nil || finished.Name != name || finished.ID != id {
			return errors.New("invalid finished manifest")
		}
		expiry, e := time.Parse(time.RFC3339, finished.Expires)
		if e != nil || now.Before(expiry) {
			return errors.New("item is active or not expired")
		}
		e = filepath.Walk(p, func(path string, info os.FileInfo, err error) error {
			if err != nil {
				return err
			}
			if info.Mode()&os.ModeType != 0 && !info.IsDir() {
				return fmt.Errorf("unsupported or reparse entry: %s", path)
			}
			if info.Mode()&os.ModeSymlink != 0 {
				return fmt.Errorf("reparse entry: %s", path)
			}
			resolved, e := plainPath(path)
			if e != nil {
				return e
			}
			rel, e := filepath.Rel(p, resolved)
			if e != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(os.PathSeparator)) {
				return errors.New("entry outside item")
			}
			return nil
		})
		if e != nil {
			return e
		}
		if len(args) == 3 {
			_, e = fmt.Fprintln(out, "候選預覽（尚未核對清單與控制代碼）：", p)
			return e
		}
		return safeDelete(root, name, m.ID, now, anchor)
	default:
		return errors.New("unknown command")
	}
}
func main() {
	if e := run(os.Args[1:], os.Stdout, time.Now()); e != nil {
		fmt.Fprintln(os.Stderr, e)
		os.Exit(1)
	}
}
