package scanner

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestParallelScanAndHardLinkDedup(t *testing.T) {
	tmp := t.TempDir()

	// Create nested directories: a/b/c and x/y
	dirABC := filepath.Join(tmp, "a", "b", "c")
	dirXY := filepath.Join(tmp, "x", "y")
	if err := os.MkdirAll(dirABC, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(dirXY, 0o755); err != nil {
		t.Fatal(err)
	}

	// Write a 64 KB file in a/b/c
	data := make([]byte, 64*1024)
	for i := range data {
		data[i] = byte(i % 251)
	}
	f1 := filepath.Join(dirABC, "big.bin")
	if err := os.WriteFile(f1, data, 0o644); err != nil {
		t.Fatal(err)
	}

	// Hard-link f1 into x/y/hardlink.bin -> should NOT double-count!
	f2 := filepath.Join(dirXY, "hardlink.bin")
	if err := os.Link(f1, f2); err != nil {
		t.Fatal(err)
	}

	// Symlink back to tmp -> should NOT loop!
	if err := os.Symlink(tmp, filepath.Join(dirABC, "loop")); err != nil {
		t.Fatal(err)
	}

	// Write a second 32 KB file in x/y
	f3 := filepath.Join(dirXY, "other.bin")
	if err := os.WriteFile(f3, data[:32*1024], 0o644); err != nil {
		t.Fatal(err)
	}

	sc := New(Options{
		VolumeID:   tmp,
		VolumeName: "TestDisk",
		RootPath:   tmp,
		Workers:    4,
	})
	res, err := sc.Run(context.Background())
	if err != nil {
		t.Fatalf("Run failed: %v", err)
	}

	if res.TotalFiles != 2 {
		t.Errorf("expected 2 unique files (hard link deduped), got %d", res.TotalFiles)
	}
	if res.Root.Apparent != 96*1024 {
		t.Errorf("expected apparent size %d, got %d", 96*1024, res.Root.Apparent)
	}
	if res.Root.Size == 0 {
		t.Errorf("expected non-zero allocated size")
	}

	// Verify FindPath + Breadcrumbs on dirXY (always non-empty due to other.bin)
	found, crumbs := res.Root.FindPath(dirXY)
	if found == nil || filepath.Clean(found.Path) != filepath.Clean(dirXY) {
		t.Fatalf("FindPath(%s) failed, got %+v", dirXY, found)
	}
	if len(crumbs) != 3 { // TestDisk -> x -> y
		t.Errorf("expected 3 breadcrumbs, got %d: %+v", len(crumbs), crumbs)
	}

	// Verify ProjectView
	vn, maxD := ProjectView(res.Root, 10, false, res.Root.Size)
	if vn.Name != "TestDisk" {
		t.Errorf("unexpected root name %q", vn.Name)
	}
	if maxD < 2 {
		t.Errorf("expected projected depth >= 2, got %d", maxD)
	}

	// Verify RemovePath & RestoreNode round-trip (used by Move to Trash / Undo)
	origSize := res.Root.Size
	origFiles := res.Root.Files
	removed, parentPath, ok := res.Root.RemovePath(dirXY)
	if !ok || removed == nil {
		t.Fatalf("RemovePath(%s) failed", dirXY)
	}
	if res.Root.Size >= origSize {
		t.Errorf("expected root size to decrease after RemovePath, was %d now %d", origSize, res.Root.Size)
	}
	if !res.Root.RestoreNode(parentPath, removed) {
		t.Fatalf("RestoreNode(%s) failed", parentPath)
	}
	if res.Root.Size != origSize || res.Root.Files != origFiles {
		t.Errorf("expected root size/files (%d/%d) after RestoreNode, got (%d/%d)",
			origSize, origFiles, res.Root.Size, res.Root.Files)
	}

	// Verify SaveCache / LoadAllCache round-trip
	cacheDir := filepath.Join(t.TempDir(), "cache")
	if err := SaveCache(cacheDir, res); err != nil {
		t.Fatalf("SaveCache failed: %v", err)
	}
	loaded := LoadAllCache(cacheDir)
	got, ok := loaded[res.VolumeID]
	if !ok || got == nil || got.Root == nil {
		t.Fatalf("LoadAllCache missing volume %q", res.VolumeID)
	}
	if got.Root.Size != res.Root.Size || got.TotalFiles != res.TotalFiles {
		t.Errorf("cached result mismatch: got size=%d files=%d, want size=%d files=%d",
			got.Root.Size, got.TotalFiles, res.Root.Size, res.TotalFiles)
	}
}
