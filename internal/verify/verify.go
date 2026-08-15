// Package verify runs a card's verify block: direct process spawn (argv, no
// shell interpretation anywhere), merged stdout+stderr, wall timeout, stop at
// first failing entry, v1-format transcript appended to the task's verify.log.
// Windows caveat carried from v1: extension-less .cmd/.bat shims (npm, ng)
// do not spawn directly - cards front them with `cmd /c`.
package verify

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"muster/internal/card"
)

const outputCap = 64 * 1024

type Result struct {
	Pass      bool
	FirstFail string
}

type BlockOpts struct {
	WorkDir string
	LogPath string
	Label   string // "attempt <n>" | "done-check" | "claim-probe"
	TaskID  string
	Head    string
	NowIso  func() string
}

// SplitCmdLine tokenizes one command line: whitespace-separated, double quotes
// group (v1 spec 2.4). Tokens go straight to exec.Command.
func SplitCmdLine(cmd string) ([]string, error) {
	var tokens []string
	var sb strings.Builder
	inQuote := false
	for _, ch := range cmd {
		switch {
		case ch == '"':
			inQuote = !inQuote
		case !inQuote && (ch == ' ' || ch == '\t'):
			if sb.Len() > 0 {
				tokens = append(tokens, sb.String())
				sb.Reset()
			}
		default:
			sb.WriteRune(ch)
		}
	}
	if inQuote {
		return nil, fmt.Errorf("unbalanced double quote in cmd: %s", cmd)
	}
	if sb.Len() > 0 {
		tokens = append(tokens, sb.String())
	}
	return tokens, nil
}

type entryResult struct {
	Output   string
	ExitCode int
	TimedOut bool
	Timeout  int
	SpawnErr string
}

func runEntry(e card.VerifyEntry, workDir string) entryResult {
	timeout := 300
	if e.TimeoutSeconds != "" {
		timeout, _ = strconv.Atoi(e.TimeoutSeconds)
	}
	tokens, err := SplitCmdLine(e.Cmd)
	if err != nil || len(tokens) == 0 {
		return entryResult{SpawnErr: fmt.Sprintf("spawn failed: %v", err), ExitCode: -1, Timeout: timeout}
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeout)*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, tokens[0], tokens[1:]...)
	cmd.Dir = workDir
	out, err := cmd.CombinedOutput()
	res := entryResult{Output: string(out), Timeout: timeout, ExitCode: -1}
	if ctx.Err() == context.DeadlineExceeded {
		res.TimedOut = true
		return res
	}
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			res.ExitCode = ee.ExitCode()
			return res
		}
		res.SpawnErr = "spawn failed: " + err.Error()
		return res
	}
	res.ExitCode = cmd.ProcessState.ExitCode()
	return res
}

func appendLog(path, text string) error {
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.WriteString(text)
	return err
}

// RunBlock runs all entries in order, appending a transcript block to
// o.LogPath. Stops at the first failing entry.
func RunBlock(entries []card.VerifyEntry, o BlockOpts) (Result, error) {
	if err := appendLog(o.LogPath, fmt.Sprintf("=== %s | %s | task %s | HEAD %s\n",
		o.Label, o.NowIso(), o.TaskID, o.Head)); err != nil {
		return Result{}, err
	}
	pass := true
	firstFail := ""
	for _, e := range entries {
		if err := appendLog(o.LogPath, "$ "+e.Cmd+"\n"); err != nil {
			return Result{}, err
		}
		r := runEntry(e, o.WorkDir)
		body := r.Output
		if r.SpawnErr != "" {
			body = r.SpawnErr
		}
		if len(body) > outputCap {
			body = body[:outputCap] + "\n[output truncated]"
		}
		if strings.TrimSpace(body) != "" {
			appendLog(o.LogPath, strings.TrimRight(body, "\r\n")+"\n")
		}
		var parts, why []string
		ok := true
		if r.TimedOut {
			parts = append(parts, fmt.Sprintf("timeout %ds -> FAIL", r.Timeout))
			why = append(why, fmt.Sprintf("timed out after %ds", r.Timeout))
			ok = false
		} else {
			parts = append(parts, fmt.Sprintf("exit %d", r.ExitCode))
			if e.ExpectExit != "" {
				want, _ := strconv.Atoi(e.ExpectExit)
				if want == r.ExitCode {
					parts = append(parts, fmt.Sprintf("expect_exit %s -> OK", e.ExpectExit))
				} else {
					parts = append(parts, fmt.Sprintf("expect_exit %s -> FAIL", e.ExpectExit))
					why = append(why, fmt.Sprintf("exit %d, expected %s", r.ExitCode, e.ExpectExit))
					ok = false
				}
			}
			if e.ExpectContains != "" {
				if strings.Contains(r.Output, e.ExpectContains) {
					parts = append(parts, fmt.Sprintf("expect_contains %q -> OK", e.ExpectContains))
				} else {
					parts = append(parts, fmt.Sprintf("expect_contains %q -> MISSING", e.ExpectContains))
					why = append(why, fmt.Sprintf("output missing %q", e.ExpectContains))
					ok = false
				}
			}
		}
		if err := appendLog(o.LogPath, strings.Join(parts, " | ")+"\n"); err != nil {
			return Result{}, err
		}
		if !ok {
			pass = false
			firstFail = e.Cmd + ": " + strings.Join(why, "; ")
			break
		}
	}
	verdict := "FAIL"
	if pass {
		verdict = "PASS"
	}
	if err := appendLog(o.LogPath, fmt.Sprintf("=== %s result: %s\n", o.Label, verdict)); err != nil {
		return Result{}, err
	}
	return Result{Pass: pass, FirstFail: firstFail}, nil
}
