package main

import (
	"path/filepath"
	"strings"
	"testing"
)

// run() must hand every rule id to QdfCli.ps1. The original bug passed them as
// separate arguments ("-RuleIds a b c"), which PowerShell's -File binding does
// not collect into an array: the surplus ids spilled onto the script's
// positional parameters and killed it before the script body ever ran. Four
// ids is the smallest count that triggered it.
func TestRunPassesAllRuleIds(t *testing.T) {
	root, err := filepath.Abs("..")
	if err != nil {
		t.Fatal(err)
	}

	var lines []string
	r := newRunner(root)
	err = r.run("scan", []string{"nope-1", "nope-2", "nope-3", "nope-4"}, false, func(line []byte) {
		lines = append(lines, string(line))
	})
	if err != nil {
		t.Fatalf("run() failed: %v", err)
	}
	if len(lines) == 0 {
		t.Fatal("run() produced no NDJSON on stdout")
	}

	last := lines[len(lines)-1]
	if !strings.Contains(last, `"type":"result"`) {
		t.Fatalf("last line is not a result: %s", last)
	}
	// Unknown ids must not silently match anything.
	if strings.Contains(last, "nope-") {
		t.Fatalf("unknown rule ids leaked into the result: %s", last)
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
