package acceptance

import (
	"encoding/json"
	"fmt"
	"math/big"
	"reflect"
	c "windows_setup/script/test/repo_coverage"
)

// ValidateRepoCoverageReport recalculates the public total from its exact source
// inventory and normalized executable-line evidence, including missing sources.
func ValidateRepoCoverageReport(read Reader, summary []byte, sha, run string, required bool) (*c.Evidence, error) {
	var raw struct{ RepoCoverage json.RawMessage }
	if err := decode(summary, &raw); err != nil {
		return nil, err
	}
	if len(raw.RepoCoverage) == 0 || string(raw.RepoCoverage) == "null" {
		if required {
			return nil, fmt.Errorf("缺少完整儲存庫覆蓋率證據")
		}
		return nil, nil
	}
	inventory, err := read("coverage_inventory.json")
	if err != nil {
		return nil, err
	}
	normalized, err := read("coverage.xml")
	if err != nil {
		return nil, err
	}
	published, err := read("repo_coverage.json")
	if err != nil {
		return nil, err
	}
	validate := func(data []byte) (c.Evidence, error) {
		var header struct{ SchemaVersion int }
		if err := json.Unmarshal(data, &header); err != nil {
			return c.Evidence{}, err
		}
		if header.SchemaVersion == c.RuntimeSchemaVersion {
			runtime, err := c.ValidateRuntimeEvidence(data, inventory, normalized, sha, run)
			if err != nil {
				return c.Evidence{}, err
			}
			return c.Evidence{SchemaVersion: runtime.SchemaVersion, Metric: runtime.Metric, Scope: runtime.Scope, Identity: runtime.Identity, InventorySHA256: runtime.InventorySHA256, NormalizedSHA256: runtime.NormalizedSHA256, Result: runtime.Result}, nil
		}
		return c.ValidateEvidence(data, inventory, normalized, sha, run)
	}
	embedded, err := validate(raw.RepoCoverage)
	if err != nil {
		return nil, err
	}
	sidecar, err := validate(published)
	if err != nil {
		return nil, err
	}
	if !reflect.DeepEqual(embedded, sidecar) {
		return nil, fmt.Errorf("報告與公開整體覆蓋率證據不一致")
	}
	if required && (!embedded.Result.Complete || embedded.Result.Executable <= 0) {
		return nil, fmt.Errorf("整體覆蓋率來源量測不完整")
	}
	if required {
		covered := new(big.Int).Mul(big.NewInt(int64(embedded.Result.Covered)), big.NewInt(100))
		minimum := new(big.Int).Mul(big.NewInt(int64(embedded.Result.Executable)), big.NewInt(80))
		if covered.Cmp(minimum) < 0 {
			return nil, fmt.Errorf("整體覆蓋率未達精確80%%發布門檻")
		}
	}
	return &embedded, nil
}
