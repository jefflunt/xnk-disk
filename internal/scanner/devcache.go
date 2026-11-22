package scanner

import (
	"os"
	"path/filepath"
	"strings"
)

// Safety constants for NodeHint.Safety.
const (
	SafetyRebuilds = "rebuilds" // Pure cache or build artifacts that regenerate automatically
	SafetyCaution  = "caution"  // Known space consumer that may hold user data or large downloads
)

// Tag labels using cautious, honest phrasing.
const (
	TagRebuilds = "Rebuilds itself"
	TagCaution  = "May hold your data"
)

// NodeHint annotates a recognized macOS developer cache or known space consumer.
type NodeHint struct {
	Label       string `json:"label"`
	Tag         string `json:"tag"`
	Safety      string `json:"safety"`
	Description string `json:"description"`
}

type pathRule struct {
	relSuffix string // Suffix relative to /Users/<user>/ (e.g. "Library/Developer/Xcode/DerivedData")
	hint      NodeHint
}

// userPathRules matches well-known macOS developer caches and space consumers under /Users/<user>/.
var userPathRules = []pathRule{
	{
		relSuffix: "Library/Developer/Xcode/DerivedData",
		hint: NodeHint{
			Label:       "Xcode Build Cache",
			Tag:         TagRebuilds,
			Safety:      SafetyRebuilds,
			Description: "Intermediate build artifacts and indexes; Xcode regenerates these on next build.",
		},
	},
	{
		relSuffix: "Library/Developer/Xcode/iOS DeviceSupport",
		hint: NodeHint{
			Label:       "Xcode iOS Device Symbols",
			Tag:         TagRebuilds,
			Safety:      SafetyRebuilds,
			Description: "Debug symbols copied from connected iOS devices; Xcode re-downloads them if needed.",
		},
	},
	{
		relSuffix: "Library/Developer/Xcode/watchOS DeviceSupport",
		hint: NodeHint{
			Label:       "Xcode watchOS Device Symbols",
			Tag:         TagRebuilds,
			Safety:      SafetyRebuilds,
			Description: "Debug symbols for connected Apple Watch devices; re-downloaded if needed.",
		},
	},
	{
		relSuffix: "Library/Developer/Xcode/tvOS DeviceSupport",
		hint: NodeHint{
			Label:       "Xcode tvOS Device Symbols",
			Tag:         TagRebuilds,
			Safety:      SafetyRebuilds,
			Description: "Debug symbols for connected Apple TV devices; re-downloaded if needed.",
		},
	},
	{
		relSuffix: "Library/Developer/Xcode/visionOS DeviceSupport",
		hint: NodeHint{
			Label:       "Xcode visionOS Device Symbols",
			Tag:         TagRebuilds,
			Safety:      SafetyRebuilds,
			Description: "Debug symbols for connected Vision Pro devices; re-downloaded if needed.",
		},
	},
	{
		relSuffix: "Library/Developer/Xcode/Archives",
		hint: NodeHint{
			Label:       "Xcode App Archives",
			Tag:         TagCaution,
			Safety:      SafetyCaution,
			Description: "Archived app builds and dSYMs used for App Store distribution and crash symbolication.",
		},
	},
	{
		relSuffix: "Library/Developer/CoreSimulator",
		hint: NodeHint{
			Label:       "iOS Simulators",
			Tag:         TagCaution,
			Safety:      SafetyCaution,
			Description: "Simulator devices and app state; deleting removes simulated data and may require re-downloading runtimes.",
		},
	},
	{
		relSuffix: "Library/Developer/CoreSimulator/Caches",
		hint: NodeHint{
			Label:       "Simulator Caches",
			Tag:         TagRebuilds,
			Safety:      SafetyRebuilds,
			Description: "Cached simulator runtime images and dyld caches; recreated automatically.",
		},
	},
	{
		relSuffix: "Library/Caches/Homebrew",
		hint: NodeHint{
			Label:       "Homebrew Download Cache",
			Tag:         TagRebuilds,
			Safety:      SafetyRebuilds,
			Description: "Downloaded formula bottles and casks; Homebrew re-downloads them when needed.",
		},
	},
	{
		relSuffix: "Library/Caches/CocoaPods",
		hint: NodeHint{
			Label:       "CocoaPods Cache",
			Tag:         TagRebuilds,
			Safety:      SafetyRebuilds,
			Description: "Cached CocoaPods specs and archives; re-downloaded on pod install.",
		},
	},
	{
		relSuffix: "Library/Caches/com.apple.dt.Xcode",
		hint: NodeHint{
			Label:       "Xcode Caches",
			Tag:         TagRebuilds,
			Safety:      SafetyRebuilds,
			Description: "Xcode internal caches; regenerated automatically.",
		},
	},
	{
		relSuffix: "Library/Caches/org.swift.swiftpm",
		hint: NodeHint{
			Label:       "SwiftPM Cache",
			Tag:         TagRebuilds,
			Safety:      SafetyRebuilds,
			Description: "Cached Swift Package Manager repositories; re-fetched on build.",
		},
	},
	{
		relSuffix: "Library/Caches/pip",
		hint: NodeHint{
			Label:       "pip Package Cache",
			Tag:         TagRebuilds,
			Safety:      SafetyRebuilds,
			Description: "Cached Python wheels and packages; re-downloaded on pip install.",
		},
	},
	{
		relSuffix: "Library/Caches/uv",
		hint: NodeHint{
			Label:       "uv Package Cache",
			Tag:         TagRebuilds,
			Safety:      SafetyRebuilds,
			Description: "Cached Python packages and wheels managed by uv; re-downloaded as needed.",
		},
	},
	{
		relSuffix: "Library/Caches/Yarn",
		hint: NodeHint{
			Label:       "Yarn Package Cache",
			Tag:         TagRebuilds,
			Safety:      SafetyRebuilds,
			Description: "Cached JavaScript packages; Yarn re-downloads them on install.",
		},
	},
	{
		relSuffix: "Library/Caches/pnpm",
		hint: NodeHint{
			Label:       "pnpm Cache",
			Tag:         TagRebuilds,
			Safety:      SafetyRebuilds,
			Description: "Cached pnpm metadata and packages; re-downloaded on install.",
		},
	},
	{
		relSuffix: "Library/pnpm/store",
		hint: NodeHint{
			Label:       "pnpm Package Store",
			Tag:         TagRebuilds,
			Safety:      SafetyRebuilds,
			Description: "Content-addressable pnpm package store; re-downloaded on pnpm install.",
		},
	},
	{
		relSuffix: "Library/Caches/go-build",
		hint: NodeHint{
			Label:       "Go Build Cache",
			Tag:         TagRebuilds,
			Safety:      SafetyRebuilds,
			Description: "Compiled Go build cache; regenerated automatically on go build or test.",
		},
	},
	{
		relSuffix: "Library/Caches/JetBrains",
		hint: NodeHint{
			Label:       "JetBrains IDE Caches",
			Tag:         TagRebuilds,
			Safety:      SafetyRebuilds,
			Description: "IDE indexes and caches; JetBrains IDEs rebuild these on next launch.",
		},
	},
	{
		relSuffix: "Library/Caches",
		hint: NodeHint{
			Label:       "macOS App Caches",
			Tag:         TagCaution,
			Safety:      SafetyCaution,
			Description: "App cache directories; most subfolders rebuild, though active apps may need a restart.",
		},
	},
	{
		relSuffix: "Library/Logs",
		hint: NodeHint{
			Label:       "macOS App Logs",
			Tag:         TagRebuilds,
			Safety:      SafetyRebuilds,
			Description: "Diagnostic and application log files; recreated as apps run.",
		},
	},
	{
		relSuffix: "Library/Containers/com.docker.docker/Data/vms",
		hint: NodeHint{
			Label:       "Docker Desktop Disk Image",
			Tag:         TagCaution,
			Safety:      SafetyCaution,
			Description: "Stores Docker images, containers, and volumes; deleting removes local container data.",
		},
	},
	{
		relSuffix: "Library/Application Support/MobileSync/Backup",
		hint: NodeHint{
			Label:       "iOS Device Backups",
			Tag:         TagCaution,
			Safety:      SafetyCaution,
			Description: "Local iPhone and iPad backups; deleting permanently removes those backups.",
		},
	},
	{
		relSuffix: "go/pkg/mod",
		hint: NodeHint{
			Label:       "Go Module Cache",
			Tag:         TagRebuilds,
			Safety:      SafetyRebuilds,
			Description: "Downloaded Go module dependencies; re-fetched on next build.",
		},
	},
	{
		relSuffix: ".npm",
		hint: NodeHint{
			Label:       "npm Cache",
			Tag:         TagRebuilds,
			Safety:      SafetyRebuilds,
			Description: "Cached npm tarballs and metadata; npm re-downloads packages as needed.",
		},
	},
	{
		relSuffix: ".bun/install/cache",
		hint: NodeHint{
			Label:       "Bun Package Cache",
			Tag:         TagRebuilds,
			Safety:      SafetyRebuilds,
			Description: "Cached Bun packages; re-downloaded on bun install.",
		},
	},
	{
		relSuffix: ".cargo/registry",
		hint: NodeHint{
			Label:       "Cargo Crate Cache",
			Tag:         TagRebuilds,
			Safety:      SafetyRebuilds,
			Description: "Downloaded Rust crates; Cargo re-downloads them on next build.",
		},
	},
	{
		relSuffix: ".cargo/git",
		hint: NodeHint{
			Label:       "Cargo Git Cache",
			Tag:         TagRebuilds,
			Safety:      SafetyRebuilds,
			Description: "Checked-out Rust git dependencies; Cargo re-fetches them on next build.",
		},
	},
	{
		relSuffix: ".gradle/caches",
		hint: NodeHint{
			Label:       "Gradle Build Cache",
			Tag:         TagRebuilds,
			Safety:      SafetyRebuilds,
			Description: "Cached Gradle dependencies and build outputs; re-downloaded on next build.",
		},
	},
	{
		relSuffix: ".m2/repository",
		hint: NodeHint{
			Label:       "Maven Repository Cache",
			Tag:         TagRebuilds,
			Safety:      SafetyRebuilds,
			Description: "Local Maven artifact cache; re-downloaded on next build.",
		},
	},
	{
		relSuffix: ".cache/huggingface",
		hint: NodeHint{
			Label:       "Hugging Face Model Cache",
			Tag:         TagRebuilds,
			Safety:      SafetyRebuilds,
			Description: "Downloaded ML models and datasets; re-downloadable when needed.",
		},
	},
	{
		relSuffix: ".ollama/models",
		hint: NodeHint{
			Label:       "Ollama Local Models",
			Tag:         TagCaution,
			Safety:      SafetyCaution,
			Description: "Local LLM model weights; re-downloadable, though custom Modelfiles may depend on them.",
		},
	},
}

// userPathIndex maps normalized user-relative paths to their NodeHint for O(1) lookup.
var userPathIndex = func() map[string]NodeHint {
	m := make(map[string]NodeHint, len(userPathRules))
	for _, r := range userPathRules {
		m[r.relSuffix] = r.hint
	}
	return m
}()

// userRelativePath extracts the path relative to /Users/<username>/ if p is inside a user home directory.
// Returns ("", false) if p is not under /Users/<username>/<something>.
func userRelativePath(p string) (string, bool) {
	if !strings.HasPrefix(p, "/Users/") {
		return "", false
	}
	rest := p[len("/Users/"):]
	idx := strings.IndexByte(rest, '/')
	if idx <= 0 || idx+1 >= len(rest) {
		return "", false
	}
	return rest[idx+1:], true
}

// hasSibling checks whether any of the named sibling files/dirs exist alongside cur.
// If parent is available in the scanned tree, it checks parent.Children in memory (zero I/O).
// Otherwise (when cur is the zoomed-in root), it falls back to a lightweight os.Stat check.
func hasSibling(cur, parent *Node, names ...string) bool {
	if parent != nil {
		for _, c := range parent.Children {
			for _, want := range names {
				if c.Name == want {
					return true
				}
			}
		}
		return false
	}
	dir := filepath.Dir(cur.Path)
	if dir == "" || dir == cur.Path {
		return false
	}
	for _, want := range names {
		if _, err := os.Stat(filepath.Join(dir, want)); err == nil {
			return true
		}
	}
	return false
}

// ClassifyNode inspects a directory node (and optionally its parent for sibling context)
// and returns a NodeHint if it matches a well-known macOS developer cache or space consumer.
func ClassifyNode(cur, parent *Node) *NodeHint {
	if cur == nil || !cur.IsDir {
		return nil
	}

	p := filepath.Clean(cur.Path)

	// 1. Exact user-home relative path match (highest confidence).
	if rel, ok := userRelativePath(p); ok {
		if hint, found := userPathIndex[rel]; found {
			h := hint
			return &h
		}
	}

	// 2. High-confidence folder-name matches (project-level caches & build directories).
	switch cur.Name {
	case "node_modules":
		// Avoid re-tagging nested node_modules inside an already-tagged node_modules tree.
		parentDir := filepath.Dir(p)
		if strings.Contains(parentDir, "/node_modules/") || strings.HasSuffix(parentDir, "/node_modules") {
			return nil
		}
		return &NodeHint{
			Label:       "Node.js Dependencies",
			Tag:         TagRebuilds,
			Safety:      SafetyRebuilds,
			Description: "Installed npm, Yarn, or pnpm packages; re-run package install to restore.",
		}

	case "DerivedData":
		return &NodeHint{
			Label:       "Xcode Build Cache",
			Tag:         TagRebuilds,
			Safety:      SafetyRebuilds,
			Description: "Intermediate Xcode build artifacts; regenerated on next build.",
		}

	case "Pods":
		if hasSibling(cur, parent, "Podfile", "Podfile.lock") {
			return &NodeHint{
				Label:       "CocoaPods Dependencies",
				Tag:         TagRebuilds,
				Safety:      SafetyRebuilds,
				Description: "Installed CocoaPods libraries; re-run pod install to restore.",
			}
		}

	case ".next":
		if hasSibling(cur, parent, "package.json") {
			return &NodeHint{
				Label:       "Next.js Build Cache",
				Tag:         TagRebuilds,
				Safety:      SafetyRebuilds,
				Description: "Next.js compiled build output and cache; regenerated on next dev or build.",
			}
		}

	case "target":
		if hasSibling(cur, parent, "Cargo.toml") {
			return &NodeHint{
				Label:       "Rust Build Artifacts",
				Tag:         TagRebuilds,
				Safety:      SafetyRebuilds,
				Description: "Cargo compiled targets and incremental cache; regenerated on next cargo build.",
			}
		}
		if hasSibling(cur, parent, "pom.xml") {
			return &NodeHint{
				Label:       "Maven Build Output",
				Tag:         TagRebuilds,
				Safety:      SafetyRebuilds,
				Description: "Compiled Maven build directory; regenerated on next mvn build.",
			}
		}

	case ".venv", "venv":
		if cur.Name == ".venv" || hasSibling(cur, parent, "pyproject.toml", "requirements.txt", "setup.py") {
			return &NodeHint{
				Label:       "Python Virtual Environment",
				Tag:         TagRebuilds,
				Safety:      SafetyRebuilds,
				Description: "Local Python virtualenv packages; recreate from pyproject.toml or requirements.txt.",
			}
		}

	case ".gradle":
		if hasSibling(cur, parent, "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts") {
			return &NodeHint{
				Label:       "Project Gradle Cache",
				Tag:         TagRebuilds,
				Safety:      SafetyRebuilds,
				Description: "Local project Gradle cache; regenerated on next Gradle build.",
			}
		}
	}

	return nil
}
