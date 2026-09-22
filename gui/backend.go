package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"

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
}

func NewApp() *App { return &App{} }

func (a *App) startup(ctx context.Context) {
	a.ctx = ctx
	a.root = findRoot()
	a.ps = newRunner(a.root)
}

func (a *App) shutdown(ctx context.Context) {
	_ = a.ps.stop()
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
	if err := a.launch("scan"); err != nil {
		return err
	}
	go a.runStream("scan", ruleIds, false)
	return nil
}

// Clean executes the selected rules. The delete-vs-recycle choice
// lives in rules.json; the GUI never passes an action. Streams
// clean:progress / clean:done / app:error.
func (a *App) Clean(ruleIds []string) error {
	if err := a.launch("clean"); err != nil {
		return err
	}
	go a.runStream("clean", ruleIds, false)
	return nil
}

func (a *App) launch(command string) error {
	if _, err := a.cliPath(); err != nil {
		return err
	}
	return a.ps.reserve(command)
}

func (a *App) beforeClose(ctx context.Context) bool {
	if a.ps == nil || !a.ps.busy() {
		return false
	}
	if err := a.ps.stop(); err != nil {
		log.Printf("stop: %v", err)
	}
	runtime.EventsEmit(a.ctx, "app:stopping", "正在停止任务并保存回执，请稍后再关闭窗口。")
	return true
}

func (a *App) runStream(command string, ids []string, dryRun bool) {
	var result map[string]interface{}
	var coreError string
	err := a.ps.runReserved(command, ids, dryRun, func(line []byte) {
		var ev psEvent
		if json.Unmarshal(line, &ev) != nil {
			return
		}
		switch ev.Type {
		case "progress":
			runtime.EventsEmit(a.ctx, command+":progress", ev)
		case "result":
			if e := json.Unmarshal(line, &result); e != nil {
				coreError = e.Error()
			}
		case "error":
			coreError = ev.Message
		}
	})
	if errors.Is(err, errKilled) {
		runtime.EventsEmit(a.ctx, "app:cancelled", command)
		return
	}
	if err != nil || coreError != "" || result == nil {
		message := coreError
		if message == "" && err != nil {
			message = err.Error()
		}
		if message == "" {
			message = "核心组件退出但没有返回结果；请检查操作记录。"
		}
		runtime.EventsEmit(a.ctx, "app:error", map[string]string{"message": message, "phase": command})
		return
	}
	runtime.EventsEmit(a.ctx, command+":done", result)
}

func (a *App) Cancel() error { return a.ps.stop() }

// GetHistory reads the last n entries of %LOCALAPPDATA%\QingDaoFu\logs\operations.jsonl
// (newest first) directly from Go — reading a log needs no PS.
func (a *App) GetHistory(last int) ([]map[string]interface{}, error) {
	if a.ps != nil && a.ps.busy() {
		return nil, fmt.Errorf("任务执行中，请在完成或停止后查看记录")
	}
	if last <= 0 || last > 200 {
		last = 50
	}
	files, err := filepath.Glob(filepath.Join(dataRoot(), "receipts", "receipt-*.json"))
	if err != nil {
		return nil, err
	}
	entries := []map[string]interface{}{}
	for _, file := range files {
		receipt, err := a.GetReceipt(file)
		if err != nil {
			log.Printf("Unreadable receipt %s: %v", filepath.Base(file), err)
			continue
		}
		if summary, ok := receipt["Summary"].(map[string]interface{}); ok {
			if dry, _ := summary["DryRun"].(bool); dry {
				continue
			}
			summary["ReceiptPath"] = file
			entries = append(entries, summary)
		}
	}
	sort.Slice(entries, func(i, j int) bool { return fmt.Sprint(entries[i]["StartedAt"]) > fmt.Sprint(entries[j]["StartedAt"]) })
	if len(entries) > last {
		entries = entries[:last]
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
		if err := checkReceiptPath(clean, receiptsDir); err != nil {
			return nil, err
		}
		raw, err := os.ReadFile(clean)
		if err != nil {
			return nil, err
		}
		var m map[string]interface{}
		if err := json.Unmarshal(bytes.TrimPrefix(raw, []byte{0xef, 0xbb, 0xbf}), &m); err != nil {
			return nil, err
		}
		if err := recoverJournal(clean, m); err != nil {
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
			if err := os.MkdirAll(dir, 0o755); err != nil {
				return err
			}
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
