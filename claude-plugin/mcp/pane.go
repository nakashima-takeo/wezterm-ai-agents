package main

import (
	"bytes"
	"context"
	"fmt"
	"os/exec"
	"strconv"
	"strings"

	"github.com/mark3labs/mcp-go/mcp"
	"github.com/mark3labs/mcp-go/server"
)

func registerPaneTools(s *server.MCPServer, cfg *Config) {
	s.AddTool(
		mcp.NewTool("list_panes",
			mcp.WithDescription("List all WezTerm windows, tabs, and panes with their workspace, title, cwd, and active state"),
		),
		func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			cmd := exec.Command("wezterm", "cli", "list", "--format", "json")
			out, err := cmd.Output()
			if err != nil {
				return mcp.NewToolResultError(fmt.Sprintf("wezterm cli list failed: %v", err)), nil
			}
			return mcp.NewToolResultText(string(out)), nil
		},
	)

	s.AddTool(
		mcp.NewTool("spawn_agent",
			mcp.WithDescription("Spawn an AI agent in a new WezTerm tab. Returns the new pane ID."),
			mcp.WithString("agent",
				mcp.Required(),
				mcp.Description("Agent name: claude, codex, gemini, cursor"),
				mcp.Enum("claude", "codex", "gemini", "cursor"),
			),
			mcp.WithString("cwd",
				mcp.Description("Working directory for the agent"),
			),
			mcp.WithInteger("pane_id",
				mcp.Description("Reference pane ID to determine the target window. If omitted, uses the current window."),
			),
			mcp.WithString("session_id",
				mcp.Description("Session ID to resume a previous agent session"),
			),
		),
		func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			agentName, _ := req.RequireString("agent")
			cwd := req.GetString("cwd", "")
			paneID := req.GetInt("pane_id", -1)
			sessionID := req.GetString("session_id", "")

			agentCmd, ok := cfg.Agents[agentName]
			if !ok {
				return mcp.NewToolResultError(fmt.Sprintf("unknown agent: %s", agentName)), nil
			}

			if sessionID != "" {
				if agentName == "codex" {
					agentCmd += " resume " + sessionID
				} else {
					agentCmd += " --resume " + sessionID
				}
			}

			args := []string{"cli", "spawn"}
			if cwd != "" {
				args = append(args, "--cwd", cwd)
			}
			if paneID >= 0 {
				args = append(args, "--pane-id", strconv.Itoa(paneID))
			}

			shellCmd := fmt.Sprintf("export WEZTERM_AGENT_STATUS_DIR=%q && exec %s", cfg.StatusDir, agentCmd)
			args = append(args, "--", "sh", "-c", shellCmd)

			cmd := exec.Command("wezterm", args...)
			out, err := cmd.Output()
			if err != nil {
				if exitErr, ok := err.(*exec.ExitError); ok {
					return mcp.NewToolResultError(fmt.Sprintf("spawn failed: %s", string(exitErr.Stderr))), nil
				}
				return mcp.NewToolResultError(fmt.Sprintf("spawn failed: %v", err)), nil
			}

			newPaneID := strings.TrimSpace(string(out))
			return mcp.NewToolResultText(fmt.Sprintf("Agent %s spawned in pane %s", agentName, newPaneID)), nil
		},
	)

	s.AddTool(
		mcp.NewTool("get_pane_text",
			mcp.WithDescription("Get the text content of a WezTerm pane. Uses --escapes to capture text from alternate screen buffers (e.g. Claude Code TUI)."),
			mcp.WithInteger("pane_id",
				mcp.Required(),
				mcp.Description("The pane ID to read text from"),
			),
			mcp.WithInteger("start_line",
				mcp.Description("Start line number (0 = first visible line, negative = scrollback). Default: 0"),
			),
			mcp.WithInteger("end_line",
				mcp.Description("End line number. Default: bottom of screen"),
			),
		),
		func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			paneID, _ := req.RequireInt("pane_id")
			startLine := req.GetInt("start_line", 0)
			endLine := req.GetInt("end_line", -1)

			args := []string{"cli", "get-text", "--pane-id", strconv.Itoa(paneID)}
			if startLine != 0 {
				args = append(args, "--start-line", strconv.Itoa(startLine))
			}
			if endLine >= 0 {
				args = append(args, "--end-line", strconv.Itoa(endLine))
			}

			args = append(args, "--escapes")
			cmd := exec.Command("wezterm", args...)
			out, err := cmd.Output()
			if err != nil {
				return mcp.NewToolResultError(fmt.Sprintf("get-text failed: %v", err)), nil
			}

			return mcp.NewToolResultText(stripAnsiEscapes(string(out))), nil
		},
	)

	s.AddTool(
		mcp.NewTool("send_text",
			mcp.WithDescription("Send text to a WezTerm pane. Text is piped via stdin to preserve raw bytes. Set submit=true to append CR and auto-submit in Claude Code."),
			mcp.WithInteger("pane_id",
				mcp.Required(),
				mcp.Description("The target pane ID"),
			),
			mcp.WithString("text",
				mcp.Required(),
				mcp.Description("The text to send"),
			),
			mcp.WithBoolean("submit",
				mcp.Description("Append CR after the text to submit the prompt. Default: false"),
			),
			mcp.WithBoolean("no_paste",
				mcp.Description("Send text directly instead of as a bracketed paste. Default: false"),
			),
		),
		func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			paneID, _ := req.RequireInt("pane_id")
			text, _ := req.RequireString("text")
			submit := req.GetBool("submit", false)
			noPaste := req.GetBool("no_paste", false)

			if submit {
				text += "\r"
			}

			args := []string{"cli", "send-text", "--pane-id", strconv.Itoa(paneID)}
			if noPaste {
				args = append(args, "--no-paste")
			}

			cmd := exec.Command("wezterm", args...)
			cmd.Stdin = bytes.NewReader([]byte(text))
			if err := cmd.Run(); err != nil {
				return mcp.NewToolResultError(fmt.Sprintf("send-text failed: %v", err)), nil
			}
			return mcp.NewToolResultText(fmt.Sprintf("Text sent to pane %d", paneID)), nil
		},
	)
}

func stripAnsiEscapes(s string) string {
	var out strings.Builder
	i := 0
	for i < len(s) {
		if s[i] == 0x1b {
			i++
			if i >= len(s) {
				break
			}
			switch s[i] {
			case '[':
				// CSI sequence: ESC [ <params> <final>
				i++
				for i < len(s) && s[i] >= 0x20 && s[i] <= 0x3f {
					i++
				}
				if i < len(s) {
					i++
				}
			case ']':
				// OSC sequence: ESC ] ... (BEL | ST)
				i++
				for i < len(s) && s[i] != 0x07 && !(i+1 < len(s) && s[i] == 0x1b && s[i+1] == '\\') {
					i++
				}
				if i < len(s) && s[i] == 0x07 {
					i++
				} else if i+1 < len(s) {
					i += 2
				}
			case '(':
				// Character set designation: ESC ( <charset>
				i++
				if i < len(s) {
					i++
				}
			case ')':
				// Character set designation: ESC ) <charset>
				i++
				if i < len(s) {
					i++
				}
			default:
				// Other 2-byte ESC sequences (ESC =, ESC >, etc.)
				i++
			}
		} else {
			out.WriteByte(s[i])
			i++
		}
	}
	return out.String()
}
