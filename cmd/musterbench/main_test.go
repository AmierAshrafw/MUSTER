// cmd/musterbench/main_test.go
package main

import "testing"

func TestParseNSet(t *testing.T) {
	got, err := parseNSet("10,100,1000")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 3 || got[0] != 10 || got[2] != 1000 {
		t.Fatalf("parseNSet = %v", got)
	}
}

func TestParseNSetRejectsGarbage(t *testing.T) {
	if _, err := parseNSet("10,abc"); err == nil {
		t.Fatal("expected error on non-numeric N")
	}
}
