package main

import "strings"

func reportDomain(name string) string {
	tokens := strings.FieldsFunc(strings.ToLower(name), func(r rune) bool { return r == '.' || r == '_' || r == '-' })
	has := func(names ...string) bool {
		for _, token := range tokens {
			for _, n := range names {
				if token == n {
					return true
				}
			}
		}
		return false
	}
	adjacent := func(a, b string) bool {
		for i := 0; i+1 < len(tokens); i++ {
			if tokens[i] == a && tokens[i+1] == b {
				return true
			}
		}
		return false
	}
	switch {
	case has("hardware", "driver", "drivers"):
		return "硬體與驅動包"
	case has("account", "accounts", "uac", "permission", "permissions"):
		return "帳號與權限"
	case adjacent("source", "release") || has("version", "versions", "release"):
		return "版本與來源準備"
	case adjacent("one", "drive") || has("input", "taskbar", "start", "desktop", "theme", "display", "power", "privacy", "debloat", "cleanup"):
		return "Windows 設定與清理"
	case has("network", "networking", "ssh", "mdns", "hosts", "firewall"):
		return "網路與 SSH"
	case has("ci", "coverage", "container", "containers", "docker", "report", "reports", "portal"):
		return "測試與交付工具"
	default:
		return "其他檢查"
	}
}
