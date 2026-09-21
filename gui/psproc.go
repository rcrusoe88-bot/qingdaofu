package main

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode/utf8"

	"golang.org/x/text/encoding/simplifiedchinese"
)

var errKilled = errors.New("process killed by user")

// runner manages at most one PowerShell subprocess at a time.
type runner struct {
	root string

	mu      sync.Mutex
	cmd     *exec.Cmd
	killed  bool
	waitErr error
}

func newRunner(root string) *runner { return &runner{root: root} }

func (r *runner) busy() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.cmd != nil && r.cmd.ProcessState == nil
}

func (r *runner) wasKilled() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.killed
}

// kill terminates the current subprocess. Safe to call anytime.
func (r *runner) kill() {
	r.mu.Lock()
	cmd, killed := r.cmd, r.killed
	r.mu.Unlock()
	if cmd != nil && cmd.Process != nil && !killed {
		r.mu.Lock()
		r.killed = true
		r.mu.Unlock()
		_ = cmd.Process.Kill()
	}
}

// run spawns powershell.exe -File QdfCli.ps1 ... and feeds every NDJSON
// stdout line to onLine. Returns after the process exits: nil on exit
// code 0, errKilled if killed, or a descriptive error otherwise.
func (r *runner) run(command string, ruleIds []string, dryRun bool, onLine func([]byte)) error {
	cliPath, err := (func() (string, error) {
		p := filepath.Join(r.root, "app", "modules", "QdfCli.ps1")
		if st, statErr := os.Stat(p); statErr != nil || st.IsDir() {
			return "", fmt.Errorf("未找到核心组件 app\\modules\\QdfCli.ps1")
		}
		return p, nil
	}())
	if err != nil {
		return err
	}

	args := []string{
		"-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
		"-File", cliPath,
		"-Command", command,
	}
	if len(ruleIds) > 0 {
		// PowerShell's -File binding does not split arrays: "-RuleIds a b c"
		// binds only "a" and spills b/c onto the script's positional
		// parameters, which aborts the script before it runs. Pass one
		// comma-joined argument; QdfCli.ps1 unfolds it again. An id holding a
		// comma would unfold into two ids that match no rule, leaving the
		// cleaner reporting success for zero work — reject it up front.
		for _, id := range ruleIds {
			if strings.Contains(id, ",") {
				return fmt.Errorf("规则 id 不能包含逗号：%q", id)
			}
		}
		args = append(args, "-RuleIds", strings.Join(ruleIds, ","))
	}
	if dryRun {
		args = append(args, "-DryRun")
	}

	cmd := exec.Command("powershell.exe", args...)
	cmd.Dir = r.root
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	var stderrBuf bytes.Buffer
	cmd.Stderr = &stderrBuf

	r.mu.Lock()
	r.killed = false
	r.waitErr = nil
	r.cmd = cmd
	r.mu.Unlock()

	start := time.Now()
	if err := cmd.Start(); err != nil {
		r.clear(cmd)
		return fmt.Errorf("无法启动 PowerShell: %w", err)
	}

	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 0, 64*1024), 16*1024*1024)
	for scanner.Scan() {
		line := bytes.TrimSpace(scanner.Bytes())
		if len(line) > 0 {
			onLine(line)
		}
	}

	waitErr := cmd.Wait()
	elapsed := time.Since(start)
	r.clear(cmd)

	r.mu.Lock()
	killed := r.killed
	r.mu.Unlock()
	if killed {
		return errKilled
	}
	if waitErr != nil {
		detail := strings.TrimSpace(decodeConsoleOutput(stderrBuf.Bytes()))
		if r := []rune(detail); len(r) > 400 {
			detail = string(r[:400])
		}
		return fmt.Errorf("核心组件退出异常（%v）%s", waitErr, detailSuffix(detail))
	}
	_ = elapsed
	return nil
}

func (r *runner) clear(cmd *exec.Cmd) {
	r.mu.Lock()
	if r.cmd == cmd {
		r.cmd = nil
	}
	r.mu.Unlock()
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
