package acceptance

import (
	"fmt"
	"regexp"
	"strings"
	c "windows_setup/script/test/repo_coverage"
)

// ValidatePortalCoverage checks the visible overview against already verified report evidence.
func ValidatePortalCoverage(visible string, summary []byte) error {
	var metadata struct {
		SchemaVersion int
		GoCoverage    *GoCoverage
		RepoCoverage  *c.Evidence
	}
	if e := decode(summary, &metadata); e != nil {
		return e
	}
	if metadata.SchemaVersion == 2 {
		label := "整體覆蓋率"
		if metadata.RepoCoverage != nil && metadata.RepoCoverage.SchemaVersion == c.RuntimeSchemaVersion {
			label = "PowerShell/C# runtime 覆蓋率"
		}
		if !strings.Contains(visible, label) {
			return fmt.Errorf("首頁缺少整體覆蓋率標示")
		}
		overall := metadata.RepoCoverage
		if overall == nil || !overall.Result.Complete {
			if !strings.Contains(visible, "尚未提供完整量測") || regexp.MustCompile(`[0-9]+(?:\.[0-9]+)?%`).MatchString(visible) {
				return fmt.Errorf("缺少整體量測時不得以分項百分比冒充")
			}
			return nil
		}
		r := overall.Result
		if r.Percent == nil || r.Executable <= 0 || r.Covered < 0 || r.Covered > r.Executable {
			return fmt.Errorf("整體覆蓋率計數無效")
		}
		for _, text := range []string{fmt.Sprintf("%.1f%%", *r.Percent), fmt.Sprintf("%d/%d 可執行行", r.Covered, r.Executable)} {
			if !strings.Contains(visible, text) {
				return fmt.Errorf("首頁整體覆蓋率與證據不同：%s", text)
			}
		}
		return nil
	}
	c := metadata.GoCoverage
	if c == nil {
		return nil
	}
	expected := []string{
		fmt.Sprintf("Go 程式敘述覆蓋率：%.1f%%", c.Percent),
		fmt.Sprintf("%d/%d statements", c.Covered, c.TotalStatements),
		"全部自有 Go 工具（含 CLI）", "不含 PowerShell 或第三方程式", "PowerShell 覆蓋率尚未量測",
	}
	for _, text := range expected {
		if !strings.Contains(visible, text) {
			return fmt.Errorf("首頁缺少正確可見 Go 覆蓋率或範圍：%s", text)
		}
	}
	return nil
}
