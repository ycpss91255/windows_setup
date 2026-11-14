package main

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
	a "windows_setup/script/test/acceptance"
	c "windows_setup/script/test/repo_coverage"
)

type releaseAsset struct {
	Name   string `json:"name"`
	Digest string `json:"digest"`
	Size   int64  `json:"size"`
}
type verifiedBundle struct {
	Summary       []byte
	Profile       []byte
	ArchiveDigest string
	CoverageScope string
}

type releaseMetadata struct {
	Tag       string         `json:"tag_name"`
	URL       string         `json:"html_url"`
	Draft     *bool          `json:"draft"`
	Immutable *bool          `json:"immutable"`
	Assets    []releaseAsset `json:"assets"`
}

func releaseRequiresGoProfile(e *c.Evidence, bundle *verifiedBundle) (bool, error) {
	runtime := e != nil && e.SchemaVersion == c.RuntimeSchemaVersion && e.Metric == c.RuntimeMetric && e.Scope == c.RuntimeScope
	if runtime {
		if bundle == nil || bundle.CoverageScope != c.RuntimeScope {
			return false, fmt.Errorf("runtime report requires matching bundle scope")
		}
		return false, nil
	}
	if bundle != nil && bundle.CoverageScope != "" {
		return false, fmt.Errorf("legacy report requires legacy bundle scope")
	}
	return true, nil
}

func verifyTag(read a.Reader, metadata []byte, tag, sha, run string, files []string, bundle *verifiedBundle, requireRuntime bool) error {
	if !regexp.MustCompile(`^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-rc[1-9][0-9]*)?$`).MatchString(tag) {
		return fmt.Errorf("invalid release tag")
	}
	var release releaseMetadata
	if e := json.Unmarshal(metadata, &release); e != nil {
		return e
	}
	if release.Tag != tag || release.Draft == nil || *release.Draft || release.Immutable == nil || !*release.Immutable {
		return fmt.Errorf("release identity or immutable state mismatch")
	}
	assets := map[string]releaseAsset{}
	format, err := classifyReleaseEvidence(release.Assets, tag)
	if err != nil {
		return err
	}
	if (format == "bundle") != (bundle != nil) {
		return fmt.Errorf("release evidence format mismatch")
	}
	for _, v := range release.Assets {
		if v.Name == "quality.json" || v.Name == "go_coverage.out" {
			if _, ok := assets[v.Name]; ok {
				return fmt.Errorf("duplicate release evidence")
			}
			assets[v.Name] = v
		}
	}
	if bundle != nil {
		assets["quality.json"] = assetFromBytes("quality.json", bundle.Summary)
		if bundle.CoverageScope == "" {
			assets["go_coverage.out"] = assetFromBytes("go_coverage.out", bundle.Profile)
		}
	}
	for _, n := range []string{"quality.json"} {
		v, ok := assets[n]
		if !ok || v.Size <= 0 || !regexp.MustCompile(`^sha256:[a-f0-9]{64}$`).MatchString(v.Digest) {
			return fmt.Errorf("missing or invalid release evidence: %s", n)
		}
	}
	index, e := read("versions.json")
	if e != nil {
		return e
	}
	var versions []struct{ Version, Status, Path, Commit, ReleaseUrl, Digest, ArchiveDigest, MeasuredAt string }
	if e = json.Unmarshal(index, &versions); e != nil {
		return e
	}
	count := 0
	versionStamp := ""
	prefix := "versions/" + tag + "/"
	for _, v := range versions {
		if v.Version == tag {
			count++
			versionStamp = v.MeasuredAt
			if bundle != nil && v.ArchiveDigest != bundle.ArchiveDigest {
				return fmt.Errorf("release archive digest mismatch")
			}
			if v.Status != "Verified" || v.Path != prefix+"index.html" || v.Commit != sha || release.URL == "" || v.ReleaseUrl != release.URL || v.Digest != assets["quality.json"].Digest {
				return fmt.Errorf("release listing invalid")
			}
		}
	}
	if count != 1 {
		return fmt.Errorf("release listing missing or duplicated")
	}
	reader := func(n string) ([]byte, error) { return read(prefix + n) }
	summary, e := reader("summary.json")
	if e != nil {
		return e
	}
	match := func(data []byte, asset releaseAsset) bool {
		sum := sha256.Sum256(data)
		return int64(len(data)) == asset.Size && fmt.Sprintf("sha256:%x", sum) == asset.Digest
	}
	if !match(summary, assets["quality.json"]) {
		return fmt.Errorf("published summary differs from immutable release")
	}
	report, e := a.ValidateReport(reader, sha, run, false)
	if e != nil {
		return e
	}
	if report.MeasuredAt == "" || report.MeasuredAt != versionStamp || report.SchemaVersion != 2 || report.RefType != "Release" || report.RefName != tag || report.Version != tag || !report.Success || report.Totals.UnexecutedSuites != 0 {
		return fmt.Errorf("published release report identity mismatch")
	}
	coverage, e := a.ValidateRepoCoverageReport(reader, summary, sha, run, true)
	if e != nil {
		return e
	}
	if requireRuntime {
		if bundle == nil || bundle.CoverageScope != c.RuntimeScope || requireCurrentRuntimeCoverage(coverage) != nil {
			return fmt.Errorf("current release requires matching runtime bundle")
		}
	}
	requireProfile, e := releaseRequiresGoProfile(coverage, bundle)
	if e != nil {
		return e
	}
	if requireProfile {
		asset, ok := assets["go_coverage.out"]
		if !ok || asset.Size <= 0 || !regexp.MustCompile(`^sha256:[a-f0-9]{64}$`).MatchString(asset.Digest) {
			return fmt.Errorf("missing or invalid release Go profile")
		}
		profile, err := reader("go_coverage.out")
		if err != nil || !match(profile, asset) {
			return fmt.Errorf("published profile differs from immutable release")
		}
	}
	inventory, e := reader("coverage_inventory.json")
	if e != nil {
		return e
	}
	if e = validatePublishedInventory(coverage, ".", inventory); e != nil {
		return e
	}
	if e = a.ValidateGoCoverageReport(reader, files, sha, run, requireProfile); e != nil {
		return e
	}
	pageBytes, e := reader("index.html")
	if e != nil {
		return e
	}
	page, e := a.ParsePage(pageBytes)
	if e != nil {
		return e
	}
	expectedIdentity := "版本 " + tag + " · 提交 " + sha + " 量測時間（UTC）：" + report.MeasuredAt
	identityCount := 0
	for _, paragraph := range page.VisibleParagraphs {
		text := strings.Join(strings.Fields(paragraph), " ")
		if strings.HasPrefix(text, "版本 ") {
			identityCount++
			if text != expectedIdentity {
				return fmt.Errorf("visible release identity paragraph mismatch")
			}
		}
	}
	if identityCount != 1 {
		return fmt.Errorf("visible release identity paragraph missing or duplicated")
	}
	runCount := 0
	for _, anchor := range page.VisibleAnchors {
		if strings.Join(strings.Fields(anchor.Text), " ") == "GitHub Actions 執行紀錄" {
			runCount++
			if anchor.Href != run {
				return fmt.Errorf("visible release run link mismatch")
			}
		}
	}
	if runCount != 1 {
		return fmt.Errorf("visible release run link missing or duplicated")
	}
	return nil
}
