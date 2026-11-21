// Package actions_timing validates caller-supplied Actions observations; it does not authenticate their origin.
package actions_timing

import (
	"fmt"
	"regexp"
	"strings"
	"time"
)

type Repository struct {
	FullName string `json:"full_name"`
}
type Run struct {
	ID         int64      `json:"id"`
	RunAttempt int        `json:"run_attempt"`
	HeadSHA    string     `json:"head_sha"`
	Repository Repository `json:"repository"`
}
type Step struct {
	Number      int     `json:"number"`
	Name        string  `json:"name"`
	Status      string  `json:"status"`
	Conclusion  string  `json:"conclusion"`
	StartedAt   *string `json:"started_at"`
	CompletedAt *string `json:"completed_at"`
}
type Job struct {
	ID          int64   `json:"id"`
	RunID       int64   `json:"run_id"`
	RunAttempt  int     `json:"run_attempt"`
	HeadSHA     *string `json:"head_sha,omitempty"`
	Name        string  `json:"name"`
	Status      string  `json:"status"`
	Conclusion  string  `json:"conclusion"`
	CreatedAt   *string `json:"created_at"`
	StartedAt   *string `json:"started_at"`
	CompletedAt *string `json:"completed_at"`
	Steps       []Step  `json:"steps"`
}
type Page struct {
	PageNumber int   `json:"page_number"`
	PerPage    int   `json:"per_page"`
	TotalCount int   `json:"total_count"`
	Jobs       []Job `json:"jobs"`
}
type Input struct {
	Repository  string `json:"repository"`
	RunID       int64  `json:"run_id"`
	Attempt     int    `json:"attempt"`
	HeadSHA     string `json:"head_sha"`
	CheckoutSHA string `json:"checkout_sha"`
	Run         Run    `json:"run"`
	Pages       []Page `json:"pages"`
}
type StepObservation struct {
	Step
	ElapsedMilliseconds *int64 `json:"elapsed_ms"`
}
type JobObservation struct {
	Job
	PendingMilliseconds *int64            `json:"pending_ms"`
	ElapsedMilliseconds *int64            `json:"elapsed_ms"`
	Steps               []StepObservation `json:"steps"`
}
type Output struct {
	Repository       string           `json:"repository"`
	RunID            int64            `json:"run_id"`
	Attempt          int              `json:"attempt"`
	HeadSHA          string           `json:"api_head_sha"`
	CheckoutSHA      string           `json:"caller_checkout_sha,omitempty"`
	CheckoutEvidence string           `json:"checkout_evidence"`
	Origin           string           `json:"origin"`
	Jobs             []JobObservation `json:"jobs"`
}

var shaPattern = regexp.MustCompile(`^[a-f0-9]{40}$`)
var repoPattern = regexp.MustCompile(`^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`)

func timestamp(s *string) (*time.Time, error) {
	if s == nil {
		return nil, nil
	}
	if !strings.HasSuffix(*s, "Z") {
		return nil, fmt.Errorf("timestamp must be UTC Z")
	}
	v, err := time.Parse(time.RFC3339Nano, *s)
	if err != nil {
		return nil, err
	}
	return &v, nil
}
func interval(start, end *time.Time, enabled bool) (*int64, error) {
	if !enabled || start == nil || end == nil {
		return nil, nil
	}
	if end.Before(*start) {
		return nil, fmt.Errorf("timestamp order invalid")
	}
	delta := end.Sub(*start)
	if !start.Add(delta).Equal(*end) {
		return nil, fmt.Errorf("timestamp interval exceeds duration range")
	}
	n := delta.Milliseconds()
	return &n, nil
}
func Analyze(in Input) (Output, error) {
	if !repoPattern.MatchString(in.Repository) || in.RunID < 1 || in.Attempt < 1 || !shaPattern.MatchString(in.HeadSHA) || in.CheckoutSHA != "" && !shaPattern.MatchString(in.CheckoutSHA) {
		return Output{}, fmt.Errorf("invalid expected identity")
	}
	if in.Run.ID != in.RunID || in.Run.RunAttempt != in.Attempt || in.Run.HeadSHA != in.HeadSHA || in.Run.Repository.FullName != in.Repository {
		return Output{}, fmt.Errorf("run identity mismatch")
	}
	if len(in.Pages) == 0 {
		return Output{}, fmt.Errorf("missing pages")
	}
	out := Output{Repository: in.Repository, RunID: in.RunID, Attempt: in.Attempt, HeadSHA: in.HeadSHA, CheckoutSHA: in.CheckoutSHA, CheckoutEvidence: "unverified", Origin: "caller_supplied_unverified", Jobs: []JobObservation{}}
	total := in.Pages[0].TotalCount
	per := in.Pages[0].PerPage
	if total < 0 || per < 1 || per > 100 {
		return Output{}, fmt.Errorf("invalid page size")
	}
	expectedPages := total / per
	if total%per != 0 {
		expectedPages++
	}
	if expectedPages == 0 {
		expectedPages = 1
	}
	if len(in.Pages) != expectedPages {
		return Output{}, fmt.Errorf("incomplete or extra job pages")
	}
	seen := map[int64]bool{}
	for i, page := range in.Pages {
		if page.PageNumber != i+1 || page.PerPage != per || page.TotalCount != total || len(page.Jobs) > per || i < len(in.Pages)-1 && len(page.Jobs) != per {
			return Output{}, fmt.Errorf("invalid page sequence")
		}
		for _, j := range page.Jobs {
			if j.ID < 1 || seen[j.ID] || j.RunID != in.RunID || j.RunAttempt != in.Attempt || (j.HeadSHA != nil && *j.HeadSHA != in.HeadSHA) || j.Name == "" || j.Status == "" {
				return Output{}, fmt.Errorf("invalid job identity")
			}
			seen[j.ID] = true
			created, e := timestamp(j.CreatedAt)
			if e != nil {
				return Output{}, e
			}
			start, e := timestamp(j.StartedAt)
			if e != nil {
				return Output{}, e
			}
			end, e := timestamp(j.CompletedAt)
			if e != nil {
				return Output{}, e
			}
			executed := j.Status == "completed" && j.Conclusion != "skipped" && j.Conclusion != ""
			if _, e := interval(created, end, j.Conclusion != "skipped"); e != nil {
				return Output{}, e
			}
			pending, e := interval(created, start, j.Conclusion != "skipped")
			if e != nil {
				return Output{}, e
			}
			elapsed, e := interval(start, end, j.Conclusion != "skipped")
			if e != nil {
				return Output{}, e
			}
			if !executed {
				elapsed = nil
			}
			obs := JobObservation{Job: j, PendingMilliseconds: pending, ElapsedMilliseconds: elapsed, Steps: []StepObservation{}}
			steps := map[int]bool{}
			for _, s := range j.Steps {
				if s.Number < 1 || steps[s.Number] || s.Name == "" || s.Status == "" {
					return Output{}, fmt.Errorf("invalid step identity")
				}
				steps[s.Number] = true
				ss, e := timestamp(s.StartedAt)
				if e != nil {
					return Output{}, e
				}
				se, e := timestamp(s.CompletedAt)
				if e != nil {
					return Output{}, e
				}
				if (j.Status == "completed" || j.Status == "in_progress") && j.Conclusion != "skipped" && (s.Status == "completed" || s.Status == "in_progress") && s.Conclusion != "skipped" {
					for _, point := range []*time.Time{ss, se} {
						if point != nil && (start != nil && point.Before(*start) || end != nil && point.After(*end)) {
							return Output{}, fmt.Errorf("step timestamp outside job bounds")
						}
					}
				}
				duration, e := interval(ss, se, j.Conclusion != "skipped" && s.Conclusion != "skipped")
				if e != nil {
					return Output{}, e
				}
				if s.Status != "completed" || s.Conclusion == "" {
					duration = nil
				}
				obs.Steps = append(obs.Steps, StepObservation{Step: s, ElapsedMilliseconds: duration})
			}
			out.Jobs = append(out.Jobs, obs)
		}
	}
	if len(seen) != total {
		return Output{}, fmt.Errorf("incomplete job pages")
	}
	return out, nil
}
