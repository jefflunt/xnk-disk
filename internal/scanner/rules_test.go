package scanner

import (
	"path/filepath"
	"testing"
)

func TestCustomRules_SaveLoadAndClassify(t *testing.T) {
	tmp := t.TempDir()
	rulesPath := filepath.Join(tmp, "rules.json")
	home := "/Users/alice"

	// Missing file loads as empty config without error.
	cfg, err := LoadCustomRules(rulesPath)
	if err != nil {
		t.Fatalf("LoadCustomRules missing file error: %v", err)
	}
	if len(cfg.Add) != 0 || len(cfg.Ignore) != 0 {
		t.Fatalf("expected empty config, got %+v", cfg)
	}

	// Mark a custom path as rebuilds.
	cfg.MarkPathRebuilds("/Users/alice/Movies/RenderCache", "Render Cache", home)
	// Add a folder-name rule with sibling check.
	cfg.Add = append(cfg.Add, CustomRule{
		Name:    "build",
		Sibling: "CMakeLists.txt",
		Label:   "CMake Build",
		Safety:  SafetyRebuilds,
	})
	// Suppress a built-in rule.
	cfg.UnmarkPath("/Users/alice/Library/Logs", home, true)

	if err := SaveCustomRules(rulesPath, cfg); err != nil {
		t.Fatalf("SaveCustomRules: %v", err)
	}

	loaded, err := LoadCustomRules(rulesPath)
	if err != nil {
		t.Fatalf("LoadCustomRules reload: %v", err)
	}

	// 1. Custom exact path matches and collapses to ~/ on save.
	if loaded.Add[0].Path != "~/Movies/RenderCache" {
		t.Errorf("expected ~/Movies/RenderCache, got %q", loaded.Add[0].Path)
	}
	renderNode := &Node{Name: "RenderCache", Path: "/Users/alice/Movies/RenderCache", IsDir: true}
	h := classifyNodeWithRulesHome(renderNode, nil, loaded, home)
	if h == nil || !h.Custom || h.Safety != SafetyRebuilds || h.Label != "Render Cache" {
		t.Fatalf("expected custom rebuilds hint for RenderCache, got %+v", h)
	}

	// 2. Sibling-checked custom name rule matches only when sibling exists.
	cmakeBuild := &Node{Name: "build", Path: "/Users/alice/code/cpp/build", IsDir: true}
	cppParent := &Node{
		Name: "cpp", Path: "/Users/alice/code/cpp", IsDir: true,
		Children: []*Node{
			cmakeBuild,
			{Name: "CMakeLists.txt", Path: "/Users/alice/code/cpp/CMakeLists.txt"},
		},
	}
	h2 := classifyNodeWithRulesHome(cmakeBuild, cppParent, loaded, home)
	if h2 == nil || h2.Label != "CMake Build" || !h2.Custom {
		t.Fatalf("expected CMake Build hint, got %+v", h2)
	}

	plainBuild := &Node{Name: "build", Path: "/Users/alice/Notes/build", IsDir: true}
	notesParent := &Node{Name: "Notes", Path: "/Users/alice/Notes", IsDir: true, Children: []*Node{plainBuild}}
	if h3 := classifyNodeWithRulesHome(plainBuild, notesParent, loaded, home); h3 != nil {
		t.Fatalf("expected nil for build without CMakeLists.txt, got %+v", h3)
	}

	// 3. Ignored built-in path returns nil.
	logsNode := &Node{Name: "Logs", Path: "/Users/alice/Library/Logs", IsDir: true}
	if h4 := classifyNodeWithRulesHome(logsNode, nil, loaded, home); h4 != nil {
		t.Fatalf("expected ignored Library/Logs to return nil, got %+v", h4)
	}

	// 4. Re-marking an ignored built-in path removes it from Ignore and marks it rebuilds.
	loaded.MarkPathRebuilds("/Users/alice/Library/Logs", "App Logs", home)
	if h5 := classifyNodeWithRulesHome(logsNode, nil, loaded, home); h5 == nil || h5.Safety != SafetyRebuilds {
		t.Fatalf("expected re-marked Library/Logs to be rebuilds, got %+v", h5)
	}

	// 5. Unmarking a non-builtin custom path removes it cleanly without adding to Ignore.
	loaded.UnmarkPath("/Users/alice/Movies/RenderCache", home, false)
	if h6 := classifyNodeWithRulesHome(renderNode, nil, loaded, home); h6 != nil {
		t.Fatalf("expected unmarked RenderCache to return nil, got %+v", h6)
	}
}
