package main

import (
	"strings"
	"testing"
)

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

func TestWorktreeAddArgsRejectsLeadingHyphenBranch(t *testing.T) {
	// 新規ブランチ作成時、先頭ハイフン名は git のオプションと誤解釈されるため拒否する。
	if _, err := worktreeAddArgs("/repo", "-rf", "/repo/wt", "", true); err == nil {
		t.Fatal("expected error for leading-hyphen branch with new_branch, got nil")
	}
	// 既存ブランチ (newBranch=false) は -- の後の位置引数なので拒否しない。
	if _, err := worktreeAddArgs("/repo", "-weird", "/repo/wt", "", false); err != nil {
		t.Errorf("did not expect error for existing branch, got %v", err)
	}
}

func TestWorktreeAddArgs(t *testing.T) {
	tests := []struct {
		name      string
		branch    string
		wtPath    string
		source    string
		newBranch bool
		want      []string
	}{
		{
			name: "existing branch (no -b, branch after --)",
			branch: "feature", wtPath: "/repo/wt", newBranch: false,
			want: []string{"-C", "/repo", "worktree", "add", "--", "/repo/wt", "feature"},
		},
		{
			name: "new branch without source",
			branch: "feature", wtPath: "/repo/wt", newBranch: true,
			want: []string{"-C", "/repo", "worktree", "add", "-b", "feature", "--", "/repo/wt"},
		},
		{
			name: "new branch with source",
			branch: "feature", wtPath: "/repo/wt", source: "main", newBranch: true,
			want: []string{"-C", "/repo", "worktree", "add", "-b", "feature", "--", "/repo/wt", "main"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := worktreeAddArgs("/repo", tt.branch, tt.wtPath, tt.source, tt.newBranch)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if strings.Join(got, "\x00") != strings.Join(tt.want, "\x00") {
				t.Errorf("args = %v, want %v", got, tt.want)
			}
		})
	}
}
