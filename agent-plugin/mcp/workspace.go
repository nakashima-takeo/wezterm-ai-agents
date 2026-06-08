package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"

	"github.com/mark3labs/mcp-go/mcp"
	"github.com/mark3labs/mcp-go/server"
)

type WorkspaceData struct {
	Workspaces []Workspace `json:"workspaces"`
}

type Workspace struct {
	Name     string `json:"name"`
	Cwd      string `json:"cwd"`
	LastUsed int64  `json:"lastUsed,omitempty"`
	Tabs     []Tab  `json:"tabs,omitempty"`
}

type Tab struct {
	Agent     string       `json:"agent,omitempty"`
	SessionID string       `json:"session_id,omitempty"`
	Cwd       string       `json:"cwd,omitempty"`
	Layout    []LayoutItem `json:"layout,omitempty"`
}

type LayoutItem struct {
	Split string `json:"split"`
	Pane  int    `json:"pane"`
}

func readWorkspaces(path string) (*WorkspaceData, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var ws WorkspaceData
	if err := json.Unmarshal(data, &ws); err != nil {
		return nil, err
	}
	return &ws, nil
}

func registerWorkspaceTools(s *server.MCPServer, cfg *Config) {
	s.AddTool(
		mcp.NewTool("list_workspaces",
			mcp.WithReadOnlyHintAnnotation(true),
			mcp.WithDestructiveHintAnnotation(false),
			mcp.WithOpenWorldHintAnnotation(false),
			mcp.WithDescription("List all registered WezTerm workspaces with their tabs, agents, and last-used timestamps"),
		),
		func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			ws, err := readWorkspaces(cfg.WorkspacesFile)
			if err != nil {
				if os.IsNotExist(err) {
					return mcp.NewToolResultText("No workspaces registered yet."), nil
				}
				return mcp.NewToolResultError(fmt.Sprintf("failed to read workspaces: %v", err)), nil
			}
			result, err := mcp.NewToolResultJSON(ws)
			if err != nil {
				return mcp.NewToolResultError(fmt.Sprintf("failed to serialize: %v", err)), nil
			}
			return result, nil
		},
	)
}
