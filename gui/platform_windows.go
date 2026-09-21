package main

import "os/exec"

// explorerOpen opens a shell path (e.g. shell:RecycleBinFolder) or a
// directory in Explorer.
func explorerOpen(target string) error {
	return exec.Command("explorer.exe", target).Start()
}
