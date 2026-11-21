//go:build darwin

package macui

/*
#cgo CFLAGS: -x objective-c -fobjc-arc
#cgo LDFLAGS: -framework Cocoa -framework WebKit
#include <stdlib.h>

extern void xnk_run_webview(const char *urlCStr, const char *titleCStr, int width, int height);
*/
import "C"

import (
	"runtime"
	"unsafe"
)

func init() {
	// AppKit / Cocoa UI must always run on the primary OS thread.
	runtime.LockOSThread()
}

// Run opens a native macOS desktop window hosting a WKWebView pointed at url,
// blocking until the window is closed or the user quits the application.
func Run(url, title string, width, height int) {
	runtime.LockOSThread()
	cURL := C.CString(url)
	cTitle := C.CString(title)
	defer C.free(unsafe.Pointer(cURL))
	defer C.free(unsafe.Pointer(cTitle))

	C.xnk_run_webview(cURL, cTitle, C.int(width), C.int(height))
}
