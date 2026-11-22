package scanner

import "testing"

func TestClassifyNode_UserPaths(t *testing.T) {
	cases := []struct {
		path       string
		wantLabel  string
		wantSafety string
		wantTag    string
	}{
		{"/Users/alice/Library/Developer/Xcode/DerivedData", "Xcode Build Cache", SafetyRebuilds, TagRebuilds},
		{"/Users/bob/Library/Developer/CoreSimulator", "iOS Simulators", SafetyCaution, TagCaution},
		{"/Users/bob/Library/Developer/CoreSimulator/Caches", "Simulator Caches", SafetyRebuilds, TagRebuilds},
		{"/Users/alice/Library/Caches/Homebrew", "Homebrew Download Cache", SafetyRebuilds, TagRebuilds},
		{"/Users/alice/go/pkg/mod", "Go Module Cache", SafetyRebuilds, TagRebuilds},
		{"/Users/alice/.npm", "npm Cache", SafetyRebuilds, TagRebuilds},
		{"/Users/alice/.cargo/registry", "Cargo Crate Cache", SafetyRebuilds, TagRebuilds},
		{"/Users/alice/.gradle/caches", "Gradle Build Cache", SafetyRebuilds, TagRebuilds},
		{"/Users/alice/Library/Containers/com.docker.docker/Data/vms", "Docker Desktop Disk Image", SafetyCaution, TagCaution},
		{"/Users/alice/Library/Application Support/MobileSync/Backup", "iOS Device Backups", SafetyCaution, TagCaution},
	}

	for _, tc := range cases {
		node := &Node{Name: "dir", Path: tc.path, IsDir: true}
		got := ClassifyNode(node, nil)
		if got == nil {
			t.Fatalf("ClassifyNode(%q) = nil, want %q", tc.path, tc.wantLabel)
		}
		if got.Label != tc.wantLabel || got.Safety != tc.wantSafety || got.Tag != tc.wantTag {
			t.Errorf("ClassifyNode(%q) = %+v, want label=%q safety=%q tag=%q",
				tc.path, got, tc.wantLabel, tc.wantSafety, tc.wantTag)
		}
	}
}

func TestClassifyNode_ProjectFoldersAndSiblingChecks(t *testing.T) {
	// Top-level node_modules matches; nested node_modules inside node_modules does not.
	topNM := &Node{Name: "node_modules", Path: "/Users/alice/code/app/node_modules", IsDir: true}
	if h := ClassifyNode(topNM, nil); h == nil || h.Safety != SafetyRebuilds {
		t.Fatalf("expected top-level node_modules to match rebuilds, got %+v", h)
	}
	nestedNM := &Node{Name: "node_modules", Path: "/Users/alice/code/app/node_modules/pkg/node_modules", IsDir: true}
	if h := ClassifyNode(nestedNM, nil); h != nil {
		t.Fatalf("expected nested node_modules to return nil, got %+v", h)
	}

	// Rust target/ only matches when sibling Cargo.toml exists.
	rustTarget := &Node{Name: "target", Path: "/Users/alice/code/rustapp/target", IsDir: true}
	rustParent := &Node{
		Name: "rustapp", Path: "/Users/alice/code/rustapp", IsDir: true,
		Children: []*Node{
			rustTarget,
			{Name: "Cargo.toml", Path: "/Users/alice/code/rustapp/Cargo.toml", IsDir: false},
		},
	}
	if h := ClassifyNode(rustTarget, rustParent); h == nil || h.Label != "Rust Build Artifacts" {
		t.Fatalf("expected Rust Build Artifacts, got %+v", h)
	}

	// Generic folder named "target" without Cargo.toml or pom.xml must NOT match.
	plainTarget := &Node{Name: "target", Path: "/Users/alice/Documents/target", IsDir: true}
	plainParent := &Node{
		Name: "Documents", Path: "/Users/alice/Documents", IsDir: true,
		Children: []*Node{plainTarget},
	}
	if h := ClassifyNode(plainTarget, plainParent); h != nil {
		t.Fatalf("expected plain target folder to return nil, got %+v", h)
	}

	// Pods only matches when Podfile or Podfile.lock is a sibling.
	pods := &Node{Name: "Pods", Path: "/Users/alice/code/ios/Pods", IsDir: true}
	iosParent := &Node{
		Name: "ios", Path: "/Users/alice/code/ios", IsDir: true,
		Children: []*Node{
			pods,
			{Name: "Podfile", Path: "/Users/alice/code/ios/Podfile", IsDir: false},
		},
	}
	if h := ClassifyNode(pods, iosParent); h == nil || h.Label != "CocoaPods Dependencies" {
		t.Fatalf("expected CocoaPods Dependencies, got %+v", h)
	}
	unrelatedPods := &Node{Name: "Pods", Path: "/Users/alice/Photos/Pods", IsDir: true}
	photosParent := &Node{Name: "Photos", Path: "/Users/alice/Photos", IsDir: true, Children: []*Node{unrelatedPods}}
	if h := ClassifyNode(unrelatedPods, photosParent); h != nil {
		t.Fatalf("expected unrelated Pods folder to return nil, got %+v", h)
	}
}

func TestProjectView_AttachesHints(t *testing.T) {
	derived := &Node{
		Name:  "DerivedData",
		Path:  "/Users/alice/Library/Developer/Xcode/DerivedData",
		Size:  5000,
		IsDir: true,
	}
	xcode := &Node{
		Name:     "Xcode",
		Path:     "/Users/alice/Library/Developer/Xcode",
		Size:     5000,
		IsDir:    true,
		Children: []*Node{derived},
	}

	view, _ := ProjectView(xcode, 5, false, 5000)
	if len(view.Children) != 1 {
		t.Fatalf("expected 1 child, got %d", len(view.Children))
	}
	if view.Children[0].Hint == nil {
		t.Fatalf("expected Hint on DerivedData ViewNode, got nil")
	}
	if view.Children[0].Hint.Label != "Xcode Build Cache" || view.Children[0].Hint.Tag != TagRebuilds {
		t.Fatalf("unexpected Hint: %+v", view.Children[0].Hint)
	}
}
