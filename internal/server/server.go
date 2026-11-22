//go:build darwin

package server

import (
	"context"
	"encoding/json"
	"fmt"
	"io/fs"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"sync"
	"time"

	"xnk-disk/internal/scanner"
	"xnk-disk/internal/trash"
	"xnk-disk/internal/volumes"
	"xnk-disk/web"
)

type undoEntry struct {
	VolumeID     string
	Name         string
	OriginalPath string
	TrashedPath  string
	ParentPath   string
	RemovedNode  *scanner.Node
}

// Server hosts the local HTTP + SSE API and embedded UI for the native macOS window.
type Server struct {
	mu           sync.RWMutex
	cacheDir     string
	rulesPath    string
	results      map[string]*scanner.Result
	undoStack    []undoEntry
	activeScan   *scanner.Scanner
	activeCancel context.CancelFunc
	scanDoneCh   chan scanDoneInfo
	lastDone     *scanDoneInfo

	listener net.Listener
	httpSrv  *http.Server
}

type scanDoneInfo struct {
	VolumeID string `json:"volumeId"`
	Canceled bool   `json:"canceled"`
	Error    string `json:"error,omitempty"`
}

// New creates a new local Server instance and loads any previously cached scans from disk.
func New() *Server {
	cacheDir := scanner.DefaultCacheDir()
	cached := scanner.LoadAllCache(cacheDir)
	return &Server{
		cacheDir:  cacheDir,
		rulesPath: scanner.DefaultRulesPath(),
		results:   cached,
	}
}

// Start binds to an ephemeral 127.0.0.1 port and begins serving in the background.
func (s *Server) Start() (string, error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return "", err
	}
	s.listener = ln

	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/volumes", s.handleVolumes)
	mux.HandleFunc("POST /api/scan", s.handleScanStart)
	mux.HandleFunc("POST /api/scan/cancel", s.handleScanCancel)
	mux.HandleFunc("GET /api/scan/events", s.handleScanEvents)
	mux.HandleFunc("GET /api/tree", s.handleTree)
	mux.HandleFunc("POST /api/reveal", s.handleReveal)
	mux.HandleFunc("POST /api/trash", s.handleTrash)
	mux.HandleFunc("POST /api/trash/undo", s.handleTrashUndo)
	mux.HandleFunc("GET /api/trash/status", s.handleTrashStatus)
	mux.HandleFunc("POST /api/rules/mark", s.handleRulesMark)
	mux.HandleFunc("POST /api/rules/unmark", s.handleRulesUnmark)

	staticFS, err := fs.Sub(web.Assets, ".")
	if err != nil {
		return "", err
	}
	mux.Handle("/", http.FileServer(http.FS(staticFS)))

	s.httpSrv = &http.Server{Handler: mux}
	go func() {
		_ = s.httpSrv.Serve(ln)
	}()

	return "http://" + ln.Addr().String() + "/", nil
}

// Close gracefully shuts down any active scan and the local HTTP server.
func (s *Server) Close() {
	s.mu.Lock()
	if s.activeCancel != nil {
		s.activeCancel()
	}
	s.mu.Unlock()
	if s.httpSrv != nil {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_ = s.httpSrv.Shutdown(ctx)
	}
}

type volumeDTO struct {
	volumes.Volume
	Scanned   bool   `json:"scanned"`
	ScannedAt string `json:"scannedAt,omitempty"`
}

func (s *Server) handleVolumes(w http.ResponseWriter, r *http.Request) {
	vols, err := volumes.List()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	s.mu.RLock()
	dtos := make([]volumeDTO, 0, len(vols))
	for _, v := range vols {
		res, scanned := s.results[v.ID]
		scannedAt := ""
		if scanned && res != nil && !res.ScannedAt.IsZero() {
			scannedAt = res.ScannedAt.Format(time.RFC3339)
		}
		dtos = append(dtos, volumeDTO{Volume: v, Scanned: scanned, ScannedAt: scannedAt})
	}
	s.mu.RUnlock()

	writeJSON(w, map[string]any{"volumes": dtos})
}

func (s *Server) handleScanStart(w http.ResponseWriter, r *http.Request) {
	var req struct {
		VolumeID string `json:"volumeId"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid request body", http.StatusBadRequest)
		return
	}

	vols, err := volumes.List()
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	var target *volumes.Volume
	for i := range vols {
		if vols[i].ID == req.VolumeID {
			target = &vols[i]
			break
		}
	}
	if target == nil {
		http.Error(w, "volume not found", http.StatusNotFound)
		return
	}

	s.mu.Lock()
	if s.activeCancel != nil {
		s.activeCancel()
	}
	ctx, cancel := context.WithCancel(context.Background())
	sc := scanner.New(scanner.Options{
		VolumeID:    target.ID,
		VolumeName:  target.Name,
		RootPath:    target.MountPoint,
		AllowedDevs: target.AllowedDevs,
	})
	doneCh := make(chan scanDoneInfo, 1)
	s.activeScan = sc
	s.activeCancel = cancel
	s.scanDoneCh = doneCh
	s.lastDone = nil
	s.mu.Unlock()

	go func() {
		res, err := sc.Run(ctx)
		info := scanDoneInfo{VolumeID: target.ID}
		if err != nil {
			if ctx.Err() != nil {
				info.Canceled = true
			} else {
				info.Error = err.Error()
			}
		}

		s.mu.Lock()
		if err == nil && res != nil {
			s.results[target.ID] = res
		}
		if s.activeScan == sc {
			s.activeScan = nil
			s.activeCancel = nil
		}
		s.lastDone = &info
		s.mu.Unlock()

		if err == nil && res != nil {
			s.persistResult(res)
		}

		doneCh <- info
		close(doneCh)
	}()

	writeJSON(w, map[string]any{"started": true, "volumeId": target.ID})
}

func (s *Server) handleScanCancel(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	if s.activeCancel != nil {
		s.activeCancel()
	}
	s.mu.Unlock()
	writeJSON(w, map[string]any{"canceled": true})
}

func (s *Server) handleScanEvents(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")

	s.mu.RLock()
	sc := s.activeScan
	doneCh := s.scanDoneCh
	lastDone := s.lastDone
	s.mu.RUnlock()

	if sc == nil {
		if lastDone != nil {
			sendSSE(w, flusher, "done", lastDone)
		} else {
			sendSSE(w, flusher, "done", scanDoneInfo{})
		}
		return
	}

	ticker := time.NewTicker(80 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-r.Context().Done():
			return
		case info := <-doneCh:
			sendSSE(w, flusher, "done", info)
			return
		case <-ticker.C:
			sendSSE(w, flusher, "progress", sc.Progress(true))
		}
	}
}

func (s *Server) handleTree(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	volID := q.Get("volume")
	targetPath := q.Get("path")
	groupSmall := q.Get("groupSmall") == "1"

	maxDepth := 10
	if raw := q.Get("maxDepth"); raw != "" {
		if md, err := strconv.Atoi(raw); err == nil && md >= 0 {
			maxDepth = md
		}
	}

	s.mu.RLock()
	res, ok := s.results[volID]
	s.mu.RUnlock()
	if !ok || res == nil || res.Root == nil {
		http.Error(w, "volume not scanned yet", http.StatusNotFound)
		return
	}

	var volInfo volumes.Volume
	if vols, err := volumes.List(); err == nil {
		for _, v := range vols {
			if v.ID == volID {
				volInfo = v
				break
			}
		}
	}

	focusNode, crumbs := res.Root.FindPath(targetPath)
	isRoot := focusNode == res.Root

	scaleBytes := focusNode.Size
	if isRoot && volInfo.TotalBytes > 0 {
		scaleBytes = volInfo.TotalBytes
	}

	rules, _ := scanner.LoadCustomRules(s.rulesPath)
	viewRoot, deepest := scanner.ProjectViewWithRules(focusNode, maxDepth, groupSmall, scaleBytes, rules)

	resp := scanner.TreeResponse{
		VolumeID:    res.VolumeID,
		VolumeName:  res.VolumeName,
		TotalBytes:  volInfo.TotalBytes,
		UsedBytes:   volInfo.UsedBytes,
		AvailBytes:  volInfo.AvailBytes,
		ScannedAt:   res.ScannedAt.Format(time.RFC3339),
		DurationMs:  res.Duration.Milliseconds(),
		TotalFiles:  res.TotalFiles,
		TotalDirs:   res.TotalDirs,
		SkippedPerm: res.SkippedPerm,
		MaxDepth:    deepest,
		IsRoot:      isRoot,
		Breadcrumbs: crumbs,
		Root:        viewRoot,
	}

	writeJSON(w, resp)
}

func (s *Server) handleReveal(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Path string `json:"path"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Path == "" {
		http.Error(w, "invalid path", http.StatusBadRequest)
		return
	}
	clean := filepath.Clean(req.Path)
	_ = exec.Command("open", "-R", clean).Start()
	writeJSON(w, map[string]any{"ok": true})
}

func (s *Server) handleRulesMark(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Path  string `json:"path"`
		Label string `json:"label"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Path == "" {
		http.Error(w, "invalid path", http.StatusBadRequest)
		return
	}
	clean := filepath.Clean(req.Path)
	home, _ := os.UserHomeDir()

	s.mu.Lock()
	cfg, _ := scanner.LoadCustomRules(s.rulesPath)
	cfg.MarkPathRebuilds(clean, req.Label, home)
	err := scanner.SaveCustomRules(s.rulesPath, cfg)
	s.mu.Unlock()

	if err != nil {
		http.Error(w, "failed to save custom rules: "+err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, map[string]any{"ok": true, "path": clean})
}

func (s *Server) handleRulesUnmark(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Path string `json:"path"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Path == "" {
		http.Error(w, "invalid path", http.StatusBadRequest)
		return
	}
	clean := filepath.Clean(req.Path)
	home, _ := os.UserHomeDir()
	dummy := &scanner.Node{Name: filepath.Base(clean), Path: clean, IsDir: true}
	hasBuiltin := scanner.ClassifyNode(dummy, nil) != nil

	s.mu.Lock()
	cfg, _ := scanner.LoadCustomRules(s.rulesPath)
	cfg.UnmarkPath(clean, home, hasBuiltin)
	err := scanner.SaveCustomRules(s.rulesPath, cfg)
	s.mu.Unlock()

	if err != nil {
		http.Error(w, "failed to save custom rules: "+err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, map[string]any{"ok": true, "path": clean})
}

func (s *Server) undoSummaryLocked() (int, string) {
	n := len(s.undoStack)
	if n == 0 {
		return 0, ""
	}
	return n, s.undoStack[n-1].Name
}

func (s *Server) handleTrashStatus(w http.ResponseWriter, r *http.Request) {
	s.mu.RLock()
	count, label := s.undoSummaryLocked()
	s.mu.RUnlock()
	writeJSON(w, map[string]any{
		"undoCount": count,
		"undoLabel": label,
	})
}

func (s *Server) handleTrash(w http.ResponseWriter, r *http.Request) {
	var req struct {
		VolumeID string `json:"volumeId"`
		Path     string `json:"path"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Path == "" {
		http.Error(w, "invalid request", http.StatusBadRequest)
		return
	}

	if err := trash.ValidateTrashable(req.Path, req.VolumeID); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	trashedPath, err := trash.MoveToTrash(req.Path)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	cleanPath := filepath.Clean(req.Path)
	name := filepath.Base(cleanPath)
	parentPath := filepath.Dir(cleanPath)

	s.mu.Lock()
	var removed *scanner.Node
	if res, ok := s.results[req.VolumeID]; ok && res != nil && res.Root != nil {
		if node, pPath, ok := res.Root.RemovePath(cleanPath); ok {
			removed = node
			parentPath = pPath
			res.TotalFiles -= node.Files
			if res.TotalFiles < 0 {
				res.TotalFiles = 0
			}
			dirsDelta := node.Dirs
			if node.IsDir {
				dirsDelta++
			}
			res.TotalDirs -= dirsDelta
			if res.TotalDirs < 0 {
				res.TotalDirs = 0
			}
		}
	}

	s.undoStack = append(s.undoStack, undoEntry{
		VolumeID:     req.VolumeID,
		Name:         name,
		OriginalPath: cleanPath,
		TrashedPath:  trashedPath,
		ParentPath:   parentPath,
		RemovedNode:  removed,
	})
	count, label := s.undoSummaryLocked()
	updatedRes := s.results[req.VolumeID]
	s.mu.Unlock()

	if updatedRes != nil {
		go s.persistResult(updatedRes)
	}

	writeJSON(w, map[string]any{
		"ok":           true,
		"name":         name,
		"originalPath": cleanPath,
		"parentPath":   parentPath,
		"undoCount":    count,
		"undoLabel":    label,
	})
}

func (s *Server) handleTrashUndo(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	if len(s.undoStack) == 0 {
		s.mu.Unlock()
		http.Error(w, "nothing to undo", http.StatusBadRequest)
		return
	}
	entry := s.undoStack[len(s.undoStack)-1]
	s.undoStack = s.undoStack[:len(s.undoStack)-1]
	s.mu.Unlock()

	if err := trash.RestoreFromTrash(entry.TrashedPath, entry.OriginalPath); err != nil {
		// Push back onto stack if restore failed so the user doesn't lose track of it.
		s.mu.Lock()
		s.undoStack = append(s.undoStack, entry)
		s.mu.Unlock()
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	s.mu.Lock()
	if entry.RemovedNode != nil {
		if res, ok := s.results[entry.VolumeID]; ok && res != nil && res.Root != nil {
			if res.Root.RestoreNode(entry.ParentPath, entry.RemovedNode) {
				res.TotalFiles += entry.RemovedNode.Files
				res.TotalDirs += entry.RemovedNode.Dirs
				if entry.RemovedNode.IsDir {
					res.TotalDirs++
				}
			}
		}
	}
	count, label := s.undoSummaryLocked()
	updatedRes := s.results[entry.VolumeID]
	s.mu.Unlock()

	if updatedRes != nil {
		go s.persistResult(updatedRes)
	}

	writeJSON(w, map[string]any{
		"ok":           true,
		"name":         entry.Name,
		"restoredPath": entry.OriginalPath,
		"volumeId":     entry.VolumeID,
		"undoCount":    count,
		"undoLabel":    label,
	})
}

func (s *Server) persistResult(res *scanner.Result) {
	if s.cacheDir == "" || res == nil {
		return
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	_ = scanner.SaveCache(s.cacheDir, res)
}

func sendSSE(w http.ResponseWriter, f http.Flusher, event string, payload any) {
	b, err := json.Marshal(payload)
	if err != nil {
		return
	}
	_, _ = fmt.Fprintf(w, "event: %s\ndata: %s\n\n", event, b)
	f.Flush()
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}
