package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
)

func TestReservationIsAtomic(t *testing.T) {
	r := newRunner(".")
	var winners int32
	var group sync.WaitGroup
	for i := 0; i < 30; i++ {
		group.Add(1)
		go func() {
			defer group.Done()
			if r.reserve("scan") == nil {
				atomic.AddInt32(&winners, 1)
			}
		}()
	}
	group.Wait()
	defer r.release()
	if winners != 1 {
		t.Fatalf("reservations: %d", winners)
	}
	if err := r.stop(); err != nil {
		t.Fatal(err)
	}
	if !r.stopped {
		t.Fatal("pre-start cancellation lost")
	}
}
func TestCleanCancellationIsCooperative(t *testing.T) {
	r := newRunner(".")
	if err := r.reserve("clean"); err != nil {
		t.Fatal(err)
	}
	defer r.release()
	if err := r.stop(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(r.cancelDir, "cancel")); err != nil {
		t.Fatal(err)
	}
}
func TestChunkedResultExceedsOldLimit(t *testing.T) {
	payload := []byte("{\"type\":\"result\",\"data\":\"" + strings.Repeat("x", 17*1024*1024) + "\"}")
	var input bytes.Buffer
	for offset := 0; offset < len(payload); offset += 24576 {
		end := offset + 24576
		if end > len(payload) {
			end = len(payload)
		}
		fmt.Fprintf(&input, "{\"type\":\"result-chunk\",\"data\":\"%s\"}\n", base64.StdEncoding.EncodeToString(payload[offset:end]))
	}
	input.WriteString("{\"type\":\"result-end\"}\n")
	var got []byte
	if err := readProtocol(&input, func(line []byte) { got = append([]byte(nil), line...) }); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(payload, got) {
		t.Fatal("result mismatch")
	}
}
func TestProtocolRejectsMalformedAndTruncatedResults(t *testing.T) {
	for _, input := range []string{
		"not-json\n",
		"{\"type\":\"result-chunk\",\"data\":\"e30=\"}\n",
		"{\"type\":\"result-end\"}\n",
		strings.Repeat("x", 1024*1024+1),
	} {
		if err := readProtocol(strings.NewReader(input), func([]byte) {}); err == nil {
			t.Fatal("accepted broken protocol")
		}
	}
}
func TestReceiptBOMAndInterruptedRecovery(t *testing.T) {
	t.Setenv("LOCALAPPDATA", t.TempDir())
	dir := filepath.Join(dataRoot(), "receipts")
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(dir, "receipt-test.json")
	receipt := map[string]interface{}{"Summary": map[string]interface{}{"State": "Incomplete", "StartedAt": "2026-09-22T00:00:00Z"}}
	raw, err := json.Marshal(receipt)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(file, append([]byte{0xef, 0xbb, 0xbf}, raw...), 0600); err != nil {
		t.Fatal(err)
	}
	journal := "{\"Type\":\"planned\",\"Path\":\"one\"}\n{\"Type\":\"outcome\",\"Path\":\"one\",\"Status\":\"Deleted\",\"Size\":1024}\n{\"Type\":\"planned\",\"Path\":\"two\"}\n{\"Type\":"
	if err := os.WriteFile(file+".jsonl", []byte(journal), 0600); err != nil {
		t.Fatal(err)
	}
	app := NewApp()
	got, err := app.GetReceipt(file)
	if err != nil {
		t.Fatal(err)
	}
	summary := got["Summary"].(map[string]interface{})
	if summary["SuccessfulCount"] != 1 || summary["UnknownCount"] != 1 {
		t.Fatalf("bad recovery: %v", summary)
	}
	history, err := app.GetHistory(50)
	if err != nil || len(history) != 1 {
		t.Fatalf("missing incomplete history: %v %v", history, err)
	}
	if _, err := app.GetReceipt(filepath.Join(dataRoot(), "receipts-other", "evil.json")); err == nil {
		t.Fatal("accepted sibling")
	}
}

func TestRunnerConsumesChunkedPowerShellAndReleasesAfterFailure(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, "app", "modules")
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	script := "param([string]$Command,[string]$CancelPath)\n[Console]::Out.WriteLine('{\"type\":\"result-chunk\",\"data\":\"eyJ0eXBlIjoicmVzdWx0In0=\"}')\n[Console]::Out.WriteLine('{\"type\":\"result-end\"}')\n"
	file := filepath.Join(dir, "QdfCli.ps1")
	if err := os.WriteFile(file, []byte(script), 0600); err != nil {
		t.Fatal(err)
	}
	r := newRunner(root)
	var result []byte
	if err := r.run("scan", nil, false, func(line []byte) { result = append([]byte(nil), line...) }); err != nil {
		t.Fatal(err)
	}
	if string(result) != "{\"type\":\"result\"}" || r.busy() {
		t.Fatalf("result=%s busy=%v", result, r.busy())
	}
	if err := os.WriteFile(file, []byte("param([string]$Command,[string]$CancelPath)\nexit 2\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := r.run("scan", nil, false, func([]byte) {}); err == nil {
		t.Fatal("nonzero exit swallowed")
	}
	if r.busy() {
		t.Fatal("failed task retained reservation")
	}
}
