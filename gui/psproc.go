package main

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"unicode/utf8"

	"golang.org/x/text/encoding/simplifiedchinese"
)

var errKilled = errors.New("process cancelled by user")

type runner struct {
	root      string
	mu        sync.Mutex
	cmd       *exec.Cmd
	active    bool
	stopped   bool
	command   string
	cancelDir string
}

func newRunner(root string) *runner { return &runner{root: root} }
func (r *runner) busy() bool        { r.mu.Lock(); defer r.mu.Unlock(); return r.active }
func (r *runner) reserve(command string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.active {
		return fmt.Errorf("已有任务正在运行，请稍候")
	}
	dir, err := os.MkdirTemp("", "qingdaofu-cancel-")
	if err != nil {
		return err
	}
	r.active, r.stopped, r.command, r.cancelDir = true, false, command, dir
	return nil
}

// Clean cancellation is cooperative; scans may be terminated because they never delete.
func (r *runner) stop() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if !r.active {
		return nil
	}
	r.stopped = true
	if r.command == "clean" {
		return os.WriteFile(filepath.Join(r.cancelDir, "cancel"), []byte("stop"), 0600)
	}
	if r.cmd != nil && r.cmd.Process != nil {
		return r.cmd.Process.Kill()
	}
	return nil
}
func (r *runner) release() {
	r.mu.Lock()
	defer r.mu.Unlock()
	// Only remove the exact marker in the uniquely owned directory; never recurse.
	if r.cancelDir != "" {
		if err := os.Remove(filepath.Join(r.cancelDir, "cancel")); err != nil && !os.IsNotExist(err) {
			log.Printf("Cancellation marker cleanup: %v", err)
		}
		if err := os.Remove(r.cancelDir); err != nil {
			log.Printf("Cancellation directory retained: %v", err)
		}
	}
	r.active, r.cmd, r.cancelDir = false, nil, ""
}
func (r *runner) run(command string, ids []string, dryRun bool, onLine func([]byte)) error {
	if err := r.reserve(command); err != nil {
		return err
	}
	return r.runReserved(command, ids, dryRun, onLine)
}
func (r *runner) runReserved(command string, ids []string, dryRun bool, onLine func([]byte)) error {
	defer r.release()
	cli := filepath.Join(r.root, "app", "modules", "QdfCli.ps1")
	if st, err := os.Stat(cli); err != nil || st.IsDir() {
		return fmt.Errorf("未找到核心组件 app\\modules\\QdfCli.ps1")
	}
	args := []string{"-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", cli, "-Command", command}
	for _, id := range ids {
		if strings.Contains(id, ",") {
			return fmt.Errorf("规则 id 不能包含逗号：%q", id)
		}
	}
	if len(ids) > 0 {
		args = append(args, "-RuleIds", strings.Join(ids, ","))
	}
	if dryRun {
		args = append(args, "-DryRun")
	}
	r.mu.Lock()
	if r.stopped && command != "clean" {
		r.mu.Unlock()
		return errKilled
	}
	args = append(args, "-CancelPath", filepath.Join(r.cancelDir, "cancel"))
	cmd := exec.Command("powershell.exe", args...)
	cmd.Dir = r.root
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		r.mu.Unlock()
		return err
	}
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	r.cmd = cmd
	err = cmd.Start()
	r.mu.Unlock()
	if err != nil {
		return fmt.Errorf("无法启动 PowerShell: %w", err)
	}
	readErr := readProtocol(stdout, onLine)
	if readErr != nil {
		// Stop a producer blocked on stdout before waiting. Its write-ahead journal survives.
		if err := cmd.Process.Kill(); err != nil && !errors.Is(err, os.ErrProcessDone) {
			log.Printf("Core termination after read failure: %v", err)
		}
	}
	waitErr := cmd.Wait()
	r.mu.Lock()
	stopped := r.stopped
	r.mu.Unlock()
	if stopped && command != "clean" {
		return errKilled
	}
	if readErr != nil {
		return readErr
	}
	if waitErr != nil {
		detail := strings.TrimSpace(decodeConsoleOutput(stderr.Bytes()))
		if v := []rune(detail); len(v) > 400 {
			detail = string(v[:400])
		}
		return fmt.Errorf("核心组件退出异常（%v）%s", waitErr, detailSuffix(detail))
	}
	return nil
}

// Result frames bound each pipe line; malformed/truncated transport is never success.
func readProtocol(input io.Reader, onLine func([]byte)) error {
	scanner := bufio.NewScanner(input)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	var payload bytes.Buffer
	chunking := false
	for scanner.Scan() {
		line := bytes.TrimSpace(scanner.Bytes())
		if len(line) == 0 {
			continue
		}
		var frame struct {
			Type string `json:"type"`
			Data string `json:"data"`
		}
		if err := json.Unmarshal(line, &frame); err != nil {
			return fmt.Errorf("Invalid core protocol: %w", err)
		}
		switch frame.Type {
		case "result-chunk":
			chunking = true
			part, err := base64.StdEncoding.DecodeString(frame.Data)
			if err != nil {
				return err
			}
			if payload.Len()+len(part) > 256*1024*1024 {
				return fmt.Errorf("Result exceeds 256 MiB safety limit")
			}
			payload.Write(part)
		case "result-end":
			if !chunking || !json.Valid(payload.Bytes()) {
				return fmt.Errorf("Incomplete result payload")
			}
			onLine(payload.Bytes())
			payload.Reset()
			chunking = false
		default:
			if chunking {
				return fmt.Errorf("Interrupted result payload")
			}
			onLine(line)
		}
	}
	if err := scanner.Err(); err != nil {
		return fmt.Errorf("Core output read failed: %w", err)
	}
	if chunking {
		return fmt.Errorf("Truncated result payload")
	}
	return nil
}

func detailSuffix(detail string) string {
	if detail == "" {
		return ""
	}
	return "：" + detail
}

// decodeConsoleOutput recovers text from PowerShell's stderr. QdfCli.ps1
// switches the console to UTF-8, but anything PowerShell itself reports
// before the script body runs — a parameter binding failure, say — is still
// written in the system OEM code page (GBK on zh-CN), which would reach the
// UI as mojibake. UTF-8 is tried first because GBK bytes are rarely valid
// UTF-8.
func decodeConsoleOutput(raw []byte) string {
	if utf8.Valid(raw) {
		return string(raw)
	}
	if decoded, err := simplifiedchinese.GBK.NewDecoder().Bytes(raw); err == nil {
		return string(decoded)
	}
	return string(raw)
}
