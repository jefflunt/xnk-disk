//go:build darwin

package scanner

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

// Progress reports live scanning metrics while a parallel scan is in progress.
type Progress struct {
	VolumeID    string `json:"volumeId"`
	Active      bool   `json:"active"`
	Files       int64  `json:"files"`
	Dirs        int64  `json:"dirs"`
	Bytes       uint64 `json:"bytes"`
	SkippedPerm int64  `json:"skippedPerm"`
	CurrentPath string `json:"currentPath"`
	ElapsedMs   int64  `json:"elapsedMs"`
	Workers     int    `json:"workers"`
}

// Result holds the completed scan tree and summary statistics.
type Result struct {
	VolumeID    string
	VolumeName  string
	Root        *Node
	TotalFiles  int64
	TotalDirs   int64
	SkippedPerm int64
	ScannedAt   time.Time
	Duration    time.Duration
}

// Options configures a parallel disk scan.
type Options struct {
	VolumeID    string
	VolumeName  string
	RootPath    string
	AllowedDevs []int32
	Workers     int
}

type inodeKey struct {
	dev int32
	ino uint64
}

const inodeShards = 64

type inodeSet struct {
	shards [inodeShards]struct {
		mu sync.Mutex
		m  map[inodeKey]struct{}
	}
}

func newInodeSet() *inodeSet {
	s := &inodeSet{}
	for i := range s.shards {
		s.shards[i].m = make(map[inodeKey]struct{}, 256)
	}
	return s
}

// add returns true if this (dev, ino) was NOT seen before.
func (s *inodeSet) add(dev int32, ino uint64) bool {
	idx := ino & (inodeShards - 1)
	sh := &s.shards[idx]
	sh.mu.Lock()
	k := inodeKey{dev: dev, ino: ino}
	_, exists := sh.m[k]
	if !exists {
		sh.m[k] = struct{}{}
	}
	sh.mu.Unlock()
	return !exists
}

// Scanner executes a multi-core parallel filesystem scan with live progress reporting.
type Scanner struct {
	opts        Options
	allowedDevs map[int32]bool
	isBootRoot  bool
	workers     int
	inodes      *inodeSet

	files       atomic.Int64
	dirs        atomic.Int64
	bytes       atomic.Uint64
	skippedPerm atomic.Int64
	currentPath atomic.Value
	startTime   time.Time
}

// New creates a new parallel Scanner.
func New(opts Options) *Scanner {
	workers := opts.Workers
	if workers <= 0 {
		workers = runtime.NumCPU() * 2
		if workers < 4 {
			workers = 4
		}
		if workers > 24 {
			workers = 24
		}
	}

	devMap := make(map[int32]bool, len(opts.AllowedDevs))
	for _, d := range opts.AllowedDevs {
		devMap[d] = true
	}

	cleanRoot := filepath.Clean(opts.RootPath)
	s := &Scanner{
		opts:        opts,
		allowedDevs: devMap,
		isBootRoot:  cleanRoot == "/",
		workers:     workers,
		inodes:      newInodeSet(),
		startTime:   time.Now(),
	}
	s.currentPath.Store(cleanRoot)
	return s
}

// Progress returns a thread-safe snapshot of current scan metrics.
func (s *Scanner) Progress(active bool) Progress {
	cur, _ := s.currentPath.Load().(string)
	return Progress{
		VolumeID:    s.opts.VolumeID,
		Active:      active,
		Files:       s.files.Load(),
		Dirs:        s.dirs.Load(),
		Bytes:       s.bytes.Load(),
		SkippedPerm: s.skippedPerm.Load(),
		CurrentPath: cur,
		ElapsedMs:   time.Since(s.startTime).Milliseconds(),
		Workers:     s.workers,
	}
}

// Run executes the parallel scan until completion or context cancellation.
func (s *Scanner) Run(ctx context.Context) (*Result, error) {
	s.startTime = time.Now()
	cleanRoot := filepath.Clean(s.opts.RootPath)

	// If no AllowedDevs were provided, lock to the root path's device ID.
	if len(s.allowedDevs) == 0 {
		var st syscall.Stat_t
		if err := syscall.Lstat(cleanRoot, &st); err == nil {
			s.allowedDevs[st.Dev] = true
		}
	}

	rootName := s.opts.VolumeName
	if rootName == "" {
		rootName = filepath.Base(cleanRoot)
	}

	sem := make(chan struct{}, s.workers)
	root := s.walkDir(ctx, cleanRoot, rootName, sem)
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}

	root.SortRecursive()

	return &Result{
		VolumeID:    s.opts.VolumeID,
		VolumeName:  rootName,
		Root:        root,
		TotalFiles:  s.files.Load(),
		TotalDirs:   s.dirs.Load(),
		SkippedPerm: s.skippedPerm.Load(),
		ScannedAt:   time.Now(),
		Duration:    time.Since(s.startTime),
	}, nil
}

// shouldSkipPath avoids double-counting APFS internal mounts and virtual filesystems when scanning "/".
func (s *Scanner) shouldSkipPath(fullPath string) bool {
	if !s.isBootRoot {
		return false
	}
	switch fullPath {
	case "/System/Volumes", "/Volumes", "/dev", "/net", "/home":
		return true
	}
	return false
}

const notableFileThreshold = 10 * 1024 * 1024 // 10 MB

func (s *Scanner) walkDir(ctx context.Context, dirPath, name string, sem chan struct{}) *Node {
	node := &Node{
		Name:  name,
		Path:  dirPath,
		IsDir: true,
	}

	if ctx.Err() != nil {
		return node
	}

	dCount := s.dirs.Add(1)
	if dCount&63 == 0 {
		s.currentPath.Store(dirPath)
	}

	entries, err := os.ReadDir(dirPath)
	if err != nil {
		if os.IsPermission(err) {
			s.skippedPerm.Add(1)
			node.Skipped = 1
		}
		return node
	}

	type subTask struct {
		path string
		name string
	}
	var subDirs []subTask
	var notableFiles []*Node
	var otherDirectBytes uint64
	var otherDirectApparent uint64
	var otherDirectCount int64

	for _, entry := range entries {
		if ctx.Err() != nil {
			return node
		}
		eName := entry.Name()
		fullPath := filepath.Join(dirPath, eName)

		if s.shouldSkipPath(fullPath) {
			continue
		}

		// Never follow symlinks.
		eType := entry.Type()
		if eType&os.ModeSymlink != 0 {
			continue
		}

		var st syscall.Stat_t
		if err := syscall.Lstat(fullPath, &st); err != nil {
			if os.IsPermission(err) {
				s.skippedPerm.Add(1)
				node.Skipped++
			}
			continue
		}

		if (st.Mode & syscall.S_IFMT) == syscall.S_IFLNK {
			continue
		}

		// Stay within the volume's allowed device ID(s).
		if len(s.allowedDevs) > 0 && !s.allowedDevs[st.Dev] {
			continue
		}

		if (st.Mode & syscall.S_IFMT) == syscall.S_IFDIR {
			subDirs = append(subDirs, subTask{path: fullPath, name: eName})
			continue
		}

		// Deduplicate hard-linked files so we never double-count them.
		if st.Nlink > 1 {
			if !s.inodes.add(st.Dev, st.Ino) {
				continue
			}
		}

		alloc := uint64(st.Blocks) * 512
		apparent := uint64(0)
		if st.Size > 0 {
			apparent = uint64(st.Size)
		}

		s.files.Add(1)
		if alloc > 0 {
			s.bytes.Add(alloc)
		}

		node.Size += alloc
		node.Apparent += apparent
		node.Files++

		if alloc >= notableFileThreshold {
			notableFiles = append(notableFiles, &Node{
				Name:     eName,
				Path:     fullPath,
				Size:     alloc,
				Apparent: apparent,
				Files:    1,
				IsDir:    false,
			})
		} else {
			otherDirectBytes += alloc
			otherDirectApparent += apparent
			otherDirectCount++
		}
	}

	if len(subDirs) > 0 {
		childNodes := make([]*Node, len(subDirs))
		var wg sync.WaitGroup

		for i, sub := range subDirs {
			if ctx.Err() != nil {
				break
			}
			// Non-blocking worker pool dispatch: avoids recursive deadlock while
			// keeping all CPU cores busy on parallel NVMe I/O.
			select {
			case sem <- struct{}{}:
				wg.Add(1)
				go func(idx int, t subTask) {
					defer func() {
						<-sem
						wg.Done()
					}()
					childNodes[idx] = s.walkDir(ctx, t.path, t.name, sem)
				}(i, sub)
			default:
				childNodes[i] = s.walkDir(ctx, sub.path, sub.name, sem)
			}
		}
		wg.Wait()

		for _, cn := range childNodes {
			if cn == nil {
				continue
			}
			node.Size += cn.Size
			node.Apparent += cn.Apparent
			node.Files += cn.Files
			node.Dirs += cn.Dirs + 1
			node.Skipped += cn.Skipped
			if cn.Size > 0 {
				node.Children = append(node.Children, cn)
			}
		}
	}

	if len(notableFiles) > 0 {
		node.Children = append(node.Children, notableFiles...)
	}

	// If this folder has both subdirectories/notable files AND significant smaller direct files,
	// include a synthetic "(files)" child so the icicle bar accounts for 100% of the folder's space.
	if len(node.Children) > 0 && otherDirectBytes > 0 && otherDirectBytes >= node.Size/50 {
		node.Children = append(node.Children, &Node{
			Name:     "(direct files)",
			Path:     filepath.Join(dirPath, "(direct files)"),
			Size:     otherDirectBytes,
			Apparent: otherDirectApparent,
			Files:    otherDirectCount,
			IsDir:    false,
		})
	}

	return node
}
