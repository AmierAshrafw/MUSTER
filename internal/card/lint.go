package card

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

type Mode int

const (
	Full   Mode = iota // shard batch: all checks including batch checks 11-12
	Lite               // staged fix: per-file checks, fix filename pattern
	Single             // reimport: per-file checks, normal filename pattern
)

var (
	namePat    = regexp.MustCompile(`^[a-z0-9-]+-\d{2}-[a-z0-9-]+$`)
	fixNamePat = regexp.MustCompile(`^[a-z0-9-]+-\d{2}-fix-[a-z0-9-]+$`)
	metaRx     = regexp.MustCompile("[|><;`]|\\$\\(|&&")
	netRx      = regexp.MustCompile(`(^|\s)(curl|wget|nuget|iwr|Invoke-WebRequest)(\s|$)|git (fetch|pull|push)|npm (install|ci)|dotnet restore|pip install`)
	runnerRx   = regexp.MustCompile(`(^|\s)(npm|pnpm|yarn) test(\s|$)|(^|\s)dotnet test(\s|$)|(^|\s)pytest(\s|$)|(^|\s)go test(\s|$)|(^|\s)cargo test(\s|$)|(^|\s)Invoke-Pester(\s|$)|(^|\s)ctest(\s|$)|(^|\s)(vitest|jest|mocha|rspec|phpunit)(\s|$)`)
	testPathRx = regexp.MustCompile(`(?i)(^|/)tests?/|\.tests?\.|_test\.|\.spec\.`)
	cmdSwitch  = regexp.MustCompile(`^/[a-zA-Z]$`)
	stepsRx    = regexp.MustCompile(`(?s)## Steps(.*?)(## Acceptance|$)`)
	headingsRx = regexp.MustCompile(`(?s)# .+?## Context.+?## Steps.+?## Acceptance`)
	numDotsRx  = regexp.MustCompile(`(?m)^\s*\d+\.\s*\.\.\.\s*$`)
	braceSlot  = regexp.MustCompile(`\{[a-z][a-z0-9 ,:.-]*\}`)
)

var placeholderLits = []string{"TBD", "TODO", "FIXME", "<fill", "{placeholder", "{...}"}
var uninlinedLits = []string{"see docs/", "refer to", "as described in", "per the plan"}
var judgmentLits = []string{"if needed", "as appropriate", "appropriately", "handle edge cases"}

// pathListed: path equals a list entry or sits under a listed directory.
func pathListed(path string, list []string) bool {
	for _, c := range list {
		if path == c || strings.HasPrefix(path, strings.TrimRight(c, "/")+"/") {
			return true
		}
	}
	return false
}

// Lint checks the batch of card files. exists reports whether an id is already
// on the board (DB resolver; replaces v1's folder scans). Findings are
// "<filename>: <message>" strings; empty means clean.
func Lint(paths []string, exists func(id string) bool, mode Mode) []string {
	var findings []string
	type parsed struct {
		c    *Card
		errs []string
		name string
		raw  string
	}
	var batch []parsed
	batchIDs := map[string]bool{}
	for _, p := range paths {
		name := filepath.Base(p)
		raw, err := os.ReadFile(p)
		if err != nil {
			findings = append(findings, name+": file not found")
			continue
		}
		c, errs := Parse(string(raw), mode == Lite)
		batch = append(batch, parsed{c: c, errs: errs, name: name, raw: string(raw)})
		if c.ID != "" {
			batchIDs[c.ID] = true
		}
	}

	for _, t := range batch {
		pfx := t.name
		stem := strings.TrimSuffix(t.name, ".md")

		// 1. frontmatter parses + schema per type
		if len(t.errs) > 0 {
			for _, e := range t.errs {
				findings = append(findings, pfx+": "+e)
			}
			if t.c.Type == "" {
				continue
			}
		}
		c := t.c

		// 2. id = stem; filename pattern; collision against board + batch dupes
		if c.ID != stem {
			findings = append(findings, fmt.Sprintf("%s: id '%s' does not equal filename stem", pfx, c.ID))
		}
		pat := namePat
		if mode == Lite {
			pat = fixNamePat
		}
		if !pat.MatchString(stem) {
			findings = append(findings, pfx+": filename does not match the task pattern (spec 2.1)")
		}
		if exists(c.ID) {
			findings = append(findings, fmt.Sprintf("%s: id '%s' already on the board", pfx, c.ID))
		}
		dupes := 0
		for _, o := range batch {
			if o.c.ID == c.ID {
				dupes++
			}
		}
		if dupes > 1 {
			findings = append(findings, fmt.Sprintf("%s: id '%s' duplicated in batch", pfx, c.ID))
		}

		// 3. every depends_on exists in batch or on the board (fail closed)
		for _, dep := range c.DependsOn {
			if !batchIDs[dep] && !exists(dep) {
				findings = append(findings, fmt.Sprintf("%s: depends_on '%s' exists nowhere", pfx, dep))
			}
		}

		// 4 + 5. verify cmd checks
		listed := append(append([]string{}, c.Protected...), c.CommitPaths...)
		runsTests := false
		for _, en := range c.Verify {
			if metaRx.MatchString(en.Cmd) {
				findings = append(findings, pfx+": verify cmd has shell metacharacters: "+en.Cmd)
			}
			if netRx.MatchString(en.Cmd) && c.Harness != "claude" {
				findings = append(findings, pfx+": verify cmd needs network but harness is not claude: "+en.Cmd)
			}
			if runnerRx.MatchString(en.Cmd) {
				runsTests = true
			}
			if c.Type == "impl" || c.Type == "fix" {
				toks, err := tokenizeForLint(en.Cmd)
				if err != nil {
					findings = append(findings, pfx+": verify cmd unparseable (unbalanced quote): "+en.Cmd)
				}
				for _, tok := range toks {
					if !strings.Contains(tok, "/") || strings.HasPrefix(tok, "-") || cmdSwitch.MatchString(tok) {
						continue
					}
					if !pathListed(tok, listed) {
						findings = append(findings, fmt.Sprintf("%s: verify path '%s' not in protected or commit_paths", pfx, tok))
						continue
					}
					// 5b (M2): a test-looking path satisfied only by commit_paths
					if testPathRx.MatchString(tok) && !pathListed(tok, c.Protected) {
						findings = append(findings, fmt.Sprintf("%s: verify test path '%s' only in commit_paths - executor-writable grader; move it to protected", pfx, tok))
					}
				}
			}
		}

		// 6. size cap
		if len(strings.Split(t.raw, "\n")) > 300 || len(t.raw) > 16*1024 {
			findings = append(findings, pfx+": over the size cap (300 lines / 16 KB) - reshard")
		}
		// 7. placeholders
		phFound := false
		for _, lit := range placeholderLits {
			if strings.Contains(t.raw, lit) {
				findings = append(findings, fmt.Sprintf("%s: placeholder text matches '%s'", pfx, lit))
				phFound = true
				break
			}
		}
		if !phFound && (braceSlot.MatchString(t.raw) || numDotsRx.MatchString(t.raw)) {
			findings = append(findings, pfx+": placeholder text matches a template-brace or dotted-step pattern")
		}
		// 8. un-inlined references
		for _, lit := range uninlinedLits {
			if strings.Contains(t.raw, lit) {
				findings = append(findings, fmt.Sprintf("%s: un-inlined reference ('%s')", pfx, lit))
				break
			}
		}
		// 9. judgment language in Steps
		if m := stepsRx.FindStringSubmatch(t.raw); m != nil {
			for _, lit := range judgmentLits {
				if strings.Contains(m[1], lit) {
					findings = append(findings, fmt.Sprintf("%s: judgment language in Steps ('%s')", pfx, lit))
					break
				}
			}
		}
		// 10. heading order
		if !headingsRx.MatchString(t.raw) {
			findings = append(findings, pfx+": body headings missing or out of order (Context, Steps, Acceptance)")
		}
		// 13. commit_paths non-empty on impl/fix
		if (c.Type == "impl" || c.Type == "fix") && len(c.CommitPaths) == 0 {
			findings = append(findings, pfx+": commit_paths empty")
		}
		// 14. runner without protected = delete-the-test pass linting clean (M2)
		if (c.Type == "impl" || c.Type == "fix") && runsTests && len(c.Protected) == 0 {
			findings = append(findings, pfx+": verify runs a test runner but protected is empty - tests are executor-writable")
		}
	}

	if mode == Full {
		// 11. exactly one integration task: seq 99, strong, depends on every other batch id
		var ints []parsed
		for _, t := range batch {
			if len(t.errs) == 0 && t.c.Type == "integration" {
				ints = append(ints, t)
			}
		}
		if len(ints) != 1 {
			findings = append(findings, fmt.Sprintf("batch: expected exactly 1 integration task, found %d", len(ints)))
		} else {
			in := ints[0].c
			if in.Seq != 99 {
				findings = append(findings, in.ID+".md: integration task must use seq 99")
			}
			if in.Tier != "strong" {
				findings = append(findings, in.ID+".md: integration task must be tier: strong")
			}
			depSet := map[string]bool{}
			for _, d := range in.DependsOn {
				depSet[d] = true
			}
			for id := range batchIDs {
				if id != in.ID && !depSet[id] {
					findings = append(findings, fmt.Sprintf("%s.md: integration depends_on missing '%s'", in.ID, id))
				}
			}
		}
		// 12. review wiring
		for _, t := range batch {
			if len(t.errs) > 0 || t.c.Type != "review" {
				continue
			}
			if !batchIDs[t.c.Reviews] {
				findings = append(findings, fmt.Sprintf("%s.md: reviews '%s' not in batch", t.c.ID, t.c.Reviews))
			}
			found := false
			for _, d := range t.c.DependsOn {
				if d == t.c.Reviews {
					found = true
				}
			}
			if !found {
				findings = append(findings, t.c.ID+".md: review depends_on must include its reviews id")
			}
		}
	}
	return findings
}

// tokenizeForLint mirrors the verify runner's tokenizer without importing it
// (card must not depend on verify). Same rules: whitespace splits, quotes group.
func tokenizeForLint(cmd string) ([]string, error) {
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
		return nil, fmt.Errorf("unbalanced quote")
	}
	if sb.Len() > 0 {
		tokens = append(tokens, sb.String())
	}
	return tokens, nil
}
