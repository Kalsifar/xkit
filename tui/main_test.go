package main

import (
	"bytes"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	tea "github.com/charmbracelet/bubbletea"
)

func key(s string) tea.KeyMsg {
	if s == "enter" {
		return tea.KeyMsg{Type: tea.KeyEnter}
	}
	return tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(s)}
}

func TestMainNavigationAndBack(t *testing.T) {
	m := initialModel("xkit")
	updated, _ := m.Update(tea.KeyMsg{Type: tea.KeyDown})
	m = updated.(model)
	updated, cmd := m.Update(key("enter"))
	m = updated.(model)
	if m.page != pageProtocols || cmd != nil {
		t.Fatalf("protocol page not opened: page=%v cmd=%v", m.page, cmd)
	}
	if len(m.items) != 5 {
		t.Fatalf("unexpected protocol items: %d", len(m.items))
	}
	updated, _ = m.Update(key("q"))
	m = updated.(model)
	if m.page != pageMain {
		t.Fatalf("q did not return to main")
	}
}

func TestActionUsesExistingCore(t *testing.T) {
	m := initialModel("xkit")
	m.page = pageService
	m.items = itemsFor(pageService, snapshot{})
	_, cmd := m.enter()
	if cmd == nil {
		t.Fatal("service action did not return a command")
	}
}

func TestActionWrapperPreservesArgvAndExitCode(t *testing.T) {
	dir := t.TempDir()
	script := filepath.Join(dir, "action.sh")
	body := "#!/bin/bash\nprintf '<%s>\\n' \"$@\"\nexit 23\n"
	if err := os.WriteFile(script, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	args := []string{"plain", "two words", "$(printf should-not-run)", "; printf should-not-run"}
	cmd := actionCommand(script, args)
	cmd.Stdin = strings.NewReader("\n")
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	err := cmd.Run()
	exitErr, ok := err.(*exec.ExitError)
	if !ok || exitErr.ExitCode() != 23 {
		t.Fatalf("original exit code lost: err=%v output=%s", err, out.String())
	}
	for _, want := range []string{"<plain>", "<two words>", "<$(printf should-not-run)>", "<; printf should-not-run>"} {
		if !strings.Contains(out.String(), want) {
			t.Fatalf("argument changed or evaluated: missing %q in %s", want, out.String())
		}
	}
	if strings.Contains(out.String(), "should-not-run\n") {
		t.Fatalf("argument was executed: %s", out.String())
	}
	if !strings.Contains(out.String(), "Enter — вернуться в XKIT TUI") {
		t.Fatalf("return prompt missing: %s", out.String())
	}
}

func TestActionWrapperWaitsForEnter(t *testing.T) {
	stdin, writer := io.Pipe()
	defer stdin.Close()
	defer writer.Close()
	cmd := actionCommand("/bin/echo", []string{"fast-output"})
	cmd.Stdin = stdin
	cmd.Stdout, cmd.Stderr = io.Discard, io.Discard
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		t.Fatalf("fast command returned to TUI before Enter: %v", err)
	case <-time.After(150 * time.Millisecond):
	}
	if _, err := writer.Write([]byte("\n")); err != nil {
		t.Fatal(err)
	}
	// exec.Cmd копирует не-файловый stdin в отдельной goroutine; EOF нужен,
	// чтобы Wait не ждал завершения этой тестовой копии после выхода Bash.
	writer.Close()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("wrapper failed after Enter: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("wrapper did not finish after Enter")
	}
}

func TestFilterIsUnicodeSafe(t *testing.T) {
	m := initialModel("xkit")
	m.items = itemsFor(pageUsers, snapshot{})
	updated, _ := m.Update(key("/"))
	m = updated.(model)
	for _, r := range "ссылки" {
		updated, _ = m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}})
		m = updated.(model)
	}
	if len(visibleItems(m)) != 1 {
		t.Fatalf("filter result: %#v", visibleItems(m))
	}
	updated, _ = m.Update(tea.KeyMsg{Type: tea.KeyBackspace})
	m = updated.(model)
	if !utf8.ValidString(m.filter) {
		t.Fatal("broken UTF-8 after backspace")
	}
}

func TestSnapshotUpdatesProtocolDescriptions(t *testing.T) {
	m := initialModel("xkit")
	m.page = pageProtocols
	m.items = itemsFor(pageProtocols, snapshot{})
	s := snapshot{Protocols: []protocol{{ID: "awg", Status: "active", Details: "UDP 51820"}}}
	updated, _ := m.Update(snapshotMsg{snap: s})
	m = updated.(model)
	if !strings.Contains(m.items[2].desc, "UDP 51820") {
		t.Fatalf("status not rendered: %s", m.items[2].desc)
	}
}

func TestNodeMetricsRenderActivityAndUnknownResources(t *testing.T) {
	rate := 2000000.0
	interval := int64(150000000)
	cpu := 12.5
	m := initialModel("xkit")
	m.page, m.width, m.height = pageNodes, 140, 50
	m.items = itemsFor(pageNodes, snapshot{})
	m.snap = snapshot{Nodes: 2, NodeMetrics: []nodeMetric{
		{Name: "de1", Status: "ok", Panel: "ok", RateBps: &rate, IntervalTotal: &interval, CPUPercent: &cpu},
		{Name: "nl1", Status: "ok", Panel: "fail"},
	}}
	view := m.View()
	for _, want := range []string{"★de1", "2.0 MB/s", "150.0 MB", "nl1", "системные"} {
		if !strings.Contains(view, want) {
			t.Fatalf("node metrics missing %q:\n%s", want, view)
		}
	}
	if m.items[1].args[0] != "nodes" || m.items[1].args[1] != "metrics" {
		t.Fatalf("metrics action not wired to core: %#v", m.items[1].args)
	}
}

func TestSmallTerminalFallback(t *testing.T) {
	m := initialModel("xkit")
	m.width, m.height = 30, 8
	if !strings.Contains(m.View(), "увеличьте окно") {
		t.Fatal("small terminal hint missing")
	}
}
