// Package cli implements every muster verb over four seams: the store (SQLite),
// gitx (git), the verify runner, and the card parser. Verbs return process exit
// codes; main only maps argv and os.Exit.
package cli

import (
	"fmt"
	"io"
	"time"

	"muster/internal/gitx"
	"muster/internal/store"
)

type App struct {
	Root   string // repo root, absolute
	Dir    string // <Root>/.muster
	St     *store.Store
	G      gitx.Git
	Out    io.Writer
	Now    func() time.Time
	Getenv func(string) string
}

func (a *App) iso() string { return store.IsoNow(a.Now()) }

func (a *App) pf(format string, args ...any) {
	fmt.Fprintf(a.Out, format+"\n", args...)
}

// refuse prints the single-line refusal and returns exit code 1.
func (a *App) refuse(format string, args ...any) int {
	a.pf("MUSTER refuse: "+format, args...)
	return 1
}

// Dispatch routes one verb. Verbs are added task by task; unknown or
// not-yet-implemented verbs refuse.
func (a *App) Dispatch(verb string, args []string) int {
	switch verb {
	case "board":
		return a.Board()
	case "show":
		return a.Show(args)
	case "ingest":
		return a.Ingest(args)
	case "claim":
		return a.Claim(args)
	case "verify":
		return a.Verify()
	default:
		return a.refuse("verb %q is not implemented yet.", verb)
	}
}

// Init is implemented in Task 23; stub keeps main wired meanwhile.
func (a *App) Init(args []string) int {
	return a.refuse("verb \"init\" is not implemented yet.")
}
