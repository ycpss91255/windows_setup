package repo_coverage

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"reflect"
	"regexp"
	"sort"
	"strings"
	"time"
)

type Identity struct{ Commit, RunUrl, MeasuredAt, SourceState string }
type Evidence struct {
	SchemaVersion int
	Metric        string
	Scope         string `json:",omitempty"`
	Identity
	InventorySHA256, NormalizedSHA256 string
	Result                            Result
}
type Artifacts struct{ Summary, Inventory, XML []byte }

func digest(data []byte) string { return fmt.Sprintf("%x", sha256.Sum256(data)) }
func validateIdentity(identity Identity) error {
	if !regexp.MustCompile(`^[a-f0-9]{40}$`).MatchString(identity.Commit) || identity.SourceState != "Clean" {
		return fmt.Errorf("coverage requires exact clean source identity")
	}
	if _, err := time.Parse(time.RFC3339, identity.MeasuredAt); err != nil || len(identity.MeasuredAt) == 0 || identity.MeasuredAt[len(identity.MeasuredAt)-1] != 'Z' {
		return fmt.Errorf("coverage requires UTC measurement time")
	}
	if identity.RunUrl != "" && !regexp.MustCompile(`^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/actions/runs/[0-9]+$`).MatchString(identity.RunUrl) {
		return fmt.Errorf("invalid coverage workflow identity")
	}
	return nil
}

// uniqueJSON rejects duplicate object keys at every nesting level. Standard
// decoding alone silently accepts later replacements of trusted evidence.
func uniqueJSON(decoder *json.Decoder) error {
	token, err := decoder.Token()
	if err != nil {
		return err
	}
	delim, ok := token.(json.Delim)
	if !ok {
		return nil
	}
	switch delim {
	case '{':
		seen := map[string]bool{}
		for decoder.More() {
			key, err := decoder.Token()
			if err != nil {
				return err
			}
			name, ok := key.(string)
			name = strings.ToLower(name)
			if !ok || seen[name] {
				return fmt.Errorf("duplicate or invalid JSON key")
			}
			seen[name] = true
			if err := uniqueJSON(decoder); err != nil {
				return err
			}
		}
	case '[':
		for decoder.More() {
			if err := uniqueJSON(decoder); err != nil {
				return err
			}
		}
	default:
		return fmt.Errorf("invalid JSON delimiter")
	}
	_, err = decoder.Token()
	return err
}
func strictJSON(data []byte, target any) error {
	check := json.NewDecoder(bytes.NewReader(data))
	if err := uniqueJSON(check); err != nil {
		return err
	}
	if _, err := check.Token(); err != io.EOF {
		return fmt.Errorf("trailing JSON content")
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	return decoder.Decode(target)
}

func CreateEvidence(inventory Inventory, reports []Report, identity Identity) (Artifacts, error) {
	var a Artifacts
	if err := validateIdentity(identity); err != nil {
		return a, err
	}
	result, err := inventory.Merge(reports...)
	if err != nil {
		return a, err
	}
	a.Inventory, err = json.MarshalIndent(inventory, "", "  ")
	if err != nil {
		return a, err
	}
	a.XML, err = normalizedXML(inventory, reports)
	if err != nil {
		return a, err
	}
	if _, err = ParseCobertura(a.XML, ""); err != nil {
		return a, err
	}
	evidence := Evidence{SchemaVersion: SchemaVersion, Metric: Metric, Identity: identity, InventorySHA256: digest(a.Inventory), NormalizedSHA256: digest(a.XML), Result: result}
	a.Summary, err = json.MarshalIndent(evidence, "", "  ")
	if err == nil {
		_, err = ValidateEvidence(a.Summary, a.Inventory, a.XML, identity.Commit, identity.RunUrl)
	}
	return a, err
}

func ValidateInventory(root string, data []byte) error {
	actual, err := ScanInventory(root)
	if err != nil {
		return err
	}
	return validateInventory(actual, data)
}

func ValidateRuntimeInventory(root string, data []byte) error {
	actual, err := ScanRuntimeInventory(root)
	if err != nil {
		return err
	}
	return validateInventory(actual, data)
}

func validateInventory(actual Inventory, data []byte) error {
	var declared Inventory
	if err := strictJSON(data, &declared); err != nil {
		return err
	}
	if len(actual.Sources) != len(declared.Sources) {
		return fmt.Errorf("coverage inventory omitted or added owned source")
	}
	sort.Slice(declared.Sources, func(i, j int) bool { return declared.Sources[i].Path < declared.Sources[j].Path })
	for i, source := range actual.Sources {
		given := declared.Sources[i]
		if source.Path != given.Path || source.Language != given.Language || source.SHA256 != given.SHA256 {
			return fmt.Errorf("coverage inventory differs from current source: %s", source.Path)
		}
	}
	if !reflect.DeepEqual(actual.Blockers, declared.Blockers) {
		return fmt.Errorf("coverage inventory concealed unsupported executable sources")
	}
	for _, excluded := range declared.Excluded {
		if excluded.Reason == "" {
			return fmt.Errorf("coverage exclusion has no reason")
		}
	}
	return nil
}

// ValidateEvidence verifies immutable normalized evidence. A live checkout
// comparison (including source hashes and the complete source roster) is also
// required by CI; artifact-only validation cannot prove omitted source bytes.
func ValidateEvidence(summary, inventoryData, xmlData []byte, commit, run string) (Evidence, error) {
	var evidence Evidence
	var inventory Inventory
	if err := strictJSON(summary, &evidence); err != nil {
		return evidence, err
	}
	if err := strictJSON(inventoryData, &inventory); err != nil {
		return evidence, err
	}
	if err := validateIdentity(evidence.Identity); err != nil {
		return evidence, err
	}
	if evidence.Commit != commit || evidence.RunUrl != run || evidence.SchemaVersion != SchemaVersion || evidence.Metric != Metric || evidence.Scope != "" {
		return evidence, fmt.Errorf("coverage identity or metric mismatch")
	}
	if evidence.InventorySHA256 != digest(inventoryData) || evidence.NormalizedSHA256 != digest(xmlData) {
		return evidence, fmt.Errorf("coverage artifact digest mismatch")
	}
	for _, source := range inventory.Sources {
		if !regexp.MustCompile(`^[a-f0-9]{64}$`).MatchString(source.SHA256) {
			return evidence, fmt.Errorf("invalid inventory source digest")
		}
	}
	report, err := ParseCobertura(xmlData, "")
	if err != nil {
		return evidence, err
	}
	result, err := inventory.Merge(report)
	if err != nil {
		return evidence, err
	}
	if !reflect.DeepEqual(evidence.Result, result) {
		return evidence, fmt.Errorf("coverage result does not match original executable lines")
	}
	return evidence, nil
}
