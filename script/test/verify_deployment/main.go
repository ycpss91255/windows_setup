package main

import (
	"encoding/json"
	"encoding/xml"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"regexp"
	"sort"
	"strings"
	"time"
	a "windows_setup/script/test/acceptance"
	c "windows_setup/script/test/repo_coverage"
)

var deploymentSleep = time.Sleep

func releaseGoFiles(root string, bundle *verifiedBundle) ([]string, error) {
	if bundle != nil && bundle.CoverageScope == c.RuntimeScope {
		return nil, nil
	}
	return a.OwnedGoFiles(root)
}

func requireCurrentRuntimeCoverage(e *c.Evidence) error {
	if e == nil || e.SchemaVersion != c.RuntimeSchemaVersion || e.Metric != c.RuntimeMetric || e.Scope != c.RuntimeScope {
		return fmt.Errorf("current deployment requires runtime PowerShell/C# coverage")
	}
	return nil
}

func validatePublishedInventory(evidence *c.Evidence, root string, inventory []byte) error {
	if evidence == nil {
		return fmt.Errorf("missing coverage evidence")
	}
	if evidence.SchemaVersion == c.RuntimeSchemaVersion {
		if evidence.Metric != c.RuntimeMetric || evidence.Scope != c.RuntimeScope {
			return fmt.Errorf("runtime scope mismatch")
		}
		return c.ValidateRuntimeInventory(root, inventory)
	}
	return c.ValidateInventory(root, inventory)
}

func run() error {
	mode := flag.String("mode", "branch", "branch or release")
	tag := flag.String("tag", "", "release tag")
	metadata := flag.String("release-metadata", "", "immutable GitHub release metadata")
	download := flag.Bool("download-release-asset", false, "download report asset from release")
	repository := flag.String("release-repository", "", "repository for report download")
	bundleTool := flag.String("report-bundle-tool", "", "trusted report verifier executable")
	archive := flag.String("report-archive", "", "downloaded report archive")
	attempt := flag.Int("run-attempt", 0, "expected run attempt")
	requireRuntime := flag.Bool("require-runtime", false, "require current release runtime report bundle")
	portalDir := flag.String("portal-dir", "", "validated same-run portal artifact")
	latestMetadata := flag.String("latest-release-metadata", "", "immutable latest release metadata")
	base := flag.String("base-url", "", "HTTPS Pages root")
	doc := flag.String("readme", "", "README path")
	sha := flag.String("expected-sha", "", "expected commit")
	run := flag.String("expected-run-url", "", "expected run")
	if err := flag.CommandLine.Parse(os.Args[1:]); err != nil {
		return err
	}
	provided := map[string]bool{}
	flag.Visit(func(f *flag.Flag) { provided[f.Name] = true })
	if *base == "" || *doc == "" || *sha == "" || !provided["expected-run-url"] {
		return fmt.Errorf("四個驗收參數皆為必要")
	}
	*base = strings.TrimRight(*base, "/") + "/"
	read, e := a.HTTPReader(*base, nil)
	if e != nil {
		return e
	}
	b, e := os.ReadFile(*doc)
	if e != nil {
		return e
	}
	if *mode == "release" {
		if *portalDir != "" || *latestMetadata != "" {
			return fmt.Errorf("portal artifact is only valid in branch mode")
		}
		if *tag == "" || *metadata == "" || *run == "" {
			return fmt.Errorf("release mode requires tag, metadata and run")
		}
		data, err := os.ReadFile(*metadata)
		if err != nil {
			return err
		}
		if *download {
			if err := downloadReportAsset(data, *tag, *repository, *archive); err != nil {
				return err
			}
		} else if *repository != "" {
			return fmt.Errorf("repository requires report download")
		}
		bundle, err := prepareReleaseBundle(data, *tag, *sha, *run, *attempt, *bundleTool, *archive)
		if err != nil {
			return err
		}
		if *requireRuntime && (bundle == nil || bundle.CoverageScope != c.RuntimeScope) {
			return fmt.Errorf("current release requires verified runtime bundle")
		}
		files, err := releaseGoFiles(".", bundle)
		if err != nil {
			return err
		}
		for i := 0; i < 12; i++ {
			err = verifyTag(read, data, *tag, *sha, *run, files, bundle, *requireRuntime)
			if err == nil {
				fmt.Printf("公開版本驗收通過：%s %s\n", *tag, *sha)
				return nil
			}
			if i < 11 {
				deploymentSleep(10 * time.Second)
			}
		}
		return err
	}
	if *mode != "branch" || *tag != "" || *metadata != "" || *bundleTool != "" || *archive != "" || *attempt != 0 || *download || *repository != "" || *requireRuntime {
		return fmt.Errorf("invalid deployment mode")
	}
	requiredVersion := ""
	if *latestMetadata != "" {
		if *portalDir == "" {
			return fmt.Errorf("latest release requires portal artifact")
		}
		data, err := os.ReadFile(*latestMetadata)
		if err != nil {
			return err
		}
		var latest releaseMetadata
		if err = json.Unmarshal(data, &latest); err != nil {
			return err
		}
		if latest.Draft == nil || *latest.Draft || latest.Immutable == nil || !*latest.Immutable || !regexp.MustCompile(`^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-rc[1-9][0-9]*)?$`).MatchString(latest.Tag) {
			return fmt.Errorf("invalid immutable latest release")
		}
		requiredVersion = latest.Tag
	}
	var measured *c.Evidence
	r, e := a.VerifyWithRetry(read, string(b), *sha, *run, *base, 12, func() {
		fmt.Println("部署驗收尚未符合本次來源，有限等待 CDN 更新。")
		deploymentSleep(10 * time.Second)
	}, func() error {
		reportReader := func(n string) ([]byte, error) { return read("main/" + n) }
		summary, err := reportReader("summary.json")
		if err != nil {
			return err
		}
		measured, err = a.ValidateRepoCoverageReport(reportReader, summary, *sha, *run, true)
		if err != nil {
			return err
		}
		if err = requireCurrentRuntimeCoverage(measured); err != nil {
			return err
		}
		inventory, err := reportReader("coverage_inventory.json")
		if err != nil {
			return err
		}
		if err = validatePublishedInventory(measured, ".", inventory); err != nil {
			return err
		}
		if *portalDir != "" {
			return verifyPortalBytes(read, *portalDir, requiredVersion)
		}
		return nil
	})
	if e != nil {
		return e
	}
	badges := regexp.MustCompile(`https://github\.com/[^/]+/[^/]+/actions/workflows/[^/]+/badge\.svg`).FindAllString(string(b), -1)
	if len(badges) != 1 {
		return fmt.Errorf("R05 缺少唯一 GitHub CI 徽章")
	}
	client := http.Client{Timeout: 20 * time.Second, CheckRedirect: func(req *http.Request, via []*http.Request) error {
		if req.URL.Scheme != "https" || len(via) >= 10 {
			return fmt.Errorf("R05 非法徽章重導向")
		}
		return nil
	}}
	response, e := client.Get(badges[0])
	if e != nil {
		return e
	}
	defer response.Body.Close()
	if response.StatusCode != 200 {
		return fmt.Errorf("R05 GitHub CI 徽章不可讀")
	}
	body, e := io.ReadAll(response.Body)
	if e != nil {
		return e
	}
	if e = a.ValidateXMLNamespace(body, "http://www.w3.org/2000/svg"); e != nil {
		return e
	}
	var svg struct{ XMLName xml.Name }
	if e = xml.Unmarshal(body, &svg); e != nil {
		return e
	}
	if svg.XMLName.Local != "svg" || svg.XMLName.Space != "http://www.w3.org/2000/svg" {
		return fmt.Errorf("R05 GitHub CI 徽章不是SVG")
	}
	summary := fmt.Sprintf("## 公開部署需求驗收通過\n\n- 本次 main 提交：`%s`\n- 報告執行：%s\n- 首頁、測試報告、runtime 徽章與三份覆蓋率證據可讀，來源清單與本次 checkout 一致。\n- PowerShell/C# runtime 可執行行覆蓋率：%.1f%%（%d/%d），完整量測且精確八成門檻通過；不含 CMD 與 Go。\n", r.Commit, r.RunUrl, *measured.Result.Percent, measured.Result.Covered, measured.Result.Executable)
	languages := []string{}
	for language := range measured.Result.Languages {
		languages = append(languages, language)
	}
	sort.Strings(languages)
	for _, language := range languages {
		counts := measured.Result.Languages[language]
		summary += fmt.Sprintf("- %s：%d/%d 可執行行\n", language, counts.Covered, counts.Executable)
	}
	fmt.Print(summary)
	if p := os.Getenv("GITHUB_STEP_SUMMARY"); p != "" {
		return os.WriteFile(p, []byte(summary), 0600)
	}
	return nil
}
func main() {
	if e := run(); e != nil {
		fmt.Fprintln(os.Stderr, "公開部署驗收失敗：", e)
		os.Exit(1)
	}
}
