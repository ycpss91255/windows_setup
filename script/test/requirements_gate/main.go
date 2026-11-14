package main

import (
	"flag"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	a "windows_setup/script/test/acceptance"
	rc "windows_setup/script/test/repo_coverage"
)

func requireRuntimeCoverage(report a.Report) error {
	e := report.RepoCoverage
	if e == nil || e.SchemaVersion != rc.RuntimeSchemaVersion || e.Metric != rc.RuntimeMetric || e.Scope != rc.RuntimeScope || !e.Result.Complete || e.Result.Executable <= 0 {
		return fmt.Errorf("缺少完整 PowerShell／C# runtime 覆蓋率")
	}
	covered := new(big.Int).Mul(big.NewInt(int64(e.Result.Covered)), big.NewInt(100))
	minimum := new(big.Int).Mul(big.NewInt(int64(e.Result.Executable)), big.NewInt(80))
	if covered.Cmp(minimum) < 0 {
		return fmt.Errorf("runtime 覆蓋率未達精確 80%%")
	}
	return nil
}

func run() error {
	dir := flag.String("artifact-dir", "", "report directory")
	root := flag.String("source-root", "", "repository")
	sha := flag.String("expected-sha", "", "expected commit")
	run := flag.String("expected-run-url", "", "expected run")
	runtimeScope := flag.Bool("require-runtime", false, "require complete runtime coverage")
	testsOnly := flag.Bool("tests-only", false, "validate source and test report without coverage")
	historicalGo := flag.Bool("historical-go", false, "validate historical Go coverage contract")
	flag.Parse()
	provided := map[string]bool{}
	flag.Visit(func(f *flag.Flag) { provided[f.Name] = true })
	if *dir == "" || *root == "" || *sha == "" || !provided["expected-run-url"] {
		return fmt.Errorf("四個驗收參數皆為必要")
	}
	if (*testsOnly && (*runtimeScope || *historicalGo)) || (*historicalGo && *runtimeScope) {
		return fmt.Errorf("驗收模式不可混用")
	}
	if _, e := a.ValidateSource(*root); e != nil {
		return e
	}
	read := func(n string) ([]byte, error) { return os.ReadFile(filepath.Join(*dir, n)) }
	report, e := a.ValidateReport(read, *sha, *run, false)
	if e != nil {
		return e
	}
	if *testsOnly {
		return nil
	}
	if *historicalGo {
		files, err := a.OwnedGoFiles(*root)
		if err != nil {
			return err
		}
		return a.ValidateGoCoverageReport(read, files, *sha, *run, false)
	}
	if err := requireRuntimeCoverage(report); err != nil {
		return err
	}
	summary, err := read("summary.json")
	if err != nil {
		return err
	}
	evidence, err := a.ValidateRepoCoverageReport(read, summary, *sha, *run, true)
	if err != nil {
		return err
	}
	if err = requireRuntimeCoverage(a.Report{RepoCoverage: evidence}); err != nil {
		return err
	}
	inventory, err := read("coverage_inventory.json")
	if err != nil {
		return err
	}
	return rc.ValidateRuntimeInventory(*root, inventory)
}
func main() {
	if e := run(); e != nil {
		fmt.Fprintln(os.Stderr, "需求驗收失敗：", e)
		os.Exit(1)
	}
	fmt.Println("需求驗收通過：來源命名／入口、真實測試產物、證據連結與 base 徽章；實機與人工視覺驗收未冒稱完成。")
}
