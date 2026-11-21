package actions_timing

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

type Expected struct {
	Repository           string
	RunID                int64
	Attempt              int
	HeadSHA, CheckoutSHA string
}

// rejectUnpairedSurrogates preserves string content before encoding/json can
// replace isolated UTF-16 surrogates. JSON syntax remains the decoder's job.
func rejectUnpairedSurrogates(data []byte) error {
	inString := false
	for i := 0; i < len(data); i++ {
		switch {
		case data[i] == '"':
			inString = !inString
		case inString && data[i] == '\\':
			i++
			if i >= len(data) || data[i] != 'u' || i+4 >= len(data) {
				continue
			}
			unit, err := strconv.ParseUint(string(data[i+1:i+5]), 16, 16)
			if err != nil {
				continue
			}
			i += 4
			if unit >= 0xdc00 && unit <= 0xdfff {
				return fmt.Errorf("unpaired JSON surrogate")
			}
			if unit >= 0xd800 && unit <= 0xdbff {
				if i+6 >= len(data) || data[i+1] != '\\' || data[i+2] != 'u' {
					return fmt.Errorf("unpaired JSON surrogate")
				}
				low, err := strconv.ParseUint(string(data[i+3:i+7]), 16, 16)
				if err != nil || low < 0xdc00 || low > 0xdfff {
					return fmt.Errorf("unpaired JSON surrogate")
				}
				i += 6
			}
		}
	}
	return nil
}

// foldField uses the complete Unicode simple-fold cycle, matching the
// case-insensitive field matching used by encoding/json (including long s and Kelvin sign).
func foldField(s string) string {
	return strings.Map(func(r rune) rune {
		min := r
		for next := unicode.SimpleFold(r); next != r; next = unicode.SimpleFold(next) {
			if next < min {
				min = next
			}
		}
		return min
	}, s)
}

func (j *Job) UnmarshalJSON(data []byte) error {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		return err
	}
	steps, ok := fields["steps"]
	if !ok || bytes.Equal(bytes.TrimSpace(steps), []byte("null")) {
		return fmt.Errorf("missing job steps inventory")
	}
	for name, raw := range fields {
		if foldField(name) == foldField("head_sha") && bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
			return fmt.Errorf("job head cannot be null when supplied")
		}
	}
	type plainJob Job
	var value plainJob
	if err := json.Unmarshal(data, &value); err != nil {
		return err
	}
	*j = Job(value)
	return nil
}

func (p *Page) UnmarshalJSON(data []byte) error {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil {
		return err
	}
	for _, name := range []string{"page_number", "per_page", "total_count", "jobs"} {
		raw, ok := fields[name]
		if !ok || bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
			return fmt.Errorf("missing page field %s", name)
		}
	}
	type plainPage Page
	var value plainPage
	if err := json.Unmarshal(data, &value); err != nil {
		return err
	}
	*p = Page(value)
	return nil
}

// Decode validates shape and internal consistency of caller-supplied data;
// independently obtained Expected values do not authenticate the data origin.
func Decode(data []byte, expected Expected) (Output, error) {
	if len(data) > 16*1024*1024 {
		return Output{}, fmt.Errorf("observation input too large")
	}
	if !utf8.Valid(data) {
		return Output{}, fmt.Errorf("observation input is not valid UTF-8")
	}
	if err := rejectUnpairedSurrogates(data); err != nil {
		return Output{}, err
	}
	d := json.NewDecoder(bytes.NewReader(data))
	var value func(int) error
	value = func(depth int) error {
		if depth > 100 {
			return fmt.Errorf("JSON nesting too deep")
		}
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
			seen := map[string]bool{}
			for d.More() {
				key, e := d.Token()
				if e != nil {
					return e
				}
				name, ok := key.(string)
				fold := foldField(name)
				if !ok || seen[fold] {
					return fmt.Errorf("duplicate JSON field")
				}
				seen[fold] = true
				if e = value(depth + 1); e != nil {
					return e
				}
			}
			_, err = d.Token()
			return err
		case '[':
			for d.More() {
				if err = value(depth + 1); err != nil {
					return err
				}
			}
			_, err = d.Token()
			return err
		default:
			return fmt.Errorf("invalid JSON delimiter")
		}
	}
	if err := value(0); err != nil {
		return Output{}, err
	}
	if _, err := d.Token(); err != io.EOF {
		return Output{}, fmt.Errorf("trailing JSON content")
	}
	var wire struct {
		Run   Run    `json:"run"`
		Pages []Page `json:"pages"`
	}
	if err := json.Unmarshal(data, &wire); err != nil {
		return Output{}, err
	}
	return Analyze(Input{Repository: expected.Repository, RunID: expected.RunID, Attempt: expected.Attempt, HeadSHA: expected.HeadSHA, CheckoutSHA: expected.CheckoutSHA, Run: wire.Run, Pages: wire.Pages})
}
