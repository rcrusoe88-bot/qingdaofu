package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/wailsapp/wails/v2/pkg/runtime"
)

// psEvent mirrors the NDJSON progress/error lines emitted by
// app/modules/QdfCli.ps1. Result lines are kept raw (map).
type psEvent struct {
	Type     string `json:"type"`
	Phase    string `json:"phase"`
	RuleID   string `json:"ruleId"`
	RuleName string `json:"ruleName"`
	Index    int    `json:"index"`
	Total    int    `json:"total"`
	Message  string `json:"message"`
}

type App struct {
	ctx  context.Context
	root string // portable root: directory containing app/ and rules/
	ps   *runner

	mu sync.Mutex // serializes Scan/Clean launches
}

func NewApp() *App { return &App{} }

func (a *App) startup(ctx context.Context) {
	a.ctx = ctx
	a.root = findRoot()
	a.ps = newRunner(a.root)
}

func (a *App) shutdown(ctx context.Context) {
	a.ps.kill()
}

// findRoot locates the directory containing app/ and rules/.
// Packaged: the exe sits at the portable root. Dev: set QDF_GUI_ROOT.
func findRoot() string {
	if v := os.Getenv("QDF_GUI_ROOT"); v != "" {
		return v
	}
	if exe, err := os.Executable(); err == nil {
		return filepath.Dir(exe)
	}
	return "."
}

func (a *App) cliPath() (string, error) {
	p := filepath.Join(a.root, "app", "modules", "QdfCli.ps1")
	if st, err := os.Stat(p); err != nil || st.IsDir() {
		return "", fmt.Errorf("未找到核心组件 app\\modules\\QdfCli.ps1（安装目录: %s）", a.root)
	}
	return p, nil
}

// Scan runs the rule scan in the background. Progress and the final
// result are streamed to the frontend via events scan:progress /
// scan:done / app:error.
func (a *App) Scan(ruleIds []string) error {
	if err := a.launch(); err != nil {
		return err
	}
	go a.runStream("scan", ruleIds, false)
	return nil
}

// Clean executes the selected rules. The delete-vs-recycle choice
// lives in rules.json; the GUI never passes an action. Streams
// clean:progress / clean:done / app:error.
func (a *App) Clean(ruleIds []string) error {
	if err := a.launch(); err != nil {
		return err
	}
	go a.runStream("clean", ruleIds, false)
	return nil
}

func (a *App) launch() error {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.ps.busy() {
		return fmt.Errorf("已有任务正在运行，请稍候")
	}
	if _, err := a.cliPath(); err != nil {
		return err
	}
	return nil
}

// runStream spawns QdfCli.ps1, parses NDJSON lines and emits Wails events.
func (a *App) runStream(command string, ruleIds []string, dryRun bool) {
	prefix := command + ":"
	err := a.ps.run(command, ruleIds, dryRun, func(line []byte) {
		var ev psEvent
		if json.Unmarshal(line, &ev) != nil {
			return
		}
		switch ev.Type {
		case "progress":
			runtime.EventsEmit(a.ctx, prefix+"progress", ev)
		case "result":
			var raw map[string]interface{}
			if json.Unmarshal(line, &raw) == nil {
				runtime.EventsEmit(a.ctx, prefix+"done", raw)
			}
		case "error":
			runtime.EventsEmit(a.ctx, "app:error", map[string]string{"message": ev.Message})
		}
	})
	if err != nil && !a.ps.wasKilled() {
		log.Printf("%s failed: %v", command, err)
		runtime.EventsEmit(a.ctx, "app:error", map[string]string{"message": err.Error()})
	}
}

// Cancel kills the running PowerShell process, if any.
func (a *App) Cancel() error {
	a.ps.kill()
	return nil
}

// GetHistory reads the last n entries of %LOCALAPPDATA%\QingDaoFu\logs\operations.jsonl
// (newest first) directly from Go — reading a log needs no PS.
func (a *App) GetHistory(last int) ([]map[string]interface{}, error) {
	if last <= 0 || last > 200 {
		last = 50
	}
	logPath := filepath.Join(dataRoot(), "logs", "operations.jsonl")
	raw, err := os.ReadFile(logPath)
	if err != nil {
		if os.IsNotExist(err) {
			return []map[string]interface{}{}, nil
		}
		return nil, err
	}

	var entries []map[string]interface{}
	for _, line := range strings.Split(string(raw), "\n") {
		line = strings.TrimRight(line, "\r")
		if strings.TrimSpace(line) == "" {
			continue
		}
		var m map[string]interface{}
		if json.Unmarshal([]byte(line), &m) == nil {
			entries = append(entries, m)
		}
	}
	if len(entries) > last {
		entries = entries[len(entries)-last:]
	}
	// newest first
	for i, j := 0, len(entries)-1; i < j; i, j = i+1, j-1 {
		entries[i], entries[j] = entries[j], entries[i]
	}
	return entries, nil
}

// GetReceipt returns one receipt JSON. The path must sit inside
// %LOCALAPPDATA%\QingDaoFu\receipts — never accept arbitrary paths
// from the frontend.
func (a *App) GetReceipt(path string) (map[string]interface{}, error) {
	receiptsDir := filepath.Join(dataRoot(), "receipts")
	clean := filepath.Clean(path)
	if !strings.EqualFold(clean, receiptsDir) &&
		strings.HasPrefix(strings.ToLower(clean), strings.ToLower(receiptsDir)+string(os.PathSeparator)) {
		raw, err := os.ReadFile(clean)
		if err != nil {
			return nil, err
		}
		var m map[string]interface{}
		if err := json.Unmarshal(raw, &m); err != nil {
			return nil, err
		}
		return m, nil
	}
	return nil, fmt.Errorf("回执路径不在 receipts 目录内")
}

// GetStrings returns the raw zh-CN strings JSON for frontend i18n.
func (a *App) GetStrings() (string, error) {
	p := filepath.Join(a.root, "app", "strings.zh-CN.json")
	raw, err := os.ReadFile(p)
	if err != nil {
		return "", err
	}
	return string(raw), nil
}

// GetRules returns the raw rules.json. The operation history and receipts only
// record rule *ids*, so the frontend needs this to show the rule names the user
// actually recognises. Read-only: the file is never written from here.
func (a *App) GetRules() (string, error) {
	raw, err := os.ReadFile(filepath.Join(a.root, "rules", "rules.json"))
	if err != nil {
		return "", err
	}
	return string(raw), nil
}

// OpenPath opens a whitelisted target in Explorer: the recycle bin or
// the QingDaoFu data directory. Nothing else is openable.
func (a *App) OpenPath(target string) error {
	var arg string
	switch target {
	case "recyclebin":
		arg = "shell:RecycleBinFolder"
	case "logs", "receipts":
		dir := filepath.Join(dataRoot(), target)
		if st, err := os.Stat(dir); err != nil || !st.IsDir() {
			os.MkdirAll(dir, 0o755)
		}
		arg = dir
	default:
		return fmt.Errorf("不允许打开该位置")
	}
	err := explorerOpen(arg)
	if err != nil {
		log.Printf("OpenPath %s failed: %v", target, err)
	}
	return err
}

func dataRoot() string {
	local := os.Getenv("LOCALAPPDATA")
	if local == "" {
		local = filepath.Join(os.Getenv("USERPROFILE"), "AppData", "Local")
	}
	return filepath.Join(local, "QingDaoFu")
}
