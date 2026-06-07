package main

import (
	"fmt"
	"os"

	"github.com/mark3labs/mcp-go/server"
)

func main() {
	cfg := loadConfig()
	s := server.NewMCPServer(
		"wezterm-ai-agents",
		"0.1.0",
		server.WithToolCapabilities(false),
		server.WithRecovery(),
	)

	registerWorkspaceTools(s, cfg)
	registerWorktreeTools(s)
	registerAgentTools(s, cfg)
	registerPaneTools(s, cfg)
	registerWatchTools(s, cfg)

	if err := server.ServeStdio(s); err != nil {
		fmt.Fprintf(os.Stderr, "server error: %v\n", err)
		os.Exit(1)
	}
}
