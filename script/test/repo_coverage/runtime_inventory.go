package repo_coverage

import (
	"path"
	"sort"
	"strings"
)

func runtimeThirdParty(name string) bool {
	return strings.HasPrefix(strings.ToLower(name), "modules/debloat/win11debloat/")
}

func approvedRuntimeSource(name, language string) bool {
	if runtimeThirdParty(name) {
		return false
	}
	parts := strings.Split(name, "/")
	ext := strings.ToLower(path.Ext(name))
	ps := (strings.HasPrefix(name, "core/") || strings.HasPrefix(name, "modules/")) && language == "powershell" && (ext == ".ps1" || ext == ".psm1")
	native := len(parts) == 4 && parts[0] == "modules" && parts[2] == "native" && language == "csharp" && ext == ".cs"
	return ps || native
}

// ScanRuntimeInventory leaves the historical all-owned inventory unchanged.
// Only approved PowerShell and managed native sources contribute to runtime coverage.
func ScanRuntimeInventory(root string) (Inventory, error) {
	all, err := scanInventory(root, true)
	if err != nil {
		return Inventory{}, err
	}
	inv := Inventory{Excluded: append([]Exclusion(nil), all.Excluded...)}
	isRuntime := func(name string) bool { return strings.HasPrefix(name, "core/") || strings.HasPrefix(name, "modules/") }
	for _, b := range all.Blockers {
		name, _, _ := strings.Cut(b, ":")
		if isRuntime(name) && !strings.Contains(b, "unsupported CMD executable syntax") {
			inv.Blockers = append(inv.Blockers, b)
		}
	}
	for _, s := range all.Sources {
		approved := approvedRuntimeSource(s.Path, s.Language)
		if approved {
			inv.Sources = append(inv.Sources, s)
			continue
		}
		inv.Excluded = append(inv.Excluded, Exclusion{s.Path, "outside runtime PowerShell and native C# coverage scope"})
		if isRuntime(s.Path) && s.Language != "cmd" {
			inv.Blockers = append(inv.Blockers, s.Path+": runtime executable requires explicit scope decision")
		}
	}
	executable := map[string]bool{".exe": true, ".dll": true, ".com": true, ".wsf": true, ".wsh": true, ".vbe": true, ".jse": true, ".hta": true, ".msi": true, ".msp": true, ".jar": true, ".wasm": true, ".pyw": true}
	for _, e := range all.Excluded {
		if e.Reason != "non-executable data, documentation, or dependency artifact" || !isRuntime(e.Path) {
			continue
		}
		ext := strings.ToLower(path.Ext(e.Path))
		if executable[ext] && !strings.EqualFold(e.Path, "modules/accounts/Autologon64.exe") {
			inv.Blockers = append(inv.Blockers, e.Path+": runtime executable requires explicit scope decision")
		}
	}
	sort.Slice(inv.Sources, func(i, j int) bool { return inv.Sources[i].Path < inv.Sources[j].Path })
	sort.Strings(inv.Blockers)
	return inv, nil
}
