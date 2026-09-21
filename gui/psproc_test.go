package main

import (
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"
)

// run() must hand every rule id to QdfCli.ps1. The original bug passed them as
// separate arguments ("-RuleIds a b c"), which PowerShell's -File binding does
// not collect into an array: the surplus ids spilled onto the script's
// positional parameters and killed it before the script body ever ran.
//
// A real id sits last on purpose. Unknown ids alone cannot tell "all ids
// arrived" from "only the first id arrived" — both produce no progress lines at
// all — which left the first version of this test unable to catch a regression
// that silently cleaned one rule instead of four.
func TestRunPassesAllRuleIds(t *testing.T) {
	root, err := filepath.Abs("..")
	if err != nil {
		t.Fatal(err)
	}

	const real = "shell-recent"
	ids := []string{"nope-1", "nope-2", "nope-3", real}

	var lines []string
	r := newRunner(root)
	err = r.run("scan", ids, false, func(line []byte) {
		lines = append(lines, string(line))
	})
	if err != nil {
		t.Fatalf("run() failed: %v", err)
	}
	if len(lines) == 0 {
		t.Fatal("run() produced no NDJSON on stdout")
	}

	var sawReal bool
	for _, line := range lines {
		var ev struct {
			Type   string `json:"type"`
			RuleID string `json:"ruleId"`
		}
		if json.Unmarshal([]byte(line), &ev) == nil && ev.Type == "progress" && ev.RuleID == real {
			sawReal = true
		}
	}
	if !sawReal {
		t.Fatalf("QdfCli.ps1 reported no progress for %q, so the ids after the first never arrived\nlines: %v", real, lines)
	}

	last := lines[len(lines)-1]
	if !strings.Contains(last, `"type":"result"`) {
		t.Fatalf("last line is not a result: %s", last)
	}
}

// A comma inside an id would unfold into two ids that match no rule, and the
// cleaner would report success having done nothing.
func TestRunRejectsCommaInRuleId(t *testing.T) {
	root, err := filepath.Abs("..")
	if err != nil {
		t.Fatal(err)
	}

	r := newRunner(root)
	err = r.run("scan", []string{"chrome-cache,user-temp"}, false, func([]byte) {})
	if err == nil {
		t.Fatal("run() accepted a rule id containing a comma")
	}
	if !strings.Contains(err.Error(), "逗号") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestDecodeConsoleOutput(t *testing.T) {
	// "清道夫" in GBK — what PowerShell emits for errors raised before
	// QdfCli.ps1 switches the console to UTF-8.
	gbk := []byte{0xC7, 0xE5, 0xB5, 0xC0, 0xB7, 0xF2}
	if got := decodeConsoleOutput(gbk); got != "清道夫" {
		t.Errorf("GBK decode = %q, want %q", got, "清道夫")
	}

	utf8Text := []byte("清道夫")
	if got := decodeConsoleOutput(utf8Text); got != "清道夫" {
		t.Errorf("UTF-8 passthrough = %q, want %q", got, "清道夫")
	}
}
