package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"unicode"
	rc "windows_setup/script/test/repo_coverage"
)

type timingPhase struct {
	Name         string
	Milliseconds int64
}
type timingReceipt struct {
	SchemaVersion int
	Context       rc.PowerShellWorkerContext
	Phases        []timingPhase
}

// A receipt is at most 16 KiB before decoding. JSON encoding may expand each
// byte to at most six bytes (for example '&' becomes '\u0026'); 4 KiB per
// record covers this fixed schema's indentation and delimiters, and another
// 4 KiB covers the surrounding array. The roster cap keeps multiplication and
// allocation bounded even for untrusted artifact metadata.
func timingShardLimit(workers int) (int64, error) {
	const maxWorkers = 4096
	const maxWireRecord = int64(6*16384 + 4096)
	if workers < 1 || workers > maxWorkers {
		return 0, fmt.Errorf("invalid timing roster size")
	}
	return int64(workers)*maxWireRecord + 4096, nil
}

// The expected contexts must come from validated actual worker evidence, not the receipt.
func validateTimingRoster(expected []rc.PowerShellWorkerContext, receipts []timingReceipt) error {
	if len(expected) == 0 || len(receipts) != len(expected) {
		return fmt.Errorf("timing roster incomplete")
	}
	byIndex := make(map[int]rc.PowerShellWorkerContext, len(expected))
	for _, c := range expected {
		if _, ok := byIndex[c.GlobalIndex]; ok {
			return fmt.Errorf("duplicate expected worker")
		}
		byIndex[c.GlobalIndex] = c
	}
	seen := make(map[int]bool, len(receipts))
	for _, r := range receipts {
		c, ok := byIndex[r.Context.GlobalIndex]
		if !ok || seen[r.Context.GlobalIndex] || r.SchemaVersion != 1 || r.Context != c {
			return fmt.Errorf("timing worker identity or multiplicity mismatch")
		}
		seen[r.Context.GlobalIndex] = true
		if len(r.Phases) != 3 {
			return fmt.Errorf("timing phase count mismatch")
		}
		names := map[string]bool{"worker_setup": false, "pester_instrumentation_and_test": false, "serialization": false}
		for _, p := range r.Phases {
			used, ok := names[p.Name]
			if !ok || used || p.Milliseconds < 0 {
				return fmt.Errorf("invalid timing phase")
			}
			names[p.Name] = true
		}
	}
	return nil
}

// Worker file names are derived only from the validated local worker order.
func readWorkerTimings(dir string, expected []rc.PowerShellWorkerContext) ([]timingReceipt, error) {
	receipts := make([]timingReceipt, 0, len(expected))
	for i := range expected {
		b, err := readTimingRegular(filepath.Join(dir, fmt.Sprintf("worker_%d.timing.json", i)), 16384)
		if err != nil {
			return nil, err
		}
		var receipt timingReceipt
		if err := decodeTiming(b, &receipt); err != nil {
			return nil, err
		}
		receipts = append(receipts, receipt)
	}
	if err := validateTimingRoster(expected, receipts); err != nil {
		return nil, err
	}
	return receipts, nil
}

func readTimingBounded(r io.Reader, limit int64) ([]byte, error) {
	if limit < 0 {
		return nil, fmt.Errorf("invalid timing size limit")
	}
	b, err := io.ReadAll(io.LimitReader(r, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(b)) > limit {
		return nil, fmt.Errorf("timing receipt too large")
	}
	return b, nil
}

func readTimingRegular(path string, limit int64) ([]byte, error) {
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Size() > limit {
		return nil, fmt.Errorf("timing must be a bounded regular file")
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	opened, err := f.Stat()
	if err != nil || !opened.Mode().IsRegular() || opened.Size() > limit || !os.SameFile(info, opened) {
		return nil, fmt.Errorf("timing file changed before reading")
	}
	return readTimingBounded(f, limit)
}

// foldTimingKey follows the Unicode simple-fold cycles used by encoding/json.
func foldTimingKey(name string) string {
	return strings.Map(func(r rune) rune {
		min := r
		for next := unicode.SimpleFold(r); next != r; next = unicode.SimpleFold(next) {
			if next < min {
				min = next
			}
		}
		return min
	}, name)
}

// Reject duplicate object members before decoding to typed values.
func decodeTiming(data []byte, target any) error {
	d := json.NewDecoder(bytes.NewReader(data))
	var value func() error
	value = func() error {
		token, err := d.Token()
		if err != nil {
			return err
		}
		delim, ok := token.(json.Delim)
		if !ok {
			return nil
		}
		switch delim {
		case '{':
			names := map[string]bool{}
			for d.More() {
				k, err := d.Token()
				if err != nil {
					return err
				}
				name, ok := k.(string)
				if !ok || names[foldTimingKey(name)] {
					return fmt.Errorf("duplicate timing field")
				}
				names[foldTimingKey(name)] = true
				if err = value(); err != nil {
					return err
				}
			}
			_, err = d.Token()
			return err
		case '[':
			for d.More() {
				if err = value(); err != nil {
					return err
				}
			}
			_, err = d.Token()
			return err
		default:
			return fmt.Errorf("invalid timing value")
		}
	}
	if err := value(); err != nil {
		return err
	}
	var rows []json.RawMessage
	switch target.(type) {
	case *timingReceipt:
		rows = []json.RawMessage{data}
	case *[]timingReceipt:
		if err := json.Unmarshal(data, &rows); err != nil || rows == nil {
			return fmt.Errorf("invalid timing array")
		}
	default:
		return fmt.Errorf("unsupported timing target")
	}
	for _, row := range rows {
		var receipt map[string]json.RawMessage
		if err := json.Unmarshal(row, &receipt); err != nil {
			return err
		}
		if err := requireTimingFields(receipt, "SchemaVersion", "Context", "Phases"); err != nil {
			return err
		}
		var context map[string]json.RawMessage
		if err := json.Unmarshal(receipt["Context"], &context); err != nil {
			return err
		}
		if err := requireTimingFields(context, "Commit", "RunUrl", "RunAttempt", "ShardIndex", "ShardCount", "GlobalIndex", "ProcessId", "TestFile", "TestSHA256", "WrapperFile", "WrapperSHA256"); err != nil {
			return err
		}
		var phases []map[string]json.RawMessage
		if err := json.Unmarshal(receipt["Phases"], &phases); err != nil || phases == nil {
			return fmt.Errorf("invalid timing phases")
		}
		for _, phase := range phases {
			if err := requireTimingFields(phase, "Name", "Milliseconds"); err != nil {
				return err
			}
		}
	}
	return decodeShardManifest(data, target)
}

func requireTimingFields(object map[string]json.RawMessage, fields ...string) error {
	for _, name := range fields {
		value, ok := object[name]
		if !ok || bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
			return fmt.Errorf("missing or null timing field %s", name)
		}
	}
	return nil
}

func assertStableTimingInput(validatedManifest, currentManifest, worker []byte, expectedHash string) error {
	if !bytes.Equal(validatedManifest, currentManifest) || fmt.Sprintf("%x", sha256.Sum256(worker)) != expectedHash {
		return fmt.Errorf("validated shard changed during timing verification")
	}
	return nil
}
