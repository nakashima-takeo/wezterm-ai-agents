package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestNsDir(t *testing.T) {
	cfg := &Config{StatusDir: "/base"}

	t.Setenv("WEZTERM_UNIX_SOCKET", "/Users/x/.local/share/wezterm/gui-sock-12345")
	if got := nsDir(cfg); got != "/base/12345" {
		t.Errorf("nsDir = %q, want /base/12345", got)
	}

	// No socket -> fall back to the flat base.
	t.Setenv("WEZTERM_UNIX_SOCKET", "")
	if got := nsDir(cfg); got != "/base" {
		t.Errorf("nsDir fallback = %q, want /base", got)
	}

	// Non-numeric suffix -> fall back to base.
	t.Setenv("WEZTERM_UNIX_SOCKET", "/tmp/gui-sock-abc")
	if got := nsDir(cfg); got != "/base" {
		t.Errorf("nsDir non-numeric = %q, want /base", got)
	}
}

func TestReadManagedSet(t *testing.T) {
	dir := t.TempDir()
	if got := readManagedSet(dir); len(got) != 0 {
		t.Errorf("missing file should be empty, got %v", got)
	}

	if err := os.WriteFile(filepath.Join(dir, "managed.json"), []byte(`{"managed":[3,6,9]}`), 0o644); err != nil {
		t.Fatal(err)
	}
	got := readManagedSet(dir)
	for _, id := range []int{3, 6, 9} {
		if !got[id] {
			t.Errorf("pane %d should be managed", id)
		}
	}
	if got[4] {
		t.Errorf("pane 4 should not be managed")
	}
}

func TestReadAgentStates(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "wezterm-agent-3"),
		[]byte(`{"agent":"claude","state":"waiting","ts":100,"session_id":"s1"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "wezterm-agent-3.tmp"), []byte(`partial`), 0o644); err != nil { // must be ignored
		t.Fatal(err)
	}

	states := readAgentStates(dir)
	if len(states) != 1 {
		t.Fatalf("expected 1 state (.tmp ignored), got %d", len(states))
	}
	st := states[3]
	if st.Agent != "claude" || st.State != "waiting" || st.PaneID != "3" {
		t.Errorf("unexpected state: %+v", st)
	}
}

func TestDiffStates(t *testing.T) {
	prev := map[int]paneSnap{
		3: {state: "working", agent: "claude"},
		6: {state: "working", agent: "codex"},
	}
	cur := map[int]paneSnap{
		3: {state: "waiting", agent: "claude"}, // changed
		9: {state: "idle", agent: "gemini"},    // newly managed (6 dropped)
	}

	changes := diffStates(prev, cur)
	byPane := map[int]EventChange{}
	for _, c := range changes {
		byPane[c.PaneID] = c
	}
	if len(changes) != 3 {
		t.Fatalf("expected 3 changes, got %d: %+v", len(changes), changes)
	}
	if c := byPane[3]; c.State != "waiting" || c.PrevState != "working" {
		t.Errorf("pane 3 change wrong: %+v", c)
	}
	if c := byPane[9]; c.State != "idle" || c.PrevState != "" {
		t.Errorf("pane 9 (new) wrong: %+v", c)
	}
	if c := byPane[6]; c.State != "" || c.PrevState != "working" {
		t.Errorf("pane 6 (gone) wrong: %+v", c)
	}

	// Identical maps -> no changes (the blocking case).
	if changes := diffStates(cur, cur); len(changes) != 0 {
		t.Errorf("identical states should yield no changes, got %+v", changes)
	}
}
