package main

import "testing"

func TestPresentationDiscriminator(t *testing.T) {
	cases := []struct {
		raw        string
		historical bool
		want       string
		ok         bool
	}{
		{`{}`, true, "legacy", true},
		{`{}`, false, "", false},
		{`{"presentation":"overview-a-v1"}`, false, "overview-a-v1", true},
		{`{"presentation":"overview-a-v1"}`, true, "overview-a-v1", true},
		{`{"Presentation":"overview-a-v1"}`, true, "", false},
		{`{"presentation":null}`, true, "", false},
		{`{"presentation":""}`, true, "", false},
		{`{"presentation":12}`, true, "", false},
		{`{"presentation":"other"}`, true, "", false},
	}
	for _, c := range cases {
		got, err := presentationFormat([]byte(c.raw), c.historical)
		if (err == nil) != c.ok || got != c.want {
			t.Errorf("%s historical=%v: got %q, %v", c.raw, c.historical, got, err)
		}
	}
}
