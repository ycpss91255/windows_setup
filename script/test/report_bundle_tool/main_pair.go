package main

import (
	"errors"
	"strings"
	a "windows_setup/script/test/acceptance"
)

func validateMainPairData(native, container map[string][]byte, sha, run string) error {
	for i, m := range []map[string][]byte{native, container} {
		if err := validatePublicDocuments(m); err != nil {
			return err
		}
		r, err := a.ValidateReport(reportReader(m), sha, run, true)
		if err != nil {
			return err
		}
		if !r.Success || r.Totals.UnexecutedSuites != 0 {
			return errors.New("main report is incomplete or failed")
		}
		isContainer := strings.HasPrefix(r.Environment, "Windows container / Windows ")
		if !strings.HasPrefix(r.Environment, "Windows ") || (i == 1) != isContainer {
			return errors.New("main report environment mismatch")
		}
		if i == 1 && (r.Coverage != "NotMeasured" || r.RepoCoverage != nil) {
			return errors.New("container coverage must remain unmeasured")
		}
	}
	return nil
}
