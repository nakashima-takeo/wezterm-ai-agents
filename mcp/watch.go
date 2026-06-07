package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/mark3labs/mcp-go/mcp"
	"github.com/mark3labs/mcp-go/server"
)

// nsDir resolves the per-GUI-process namespace dir under the status base. It must agree with
// the hook (WEZTERM_UNIX_SOCKET -> gui-sock-<pid>) and the Lua reader (procinfo.pid()) so the
// orchestrator reads exactly the files the plugin writes. Falls back to the flat base when the
// socket is absent or malformed (legacy / non-GUI spawn).
func nsDir(cfg *Config) string {
	sock := os.Getenv("WEZTERM_UNIX_SOCKET")
	if i := strings.LastIndex(sock, "gui-sock-"); i >= 0 {
		pid := sock[i+len("gui-sock-"):]
		if pid != "" && isAllDigits(pid) {
			return filepath.Join(cfg.StatusDir, pid)
		}
	}
	return cfg.StatusDir
}

func isAllDigits(s string) bool {
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return s != ""
}

// readAgentStates reads every per-pane state file in dir into a map keyed by pane id.
func readAgentStates(dir string) map[int]AgentStatus {
	out := map[int]AgentStatus{}
	files, _ := filepath.Glob(filepath.Join(dir, "wezterm-agent-*"))
	for _, f := range files {
		idStr := strings.TrimPrefix(filepath.Base(f), "wezterm-agent-")
		id, err := strconv.Atoi(idStr)
		if err != nil {
			continue // skip .tmp and non-numeric names
		}
		data, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		var st AgentStatus
		if json.Unmarshal(data, &st) != nil {
			continue
		}
		st.PaneID = idStr
		out[id] = st
	}
	return out
}

// readManagedSet reads the supervision registry (managed.json: {"managed":[3,6,...]}).
func readManagedSet(dir string) map[int]bool {
	out := map[int]bool{}
	data, err := os.ReadFile(filepath.Join(dir, "managed.json"))
	if err != nil {
		return out
	}
	var doc struct {
		Managed []int `json:"managed"`
	}
	if json.Unmarshal(data, &doc) != nil {
		return out
	}
	for _, id := range doc.Managed {
		out[id] = true
	}
	return out
}

// ManagedAgent is one supervised pane joined with its live state.
type ManagedAgent struct {
	PaneID    int    `json:"pane_id"`
	Agent     string `json:"agent,omitempty"`
	State     string `json:"state"`
	SessionID string `json:"session_id,omitempty"`
	Timestamp int64  `json:"ts,omitempty"`
}

// managedSnapshot joins the managed set with live state. Managed panes without a state file
// yet are reported as state "unknown" so the orchestrator still sees them.
func managedSnapshot(cfg *Config) []ManagedAgent {
	dir := nsDir(cfg)
	states := readAgentStates(dir)
	managed := readManagedSet(dir)
	out := make([]ManagedAgent, 0, len(managed))
	for pid := range managed {
		a := ManagedAgent{PaneID: pid, State: "unknown"}
		if st, ok := states[pid]; ok {
			a.Agent, a.State, a.SessionID, a.Timestamp = st.Agent, st.State, st.SessionID, st.Timestamp
		}
		out = append(out, a)
	}
	return out
}

// paneSnap is the minimal per-pane fact used for change detection.
type paneSnap struct {
	state string
	agent string
}

func managedStates(cfg *Config) map[int]paneSnap {
	dir := nsDir(cfg)
	states := readAgentStates(dir)
	managed := readManagedSet(dir)
	out := make(map[int]paneSnap, len(managed))
	for pid := range managed {
		snap := paneSnap{state: "unknown"}
		if st, ok := states[pid]; ok {
			snap.state, snap.agent = st.State, st.Agent
		}
		out[pid] = snap
	}
	return out
}

// EventChange is one detected transition for a managed pane.
type EventChange struct {
	PaneID    int    `json:"pane_id"`
	Agent     string `json:"agent,omitempty"`
	State     string `json:"state"`               // "" when the pane left the managed set / closed
	PrevState string `json:"prev_state,omitempty"` // "" when newly managed
}

// diffStates compares the previous and current managed-pane state maps. A pane that appeared
// (newly managed), disappeared (unmanaged/closed), or changed state yields one change.
func diffStates(prev, cur map[int]paneSnap) []EventChange {
	var changes []EventChange
	for pid, c := range cur {
		p, ok := prev[pid]
		if !ok {
			changes = append(changes, EventChange{PaneID: pid, Agent: c.agent, State: c.state})
		} else if p.state != c.state {
			changes = append(changes, EventChange{PaneID: pid, Agent: c.agent, State: c.state, PrevState: p.state})
		}
	}
	for pid, p := range prev {
		if _, ok := cur[pid]; !ok {
			changes = append(changes, EventChange{PaneID: pid, Agent: p.agent, State: "", PrevState: p.state})
		}
	}
	return changes
}

// watcher holds the in-memory baseline for wait_for_event. The MCP server is 1:1 with the
// orchestrator session over stdio, so a single baseline (guarded by a mutex) is correct and
// lets the next call catch any change that happened while the orchestrator was reasoning.
type watcher struct {
	mu       sync.Mutex
	baseline map[int]paneSnap // nil until the first wait_for_event call (which self-primes)
}

const (
	pollInterval       = 300 * time.Millisecond
	defaultWaitTimeout = 50
	maxWaitTimeout     = 300
)

func registerWatchTools(s *server.MCPServer, cfg *Config) {
	w := &watcher{}

	s.AddTool(
		mcp.NewTool("get_agents",
			mcp.WithDescription("Snapshot of supervised (managed) agents joined with their live state. "+
				"Managed panes are toggled by the human in the WezTerm swarm console."),
		),
		func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			agents := managedSnapshot(cfg)
			if len(agents) == 0 {
				return mcp.NewToolResultText("No supervised agents."), nil
			}
			return mcp.NewToolResultJSON(agents)
		},
	)

	s.AddTool(
		mcp.NewTool("wait_for_event",
			mcp.WithDescription("Block until a supervised agent changes state (or the managed set changes), "+
				"then return the deltas. Returns immediately if changes already happened since the last call, "+
				"so nothing is missed while the orchestrator reasons. Returns timed_out=true with no changes "+
				"after timeout_seconds so the caller can simply call again to keep watching."),
			mcp.WithInteger("timeout_seconds",
				mcp.Description("Max seconds to block before returning timed_out. Default 50, max 300."),
			),
		),
		func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			timeout := req.GetInt("timeout_seconds", defaultWaitTimeout)
			if timeout < 1 {
				timeout = 1
			}
			if timeout > maxWaitTimeout {
				timeout = maxWaitTimeout
			}
			deadline := time.Now().Add(time.Duration(timeout) * time.Second)

			for {
				cur := managedStates(cfg)
				w.mu.Lock()
				changes := diffStates(w.baseline, cur)
				if len(changes) > 0 {
					w.baseline = cur
					w.mu.Unlock()
					return mcp.NewToolResultJSON(map[string]any{"changes": changes, "timed_out": false})
				}
				w.mu.Unlock()

				if time.Now().After(deadline) {
					return mcp.NewToolResultJSON(map[string]any{"changes": []EventChange{}, "timed_out": true})
				}
				select {
				case <-ctx.Done():
					return nil, ctx.Err()
				case <-time.After(pollInterval):
				}
			}
		},
	)
}
