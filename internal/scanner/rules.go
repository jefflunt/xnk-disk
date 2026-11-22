package scanner

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
)

// CustomRule defines a user-configured rule for recognizing caches or space consumers.
type CustomRule struct {
	Path        string `json:"path,omitempty"`        // Exact path (supports leading "~/")
	Name        string `json:"name,omitempty"`        // Folder name anywhere (e.g. ".turbo")
	Sibling     string `json:"sibling,omitempty"`     // Optional sibling file/dir required for Name match
	Label       string `json:"label,omitempty"`       // Friendly display label (defaults to folder name)
	Safety      string `json:"safety,omitempty"`      // "rebuilds" (default) | "caution"
	Description string `json:"description,omitempty"` // Short tooltip description
}

// CustomRulesConfig is persisted at ~/Library/Application Support/com.jefflunt.xnk-disk/rules.json.
type CustomRulesConfig struct {
	Add    []CustomRule `json:"add"`
	Ignore []string     `json:"ignore"`
}

// DefaultRulesPath returns ~/Library/Application Support/com.jefflunt.xnk-disk/rules.json.
func DefaultRulesPath() string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return ""
	}
	return filepath.Join(home, "Library", "Application Support", "com.jefflunt.xnk-disk", "rules.json")
}

func expandHome(p, home string) string {
	if p == "" {
		return ""
	}
	if home != "" {
		if p == "~" {
			return filepath.Clean(home)
		}
		if strings.HasPrefix(p, "~/") {
			return filepath.Clean(filepath.Join(home, p[2:]))
		}
	}
	return filepath.Clean(p)
}

func collapseHome(p, home string) string {
	clean := filepath.Clean(p)
	if home != "" {
		cleanHome := filepath.Clean(home)
		if clean == cleanHome {
			return "~"
		}
		if strings.HasPrefix(clean, cleanHome+string(filepath.Separator)) {
			return "~/" + strings.TrimPrefix(clean, cleanHome+string(filepath.Separator))
		}
	}
	return clean
}

// LoadCustomRules reads rules.json. If the file does not exist, an empty config is returned.
func LoadCustomRules(path string) (*CustomRulesConfig, error) {
	cfg := &CustomRulesConfig{
		Add:    []CustomRule{},
		Ignore: []string{},
	}
	if path == "" {
		return cfg, nil
	}
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return cfg, nil
		}
		return cfg, err
	}
	if err := json.Unmarshal(data, cfg); err != nil {
		return &CustomRulesConfig{Add: []CustomRule{}, Ignore: []string{}}, err
	}
	if cfg.Add == nil {
		cfg.Add = []CustomRule{}
	}
	if cfg.Ignore == nil {
		cfg.Ignore = []string{}
	}
	return cfg, nil
}

// SaveCustomRules atomically writes pretty-printed JSON to path.
func SaveCustomRules(path string, cfg *CustomRulesConfig) error {
	if path == "" || cfg == nil {
		return nil
	}
	if cfg.Add == nil {
		cfg.Add = []CustomRule{}
	}
	if cfg.Ignore == nil {
		cfg.Ignore = []string{}
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')

	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// EnsureRulesFile creates a clean starter rules.json if it doesn't exist yet.
func EnsureRulesFile(path string) error {
	if path == "" {
		return nil
	}
	if _, err := os.Stat(path); err == nil {
		return nil
	}
	return SaveCustomRules(path, &CustomRulesConfig{
		Add:    []CustomRule{},
		Ignore: []string{},
	})
}

// MarkPathRebuilds adds (or updates) an exact-path "Rebuilds itself" custom rule for targetPath
// and removes targetPath from Ignore if it was previously suppressed.
func (cfg *CustomRulesConfig) MarkPathRebuilds(targetPath, label, home string) {
	if cfg == nil || targetPath == "" {
		return
	}
	targetAbs := expandHome(targetPath, home)
	storedPath := collapseHome(targetAbs, home)
	if label == "" {
		label = filepath.Base(targetAbs)
	}

	// Remove from Ignore if present.
	filteredIgnore := cfg.Ignore[:0]
	for _, ig := range cfg.Ignore {
		if strings.Contains(ig, "/") && expandHome(ig, home) == targetAbs {
			continue
		}
		filteredIgnore = append(filteredIgnore, ig)
	}
	cfg.Ignore = filteredIgnore

	// Update existing Add rule for this path if present.
	for i := range cfg.Add {
		if cfg.Add[i].Path != "" && expandHome(cfg.Add[i].Path, home) == targetAbs {
			cfg.Add[i].Path = storedPath
			cfg.Add[i].Safety = SafetyRebuilds
			if cfg.Add[i].Label == "" {
				cfg.Add[i].Label = label
			}
			return
		}
	}

	cfg.Add = append(cfg.Add, CustomRule{
		Path:        storedPath,
		Label:       label,
		Safety:      SafetyRebuilds,
		Description: "Marked as \"Rebuilds itself\" in your custom rules.",
	})
}

// UnmarkPath removes any custom Add rule for targetPath. If a built-in rule would still
// match targetPath (i.e. hasBuiltin is true), targetPath is added to Ignore so it stays untagged.
func (cfg *CustomRulesConfig) UnmarkPath(targetPath, home string, hasBuiltin bool) {
	if cfg == nil || targetPath == "" {
		return
	}
	targetAbs := expandHome(targetPath, home)
	storedPath := collapseHome(targetAbs, home)

	// Remove any exact-path Add rule.
	filteredAdd := cfg.Add[:0]
	for _, r := range cfg.Add {
		if r.Path != "" && expandHome(r.Path, home) == targetAbs {
			continue
		}
		filteredAdd = append(filteredAdd, r)
	}
	cfg.Add = filteredAdd

	if !hasBuiltin {
		return
	}

	// Add to Ignore if not already ignored.
	for _, ig := range cfg.Ignore {
		if strings.Contains(ig, "/") && expandHome(ig, home) == targetAbs {
			return
		}
	}
	cfg.Ignore = append(cfg.Ignore, storedPath)
}

func ruleToHint(r CustomRule, folderName string) *NodeHint {
	safety := strings.ToLower(strings.TrimSpace(r.Safety))
	tag := TagRebuilds
	desc := r.Description
	if safety == SafetyCaution {
		tag = TagCaution
		if desc == "" {
			desc = "Marked as \"May hold your data\" in your custom rules."
		}
	} else {
		safety = SafetyRebuilds
		if desc == "" {
			desc = "Marked as \"Rebuilds itself\" in your custom rules."
		}
	}
	label := strings.TrimSpace(r.Label)
	if label == "" {
		label = folderName
	}
	return &NodeHint{
		Label:       label,
		Tag:         tag,
		Safety:      safety,
		Description: desc,
		Custom:      true,
	}
}

// ClassifyNodeWithRules evaluates user-configured rules first (Ignore, then Add),
// falling back to the built-in macOS developer cache rules.
func ClassifyNodeWithRules(cur, parent *Node, cfg *CustomRulesConfig) *NodeHint {
	return classifyNodeWithRulesHome(cur, parent, cfg, "")
}

func classifyNodeWithRulesHome(cur, parent *Node, cfg *CustomRulesConfig, homeOverride string) *NodeHint {
	if cur == nil || !cur.IsDir {
		return nil
	}

	if cfg != nil && (len(cfg.Ignore) > 0 || len(cfg.Add) > 0) {
		home := homeOverride
		if home == "" {
			home, _ = os.UserHomeDir()
		}
		p := filepath.Clean(cur.Path)

		// 1. Check Ignore list (suppresses both custom name rules and built-in rules).
		for _, ig := range cfg.Ignore {
			ig = strings.TrimSpace(ig)
			if ig == "" {
				continue
			}
			if strings.Contains(ig, "/") || ig == "~" {
				if expandHome(ig, home) == p {
					return nil
				}
			} else if cur.Name == ig {
				return nil
			}
		}

		// 2. Check exact-path custom rules first.
		for _, r := range cfg.Add {
			if r.Path != "" && expandHome(r.Path, home) == p {
				return ruleToHint(r, cur.Name)
			}
		}

		// 3. Check folder-name custom rules (with optional sibling check).
		for _, r := range cfg.Add {
			if r.Name != "" && cur.Name == r.Name {
				if r.Sibling == "" || hasSibling(cur, parent, r.Sibling) {
					return ruleToHint(r, cur.Name)
				}
			}
		}
	}

	// 4. Fall back to built-in rules.
	return ClassifyNode(cur, parent)
}
