//go:build windows

package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"unsafe"
)

func shortTestPath(t *testing.T, path string) string {
	t.Helper()
	input, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		t.Fatal(err)
	}
	buffer := make([]uint16, 32768)
	n, _, callErr := syscall.NewLazyDLL("kernel32.dll").NewProc("GetShortPathNameW").Call(uintptr(unsafe.Pointer(input)), uintptr(unsafe.Pointer(&buffer[0])), uintptr(len(buffer)))
	if n == 0 || n >= uintptr(len(buffer)) {
		t.Skipf("8.3 short path unavailable: %v", callErr)
	}
	short := syscall.UTF16ToString(buffer[:n])
	if strings.EqualFold(filepath.Clean(short), filepath.Clean(path)) {
		t.Skip("8.3 short names unavailable on this volume")
	}
	return short
}

func TestOutputParentRejectsWindowsJunctions(t *testing.T) {
	root := t.TempDir()
	target := filepath.Join(root, "target")
	if err := os.Mkdir(target, 0700); err != nil {
		t.Fatal(err)
	}
	child := filepath.Join(target, "child")
	if err := os.Mkdir(child, 0700); err != nil {
		t.Fatal(err)
	}
	junction := filepath.Join(root, "junction")
	cmd := exec.Command("cmd.exe", "/c", "mklink", "/J", junction, target)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("create test junction: %v %s", err, out)
	}
	if _, err := loadReport(junction, nil); err == nil {
		t.Fatal("source report junction accepted")
	}
	for _, parent := range []string{junction, filepath.Join(junction, "child")} {
		if err := writeVerifiedOutput(filepath.Join(parent, "verified"), nil, map[string][]byte{}, options{}, "explicit", ""); err == nil {
			t.Fatalf("junction or ancestor accepted: %s", parent)
		}
	}
}
func TestShortFixture(t *testing.T) {
	root := t.TempDir()
	long := filepath.Join(root, "ordinary_long_name")
	if err := os.Mkdir(long, 0700); err != nil {
		t.Fatal(err)
	}
	short := shortTestPath(t, long)
	fixture := filepath.Join(short, "fixture")
	cmd := exec.Command("go", "test", "-count=1", "-run", "^TestExportSyntheticConsumerFixture$", ".")
	cmd.Env = append(os.Environ(), "WINDOWS_SETUP_BUNDLE_FIXTURE_DIR="+fixture)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("ordinary short fixture parent rejected: %v %s", err, out)
	}
	if _, err := os.Stat(filepath.Join(long, "fixture", "fixture.json")); err != nil {
		t.Fatal(err)
	}
}

func TestOutputParentRejectsNonDirectory(t *testing.T) {
	root := t.TempDir()
	file := filepath.Join(root, "not_a_directory")
	if err := os.WriteFile(file, []byte("keep"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := writeVerifiedOutput(filepath.Join(file, "verified"), nil, map[string][]byte{}, options{}, "explicit", ""); err == nil {
		t.Fatal("non-directory parent accepted")
	}
	got, err := os.ReadFile(file)
	if err != nil || string(got) != "keep" {
		t.Fatal("non-directory parent changed")
	}
}
func TestLongTemp(t *testing.T) {
	root := t.TempDir()
	long := filepath.Join(root, "windows_ci_temp_parent_with_long_account_name_0123456789")
	if err := os.Mkdir(long, 0700); err != nil {
		t.Fatal(err)
	}
	short := shortTestPath(t, long)
	cmd := exec.Command("go", "test", "-count=1", "-run", "^TestShortFixture$", ".")
	cmd.Env = append(os.Environ(), "TEMP="+short, "TMP="+short)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("8.3 fixture under longer TEMP must work: %v %s", err, out)
	}
}

func TestSyntheticFixtureGitUnderLongTemp(t *testing.T) {
	root := t.TempDir()
	// Keep Git's working directory below MAX_PATH while its object files exceed it.
	const sourceLength = 215
	input, err := syscall.UTF16PtrFromString(root)
	if err != nil {
		t.Fatal(err)
	}
	buffer := make([]uint16, 32768)
	n, _, callErr := syscall.NewLazyDLL("kernel32.dll").NewProc("GetLongPathNameW").Call(uintptr(unsafe.Pointer(input)), uintptr(unsafe.Pointer(&buffer[0])), uintptr(len(buffer)))
	if n == 0 || n >= uintptr(len(buffer)) {
		t.Fatalf("resolve fixture TEMP path: %v", callErr)
	}
	root = syscall.UTF16ToString(buffer[:n])
	rootUnits := len(syscall.StringToUTF16(root)) - 1
	padding := sourceLength - rootUnits - len(string(filepath.Separator)) - len(string(filepath.Separator)+"source")
	if padding < 1 {
		t.Fatalf("fixture TEMP parent too long for bounded Git working directory: %d", rootUnits)
	}
	source := filepath.Join(root, strings.Repeat("x", padding), "source")
	objectPath := filepath.Join(source, ".git", "objects", "12", strings.Repeat("a", 38))
	sourceUnits, objectUnits := len(syscall.StringToUTF16(source))-1, len(syscall.StringToUTF16(objectPath))-1
	if sourceUnits >= 260 || objectUnits <= 260 {
		t.Fatalf("fixture paths do not exercise bounded cwd and long object: %d, %d", sourceUnits, objectUnits)
	}
	if err := os.MkdirAll(source, 0700); err != nil {
		t.Fatal(err)
	}
	syntheticNativeReport(t, source)
	cmd := exec.Command("git", "-c", "core.longpaths=true", "-C", source, "config", "--local", "--get", "core.longpaths")
	out, err := cmd.Output()
	if err != nil || strings.TrimSpace(string(out)) != "true" {
		t.Fatalf("fixture must keep long path configuration local: %v", err)
	}
}

func TestSyntheticFixtureGitUnderDeepRunnerTemp(t *testing.T) {
	root, err := os.MkdirTemp("", "runner-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(root) })
	parent := filepath.Join(root, "go_coverage_b6468c74a82746598613f97017db49d9", "cache", "tmp")
	if err := os.MkdirAll(parent, 0700); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("go", "test", "-count=1", "-run", "^TestSyntheticFixtureGitUnderLongTemp$", ".")
	cmd.Env = append(os.Environ(), "TEMP="+parent, "TMP="+parent)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("fixture must handle coverage runner TEMP: %v %s", err, out)
	}
}
