package main

import (
	"encoding/json"
	h "golang.org/x/net/html"
	"strings"
	"testing"
	a "windows_setup/script/test/acceptance"
)

func TestCoverageHeadlineShowsOnlyMeasuredPercentage(t *testing.T) {
	for _, tc := range []struct {
		name                    string
		coverage                any
		headline, scope, counts string
	}{
		{"runtime", map[string]any{"SchemaVersion": 2, "Scope": "core-modules-powershell-and-modules-native-csharp", "Result": map[string]any{"Complete": true, "Covered": 17, "Executable": 23}}, "73.9%", "PowerShell/C# runtime 覆蓋率", "17/23 可執行行"},
		{"historical", map[string]any{"SchemaVersion": 1, "Result": map[string]any{"Complete": true, "Covered": 51, "Executable": 67}}, "76.1%", "整體覆蓋率", "51/67 可執行行"},
		{"missing", nil, "尚未完整量測", "", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			report := map[string]any{"Commit": strings.Repeat("a", 40), "Success": true, "Totals": map[string]any{}}
			if tc.coverage != nil {
				report["RepoCoverage"] = tc.coverage
			}
			b, _ := json.Marshal(report)
			page, _ := overviewRootDocuments("v1.2.3", map[string][]byte{"summary.json": b}, map[string][]byte{"summary.json": b})
			root, err := h.Parse(strings.NewReader(string(page)))
			if err != nil {
				t.Fatal(err)
			}
			var headline string
			var text func(*h.Node) string
			text = func(n *h.Node) string {
				v := ""
				if n.Type == h.TextNode {
					v += n.Data
				}
				for c := n.FirstChild; c != nil; c = c.NextSibling {
					v += text(c)
				}
				return v
			}
			var walk func(*h.Node)
			walk = func(n *h.Node) {
				if n.Type == h.ElementNode && n.Data == "article" {
					found := false
					for c := n.FirstChild; c != nil; c = c.NextSibling {
						if c.Type == h.ElementNode && c.Data == "h3" && text(c) == "原生整體覆蓋率" {
							found = true
						}
					}
					if found {
						for c := n.FirstChild; c != nil; c = c.NextSibling {
							if c.Type == h.ElementNode && c.Data == "div" {
								for _, attr := range c.Attr {
									if attr.Key == "class" && attr.Val == "big" {
										headline = text(c)
									}
								}
							}
						}
					}
				}
				for c := n.FirstChild; c != nil; c = c.NextSibling {
					walk(c)
				}
			}
			walk(root)
			if headline != tc.headline {
				t.Errorf("headline=%q want %q", headline, tc.headline)
			}
			visible, err := a.ParsePage(page)
			if err != nil {
				t.Fatal(err)
			}
			for _, want := range []string{tc.scope, tc.counts} {
				if want != "" && !strings.Contains(visible.Visible, want) {
					t.Errorf("visible evidence missing %q", want)
				}
			}
			if tc.name == "missing" && strings.Contains(headline, "%") {
				t.Error("unknown coverage shows a percentage")
			}
		})
	}
}
