package repo_coverage

import (
	"encoding/json"
	"fmt"
)

const RuntimeSchemaVersion = 2
const RuntimeMetric = "runtime-powershell-csharp-executable-lines-v2"
const RuntimeScope = "core-modules-powershell-and-modules-native-csharp"

type RuntimeEvidence struct {
	SchemaVersion int
	Metric, Scope string
	Identity
	InventorySHA256, NormalizedSHA256 string
	Result                            Result
}

func validateRuntimeSources(inv Inventory) error {
	for _, source := range inv.Sources {
		if !approvedRuntimeSource(source.Path, source.Language) {
			return fmt.Errorf("source outside runtime scope: %s", source.Path)
		}
	}
	return nil
}

func CreateRuntimeEvidence(inv Inventory, reports []Report, identity Identity) (Artifacts, error) {
	if err := validateRuntimeSources(inv); err != nil {
		return Artifacts{}, err
	}
	a, err := CreateEvidence(inv, reports, identity)
	if err != nil {
		return a, err
	}
	var old Evidence
	if err = json.Unmarshal(a.Summary, &old); err != nil {
		return Artifacts{}, err
	}
	current := RuntimeEvidence{SchemaVersion: RuntimeSchemaVersion, Metric: RuntimeMetric, Scope: RuntimeScope, Identity: old.Identity, InventorySHA256: old.InventorySHA256, NormalizedSHA256: old.NormalizedSHA256, Result: old.Result}
	a.Summary, err = json.MarshalIndent(current, "", "  ")
	if err != nil {
		return Artifacts{}, err
	}
	if _, err = ValidateRuntimeEvidence(a.Summary, a.Inventory, a.XML, identity.Commit, identity.RunUrl); err != nil {
		return Artifacts{}, err
	}
	return a, nil
}

func ValidateRuntimeEvidence(summary, inventoryData, xmlData []byte, commit, run string) (RuntimeEvidence, error) {
	var current RuntimeEvidence
	if err := strictJSON(summary, &current); err != nil {
		return current, err
	}
	if current.SchemaVersion != RuntimeSchemaVersion || current.Metric != RuntimeMetric || current.Scope != RuntimeScope {
		return current, fmt.Errorf("runtime coverage schema or scope mismatch")
	}
	var inv Inventory
	if err := strictJSON(inventoryData, &inv); err != nil {
		return current, err
	}
	if err := validateRuntimeSources(inv); err != nil {
		return current, err
	}
	old := Evidence{SchemaVersion: SchemaVersion, Metric: Metric, Identity: current.Identity, InventorySHA256: current.InventorySHA256, NormalizedSHA256: current.NormalizedSHA256, Result: current.Result}
	oldSummary, err := json.Marshal(old)
	if err != nil {
		return current, err
	}
	if _, err = ValidateEvidence(oldSummary, inventoryData, xmlData, commit, run); err != nil {
		return current, err
	}
	return current, nil
}
