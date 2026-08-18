package gitx

import (
	"reflect"
	"testing"
)

func TestFakeImplementsGit(t *testing.T) {
	var _ Git = (*Fake)(nil)
}

func TestFakeAddForceRecords(t *testing.T) {
	f := &Fake{}
	if err := f.Add([]string{"src/app.go"}); err != nil {
		t.Fatal(err)
	}
	if err := f.AddForce([]string{".muster/cards/x.verify.log"}); err != nil {
		t.Fatal(err)
	}
	if len(f.Added) != 1 || f.Added[0][0] != "src/app.go" {
		t.Fatalf("plain Add not recorded: %v", f.Added)
	}
	if len(f.Forced) != 1 || f.Forced[0][0] != ".muster/cards/x.verify.log" {
		t.Fatalf("AddForce not recorded separately: %v", f.Forced)
	}
}

func TestParsePorcelain(t *testing.T) {
	lines := []string{
		" M src/app.go",
		"?? new dir/file.txt",
		`R  "old name.txt" -> "new name.txt"`,
		"",
	}
	got := ParsePorcelain(lines)
	want := []string{"src/app.go", "new dir/file.txt", "old name.txt", "new name.txt"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v", got)
	}
}

func TestFakeShowAtHead(t *testing.T) {
	f := &Fake{HeadFiles: map[string]string{".muster/cards/x.md": "body"}}
	got, err := f.ShowAtHead(".muster/cards/x.md")
	if err != nil || got != "body" {
		t.Fatalf("%q %v", got, err)
	}
	if _, err := f.ShowAtHead("missing"); err == nil {
		t.Fatal("missing path must error")
	}
}

func TestFakeCommitRecordsAndMutates(t *testing.T) {
	f := &Fake{HeadSHA: "h1"}
	mutated := false
	f.MutateOnCommit = func(g *Fake) { mutated = true; g.Dirty = []string{"src/app.go"} }
	if err := f.Commit("muster(p): done x", []string{"a", "b"}); err != nil {
		t.Fatal(err)
	}
	if len(f.Commits) != 1 || f.Commits[0].Msg != "muster(p): done x" || !mutated {
		t.Fatalf("%+v", f.Commits)
	}
}

func TestFakeIndexHasAndPathHistory(t *testing.T) {
	f := &Fake{
		IndexFiles:  map[string]bool{".muster/cards/staged.md": true},
		HistorySHAs: map[string][]string{".muster/cards/old.md": {"deadbeef"}},
	}
	if ok, _ := f.IndexHas(".muster/cards/staged.md"); !ok {
		t.Fatal("staged card must report in-index")
	}
	if ok, _ := f.IndexHas(".muster/cards/absent.md"); ok {
		t.Fatal("absent card must report not-in-index")
	}
	if h, _ := f.PathHistory(".muster/cards/old.md"); len(h) != 1 {
		t.Fatalf("committed card must have history, got %v", h)
	}
	if h, _ := f.PathHistory(".muster/cards/absent.md"); len(h) != 0 {
		t.Fatalf("never-committed card must have empty history, got %v", h)
	}
}
