package store

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"strings"
)

// Fingerprint returns a content digest of the integrity-relevant board state:
// task rows, dependency edges, the event-chain tip, and verdict count. It is
// WAL-agnostic (reads the merged view) and used by the codex-executor loop to
// detect any raw DB write by the sandboxed executor. Read-only.
func (s *Store) Fingerprint() (string, error) {
	var b strings.Builder
	rows, err := s.db.Query(`SELECT id,status,tier,COALESCE(harness,''),
		COALESCE(claimed_by,''),COALESCE(head_at_claim,'') FROM tasks ORDER BY id`)
	if err != nil {
		return "", err
	}
	for rows.Next() {
		var id, st, tier, h, cb, hac string
		if err := rows.Scan(&id, &st, &tier, &h, &cb, &hac); err != nil {
			rows.Close()
			return "", err
		}
		fmt.Fprintf(&b, "T|%s|%s|%s|%s|%s|%s\n", id, st, tier, h, cb, hac)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return "", err
	}
	dep, err := s.db.Query(`SELECT task_id,depends_on FROM deps ORDER BY task_id,depends_on`)
	if err != nil {
		return "", err
	}
	for dep.Next() {
		var a, d string
		if err := dep.Scan(&a, &d); err != nil {
			dep.Close()
			return "", err
		}
		fmt.Fprintf(&b, "D|%s|%s\n", a, d)
	}
	dep.Close()
	if err := dep.Err(); err != nil {
		return "", err
	}
	var evCount, evMax int
	var evHash string
	if err := s.db.QueryRow(`SELECT count(*),COALESCE(max(id),0),
		COALESCE((SELECT hash FROM events ORDER BY id DESC LIMIT 1),'')
		FROM events`).Scan(&evCount, &evMax, &evHash); err != nil {
		return "", err
	}
	var vdCount int
	if err := s.db.QueryRow(`SELECT count(*) FROM verdicts`).Scan(&vdCount); err != nil {
		return "", err
	}
	fmt.Fprintf(&b, "E|%d|%d|%s\nV|%d\n", evCount, evMax, evHash, vdCount)
	sum := sha256.Sum256([]byte(b.String()))
	return hex.EncodeToString(sum[:]), nil
}
