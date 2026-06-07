package main

import (
	"strings"
	"testing"
)

func TestSendTextSteps(t *testing.T) {
	// Text only: a single bracketed-paste step, no trailing CR appended to the body.
	steps := sendTextSteps(2, "hello", false, false)
	if len(steps) != 1 {
		t.Fatalf("text only: want 1 step, got %d", len(steps))
	}
	if steps[0].stdin != "hello" {
		t.Errorf("body stdin = %q, want %q (no CR appended to the paste)", steps[0].stdin, "hello")
	}
	if strings.Contains(strings.Join(steps[0].args, " "), "--no-paste") {
		t.Errorf("default body should be a bracketed paste, got --no-paste: %v", steps[0].args)
	}

	// Text + submit: body paste, then a SEPARATE raw Enter (--no-paste, stdin "\r").
	steps = sendTextSteps(2, "hello", true, false)
	if len(steps) != 2 {
		t.Fatalf("text+submit: want 2 steps, got %d", len(steps))
	}
	if steps[0].stdin != "hello" {
		t.Errorf("body stdin = %q, want %q", steps[0].stdin, "hello")
	}
	enter := steps[1]
	if enter.stdin != "\r" {
		t.Errorf("submit stdin = %q, want %q", enter.stdin, "\r")
	}
	if !strings.Contains(strings.Join(enter.args, " "), "--no-paste") {
		t.Errorf("submit Enter must be raw (--no-paste), got %v", enter.args)
	}

	// Submit only (empty text): just the Enter key — useful for confirming a prompt.
	steps = sendTextSteps(2, "", true, false)
	if len(steps) != 1 || steps[0].stdin != "\r" {
		t.Fatalf("submit only: want 1 Enter step, got %+v", steps)
	}
}

func TestKeyPayload(t *testing.T) {
	if p, ok := keyPayload("ctrl-c", 1); !ok || p != "\x03" {
		t.Errorf("ctrl-c = %q ok=%v, want \\x03", p, ok)
	}
	if p, ok := keyPayload("enter", 1); !ok || p != "\r" {
		t.Errorf("enter = %q", p)
	}
	if p, ok := keyPayload("down", 3); !ok || p != "\x1b[B\x1b[B\x1b[B" {
		t.Errorf("down x3 = %q, want triple CSI B", p)
	}
	if _, ok := keyPayload("nope", 1); ok {
		t.Errorf("unknown key should return ok=false")
	}
	if p, _ := keyPayload("up", 0); p != "\x1b[A" {
		t.Errorf("count<1 should clamp to 1, got %q", p)
	}
	if p, _ := keyPayload("space", 100); len(p) != 50 {
		t.Errorf("count>50 should clamp to 50, got len %d", len(p))
	}
}

func TestStripAnsiEscapes(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  string
	}{
		{"plain text", "hello world", "hello world"},
		{"CSI color", "\x1b[31mred\x1b[0m", "red"},
		{"CSI with params", "\x1b[38:2::177:185:249mtext\x1b[39m", "text"},
		{"charset designation ESC(B", "\x1b(Bhello", "hello"},
		{"charset designation ESC)0", "\x1b)0hello", "hello"},
		{"OSC with BEL", "\x1b]8;;http://example.com\x07link\x1b]8;;\x07", "link"},
		{"OSC with ST", "\x1b]8;;http://example.com\x1b\\link\x1b]8;;\x1b\\", "link"},
		{"mixed sequences", "\x1b(B\x1b[0;1mBold\x1b(B\x1b[0m normal", "Bold normal"},
		{"ESC = and ESC >", "\x1b=hello\x1b>world", "helloworld"},
		{"empty string", "", ""},
		{"only escapes", "\x1b[31m\x1b[0m", ""},
		{"Claude Code TUI sample", " \x1b(BClaude\x1b(B \x1b(BCode\x1b(B v2.1", " Claude Code v2.1"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := stripAnsiEscapes(tt.input)
			if got != tt.want {
				t.Errorf("stripAnsiEscapes(%q) = %q, want %q", tt.input, got, tt.want)
			}
		})
	}
}
