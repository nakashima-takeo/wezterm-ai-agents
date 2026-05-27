package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/mark3labs/mcp-go/mcp"
	"github.com/mark3labs/mcp-go/server"
)

type AgentStatus struct {
	PaneID    string `json:"pane_id"`
	Agent     string `json:"agent"`
	State     string `json:"state"`
	Timestamp int64  `json:"ts"`
	SessionID string `json:"session_id,omitempty"`
}

func registerAgentTools(s *server.MCPServer, cfg *Config) {
	s.AddTool(
		mcp.NewTool("get_agent_status",
			mcp.WithDescription("Get the status of all running AI agents across WezTerm panes"),
		),
		func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			pattern := filepath.Join(cfg.StatusDir, "wezterm-agent-*")
			files, err := filepath.Glob(pattern)
			if err != nil {
				return mcp.NewToolResultError(fmt.Sprintf("failed to glob status files: %v", err)), nil
			}

			if len(files) == 0 {
				return mcp.NewToolResultText("No active agents found."), nil
			}

			var agents []AgentStatus
			for _, f := range files {
				data, err := os.ReadFile(f)
				if err != nil {
					continue
				}
				var status AgentStatus
				if err := json.Unmarshal(data, &status); err != nil {
					continue
				}
				base := filepath.Base(f)
				status.PaneID = strings.TrimPrefix(base, "wezterm-agent-")
				agents = append(agents, status)
			}

			if len(agents) == 0 {
				return mcp.NewToolResultText("No active agents found."), nil
			}

			result, _ := json.MarshalIndent(agents, "", "  ")
			return mcp.NewToolResultText(string(result)), nil
		},
	)
}
