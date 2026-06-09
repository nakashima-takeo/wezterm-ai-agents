package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/mark3labs/mcp-go/mcp"
	"github.com/mark3labs/mcp-go/server"
)

// nsDir resolves the per-GUI-process namespace dir under the status base. It must agree with
// the hook (WEZTERM_UNIX_SOCKET -> gui-sock-<pid>) and the Lua reader (procinfo.pid()) so the
// manager reads exactly the files the plugin writes. Falls back to the flat base when the
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
		st.PaneID = id
		out[id] = st
	}
	return out
}

// AgentInfo is one agent pane with its live state.
type AgentInfo struct {
	PaneID    int    `json:"pane_id"`
	Agent     string `json:"agent,omitempty"`
	State     string `json:"state"`
	SessionID string `json:"session_id,omitempty"`
	Timestamp int64  `json:"ts,omitempty"`
}

// agentsSnapshot returns every live agent pane (one per state file) with its state. The manager
// scopes to its own workspace by cross-referencing list_panes; it then decides which panes to
// manage (its own spawned tabs and/or existing ones).
func agentsSnapshot(cfg *Config) []AgentInfo {
	states := readAgentStates(nsDir(cfg))
	out := make([]AgentInfo, 0, len(states))
	for _, st := range states {
		out = append(out, AgentInfo{
			PaneID: st.PaneID, Agent: st.Agent, State: st.State, SessionID: st.SessionID, Timestamp: st.Timestamp,
		})
	}
	return out
}

var intRunRe = regexp.MustCompile(`\d+`)

// scopeIDs parses the optional pane_ids argument into a set, so the manager watches only the panes
// it chose to manage (no noise/load from unrelated agents). Returns nil (= no filter, all agents)
// when the argument is absent or empty. Lenient: accepts "11,13", "[11, 13]", etc.
func scopeIDs(req mcp.CallToolRequest) map[int]bool {
	s := req.GetString("pane_ids", "")
	if strings.TrimSpace(s) == "" {
		return nil
	}
	out := map[int]bool{}
	for _, m := range intRunRe.FindAllString(s, -1) {
		if n, err := strconv.Atoi(m); err == nil {
			out[n] = true
		}
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// scopeSnaps returns m unchanged when ids is nil, else only the entries whose pane id is in ids.
func scopeSnaps(m map[int]paneSnap, ids map[int]bool) map[int]paneSnap {
	if ids == nil {
		return m
	}
	out := make(map[int]paneSnap, len(ids))
	for id := range ids {
		if v, ok := m[id]; ok {
			out[id] = v
		}
	}
	return out
}

// paneSnap is the minimal per-pane fact used for change detection.
type paneSnap struct {
	state string
	agent string
}

func agentStates(cfg *Config) map[int]paneSnap {
	states := readAgentStates(nsDir(cfg))
	out := make(map[int]paneSnap, len(states))
	for id, st := range states {
		out[id] = paneSnap{state: st.State, agent: st.Agent}
	}
	return out
}

// EventChange is one detected transition for an agent pane.
type EventChange struct {
	PaneID    int    `json:"pane_id"`
	Agent     string `json:"agent,omitempty"`
	State     string `json:"state"`                // "" when the pane's state file disappeared (closed)
	PrevState string `json:"prev_state,omitempty"` // "" when newly seen
}

// diffStates compares the previous and current agent state maps. A pane that appeared
// (new agent), disappeared (closed), or changed state yields one change.
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
// manager session over stdio, so a single baseline (guarded by a mutex) is correct and lets
// the next call catch any change that happened while the manager was reasoning.
type watcher struct {
	mu       sync.Mutex
	baseline map[int]paneSnap // nil on the first call: it returns the current agents as the initial events, then tracks deltas
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
			mcp.WithReadOnlyHintAnnotation(true),
			mcp.WithDestructiveHintAnnotation(false),
			mcp.WithOpenWorldHintAnnotation(false),
			mcp.WithDescription("Snapshot of agent panes with their live state. Without pane_ids, returns every agent "+
				"(use this to survey and decide which to manage). With pane_ids, returns only those — scope to the set you "+
				"chose so the result stays focused. The manager scopes to its own workspace via list_panes."),
			mcp.WithString("pane_ids",
				mcp.Description("Optional comma-separated pane ids to limit the snapshot to (e.g. \"11,13\"). Omit for all agents."),
			),
		),
		func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			ids := scopeIDs(req)
			agents := agentsSnapshot(cfg)
			if ids != nil {
				kept := agents[:0]
				for _, a := range agents {
					if ids[a.PaneID] {
						kept = append(kept, a)
					}
				}
				agents = kept
			}
			// structuredContent must be a JSON object, not a top-level array, so wrap the list.
			return mcp.NewToolResultJSON(map[string]any{"agents": agents})
		},
	)

	s.AddTool(
		mcp.NewTool("wait_for_event",
			mcp.WithReadOnlyHintAnnotation(true),
			mcp.WithDestructiveHintAnnotation(false),
			mcp.WithOpenWorldHintAnnotation(false),
			mcp.WithDescription("Block until a watched agent pane changes state (or appears/closes), then return the deltas. "+
				"Pass pane_ids to watch ONLY the panes you manage — you are woken only for those, with no noise from other "+
				"agents. Returns immediately if a watched change already happened since the last call, so nothing is missed "+
				"while you reason. Returns timed_out=true with no changes after timeout_seconds so the caller can call again."),
			mcp.WithString("pane_ids",
				mcp.Description("Optional comma-separated pane ids to watch (e.g. \"11,13\"). Omit to watch every agent."),
			),
			mcp.WithInteger("timeout_seconds",
				mcp.Description("Max seconds to block before returning timed_out. Default 50, max 300."),
			),
		),
		func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			ids := scopeIDs(req)
			timeout := req.GetInt("timeout_seconds", defaultWaitTimeout)
			if timeout < 1 {
				timeout = 1
			}
			if timeout > maxWaitTimeout {
				timeout = maxWaitTimeout
			}
			deadline := time.Now().Add(time.Duration(timeout) * time.Second)

			for {
				cur := agentStates(cfg)
				w.mu.Lock()
				// baseline tracks all agents; we only report (and block on) the requested subset.
				changes := diffStates(scopeSnaps(w.baseline, ids), scopeSnaps(cur, ids))
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
