//go:build darwin

package trash

/*
#cgo CFLAGS: -x objective-c -fobjc-arc
#cgo LDFLAGS: -framework Foundation
#include <stdlib.h>

extern int xnk_trash_item(const char *srcPath, char **outTrashedPath, char **outErrMsg);
extern int xnk_untrash_item(const char *trashedPath, const char *originalPath, char **outErrMsg);
*/
import "C"

import (
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"unsafe"
)

var protectedPaths = map[string]bool{
	"/":             true,
	"/System":       true,
	"/Library":      true,
	"/Users":        true,
	"/Applications": true,
	"/Volumes":      true,
	"/private":      true,
	"/usr":          true,
	"/bin":          true,
	"/sbin":         true,
	"/etc":          true,
	"/var":          true,
	"/dev":          true,
	"/opt":          true,
}

// ValidateTrashable ensures we never attempt to trash protected root or volume mount paths.
func ValidateTrashable(path string, volumeMount string) error {
	clean := filepath.Clean(path)
	if clean == "" || clean == "." {
		return errors.New("empty path")
	}
	if protectedPaths[clean] {
		return fmt.Errorf("refusing to move protected system path %q to Trash", clean)
	}
	if volumeMount != "" && clean == filepath.Clean(volumeMount) {
		return fmt.Errorf("refusing to move volume root %q to Trash", clean)
	}
	if strings.HasSuffix(clean, "/*") || strings.HasSuffix(clean, "(direct files)") {
		return errors.New("cannot move synthetic aggregate entry to Trash")
	}
	return nil
}

// MoveToTrash moves path to the macOS Trash using NSFileManager and returns the exact path inside Trash.
func MoveToTrash(path string) (string, error) {
	clean := filepath.Clean(path)
	cSrc := C.CString(clean)
	defer C.free(unsafe.Pointer(cSrc))

	var cOut *C.char
	var cErr *C.char
	rc := C.xnk_trash_item(cSrc, &cOut, &cErr)
	if cOut != nil {
		defer C.free(unsafe.Pointer(cOut))
	}
	if cErr != nil {
		defer C.free(unsafe.Pointer(cErr))
	}
	if rc != 0 {
		msg := "failed to move item to Trash"
		if cErr != nil {
			msg = C.GoString(cErr)
		}
		return "", errors.New(msg)
	}
	if cOut == nil {
		return "", errors.New("macOS Trash did not return resulting Trash path")
	}
	return C.GoString(cOut), nil
}

// RestoreFromTrash moves a previously trashed item back from trashedPath to originalPath.
func RestoreFromTrash(trashedPath, originalPath string) error {
	cSrc := C.CString(filepath.Clean(trashedPath))
	cDst := C.CString(filepath.Clean(originalPath))
	defer C.free(unsafe.Pointer(cSrc))
	defer C.free(unsafe.Pointer(cDst))

	var cErr *C.char
	rc := C.xnk_untrash_item(cSrc, cDst, &cErr)
	if cErr != nil {
		defer C.free(unsafe.Pointer(cErr))
	}
	if rc != 0 {
		msg := "failed to restore item from Trash"
		if cErr != nil {
			msg = C.GoString(cErr)
		}
		return errors.New(msg)
	}
	return nil
}
