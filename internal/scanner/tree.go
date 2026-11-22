package scanner

import (
	"fmt"
	"path/filepath"
	"sort"
	"strings"
)

// Node represents a directory or large file in the scanned disk tree.
type Node struct {
	Name     string
	Path     string
	Size     uint64 // Allocated bytes on disk (st_blocks * 512)
	Apparent uint64 // Logical apparent bytes (st_size)
	Files    int64
	Dirs     int64
	Skipped  int64
	IsDir    bool
	Children []*Node
}

// Crumb is a single entry in the breadcrumb trail from the volume root to the focused node.
type Crumb struct {
	Name string `json:"name"`
	Path string `json:"path"`
	Size uint64 `json:"size"`
}

// ViewNode is the JSON-serializable projection of a Node sent to the UI.
type ViewNode struct {
	Name        string     `json:"name"`
	Path        string     `json:"path"`
	Size        uint64     `json:"size"`
	Apparent    uint64     `json:"apparent"`
	Files       int64      `json:"files"`
	Dirs        int64      `json:"dirs"`
	Skipped     int64      `json:"skipped,omitempty"`
	IsDir       bool       `json:"isDir"`
	IsGrouped   bool       `json:"isGrouped,omitempty"`
	IsSystemGap bool       `json:"isSystemGap,omitempty"`
	Hint        *NodeHint  `json:"hint,omitempty"`
	Children    []ViewNode `json:"children,omitempty"`
}

// TreeResponse is returned by GET /api/tree for a scanned volume.
type TreeResponse struct {
	VolumeID    string    `json:"volumeId"`
	VolumeName  string    `json:"volumeName"`
	TotalBytes  uint64    `json:"totalBytes"`
	UsedBytes   uint64    `json:"usedBytes"`
	AvailBytes  uint64    `json:"availBytes"`
	ScannedAt   string    `json:"scannedAt"`
	DurationMs  int64     `json:"durationMs"`
	TotalFiles  int64     `json:"totalFiles"`
	TotalDirs   int64     `json:"totalDirs"`
	SkippedPerm int64     `json:"skippedPerm"`
	MaxDepth    int       `json:"maxDepth"`
	IsRoot      bool      `json:"isRoot"`
	Breadcrumbs []Crumb   `json:"breadcrumbs"`
	Root        ViewNode  `json:"root"`
}

// SortRecursive sorts all children descending by allocated Size.
func (n *Node) SortRecursive() {
	if len(n.Children) > 1 {
		sort.Slice(n.Children, func(i, j int) bool {
			if n.Children[i].Size != n.Children[j].Size {
				return n.Children[i].Size > n.Children[j].Size
			}
			return n.Children[i].Name < n.Children[j].Name
		})
	}
	for _, c := range n.Children {
		c.SortRecursive()
	}
}

// FindPath locates targetPath within the tree and returns the matching node plus its breadcrumb trail.
func (n *Node) FindPath(targetPath string) (*Node, []Crumb) {
	cleanTarget := filepath.Clean(targetPath)
	cleanRoot := filepath.Clean(n.Path)

	if cleanTarget == "" || cleanTarget == cleanRoot {
		return n, []Crumb{{Name: n.Name, Path: n.Path, Size: n.Size}}
	}

	var crumbs []Crumb
	var dfs func(cur *Node) *Node
	dfs = func(cur *Node) *Node {
		crumbs = append(crumbs, Crumb{Name: cur.Name, Path: cur.Path, Size: cur.Size})
		if filepath.Clean(cur.Path) == cleanTarget {
			return cur
		}
		for _, child := range cur.Children {
			cp := filepath.Clean(child.Path)
			if cp == cleanTarget || strings.HasPrefix(cleanTarget, cp+string(filepath.Separator)) || cp == "/" {
				if found := dfs(child); found != nil {
					return found
				}
			}
		}
		crumbs = crumbs[:len(crumbs)-1]
		return nil
	}

	if found := dfs(n); found != nil {
		return found, crumbs
	}
	return n, []Crumb{{Name: n.Name, Path: n.Path, Size: n.Size}}
}

// RemovePath removes the node at targetPath from the tree, updating all ancestor
// sizes and counts, and returns the removed node along with its parent's path.
func (n *Node) RemovePath(targetPath string) (*Node, string, bool) {
	cleanTarget := filepath.Clean(targetPath)
	if cleanTarget == "" || cleanTarget == filepath.Clean(n.Path) {
		return nil, "", false
	}

	var removed *Node
	var parentPath string

	var walk func(cur *Node) bool
	walk = func(cur *Node) bool {
		for i, child := range cur.Children {
			cp := filepath.Clean(child.Path)
			if cp == cleanTarget {
				removed = child
				parentPath = cur.Path
				cur.Children = append(cur.Children[:i], cur.Children[i+1:]...)
				subNodeStats(cur, removed)
				return true
			}
			if strings.HasPrefix(cleanTarget, cp+string(filepath.Separator)) || cp == "/" {
				if walk(child) {
					subNodeStats(cur, removed)
					return true
				}
			}
		}
		return false
	}

	if walk(n) && removed != nil {
		return removed, parentPath, true
	}
	return nil, "", false
}

// RestoreNode re-inserts a previously removed node under parentPath, restoring
// all ancestor sizes/counts and re-sorting the parent's children.
func (n *Node) RestoreNode(parentPath string, restored *Node) bool {
	if restored == nil {
		return false
	}
	cleanParent := filepath.Clean(parentPath)

	var walk func(cur *Node) bool
	walk = func(cur *Node) bool {
		if filepath.Clean(cur.Path) == cleanParent {
			cur.Children = append(cur.Children, restored)
			addNodeStats(cur, restored)
			sort.Slice(cur.Children, func(i, j int) bool {
				if cur.Children[i].Size != cur.Children[j].Size {
					return cur.Children[i].Size > cur.Children[j].Size
				}
				return cur.Children[i].Name < cur.Children[j].Name
			})
			return true
		}
		for _, child := range cur.Children {
			cp := filepath.Clean(child.Path)
			if cp == cleanParent || strings.HasPrefix(cleanParent, cp+string(filepath.Separator)) || cp == "/" {
				if walk(child) {
					addNodeStats(cur, restored)
					return true
				}
			}
		}
		return false
	}

	return walk(n)
}

func subNodeStats(ancestor, child *Node) {
	if ancestor.Size >= child.Size {
		ancestor.Size -= child.Size
	} else {
		ancestor.Size = 0
	}
	if ancestor.Apparent >= child.Apparent {
		ancestor.Apparent -= child.Apparent
	} else {
		ancestor.Apparent = 0
	}
	ancestor.Files -= child.Files
	if ancestor.Files < 0 {
		ancestor.Files = 0
	}
	dirsDelta := child.Dirs
	if child.IsDir {
		dirsDelta++
	}
	ancestor.Dirs -= dirsDelta
	if ancestor.Dirs < 0 {
		ancestor.Dirs = 0
	}
}

func addNodeStats(ancestor, child *Node) {
	ancestor.Size += child.Size
	ancestor.Apparent += child.Apparent
	ancestor.Files += child.Files
	dirsDelta := child.Dirs
	if child.IsDir {
		dirsDelta++
	}
	ancestor.Dirs += dirsDelta
}

// ProjectView builds a pruned ViewNode hierarchy rooted at n, up to maxDepth levels deep
// (maxDepth <= 0 means unlimited depth), ensuring the UI stays snappy at 60fps.
func ProjectView(n *Node, maxDepth int, groupSmall bool, scaleBytes uint64) (ViewNode, int) {
	if scaleBytes == 0 {
		scaleBytes = n.Size
	}
	if scaleBytes == 0 {
		scaleBytes = 1
	}

	// Minimum visual slice fraction:
	// - When groupSmall is true: collapse siblings smaller than 1.2% of the focused view.
	// - When groupSmall is false: still collapse sub-pixel microscopic dust (< 0.12% of focused view)
	//   so the browser never tries to render 20,000 0.01px DOM nodes at once.
	minFraction := 0.0012
	if groupSmall {
		minFraction = 0.012
	}
	minBytes := uint64(float64(scaleBytes) * minFraction)

	deepest := 0
	var build func(cur, parent *Node, depth int) ViewNode
	build = func(cur, parent *Node, depth int) ViewNode {
		if depth > deepest {
			deepest = depth
		}
		vn := ViewNode{
			Name:     cur.Name,
			Path:     cur.Path,
			Size:     cur.Size,
			Apparent: cur.Apparent,
			Files:    cur.Files,
			Dirs:     cur.Dirs,
			Skipped:  cur.Skipped,
			IsDir:    cur.IsDir,
			Hint:     ClassifyNode(cur, parent),
		}
		if (maxDepth > 0 && depth >= maxDepth) || len(cur.Children) == 0 {
			return vn
		}

		var kept []ViewNode
		var otherSize, otherApp uint64
		var otherFiles, otherDirs int64
		var otherCount int

		for _, child := range cur.Children {
			if child.Size == 0 {
				continue
			}
			if child.Size < minBytes && len(cur.Children) > 3 {
				otherSize += child.Size
				otherApp += child.Apparent
				otherFiles += child.Files
				otherDirs += child.Dirs
				otherCount++
				continue
			}
			kept = append(kept, build(child, cur, depth+1))
		}

		if otherCount > 0 {
			if otherCount == 1 {
				// Don't bother wrapping a single item as "Other (1)"
				for _, child := range cur.Children {
					if child.Size > 0 && child.Size < minBytes {
						kept = append(kept, build(child, cur, depth+1))
						break
					}
				}
			} else {
				kept = append(kept, ViewNode{
					Name:      fmt.Sprintf("Other (%d items)", otherCount),
					Path:      cur.Path + "/*",
					Size:      otherSize,
					Apparent:  otherApp,
					Files:     otherFiles,
					Dirs:      otherDirs,
					IsDir:     false,
					IsGrouped: true,
				})
				if depth+1 > deepest {
					deepest = depth + 1
				}
			}
		}

		vn.Children = kept
		return vn
	}

	return build(n, nil, 0), deepest
}
