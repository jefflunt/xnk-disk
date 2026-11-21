package scanner

import (
	"compress/gzip"
	"crypto/sha256"
	"encoding/gob"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
)

// DefaultCacheDir returns the macOS per-user cache directory for XNK Disk scans:
// ~/Library/Caches/com.jefflunt.xnk-disk/scans
func DefaultCacheDir() string {
	base, err := os.UserCacheDir()
	if err != nil || base == "" {
		base = os.TempDir()
	}
	return filepath.Join(base, "com.jefflunt.xnk-disk", "scans")
}

func cacheFilePath(dir, volumeID string) string {
	sum := sha256.Sum256([]byte(volumeID))
	return filepath.Join(dir, hex.EncodeToString(sum[:8])+".gob.gz")
}

// SaveCache atomically persists a scan Result as a gzip-compressed gob file.
func SaveCache(dir string, res *Result) error {
	if res == nil || res.Root == nil || res.VolumeID == "" {
		return nil
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}

	target := cacheFilePath(dir, res.VolumeID)
	tmpFile, err := os.CreateTemp(dir, ".scan-*.tmp")
	if err != nil {
		return err
	}
	tmpName := tmpFile.Name()
	defer func() {
		if tmpName != "" {
			_ = os.Remove(tmpName)
		}
	}()

	gz, err := gzip.NewWriterLevel(tmpFile, gzip.BestSpeed)
	if err != nil {
		_ = tmpFile.Close()
		return err
	}
	if err := gob.NewEncoder(gz).Encode(res); err != nil {
		_ = gz.Close()
		_ = tmpFile.Close()
		return err
	}
	if err := gz.Close(); err != nil {
		_ = tmpFile.Close()
		return err
	}
	if err := tmpFile.Close(); err != nil {
		return err
	}

	if err := os.Rename(tmpName, target); err != nil {
		return err
	}
	tmpName = ""
	return nil
}

// LoadAllCache loads all previously saved scan results from dir, keyed by VolumeID.
func LoadAllCache(dir string) map[string]*Result {
	out := make(map[string]*Result)
	entries, err := os.ReadDir(dir)
	if err != nil {
		return out
	}

	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".gob.gz") {
			continue
		}
		f, err := os.Open(filepath.Join(dir, e.Name()))
		if err != nil {
			continue
		}
		gz, err := gzip.NewReader(f)
		if err != nil {
			_ = f.Close()
			continue
		}
		var res Result
		err = gob.NewDecoder(gz).Decode(&res)
		_ = gz.Close()
		_ = f.Close()
		if err == nil && res.VolumeID != "" && res.Root != nil {
			out[res.VolumeID] = &res
		}
	}
	return out
}
