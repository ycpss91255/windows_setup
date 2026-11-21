package actions_timing

import "testing"

func TestIssue285JobStepBounds(t *testing.T) {
	for _, tc := range []struct {
		name      string
		change    func(*Job, *Step)
		wantError bool
	}{
		{"start_before", func(j *Job, s *Step) { s.StartedAt = ptr("2026-11-14T00:00:01Z") }, true},
		{"start_after", func(j *Job, s *Step) { s.StartedAt = ptr("2026-11-14T00:00:09Z"); s.CompletedAt = nil }, true},
		{"end_before", func(j *Job, s *Step) { s.StartedAt = nil; s.CompletedAt = ptr("2026-11-14T00:00:01Z") }, true},
		{"end_after", func(j *Job, s *Step) { s.CompletedAt = ptr("2026-11-14T00:00:09Z") }, true},
		{"equal_bounds", func(j *Job, s *Step) { s.StartedAt = j.StartedAt; s.CompletedAt = j.CompletedAt }, false},
		{"unknown_job_start", func(j *Job, s *Step) { j.StartedAt = nil; s.StartedAt = ptr("2026-11-14T00:00:01Z") }, false},
		{"unknown_job_end", func(j *Job, s *Step) { j.CompletedAt = nil; s.CompletedAt = ptr("2026-11-14T00:00:09Z") }, false},
		{"unknown_step_times", func(j *Job, s *Step) { s.StartedAt = nil; s.CompletedAt = nil }, false},
		{"skipped_step", func(j *Job, s *Step) {
			s.Conclusion = "skipped"
			s.StartedAt = ptr("2026-11-14T00:00:09Z")
			s.CompletedAt = ptr("2026-11-14T00:00:01Z")
		}, false},
		{"skipped_job", func(j *Job, s *Step) {
			j.Conclusion = "skipped"
			s.StartedAt = ptr("2026-11-14T00:00:09Z")
			s.CompletedAt = ptr("2026-11-14T00:00:01Z")
		}, false},
		{"queued_step_placeholder", func(j *Job, s *Step) {
			s.Status = "queued"
			s.Conclusion = ""
			s.StartedAt = ptr("0001-01-01T00:00:00Z")
			s.CompletedAt = ptr("0001-01-01T00:00:00Z")
		}, false},
		{"skipped_placeholder", func(j *Job, s *Step) {
			s.Conclusion = "skipped"
			s.StartedAt = ptr("0001-01-01T00:00:00Z")
			s.CompletedAt = ptr("0001-01-01T00:00:00Z")
		}, false},
		{"queued_job_placeholder", func(j *Job, s *Step) {
			j.Status = "queued"
			j.Conclusion = ""
			s.StartedAt = ptr("0001-01-01T00:00:00Z")
			s.CompletedAt = ptr("0001-01-01T00:00:00Z")
		}, false},
		{"unknown_status_unchanged", func(j *Job, s *Step) {
			s.Status = "unknown"
			s.StartedAt = ptr("2026-11-14T00:00:01Z")
		}, false},
		{"running_outside_known_start", func(j *Job, s *Step) {
			j.Status = "in_progress"
			j.Conclusion = ""
			j.CompletedAt = nil
			s.Status = "in_progress"
			s.Conclusion = ""
			s.StartedAt = ptr("2026-11-14T00:00:01Z")
			s.CompletedAt = nil
		}, true},
		{"running_inside", func(j *Job, s *Step) {
			j.Status = "in_progress"
			j.Conclusion = ""
			j.CompletedAt = nil
			s.Status = "in_progress"
			s.Conclusion = ""
			s.CompletedAt = nil
		}, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			x := fixture()
			j := &x.Pages[0].Jobs[0]
			tc.change(j, &j.Steps[0])
			out, err := Analyze(x)
			if (err != nil) != tc.wantError {
				t.Fatalf("want error=%v, got %v", tc.wantError, err)
			}
			if err == nil && (tc.name == "queued_step_placeholder" || tc.name == "skipped_placeholder") && out.Jobs[0].Steps[0].ElapsedMilliseconds != nil {
				t.Fatal("unexecuted step acquired a duration")
			}
		})
	}
}
