// muster is the MUSTER v2 board CLI: a single static binary owning every board
// state transition. Verbs are implemented in internal/cli; this file only maps
// argv to a verb and the verb's return value to a process exit code.
package main

import (
	"fmt"
	"os"
)

var verbs = []string{
	"init", "ingest", "claim", "verify", "done", "promote",
	"board", "show", "redo", "fail", "reimport", "doctor",
}

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(1)
	}
	verb := os.Args[1]
	for _, v := range verbs {
		if verb == v {
			fmt.Printf("MUSTER refuse: verb %q is not implemented yet.\n", verb)
			os.Exit(1)
		}
	}
	usage()
	os.Exit(1)
}

func usage() {
	fmt.Println("usage: muster <verb> [args]")
	fmt.Println("verbs: init ingest claim verify done promote board show redo fail reimport doctor")
}
