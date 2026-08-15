package store

import (
	"database/sql"
	"fmt"
	"path/filepath"
	"strings"
	"time"
)

type Store struct {
	db *sql.DB
}

// Open opens (creating if absent) the board database at path, applies the
// operational pragmas, and runs any pending migrations. The returned Store is
// safe for use from one process; cross-process safety comes from SQLite
// locking plus busy_timeout.
func Open(path string) (*Store, error) {
	dsn := "file:" + filepath.ToSlash(path) + "?" + strings.Join([]string{
		"_pragma=journal_mode(WAL)",
		"_pragma=synchronous(FULL)",
		"_pragma=busy_timeout(5000)",
		"_pragma=foreign_keys(1)",
	}, "&")
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	// One connection: the CLI is short-lived and single-threaded except the
	// claim race, which is cross-process, not cross-goroutine.
	db.SetMaxOpenConns(1)
	s := &Store{db: db}
	if err := s.migrate(); err != nil {
		db.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) Close() error { return s.db.Close() }

func (s *Store) migrate() error {
	var have int
	if err := s.db.QueryRow("SELECT version FROM schema_version").Scan(&have); err != nil {
		have = 0 // fresh file: migration 1 creates schema_version at version 0
	}
	for v := have; v < len(migrations); v++ {
		if err := s.applyMigration(v); err != nil {
			return err
		}
	}
	return nil
}

func (s *Store) applyMigration(v int) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec(migrations[v]); err != nil {
		return fmt.Errorf("migration %d: %w", v+1, err)
	}
	if _, err := tx.Exec("UPDATE schema_version SET version = ?", v+1); err != nil {
		return fmt.Errorf("migration %d: %w", v+1, err)
	}
	return tx.Commit()
}

// IsoNow formats t as the board's canonical UTC timestamp.
func IsoNow(t time.Time) string { return t.UTC().Format("2006-01-02T15:04:05Z") }
