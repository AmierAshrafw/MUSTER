// Package card parses and validates MUSTER task cards: a strict YAML-subset
// frontmatter (v1 spec 2.5 semantics, unknown keys rejected) plus a markdown
// body. Values stay strings; the verify runner parses integers at use time.
package card

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

type VerifyEntry struct {
	Cmd            string
	ExpectExit     string
	ExpectContains string
	TimeoutSeconds string
}

type Card struct {
	ID, Plan, Type, Tier, Harness string
	Seq                           int
	DependsOn, Protected          []string
	CommitPaths                   []string
	Reviews, Fixes                string
	Verify                        []VerifyEntry
	Body                          string
	FrontmatterSHA                string
}

var (
	kebab   = regexp.MustCompile(`^[a-z0-9-]+$`)
	keyLine = regexp.MustCompile(`^([a-z_]+):(.*)$`)
	seqPat  = regexp.MustCompile(`-(\d{2})-`)
)

// scalar and list keys the schema knows; anything else is an error.
var scalarKeys = map[string]bool{
	"id": true, "plan": true, "type": true, "tier": true,
	"harness": true, "reviews": true, "fixes": true,
}
var listKeys = map[string]bool{
	"depends_on": true, "protected": true, "commit_paths": true,
}

func stripQuotes(v string) string {
	if len(v) >= 2 && strings.HasPrefix(v, `"`) && strings.HasSuffix(v, `"`) {
		return v[1 : len(v)-1]
	}
	return v
}

// Parse parses text into a Card and validates the schema for its type.
// staged=true is lint-lite mode for a reviewer-authored fix (fix filename
// pattern is checked by lint, not here). A non-empty error list means the
// card is invalid; the returned Card is still populated as far as parsing got.
func Parse(text string, staged bool) (*Card, []string) {
	c := &Card{DependsOn: []string{}, Protected: []string{}, CommitPaths: []string{}}
	var errs []string
	scalars := map[string]string{}
	lists := map[string][]string{}

	lines := strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n")
	if len(lines) < 3 || lines[0] != "---" {
		return c, []string{"missing opening --- marker"}
	}
	close := 0
	for j := 1; j < len(lines); j++ {
		if lines[j] == "---" {
			close = j
			break
		}
	}
	if close == 0 {
		return c, []string{"missing closing --- marker"}
	}

	sum := sha256.Sum256([]byte(strings.Join(lines[0:close+1], "\n")))
	c.FrontmatterSHA = hex.EncodeToString(sum[:])

	i := 1
	for i < close {
		line := lines[i]
		if strings.TrimSpace(line) == "" {
			i++
			continue
		}
		m := keyLine.FindStringSubmatch(line)
		if m == nil {
			errs = append(errs, "unparseable frontmatter line: "+line)
			i++
			continue
		}
		key, val := m[1], strings.TrimSpace(m[2])

		if key == "verify" {
			if val != "" {
				return c, append(errs, "verify: must be a block list")
			}
			i++
			for i < close {
				vl := lines[i]
				if em := regexp.MustCompile(`^  - ([a-z_]+): (.+)$`).FindStringSubmatch(vl); em != nil {
					c.Verify = append(c.Verify, VerifyEntry{})
					setVerifyKey(&c.Verify[len(c.Verify)-1], em[1], stripQuotes(strings.TrimSpace(em[2])), &errs)
					i++
				} else if em := regexp.MustCompile(`^    ([a-z_]+): (.+)$`).FindStringSubmatch(vl); em != nil {
					if len(c.Verify) == 0 {
						return c, append(errs, "verify: continuation before first entry: "+vl)
					}
					setVerifyKey(&c.Verify[len(c.Verify)-1], em[1], stripQuotes(strings.TrimSpace(em[2])), &errs)
					i++
				} else {
					break
				}
			}
			if len(c.Verify) == 0 {
				errs = append(errs, "verify: empty block")
			}
			scalars["verify"] = "present"
			continue
		}

		if !scalarKeys[key] && !listKeys[key] {
			errs = append(errs, "unknown frontmatter key: "+key)
			i++
			continue
		}
		switch {
		case val == "[]":
			lists[key] = []string{}
			i++
		case val == "":
			var items []string
			i++
			for i < close {
				im := regexp.MustCompile(`^\s+- (.+)$`).FindStringSubmatch(lines[i])
				if im == nil {
					break
				}
				items = append(items, stripQuotes(strings.TrimSpace(im[1])))
				i++
			}
			if len(items) == 0 {
				errs = append(errs, key+": empty value - use [] for an empty list")
			}
			lists[key] = items
		default:
			if strings.HasPrefix(val, "&") || strings.HasPrefix(val, "*") {
				errs = append(errs, key+": anchors/aliases are not allowed")
			}
			if listKeys[key] {
				errs = append(errs, key+": must be a list")
				i++
				continue
			}
			scalars[key] = stripQuotes(val)
			i++
		}
	}
	if close+1 < len(lines) {
		c.Body = strings.Join(lines[close+1:], "\n")
	}

	c.ID = scalars["id"]
	c.Plan = scalars["plan"]
	c.Type = scalars["type"]
	c.Tier = scalars["tier"]
	c.Harness = scalars["harness"]
	c.Reviews = scalars["reviews"]
	c.Fixes = scalars["fixes"]
	if v, ok := lists["depends_on"]; ok {
		c.DependsOn = v
	}
	if v, ok := lists["protected"]; ok {
		c.Protected = v
	}
	if v, ok := lists["commit_paths"]; ok {
		c.CommitPaths = v
	}
	if sm := seqPat.FindStringSubmatch(c.ID); sm != nil {
		c.Seq, _ = strconv.Atoi(sm[1])
	}

	errs = append(errs, schemaErrors(c, scalars, lists, staged)...)
	return c, errs
}

func setVerifyKey(e *VerifyEntry, key, val string, errs *[]string) {
	switch key {
	case "cmd":
		e.Cmd = val
	case "expect_exit":
		e.ExpectExit = val
	case "expect_contains":
		e.ExpectContains = val
	case "timeout_seconds":
		e.TimeoutSeconds = val
	default:
		*errs = append(*errs, "verify: unknown key '"+key+"'")
	}
}

func schemaErrors(c *Card, scalars map[string]string, lists map[string][]string, staged bool) []string {
	var e []string
	req := []string{"id", "plan", "type", "tier", "verify"}
	for _, r := range req {
		if _, ok := scalars[r]; !ok {
			e = append(e, "missing required field: "+r)
		}
	}
	if _, ok := lists["depends_on"]; !ok {
		e = append(e, "missing required field: depends_on")
	}
	if len(e) > 0 {
		return e
	}
	switch c.Type {
	case "impl", "review", "fix", "integration":
	default:
		return []string{fmt.Sprintf("type: illegal value '%s'", c.Type)}
	}
	if c.Tier != "any" && c.Tier != "strong" {
		e = append(e, fmt.Sprintf("tier: illegal value '%s'", c.Tier))
	}
	if c.Harness != "" && c.Harness != "claude" && c.Harness != "codex" {
		e = append(e, fmt.Sprintf("harness: illegal value '%s'", c.Harness))
	}
	if !kebab.MatchString(c.ID) {
		e = append(e, "id: must be kebab-case [a-z0-9-]+")
	}
	if !kebab.MatchString(c.Plan) {
		e = append(e, "plan: must be kebab-case [a-z0-9-]+")
	}
	if c.Type == "review" && c.Reviews == "" {
		e = append(e, "reviews: required on review tasks")
	}
	if c.Type == "fix" && c.Fixes == "" {
		e = append(e, "fixes: required on fix tasks")
	}
	if c.Type == "impl" || c.Type == "fix" {
		if _, ok := lists["protected"]; !ok {
			e = append(e, "protected: required on "+c.Type+" tasks")
		}
		if _, ok := lists["commit_paths"]; !ok {
			e = append(e, "commit_paths: required on "+c.Type+" tasks")
		}
	} else if _, ok := lists["commit_paths"]; ok {
		e = append(e, "commit_paths: must be omitted on "+c.Type+" tasks (outputs are sidecars only)")
	}
	for _, en := range c.Verify {
		if en.Cmd == "" {
			e = append(e, "verify: entry missing cmd")
		}
		if en.ExpectExit == "" && en.ExpectContains == "" {
			e = append(e, "verify: entry needs expect_exit and/or expect_contains")
		}
		for name, v := range map[string]string{"expect_exit": en.ExpectExit, "timeout_seconds": en.TimeoutSeconds} {
			if v != "" {
				if _, err := strconv.Atoi(v); err != nil {
					e = append(e, "verify: "+name+" must be an integer")
				}
			}
		}
	}
	_ = staged // fix-filename pattern and staged-only rules live in lint (Task 10)
	return e
}
