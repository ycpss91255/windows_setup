package main

import (
	"errors"
	"flag"
	"io"
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

func validateMainPairCommand(args []string) error {
	var nativeDir, containerDir, sha, runURL string
	f := flag.NewFlagSet("validate-main-pair", flag.ContinueOnError)
	f.SetOutput(io.Discard)
	f.StringVar(&nativeDir, "native-dir", "", "")
	f.StringVar(&containerDir, "container-dir", "", "")
	f.StringVar(&sha, "commit", "", "")
	f.StringVar(&runURL, "run-url", "", "")
	if err := f.Parse(args); err != nil {
		return err
	}
	if f.NArg() != 0 || nativeDir == "" || containerDir == "" || sha == "" || runURL == "" {
		return errors.New("missing pair context")
	}
	native, err := loadReport(nativeDir, nativeRuntimeNames)
	if err != nil {
		return err
	}
	container, err := loadReport(containerDir, containerNames)
	if err != nil {
		return err
	}
	return validateMainPairData(native, container, sha, runURL)
}
