package main

import "testing"

func TestParseWorktreeList(t *testing.T) {
	input := `worktree /Users/test/repo
HEAD abc123def456
branch refs/heads/main

worktree /Users/test/repo-feature
HEAD def789abc012
branch refs/heads/feature/login

worktree /Users/test/bare-repo
HEAD 000000000000
bare

`

	trees := parseWorktreeList(input)

	if len(trees) != 3 {
		t.Fatalf("expected 3 worktrees, got %d", len(trees))
	}

	tests := []struct {
		idx    int
		path   string
		head   string
		branch string
		bare   bool
	}{
		{0, "/Users/test/repo", "abc123def456", "main", false},
		{1, "/Users/test/repo-feature", "def789abc012", "feature/login", false},
		{2, "/Users/test/bare-repo", "000000000000", "", true},
	}

	for _, tt := range tests {
		wt := trees[tt.idx]
		if wt.Path != tt.path {
			t.Errorf("[%d] path = %q, want %q", tt.idx, wt.Path, tt.path)
		}
		if wt.Head != tt.head {
			t.Errorf("[%d] head = %q, want %q", tt.idx, wt.Head, tt.head)
		}
		if wt.Branch != tt.branch {
			t.Errorf("[%d] branch = %q, want %q", tt.idx, wt.Branch, tt.branch)
		}
		if wt.Bare != tt.bare {
			t.Errorf("[%d] bare = %v, want %v", tt.idx, wt.Bare, tt.bare)
		}
	}
}

func TestParseWorktreeListEmpty(t *testing.T) {
	trees := parseWorktreeList("")
	if len(trees) != 0 {
		t.Errorf("expected 0 worktrees, got %d", len(trees))
	}
}
