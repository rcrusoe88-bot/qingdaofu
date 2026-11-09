//go:build windows

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"syscall"
	"time"
	"unsafe"

	"github.com/wailsapp/wails/v2/pkg/options/windows"
)

var (
	user32              = syscall.NewLazyDLL("user32.dll")
	messageBoxW         = user32.NewProc("MessageBoxW")
	mbIconError uintptr = 0x00000010
)

func startupMessages() *windows.Messages {
	return &windows.Messages{
		InstallationRequired: "清道夫需要 Microsoft Edge WebView2 运行库才能显示界面。\n\n点击“确定”将尝试联网下载并安装；安装过程中请保持网络畅通。",
		UpdateRequired:       "清道夫需要更新 Microsoft Edge WebView2 运行库。\n\n点击“确定”将尝试联网更新；安装过程中请保持网络畅通。",
		MissingRequirements:  "缺少运行环境",
		Webview2NotInstalled: "未能安装 WebView2 运行库，请重新运行安装程序，或手动安装后重启清道夫。",
		Error:                "启动失败",
		FailedToInstall:      "WebView2 运行库安装失败。请检查网络后重新运行安装程序，或联系管理员安装运行库。",
		DownloadPage:         "清道夫需要 WebView2 运行库。点击“确定”可打开微软下载页。最低版本：",
		PressOKToInstall:     "点击“确定”开始安装。",
		ContactAdmin:         "无法启动清道夫：电脑缺少可用的 WebView2 运行库。请重新运行安装程序，或联系管理员安装运行库。",
		InvalidFixedWebview2: "指定的 WebView2 运行库路径无效，请检查安装。",
		WebView2ProcessCrash: "清道夫的 WebView2 界面进程异常退出，请重新启动程序。",
	}
}

func reportStartupFailure(err error) {
	message := fmt.Sprintf("清道夫启动失败：%v\n\n请重新运行安装程序；若仍失败，请把这段提示发给软件提供者。", err)
	_ = writeStartupLog(message)
	showStartupError(message)
}

func showStartupError(message string) {
	text, err := syscall.UTF16PtrFromString(message)
	if err != nil {
		return
	}
	title, err := syscall.UTF16PtrFromString("清道夫 · 启动失败")
	if err != nil {
		return
	}
	_, _, _ = messageBoxW.Call(0, uintptr(unsafe.Pointer(text)), uintptr(unsafe.Pointer(title)), mbIconError)
}

func writeStartupLog(message string) error {
	root := dataRoot()
	if err := os.MkdirAll(filepath.Join(root, "logs"), 0o755); err != nil {
		return err
	}
	path := filepath.Join(root, "logs", "startup-gui.log")
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = fmt.Fprintf(f, "%s %s\n", time.Now().Format(time.RFC3339), message)
	return err
}
