//go:build darwin

package volumes

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
)

// Volume describes a mounted macOS storage volume.
type Volume struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	MountPoint  string `json:"mountPoint"`
	Device      string `json:"device"`
	FSType      string `json:"fsType"`
	TotalBytes  uint64 `json:"totalBytes"`
	UsedBytes   uint64 `json:"usedBytes"`
	AvailBytes  uint64 `json:"availBytes"`
	IsBoot      bool   `json:"isBoot"`
	IsReadOnly  bool   `json:"isReadOnly"`
	AllowedDevs []int32 `json:"-"`
}

const (
	mntNowait     = 2          // MNT_NOWAIT from <sys/mount.h>
	mntRdOnly     = 0x00000001 // MNT_RDONLY from <sys/mount.h>
	mntDontBrowse = 0x00100000 // MNT_DONTBROWSE from <sys/mount.h>
)

var ignoredFSTypes = map[string]bool{
	"devfs":  true,
	"autofs": true,
	"volfs":  true,
	"nullfs": true,
	"lifs":   true,
	"fdesc":  true,
}

func cstr(arr []int8) string {
	b := make([]byte, 0, len(arr))
	for _, c := range arr {
		if c == 0 {
			break
		}
		b = append(b, byte(c))
	}
	return string(b)
}

// List returns all user-relevant mounted macOS volumes (boot disk + external/secondary volumes),
// deduplicating internal APFS volume group mounts such as /System/Volumes/Data.
func List() ([]Volume, error) {
	n, err := syscall.Getfsstat(nil, mntNowait)
	if err != nil {
		return nil, err
	}
	if n == 0 {
		return nil, nil
	}

	buf := make([]syscall.Statfs_t, n+8)
	n, err = syscall.Getfsstat(buf, mntNowait)
	if err != nil {
		return nil, err
	}
	buf = buf[:n]

	// Look up the Data volume's device ID if present so scanning "/" can traverse
	// APFS firmlinks (/Users, /Applications, /Library, etc.) cleanly without double-counting.
	var dataDev int32
	var hasDataDev bool
	if st, err := lstatDev("/System/Volumes/Data"); err == nil {
		dataDev = st
		hasDataDev = true
	} else if st, err := lstatDev("/Users"); err == nil {
		dataDev = st
		hasDataDev = true
	}

	bootName := detectBootVolumeName()

	var result []Volume
	for _, fs := range buf {
		fsType := cstr(fs.Fstypename[:])
		if ignoredFSTypes[fsType] {
			continue
		}

		mount := cstr(fs.Mntonname[:])
		device := cstr(fs.Mntfromname[:])

		// Filter out internal macOS system helper mounts & Time Machine snapshot mounts.
		if mount != "/" {
			if (fs.Flags & mntDontBrowse) != 0 {
				continue
			}
			if !strings.HasPrefix(mount, "/Volumes/") {
				continue
			}
			rel := strings.TrimPrefix(mount, "/Volumes/")
			if strings.HasPrefix(rel, ".") || strings.Contains(rel, "/") {
				continue
			}
		}

		total := uint64(fs.Blocks) * uint64(fs.Bsize)
		if total == 0 {
			continue
		}
		avail := uint64(fs.Bavail) * uint64(fs.Bsize)
		var used uint64
		if total >= avail {
			used = total - avail
		}

		isBoot := mount == "/"
		name := filepath.Base(mount)
		if isBoot {
			name = bootName
		}

		var allowedDevs []int32
		if rootDev, err := lstatDev(mount); err == nil {
			allowedDevs = append(allowedDevs, rootDev)
		}
		if isBoot && hasDataDev {
			if len(allowedDevs) == 0 || allowedDevs[0] != dataDev {
				allowedDevs = append(allowedDevs, dataDev)
			}
		}

		// If the boot volume's Data mount has a more accurate available/used count, use it.
		if isBoot {
			var dataFS syscall.Statfs_t
			if err := syscall.Statfs("/System/Volumes/Data", &dataFS); err == nil {
				dTotal := uint64(dataFS.Blocks) * uint64(dataFS.Bsize)
				dAvail := uint64(dataFS.Bavail) * uint64(dataFS.Bsize)
				if dTotal > 0 {
					total = dTotal
					avail = dAvail
					if total >= avail {
						used = total - avail
					}
				}
			}
		}

		result = append(result, Volume{
			ID:          mount,
			Name:        name,
			MountPoint:  mount,
			Device:      device,
			FSType:      strings.ToUpper(fsType),
			TotalBytes:  total,
			UsedBytes:   used,
			AvailBytes:  avail,
			IsBoot:      isBoot,
			IsReadOnly:  (fs.Flags & mntRdOnly) != 0,
			AllowedDevs: allowedDevs,
		})
	}

	sort.Slice(result, func(i, j int) bool {
		if result[i].IsBoot != result[j].IsBoot {
			return result[i].IsBoot
		}
		return result[i].Name < result[j].Name
	})

	return result, nil
}

func lstatDev(path string) (int32, error) {
	var st syscall.Stat_t
	if err := syscall.Lstat(path, &st); err != nil {
		return 0, err
	}
	return st.Dev, nil
}

// detectBootVolumeName finds the friendly macOS boot volume name (e.g. "Macintosh HD")
// by checking symlinks in /Volumes that point to "/".
func detectBootVolumeName() string {
	entries, err := os.ReadDir("/Volumes")
	if err == nil {
		for _, e := range entries {
			if e.Type()&os.ModeSymlink != 0 {
				target, err := os.Readlink(filepath.Join("/Volumes", e.Name()))
				if err == nil && target == "/" {
					return e.Name()
				}
			}
		}
	}
	return "Macintosh HD"
}
