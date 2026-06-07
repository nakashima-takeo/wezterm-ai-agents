package main

import (
	"context"
	"encoding/json"

	"github.com/mark3labs/mcp-go/mcp"
	"github.com/mark3labs/mcp-go/server"
)

type AgentStatus struct {
	PaneID    int    `json:"pane_id"`
	Agent     string `json:"agent"`
	State     string `json:"state"`
	Timestamp int64  `json:"ts"`
	SessionID string `json:"session_id,omitempty"`
}

func registerAgentTools(s *server.MCPServer, cfg *Config) {
	s.AddTool(
		mcp.NewTool("get_agent_status",
			mcp.WithReadOnlyHintAnnotation(true),
			mcp.WithDestructiveHintAnnotation(false),
			mcp.WithOpenWorldHintAnnotation(false),
			mcp.WithDescription("Get the status of all running AI agents across WezTerm panes"),
		),
		func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			// Read from the per-GUI-process namespace dir the plugin/hooks write to.
			states := readAgentStates(nsDir(cfg))
			if len(states) == 0 {
				return mcp.NewToolResultText("No active agents found."), nil
			}
			agents := make([]AgentStatus, 0, len(states))
			for _, st := range states {
				agents = append(agents, st)
			}
			result, _ := json.MarshalIndent(agents, "", "  ")
			return mcp.NewToolResultText(string(result)), nil
		},
	)
}
