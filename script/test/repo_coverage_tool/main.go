// repo_coverage_tool verifies repository-owned coverage artifacts without a
// hosted coverage service. It is a maintenance tool, not a Windows dependency.
package main

import (
	"flag"
	"fmt"
	"io"
	"math/big"
	"os"
	"path/filepath"
	rc "windows_setup/script/test/repo_coverage"
)

func run(args []string, out io.Writer) error {
	if len(args) > 0 {
		switch args[0] {
		case "native-stage-pack", "native-stage-restore":
			return nativeStage(args[0], args[1:], out)
		case "powershell-shard-plan":
			return powershellShardPlan(args[1:], out)
		case "powershell-shard-pack":
			return powershellShardPack(args[1:], out)
		case "powershell-shard-merge":
			return powershellShardMerge(args[1:], out)
		}
	}
	if len(args) > 0 && args[0] == "export-powershell" {
		return exportPowerShell(args[1:], out)
	}
	if len(args) > 0 && args[0] == "cmd-measure" {
		return cmdMeasure(args[1:], out)
	}
	if len(args) > 0 && args[0] == "collect" {
		return collect(args[1:], out)
	}
	if len(args) == 0 || args[0] != "verify" {
		return fmt.Errorf("用法：repo_coverage_tool verify --artifact-dir 路徑 --expected-sha 提交 [--expected-run-url URL] [--source-root 原始碼]")
	}
	flags := flag.NewFlagSet("verify", flag.ContinueOnError)
	flags.SetOutput(out)
	dir := flags.String("artifact-dir", "", "三檔證據目錄")
	sha := flags.String("expected-sha", "", "預期提交")
	runURL := flags.String("expected-run-url", "", "預期 Actions 執行 URL")
	source := flags.String("source-root", "", "選用：核對實際來源清單與雜湊")
	complete := flags.Bool("require-complete", false, "要求全部來源已量測")
	minimum := flags.Int("minimum-percent", 0, "完整覆蓋率最低整數百分比")
	runtimeScope := flags.Bool("runtime", false, "驗證 PowerShell／C# runtime 範圍")
	if err := flags.Parse(args[1:]); err != nil {
		return err
	}
	if *dir == "" || *sha == "" || flags.NArg() != 0 {
		return fmt.Errorf("必須指定證據目錄與提交，不能帶額外位置參數")
	}
	if *minimum < 0 || *minimum > 100 {
		return fmt.Errorf("覆蓋率門檻必須介於 0 與 100")
	}
	files := make([][]byte, 3)
	for index, name := range []string{"repo_coverage.json", "coverage_inventory.json", "coverage.xml"} {
		data, err := os.ReadFile(filepath.Join(*dir, name))
		if err != nil {
			return fmt.Errorf("讀取 %s：%w", name, err)
		}
		files[index] = data
	}
	var result rc.Result
	var commit string
	if *runtimeScope {
		evidence, err := rc.ValidateRuntimeEvidence(files[0], files[1], files[2], *sha, *runURL)
		if err != nil {
			return err
		}
		result, commit = evidence.Result, evidence.Commit
	} else {
		evidence, err := rc.ValidateEvidence(files[0], files[1], files[2], *sha, *runURL)
		if err != nil {
			return err
		}
		result, commit = evidence.Result, evidence.Commit
	}
	if *source != "" {
		var err error
		if *runtimeScope {
			err = rc.ValidateRuntimeInventory(*source, files[1])
		} else {
			err = rc.ValidateInventory(*source, files[1])
		}
		if err != nil {
			return err
		}
	}
	if (*complete || *minimum > 0) && (!result.Complete || result.Executable == 0) {
		return fmt.Errorf("整體覆蓋率尚未完整量測")
	}
	covered := new(big.Int).Mul(big.NewInt(int64(result.Covered)), big.NewInt(100))
	threshold := new(big.Int).Mul(big.NewInt(int64(result.Executable)), big.NewInt(int64(*minimum)))
	if covered.Cmp(threshold) < 0 {
		return fmt.Errorf("整體覆蓋率低於 %d%%", *minimum)
	}
	label := "整體覆蓋率"
	if *runtimeScope {
		label = "PowerShell／C# runtime 覆蓋率"
	}
	fmt.Fprintf(out, "%s證據驗證通過：%s，完整=%t，命中=%d，可執行=%d\n", label, commit, result.Complete, result.Covered, result.Executable)
	return nil
}
func main() {
	if err := run(os.Args[1:], os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
