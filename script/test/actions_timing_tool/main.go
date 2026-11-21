// actions_timing_tool reads offline caller-supplied API observations.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	at "windows_setup/script/test/actions_timing"
)

func run(args []string, out io.Writer) error {
	f := flag.NewFlagSet("actions_timing_tool", flag.ContinueOnError)
	f.SetOutput(io.Discard)
	path := f.String("input", "", "offline JSON")
	repo := f.String("repository", "", "expected repository")
	runID := f.Int64("run-id", 0, "expected run")
	attempt := f.Int("attempt", 0, "expected attempt")
	head := f.String("head-sha", "", "expected API head")
	checkout := f.String("checkout-sha", "", "optional unverified checkout context")
	if err := f.Parse(args); err != nil {
		return err
	}
	if f.NArg() != 0 || *path == "" {
		return fmt.Errorf("input and independent identity required")
	}
	file, err := os.Open(*path)
	if err != nil {
		return err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() > 16*1024*1024 {
		return fmt.Errorf("input must be a bounded regular file")
	}
	data, err := io.ReadAll(io.LimitReader(file, 16*1024*1024+1))
	if err != nil {
		return err
	}
	if len(data) > 16*1024*1024 {
		return fmt.Errorf("input too large")
	}
	result, err := at.Decode(data, at.Expected{Repository: *repo, RunID: *runID, Attempt: *attempt, HeadSHA: *head, CheckoutSHA: *checkout})
	if err != nil {
		return err
	}
	return json.NewEncoder(out).Encode(result)
}
func main() {
	if err := run(os.Args[1:], os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "actions timing:", err)
		os.Exit(1)
	}
}
