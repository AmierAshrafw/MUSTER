package cli

import _ "embed"

//go:embed templates/RUNNER.md
var RunnerMD string

//go:embed templates/muster.gitignore
var GitignoreTemplate string

//go:embed templates/muster.gitattributes
var GitattributesTemplate string
