//go:build darwin

package main

import (
	"log"
	"runtime"

	"xnk-disk/internal/macui"
	"xnk-disk/internal/server"
)

func init() {
	runtime.LockOSThread()
}

func main() {
	srv := server.New()
	url, err := srv.Start()
	if err != nil {
		log.Fatalf("failed to start local server: %v", err)
	}
	defer srv.Close()

	macui.Run(url, "XNK Disk", 1320, 800)
}
