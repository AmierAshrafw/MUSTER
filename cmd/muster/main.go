package main

import (
	"fmt"
	"os"
	"path/filepath"
	"time"

	"muster/internal/cli"
	"muster/internal/gitx"
	"muster/internal/store"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Println("usage: muster <verb> [args]")
		fmt.Println("verbs: init ingest claim verify done promote board show redo fail reimport doctor")
		os.Exit(1)
	}
	verb, args := os.Args[1], os.Args[2:]

	root, err := gitx.FindRoot(".")
	if err != nil {
		fmt.Println("MUSTER refuse: not inside a git repository.")
		os.Exit(1)
	}
	dir := filepath.Join(root, ".muster")
	app := &cli.App{
		Root: root, Dir: dir, G: &gitx.Repo{Dir: root},
		Out: os.Stdout, Now: time.Now, Getenv: os.Getenv,
	}
	if verb == "init" {
		os.Exit(app.Init(args)) // init creates .muster/ and the db itself (Task 23)
	}
	if _, err := os.Stat(dir); err != nil {
		fmt.Println("MUSTER refuse: .muster/ not found - run muster init first.")
		os.Exit(1)
	}
	st, err := store.Open(filepath.Join(dir, "muster.db"))
	if err != nil {
		fmt.Printf("MUSTER refuse: cannot open board db: %v\n", err)
		os.Exit(1)
	}
	defer st.Close()
	app.St = st
	os.Exit(app.Dispatch(verb, args))
}
