package actions_timing

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

func ptr(s string) *string { return &s }
func fixture() Input {
	sha := strings.Repeat("a", 40)
	return Input{Repository: "example/repo", RunID: 123, Attempt: 2, HeadSHA: sha, CheckoutSHA: strings.Repeat("b", 40), Run: Run{ID: 123, RunAttempt: 2, HeadSHA: sha, Repository: Repository{FullName: "example/repo"}}, Pages: []Page{{PageNumber: 1, PerPage: 2, TotalCount: 2, Jobs: []Job{
		{ID: 10, RunID: 123, RunAttempt: 2, Name: "build", Status: "completed", Conclusion: "success", CreatedAt: ptr("2026-11-14T00:00:00Z"), StartedAt: ptr("2026-11-14T00:00:02Z"), CompletedAt: ptr("2026-11-14T00:00:08Z"), Steps: []Step{{Number: 1, Name: "test", Status: "completed", Conclusion: "success", StartedAt: ptr("2026-11-14T00:00:03Z"), CompletedAt: ptr("2026-11-14T00:00:07Z")}}},
		{ID: 11, RunID: 123, RunAttempt: 2, Name: "skipped", Status: "completed", Conclusion: "skipped", StartedAt: ptr("2026-11-14T00:00:04Z"), CompletedAt: ptr("2026-11-14T00:00:03Z"), Steps: []Step{}},
	}}}}
}
func TestSameRunTimingPreservesUnknownAndSkipped(t *testing.T) {
	out, err := Analyze(fixture())
	if err != nil {
		t.Fatal(err)
	}
	if out.CheckoutSHA == out.HeadSHA || out.CheckoutEvidence != "unverified" {
		t.Fatalf("PR checkout evidence overstated: %+v", out)
	}
	if *out.Jobs[0].PendingMilliseconds != 2000 || *out.Jobs[0].ElapsedMilliseconds != 6000 || *out.Jobs[0].Steps[0].ElapsedMilliseconds != 4000 {
		t.Fatalf("incorrect timing: %+v", out.Jobs[0])
	}
	if out.Jobs[1].ElapsedMilliseconds != nil || out.Jobs[1].PendingMilliseconds != nil {
		t.Fatal("skipped timestamps treated as execution")
	}
	x := fixture()
	x.Pages[0].Jobs[0].CreatedAt = nil
	x.Pages[0].Jobs[0].Steps[0].CompletedAt = nil
	out, err = Analyze(x)
	if err != nil {
		t.Fatal(err)
	}
	if out.Jobs[0].PendingMilliseconds != nil || out.Jobs[0].Steps[0].ElapsedMilliseconds != nil {
		t.Fatal("missing timestamp inferred")
	}
}
func TestRejectsMixedIdentityIncompletePagesAndBadTime(t *testing.T) {
	cases := map[string]func(*Input){
		"repository": func(x *Input) { x.Run.Repository.FullName = "other/repo" }, "sha": func(x *Input) { x.Run.HeadSHA = strings.Repeat("c", 40) },
		"run": func(x *Input) { x.Pages[0].Jobs[0].RunID = 999 }, "attempt": func(x *Input) { x.Pages[0].Jobs[0].RunAttempt = 1 },
		"incomplete": func(x *Input) { x.Pages[0].TotalCount = 3 }, "duplicate_job": func(x *Input) { x.Pages[0].Jobs[1].ID = 10 },
		"duplicate_step": func(x *Input) {
			x.Pages[0].Jobs[0].Steps = append(x.Pages[0].Jobs[0].Steps, x.Pages[0].Jobs[0].Steps[0])
		},
		"bad_utc":   func(x *Input) { x.Pages[0].Jobs[0].StartedAt = ptr("2026-11-14T08:00:02+08:00") },
		"backwards": func(x *Input) { x.Pages[0].Jobs[0].CompletedAt = ptr("2026-11-13T23:59:59Z") },
	}
	for name, change := range cases {
		t.Run(name, func(t *testing.T) {
			x := fixture()
			change(&x)
			if _, err := Analyze(x); err == nil {
				t.Fatal("accepted invalid observation")
			}
		})
	}
}

func TestRejectsExtraEmptyPage(t *testing.T) {
	x := fixture()
	x.Pages = append(x.Pages, Page{PageNumber: 2, PerPage: 2, TotalCount: 2, Jobs: []Job{}})
	if _, err := Analyze(x); err == nil {
		t.Fatal("accepted extra page beyond declared total")
	}
}

func TestRejectsContradictoryJobHeadFromAPI(t *testing.T) {
	x := fixture()
	raw, err := json.Marshal(x.Pages[0].Jobs[0])
	if err != nil {
		t.Fatal(err)
	}
	raw = bytes.Replace(raw, []byte(`{"id":`), []byte(`{"head_sha":"`+strings.Repeat("c", 40)+`","id":`), 1)
	if err = json.Unmarshal(raw, &x.Pages[0].Jobs[0]); err != nil {
		t.Fatal(err)
	}
	if _, err = Analyze(x); err == nil {
		t.Fatal("accepted job API head inconsistent with run metadata")
	}
}

func TestDecodeRequiresExternalExpectedIdentityAndRejectsAmbiguousJSON(t *testing.T) {
	x := fixture()
	wire := struct {
		Run   Run    `json:"run"`
		Pages []Page `json:"pages"`
	}{x.Run, x.Pages}
	data, err := json.Marshal(wire)
	if err != nil {
		t.Fatal(err)
	}
	expected := Expected{Repository: x.Repository, RunID: x.RunID, Attempt: x.Attempt, HeadSHA: x.HeadSHA, CheckoutSHA: x.CheckoutSHA}
	if _, err = Decode(data, expected); err != nil {
		t.Fatal(err)
	}
	wrong := expected
	wrong.RunID = 999
	if _, err = Decode(data, wrong); err == nil {
		t.Fatal("accepted unexpected external run")
	}
	duplicate := bytes.Replace(data, []byte(`"run_attempt":2`), []byte(`"run_attempt":1,"run_attempt":2`), 1)
	if _, err = Decode(duplicate, expected); err == nil {
		t.Fatal("accepted duplicate identity")
	}
	if _, err = Decode(append(data, []byte(` {}`)...), expected); err == nil {
		t.Fatal("accepted trailing JSON")
	}
}

func TestDecodeRejectsNullJobHeadWhenPresent(t *testing.T) {
	x := fixture()
	wire := struct {
		Run   Run    `json:"run"`
		Pages []Page `json:"pages"`
	}{x.Run, x.Pages}
	data, err := json.Marshal(wire)
	if err != nil {
		t.Fatal(err)
	}
	data = bytes.Replace(data, []byte(`"id":10`), []byte(`"head_sha":null,"id":10`), 1)
	expected := Expected{Repository: x.Repository, RunID: x.RunID, Attempt: x.Attempt, HeadSHA: x.HeadSHA}
	if _, err = Decode(data, expected); err == nil {
		t.Fatal("accepted explicit null job head")
	}
}

func TestDecodeRejectsMissingPaginationEvidence(t *testing.T) {
	x := fixture()
	wire := struct {
		Run   Run    `json:"run"`
		Pages []Page `json:"pages"`
	}{x.Run, x.Pages}
	data, err := json.Marshal(wire)
	if err != nil {
		t.Fatal(err)
	}
	var root map[string]any
	if err = json.Unmarshal(data, &root); err != nil {
		t.Fatal(err)
	}
	page := root["pages"].([]any)[0].(map[string]any)
	page["total_count"] = nil
	data, _ = json.Marshal(root)
	expected := Expected{Repository: x.Repository, RunID: x.RunID, Attempt: x.Attempt, HeadSHA: x.HeadSHA}
	if _, err = Decode(data, expected); err == nil {
		t.Fatal("accepted null total_count")
	}
	empty := `{"run":{"id":123,"run_attempt":2,"head_sha":"` + x.HeadSHA + `","repository":{"full_name":"example/repo"}},"pages":[{"page_number":1,"per_page":100}]}`
	if _, err = Decode([]byte(empty), expected); err == nil {
		t.Fatal("accepted absent page total and jobs")
	}
}

func TestInProgressJobRetainsKnownPendingWithoutInventingElapsed(t *testing.T) {
	x := fixture()
	x.Pages[0].Jobs[0].Status = "in_progress"
	x.Pages[0].Jobs[0].Conclusion = ""
	x.Pages[0].Jobs[0].CompletedAt = nil
	out, err := Analyze(x)
	if err != nil {
		t.Fatal(err)
	}
	if out.Jobs[0].PendingMilliseconds == nil || *out.Jobs[0].PendingMilliseconds != 2000 || out.Jobs[0].ElapsedMilliseconds != nil || out.Jobs[0].Steps[0].ElapsedMilliseconds == nil || *out.Jobs[0].Steps[0].ElapsedMilliseconds != 4000 {
		t.Fatalf("known pending lost or elapsed invented: %+v", out.Jobs[0])
	}
}

func TestDecodeRejectsMissingJobStepsInventory(t *testing.T) {
	x := fixture()
	wire := struct {
		Run   Run    `json:"run"`
		Pages []Page `json:"pages"`
	}{x.Run, x.Pages}
	data, err := json.Marshal(wire)
	if err != nil {
		t.Fatal(err)
	}
	var root map[string]any
	if err = json.Unmarshal(data, &root); err != nil {
		t.Fatal(err)
	}
	job := root["pages"].([]any)[0].(map[string]any)["jobs"].([]any)[0].(map[string]any)
	delete(job, "steps")
	data, _ = json.Marshal(root)
	expected := Expected{Repository: x.Repository, RunID: x.RunID, Attempt: x.Attempt, HeadSHA: x.HeadSHA}
	if _, err = Decode(data, expected); err == nil {
		t.Fatal("accepted absent job steps inventory")
	}
}

func TestRejectsUnrepresentableElapsedInsteadOfSaturating(t *testing.T) {
	x := fixture()
	x.Pages[0].Jobs[0].CreatedAt = ptr("2000-01-01T00:00:00Z")
	x.Pages[0].Jobs[0].StartedAt = ptr("2000-01-01T00:00:00Z")
	x.Pages[0].Jobs[0].CompletedAt = ptr("2400-01-01T00:00:00Z")
	if _, err := Analyze(x); err == nil {
		t.Fatal("accepted saturated 400-year elapsed as valid milliseconds")
	}
}

func TestNonterminalKnownTimestampsStillRequireValidOrderAndRange(t *testing.T) {
	cases := map[string]func(*Input){
		"job_reverse": func(x *Input) {
			j := &x.Pages[0].Jobs[0]
			j.Status = "in_progress"
			j.Conclusion = ""
			j.CompletedAt = ptr("2026-11-13T23:59:59Z")
		},
		"step_reverse": func(x *Input) {
			s := &x.Pages[0].Jobs[0].Steps[0]
			s.Status = "in_progress"
			s.Conclusion = ""
			s.CompletedAt = ptr("2026-11-14T00:00:02Z")
		},
		"job_overflow": func(x *Input) {
			j := &x.Pages[0].Jobs[0]
			j.Status = "in_progress"
			j.Conclusion = ""
			j.CreatedAt = ptr("2000-01-01T00:00:00Z")
			j.StartedAt = ptr("2000-01-01T00:00:00Z")
			j.CompletedAt = ptr("2400-01-01T00:00:00Z")
		},
	}
	for name, change := range cases {
		t.Run(name, func(t *testing.T) {
			x := fixture()
			change(&x)
			if _, err := Analyze(x); err == nil {
				t.Fatal("accepted contradictory nonterminal timestamps")
			}
		})
	}
}

func TestMissingStartStillRejectsKnownCreatedAfterCompleted(t *testing.T) {
	x := fixture()
	j := &x.Pages[0].Jobs[0]
	j.Status = "in_progress"
	j.Conclusion = ""
	j.CreatedAt = ptr("2026-11-14T00:00:08Z")
	j.StartedAt = nil
	j.CompletedAt = ptr("2026-11-14T00:00:03Z")
	if _, err := Analyze(x); err == nil {
		t.Fatal("accepted completed before created when start missing")
	}
}

func TestDecodeRejectsUnicodeFoldedDuplicateSteps(t *testing.T) {
	x := fixture()
	wire := struct {
		Run   Run    `json:"run"`
		Pages []Page `json:"pages"`
	}{x.Run, x.Pages}
	data, err := json.Marshal(wire)
	if err != nil {
		t.Fatal(err)
	}
	expected := Expected{Repository: x.Repository, RunID: x.RunID, Attempt: x.Attempt, HeadSHA: x.HeadSHA}
	if _, err = Decode(data, expected); err != nil {
		t.Fatalf("valid baseline rejected: %v", err)
	}
	bad := bytes.Replace(data, []byte(`"steps":[]`), []byte(`"steps":[],"\u017fteps":null`), 1)
	if bytes.Equal(bad, data) {
		t.Fatal("fixture did not inject alias")
	}
	if _, err = Decode(bad, expected); err == nil {
		t.Fatal("accepted Unicode-folded duplicate steps overriding required inventory")
	}
	kelvin := bytes.Replace(data, []byte(`{"run":`), []byte(`{"K":1,"\u212a":2,"run":`), 1)
	if bytes.Equal(kelvin, data) {
		t.Fatal("fixture did not inject Kelvin alias")
	}
	if _, err = Decode(kelvin, expected); err == nil {
		t.Fatal("accepted Kelvin-folded duplicate")
	}
}
