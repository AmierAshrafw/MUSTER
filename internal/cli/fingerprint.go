package cli

import "fmt"

// Fingerprint prints a content digest of board state (read-only). The
// codex-executor loop captures it before and after a Codex run to detect any
// raw DB tamper by the sandboxed executor.
func (a *App) Fingerprint() int {
	fp, err := a.St.Fingerprint()
	if err != nil {
		return a.refuse("fingerprint failed: %v", err)
	}
	fmt.Fprintln(a.Out, fp)
	return 0
}
