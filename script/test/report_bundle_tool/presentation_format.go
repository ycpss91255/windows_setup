package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
)

const overviewPresentation = "overview-a-v1"

func presentationFormat(data []byte, historical bool) (string, error) {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		return "", err
	}
	for key := range fields {
		if strings.EqualFold(key, "presentation") && key != "presentation" {
			return "", fmt.Errorf("invalid presentation key")
		}
	}
	raw, ok := fields["presentation"]
	if !ok {
		if historical {
			return "legacy", nil
		}
		return "", fmt.Errorf("current archive missing presentation")
	}
	var name string
	if bytes.Equal(bytes.TrimSpace(raw), []byte("null")) || json.Unmarshal(raw, &name) != nil || name != overviewPresentation {
		return "", fmt.Errorf("invalid presentation")
	}
	return name, nil
}
