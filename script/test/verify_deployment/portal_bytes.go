package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	a "windows_setup/script/test/acceptance"
	c "windows_setup/script/test/repo_coverage"
)

// verifyPortalBytes compares public pages to the already validated same-run portal artifact.
func verifyPortalBytes(read a.Reader, root, requiredVersion string) error {
	info, err := os.Lstat(root)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("invalid portal artifact root")
	}
	readLocal := func(name string) ([]byte, error) {
		current := root
		for _, part := range strings.Split(name, "/") {
			current = filepath.Join(current, part)
			entry, e := os.Lstat(current)
			if e != nil || entry.Mode()&os.ModeSymlink != 0 {
				return nil, fmt.Errorf("invalid portal artifact entry %s", name)
			}
		}
		entry, e := os.Lstat(current)
		if e != nil || !entry.Mode().IsRegular() || entry.Size() > 64<<20 {
			return nil, fmt.Errorf("invalid portal artifact file %s", name)
		}
		return os.ReadFile(current)
	}
	compare := func(name string) error {
		local, e := readLocal(name)
		if e != nil {
			return e
		}
		public, e := read(name)
		if e != nil {
			return e
		}
		if !bytes.Equal(local, public) {
			return fmt.Errorf("public portal bytes differ: %s", name)
		}
		return nil
	}
	data, err := readLocal("versions.json")
	if err != nil {
		return err
	}
	var rows []struct{ Version, Status, Path string }
	if err = json.Unmarshal(data, &rows); err != nil {
		return err
	}
	seen := map[string]bool{}
	foundRequired := false
	versionPattern := regexp.MustCompile(`^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-rc[1-9][0-9]*)?$`)
	for _, row := range rows {
		if !versionPattern.MatchString(row.Version) || seen[row.Version] || row.Path != "versions/"+row.Version+"/index.html" || (row.Status != "Verified" && row.Status != "Unknown" && row.Status != "Invalid") {
			return fmt.Errorf("invalid portal version entry")
		}
		seen[row.Version] = true
		if row.Version == requiredVersion && row.Status == "Verified" {
			foundRequired = true
		}
		if row.Status == "Verified" {
			prefix := "versions/" + row.Version + "/"
			for _, name := range []string{"index.html", "summary.json"} {
				if err = compare("versions/" + row.Version + "/" + name); err != nil {
					return err
				}
			}
			summary, err := readLocal(prefix + "summary.json")
			if err != nil {
				return err
			}
			var report struct {
				RepoCoverage struct {
					SchemaVersion int
					Metric, Scope string
				}
			}
			if json.Unmarshal(summary, &report) == nil && report.RepoCoverage.SchemaVersion == c.RuntimeSchemaVersion {
				if report.RepoCoverage.Metric != c.RuntimeMetric || report.RepoCoverage.Scope != c.RuntimeScope {
					return fmt.Errorf("invalid runtime portal scope")
				}
			} else if err = compare(prefix + "go_coverage.out"); err != nil {
				return err
			}
		}
	}
	if requiredVersion != "" && !foundRequired {
		return fmt.Errorf("required release is not verified in portal")
	}
	return compare("versions.json")
}
