package main

import (
	"bytes"
	"context"
	"fmt"
	"os/exec"
	"regexp"
	"strconv"
	"strings"

	"github.com/mark3labs/mcp-go/mcp"
	"github.com/mark3labs/mcp-go/server"
)

// sessionIDPattern restricts session_id to characters that are safe to interpolate into the
// `sh -c` command below. session_id originates from agent-written state files, so it is
// externally-influenced input that must not reach the shell unchecked.
var sessionIDPattern = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)

// sendStep is one `wezterm cli` invocation (args after "wezterm") with its stdin payload.
type sendStep struct {
	args  []string
	stdin string
}

// sendTextSteps builds the command sequence for send_text. The text body is sent first
// (a bracketed paste unless noPaste); when submit is set, Enter is sent as a SEPARATE raw
// key afterwards. A CR inside a bracketed paste is inserted as a literal newline by TUIs
// (e.g. Claude Code) rather than submitting, so the Enter must be sent raw on its own.
func sendTextSteps(paneID int, text string, submit, noPaste bool) []sendStep {
	id := strconv.Itoa(paneID)
	var steps []sendStep
	if text != "" {
		args := []string{"cli", "send-text", "--pane-id", id}
		if noPaste {
			args = append(args, "--no-paste")
		}
		steps = append(steps, sendStep{args: args, stdin: text})
	}
	if submit {
		steps = append(steps, sendStep{args: []string{"cli", "send-text", "--pane-id", id, "--no-paste"}, stdin: "\r"})
	}
	return steps
}

// keyBytes maps named keys to the raw byte sequences a terminal app receives. Arrow/nav keys
// use CSI sequences (the common default); control chords use their C0 byte. Sent via
// `wezterm cli send-text --no-paste` so the TUI sees a real keypress, not pasted text.
var keyBytes = map[string]string{
	"enter":     "\r",
	"escape":    "\x1b",
	"tab":       "\t",
	"backspace": "\x7f",
	"space":     " ",
	"up":        "\x1b[A",
	"down":      "\x1b[B",
	"right":     "\x1b[C",
	"left":      "\x1b[D",
	"home":      "\x1b[H",
	"end":       "\x1b[F",
	"pageup":    "\x1b[5~",
	"pagedown":  "\x1b[6~",
	"ctrl-c":    "\x03",
	"ctrl-d":    "\x04",
	"ctrl-z":    "\x1a",
	"ctrl-a":    "\x01",
	"ctrl-e":    "\x05",
	"ctrl-k":    "\x0b",
	"ctrl-u":    "\x15",
	"ctrl-w":    "\x17",
	"ctrl-l":    "\x0c",
}

// keyPayload returns the bytes for a named key repeated count times (clamped to 1..50).
func keyPayload(key string, count int) (string, bool) {
	b, ok := keyBytes[key]
	if !ok {
		return "", false
	}
	if count < 1 {
		count = 1
	}
	if count > 50 {
		count = 50
	}
	return strings.Repeat(b, count), true
}

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
				if !sessionIDPattern.MatchString(sessionID) {
					return mcp.NewToolResultError(fmt.Sprintf("invalid session_id: %q", sessionID)), nil
				}
				switch agentName {
				case "codex":
					agentCmd += " resume " + sessionID
				case "cursor":
					agentCmd += " --resume=" + sessionID
				default:
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
			mcp.WithDescription("Send text to a WezTerm pane. Text is sent as a bracketed paste by default (set no_paste=true for raw bytes). Set submit=true to press Enter afterwards as a SEPARATE raw key, which actually submits in TUIs like Claude Code (a CR inside a paste is only inserted as a newline). Use empty text + submit=true to just press Enter (e.g. to confirm a prompt)."),
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

			for _, step := range sendTextSteps(paneID, text, submit, noPaste) {
				cmd := exec.Command("wezterm", step.args...)
				cmd.Stdin = bytes.NewReader([]byte(step.stdin))
				if err := cmd.Run(); err != nil {
					return mcp.NewToolResultError(fmt.Sprintf("send-text failed: %v", err)), nil
				}
			}
			return mcp.NewToolResultText(fmt.Sprintf("Text sent to pane %d", paneID)), nil
		},
	)

	s.AddTool(
		mcp.NewTool("send_key",
			mcp.WithDescription("Send a named key or control chord to a WezTerm pane as a raw keypress (not pasted text). Use this for what send_text cannot do: interrupt a runaway agent (ctrl-c), dismiss/cancel a prompt (escape), navigate TUI menus (up/down then enter), etc."),
			mcp.WithInteger("pane_id",
				mcp.Required(),
				mcp.Description("The target pane ID"),
			),
			mcp.WithString("key",
				mcp.Required(),
				mcp.Description("The key to send"),
				mcp.Enum("enter", "escape", "tab", "backspace", "space",
					"up", "down", "left", "right", "home", "end", "pageup", "pagedown",
					"ctrl-c", "ctrl-d", "ctrl-z", "ctrl-a", "ctrl-e", "ctrl-k", "ctrl-u", "ctrl-w", "ctrl-l"),
			),
			mcp.WithInteger("count",
				mcp.Description("How many times to send the key (e.g. down x3 to move in a menu). Default 1."),
			),
		),
		func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			paneID, _ := req.RequireInt("pane_id")
			key, _ := req.RequireString("key")
			count := req.GetInt("count", 1)
			payload, ok := keyPayload(key, count)
			if !ok {
				return mcp.NewToolResultError(fmt.Sprintf("unknown key: %s", key)), nil
			}
			cmd := exec.Command("wezterm", "cli", "send-text", "--pane-id", strconv.Itoa(paneID), "--no-paste")
			cmd.Stdin = bytes.NewReader([]byte(payload))
			if err := cmd.Run(); err != nil {
				return mcp.NewToolResultError(fmt.Sprintf("send-key failed: %v", err)), nil
			}
			return mcp.NewToolResultText(fmt.Sprintf("Sent %s x%d to pane %d", key, count, paneID)), nil
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
