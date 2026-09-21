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
		Title:            "清道夫",
		Width:            1080,
		Height:           760,
		MinWidth:         960,
		MinHeight:        680,
		DisableResize:    false,
		AssetServer:      &assetserver.Options{Assets: assets},
		// Matches the top of the CSS background gradient so there is no
		// white flash before the webview paints.
		BackgroundColour: &options.RGBA{R: 237, G: 240, B: 214, A: 255},
		OnStartup:        app.startup,
		OnShutdown:       app.shutdown,
		Bind: []interface{}{
			app,
		},
		Windows: &windows.Options{
			WebviewIsTransparent: false,
			WindowIsTranslucent:  false,
		},
	})
	if err != nil {
		log.Fatal(err)
	}
}
