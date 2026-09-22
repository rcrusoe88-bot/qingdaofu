package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"syscall"
)

// Lexical containment is checked by the caller; reject reparse points in every ancestor.
func checkReceiptPath(file, root string) error {
	for current := file; ; current = filepath.Dir(current) {
		p, err := syscall.UTF16PtrFromString(current)
		if err != nil {
			return err
		}
		attributes, err := syscall.GetFileAttributes(p)
		if err != nil {
			return err
		}
		if attributes&syscall.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
			return fmt.Errorf("回执路径不能包含重解析点")
		}
		if filepath.Dir(current) == current {
			break
		}
	}
	return nil
}

// Reconstruct a crashed operation from durable outcomes, never from intentions.
func recoverJournal(file string, receipt map[string]interface{}) error {
	summary, ok := receipt["Summary"].(map[string]interface{})
	if !ok || (summary["State"] != "Incomplete" && summary["JournalIncomplete"] != true) {
		return nil
	}
	journal := file + ".jsonl"
	if _, err := os.Stat(journal); os.IsNotExist(err) {
		return nil
	} else if err != nil {
		return err
	}
	if err := checkReceiptPath(journal, filepath.Dir(file)); err != nil {
		return err
	}
	stream, err := os.Open(journal)
	if err != nil {
		return err
	}
	defer stream.Close()
	reader := bufio.NewReader(stream)
	items := []map[string]interface{}{}
	var pending map[string]interface{}
	var successful, failed, unknown, count int
	var freed, recycled float64
	appendItem := func(item map[string]interface{}) {
		count++
		if len(items) < 2000 {
			items = append(items, item)
		}
	}
	for {
		line, readErr := reader.ReadBytes('\n')
		if readErr != nil && readErr != io.EOF {
			return readErr
		}
		// Only a trailing partial record may be ignored after abrupt termination.
		if readErr == io.EOF {
			break
		}
		var event map[string]interface{}
		if err := json.Unmarshal(line, &event); err != nil {
			return fmt.Errorf("损坏的操作日志: %w", err)
		}
		switch event["Type"] {
		case "planned":
			if pending != nil {
				pending["Status"] = "Unknown"
				unknown++
				appendItem(pending)
			}
			pending = event
		case "outcome":
			if pending == nil || pending["Path"] != event["Path"] {
				return fmt.Errorf("操作日志顺序不一致")
			}
			pending = nil
			size, _ := event["Size"].(float64)
			switch event["Status"] {
			case "Deleted":
				successful++
				freed += size
			case "Recycled":
				successful++
				recycled += size
			case "DryRun":
				successful++
			default:
				failed++
			}
			appendItem(event)
		}
	}
	if pending != nil {
		pending["Status"] = "Unknown"
		unknown++
		appendItem(pending)
	}
	summary["SuccessfulCount"], summary["ProcessedCount"], summary["FailedCount"] = successful, successful, failed
	summary["UnknownCount"], summary["BytesFreed"], summary["BytesRecycled"] = unknown, freed, recycled
	summary["BytesFreedText"], summary["BytesRecycledText"] = fmt.Sprintf("%.1f MB", freed/(1024*1024)), fmt.Sprintf("%.1f MB", recycled/(1024*1024))
	receipt["Items"], receipt["ReceiptTruncated"] = items, count > len(items)
	return nil
}
