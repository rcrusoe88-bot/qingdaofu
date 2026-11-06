package main

import (
	"embed"
	"log"

	"github.com/wailsapp/wails/v2"
	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/options/assetserver"
	"github.com/wailsapp/wails/v2/pkg/options/windows"
)

//go:embed all:frontend
var assets embed.FS

func main() {
	app := NewApp()

	err := wails.Run(&options.App{
		Title:         "清道夫",
		Width:         1080,
		Height:        760,
		MinWidth:      960,
		MinHeight:     680,
		DisableResize: false,
		// Frameless so the page gradient reaches the top edge; the tab bar is
		// the drag region and carries the window controls.
		Frameless:   true,
		AssetServer: &assetserver.Options{Assets: assets},
		// Matches the base of the dark world gradient so there is no
		// white flash before the webview paints.
		BackgroundColour: &options.RGBA{R: 23, G: 20, B: 15, A: 255},
		OnStartup:        app.startup,
		OnShutdown:       app.shutdown,
		OnBeforeClose:    app.beforeClose,
		Bind: []interface{}{
			app,
		},
		Windows: &windows.Options{
			WebviewIsTransparent: false,
			WindowIsTranslucent:  false,
			// Keep WebView2 in dark mode so scrollbars and native controls match.
			Theme: windows.Dark,
		},
	})
	if err != nil {
		log.Fatal(err)
	}
}
