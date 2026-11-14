package integration_test

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	a "windows_setup/script/test/acceptance"
)

func TestActualPortalFixturePassesAcceptance(t *testing.T) {
	pages := files(t, os.Getenv("WINDOWS_SETUP_PORTAL_FIXTURE_DIR"))
	var identity struct{ Commit, RunUrl string }
	if err := json.Unmarshal([]byte(strings.TrimPrefix(string(pages["main/summary.json"]), "\ufeff")), &identity); err != nil {
		t.Fatal(err)
	}
	readme, err := os.ReadFile(filepath.Join("..", "..", "..", "readme.md"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := a.ValidatePortal(reader(pages), string(readme), identity.Commit, identity.RunUrl, "https://ycpss91255.github.io/windows_setup/"); err != nil {
		t.Fatal(err)
	}
}
