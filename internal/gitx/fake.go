package gitx

import "fmt"

type FakeCommit struct {
	Msg   string
	Paths []string
}

// Fake is the unit-tier Git double. Zero value is usable; tests set fields.
type Fake struct {
	HeadSHA, BranchName string
	AncestorOK          bool
	HeadFiles           map[string]string
	Dirty               []string
	DiffSince           []string
	UntrackedList       []string
	IndexFiles          map[string]bool
	HistorySHAs         map[string][]string
	Added               [][]string
	Commits             []FakeCommit
	Amends              int
	CommitErr           error
	GrepSHAs            []string
	UserOK              bool
	// MutateOnCommit simulates a tree-mutating hook: runs after a successful Commit.
	MutateOnCommit func(*Fake)
}

func (f *Fake) Head() (string, error)   { return f.HeadSHA, nil }
func (f *Fake) Branch() (string, error) { return f.BranchName, nil }
func (f *Fake) IsAncestor(a, d string) (bool, error) {
	return f.AncestorOK, nil
}
func (f *Fake) ShowAtHead(rel string) (string, error) {
	if body, ok := f.HeadFiles[rel]; ok {
		return body, nil
	}
	return "", fmt.Errorf("path %s does not exist at HEAD", rel)
}
func (f *Fake) DirtyPaths() ([]string, error)            { return f.Dirty, nil }
func (f *Fake) DiffNamesSince(string) ([]string, error)  { return f.DiffSince, nil }
func (f *Fake) Untracked() ([]string, error)             { return f.UntrackedList, nil }
func (f *Fake) IndexHas(rel string) (bool, error)        { return f.IndexFiles[rel], nil }
func (f *Fake) PathHistory(rel string) ([]string, error) { return f.HistorySHAs[rel], nil }
func (f *Fake) Add(paths []string) error {
	f.Added = append(f.Added, paths)
	return nil
}
func (f *Fake) Commit(msg string, paths []string) error {
	if f.CommitErr != nil {
		return f.CommitErr
	}
	f.Commits = append(f.Commits, FakeCommit{Msg: msg, Paths: paths})
	if f.MutateOnCommit != nil {
		f.MutateOnCommit(f)
	}
	return nil
}
func (f *Fake) AmendNoEdit() error {
	// Real amend folds the staged re-add into the commit, leaving the tree
	// clean - mirror that so the hook re-stage cycle terminates in tests.
	f.Amends++
	f.Dirty = nil
	return nil
}
func (f *Fake) LogGrep(grep, rangeSpec string) ([]string, error) {
	return f.GrepSHAs, nil
}
func (f *Fake) UserConfigured() (bool, error) { return f.UserOK, nil }
