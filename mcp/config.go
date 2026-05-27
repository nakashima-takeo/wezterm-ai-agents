package main

import (
	"os"
	"path/filepath"
	"strings"
)

type Config struct {
	WorkspacesFile string
	StatusDir      string
	Agents         map[string]string
	HooksDir       string
}

func loadConfig() *Config {
	cfg := &Config{
		WorkspacesFile: filepath.Join(os.Getenv("HOME"), ".wezterm-workspaces.json"),
		StatusDir:      os.TempDir(),
		Agents: map[string]string{
			"claude":  "claude",
			"codex":   "codex",
			"gemini":  "gemini",
			"cursor":  "cursor-agent",
		},
	}

	if v := os.Getenv("WEZTERM_WORKSPACES_FILE"); v != "" {
		cfg.WorkspacesFile = v
	}
	if v := os.Getenv("WEZTERM_AGENT_STATUS_DIR"); v != "" {
		cfg.StatusDir = v
	}

	for _, env := range os.Environ() {
		const prefix = "WEZTERM_MCP_AGENT_"
		if strings.HasPrefix(env, prefix) {
			parts := strings.SplitN(env, "=", 2)
			name := strings.ToLower(strings.TrimPrefix(parts[0], prefix))
			if len(parts) == 2 && name != "" {
				cfg.Agents[name] = parts[1]
			}
		}
	}

	return cfg
}
