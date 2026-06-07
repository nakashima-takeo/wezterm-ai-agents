package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/mark3labs/mcp-go/mcp"
	"github.com/mark3labs/mcp-go/server"
)

type WorktreeInfo struct {
	Path   string `json:"path"`
	Head   string `json:"head"`
	Branch string `json:"branch"`
	Bare   bool   `json:"bare,omitempty"`
}

func parseWorktreeList(output string) []WorktreeInfo {
	var result []WorktreeInfo
	var current WorktreeInfo

	scanner := bufio.NewScanner(strings.NewReader(output))
	for scanner.Scan() {
		line := scanner.Text()
		switch {
		case strings.HasPrefix(line, "worktree "):
			if current.Path != "" {
				result = append(result, current)
			}
			current = WorktreeInfo{Path: strings.TrimPrefix(line, "worktree ")}
		case strings.HasPrefix(line, "HEAD "):
			current.Head = strings.TrimPrefix(line, "HEAD ")
		case strings.HasPrefix(line, "branch "):
			branch := strings.TrimPrefix(line, "branch ")
			current.Branch = strings.TrimPrefix(branch, "refs/heads/")
		case line == "bare":
			current.Bare = true
		}
	}
	if current.Path != "" {
		result = append(result, current)
	}
	return result
}

func gitRoot(cwd string) (string, error) {
	cmd := exec.Command("git", "-C", cwd, "rev-parse", "--show-toplevel")
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("not a git repository: %s", cwd)
	}
	return strings.TrimSpace(string(out)), nil
}

func registerWorktreeTools(s *server.MCPServer) {
	s.AddTool(
		mcp.NewTool("list_worktrees",
			mcp.WithDescription("List git worktrees for a repository"),
			mcp.WithString("cwd",
				mcp.Required(),
				mcp.Description("Path to the git repository"),
			),
		),
		func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			cwd, _ := req.RequireString("cwd")

			root, err := gitRoot(cwd)
			if err != nil {
				return mcp.NewToolResultError(err.Error()), nil
			}

			cmd := exec.Command("git", "-C", root, "worktree", "list", "--porcelain")
			out, err := cmd.Output()
			if err != nil {
				return mcp.NewToolResultError(fmt.Sprintf("git worktree list failed: %v", err)), nil
			}

			trees := parseWorktreeList(string(out))
			data, _ := json.MarshalIndent(trees, "", "  ")
			return mcp.NewToolResultText(string(data)), nil
		},
	)

	s.AddTool(
		mcp.NewTool("add_worktree",
			mcp.WithDescription("Create a new git worktree. If path is omitted, creates a sibling directory named after the branch."),
			mcp.WithString("cwd",
				mcp.Required(),
				mcp.Description("Path to the git repository"),
			),
			mcp.WithString("branch",
				mcp.Required(),
				mcp.Description("Branch name for the worktree"),
			),
			mcp.WithString("path",
				mcp.Description("Path for the worktree directory. Defaults to sibling of repo root named after the branch."),
			),
			mcp.WithBoolean("new_branch",
				mcp.Description("Create a new branch (git worktree add -b). Default: false"),
			),
			mcp.WithString("source",
				mcp.Description("Source branch/commit to base the new worktree on"),
			),
		),
		func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			cwd, _ := req.RequireString("cwd")
			branch, _ := req.RequireString("branch")
			wtPath := req.GetString("path", "")
			newBranch := req.GetBool("new_branch", false)
			source := req.GetString("source", "")

			root, err := gitRoot(cwd)
			if err != nil {
				return mcp.NewToolResultError(err.Error()), nil
			}

			if wtPath == "" {
				safeBranch := strings.ReplaceAll(branch, "/", "-")
				wtPath = filepath.Join(filepath.Dir(root), safeBranch)
			}

			// Reject leading-hyphen branch names: with -b they would be parsed as git options.
			// Positional paths/branches are guarded with "--" instead (mirrors plugin/service/worktree/init.lua).
			if newBranch && strings.HasPrefix(branch, "-") {
				return mcp.NewToolResultError(fmt.Sprintf("invalid branch name: %q", branch)), nil
			}

			args := []string{"-C", root, "worktree", "add"}
			if newBranch {
				args = append(args, "-b", branch)
				if source != "" {
					args = append(args, "--", wtPath, source)
				} else {
					args = append(args, "--", wtPath)
				}
			} else {
				args = append(args, "--", wtPath, branch)
			}

			cmd := exec.Command("git", args...)
			out, err := cmd.CombinedOutput()
			if err != nil {
				return mcp.NewToolResultError(fmt.Sprintf("git worktree add failed: %s", strings.TrimSpace(string(out)))), nil
			}

			return mcp.NewToolResultText(fmt.Sprintf("Worktree created at %s for branch %s", wtPath, branch)), nil
		},
	)

	s.AddTool(
		mcp.NewTool("remove_worktree",
			mcp.WithDescription("Remove a git worktree"),
			mcp.WithString("path",
				mcp.Required(),
				mcp.Description("Path of the worktree to remove"),
			),
			mcp.WithBoolean("force",
				mcp.Description("Force removal even if there are uncommitted changes. Default: false"),
			),
		),
		func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			wtPath, _ := req.RequireString("path")
			force := req.GetBool("force", false)

			// Resolve the repository root from the worktree path itself so removal does not depend
			// on the MCP server process cwd (which is undefined under stdio launch).
			root, err := gitRoot(wtPath)
			if err != nil {
				return mcp.NewToolResultError(err.Error()), nil
			}

			args := []string{"-C", root, "worktree", "remove"}
			if force {
				args = append(args, "--force")
			}
			args = append(args, "--", wtPath)

			cmd := exec.Command("git", args...)
			out, err := cmd.CombinedOutput()
			if err != nil {
				return mcp.NewToolResultError(fmt.Sprintf("git worktree remove failed: %s", strings.TrimSpace(string(out)))), nil
			}

			return mcp.NewToolResultText(fmt.Sprintf("Worktree removed: %s", wtPath)), nil
		},
	)
}
