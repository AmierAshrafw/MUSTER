package store

import (
	"database/sql"
	"fmt"
	"os"
	"sort"
)

type Task struct {
	ID, Plan                          string
	Seq                               int
	Type, Tier, Harness, Status       string
	CardPath, FrontmatterSHA          string
	Reviews, Fixes                    string
	HeadAtClaim, ClaimedAt, ClaimedBy string
	Generation                        int
}

type IngestTask struct {
	Task Task
	Deps []string
}

const taskCols = `id, plan, seq, type, tier, harness, status, card_path,
	frontmatter_sha, reviews, fixes, head_at_claim, claimed_at, claimed_by, generation`

func scanTask(row interface{ Scan(...any) error }) (*Task, error) {
	var t Task
	err := row.Scan(&t.ID, &t.Plan, &t.Seq, &t.Type, &t.Tier, &t.Harness, &t.Status,
		&t.CardPath, &t.FrontmatterSHA, &t.Reviews, &t.Fixes,
		&t.HeadAtClaim, &t.ClaimedAt, &t.ClaimedBy, &t.Generation)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &t, nil
}

// Ingest inserts a linted batch: all task rows, then all deps, one transaction.
// Deps must resolve inside the batch or against rows already on the board -
// unknown ids fail the whole batch (spec D-v2-3: fail closed). Duplicate ids
// refuse. status starts at backlog; promote lifts the dep-free ones.
func (s *Store) Ingest(batch []IngestTask, actor, now string) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	inBatch := map[string]bool{}
	for _, it := range batch {
		inBatch[it.Task.ID] = true
	}
	for _, it := range batch {
		var exists int
		if err := tx.QueryRow(`SELECT COUNT(*) FROM tasks WHERE id = ?`, it.Task.ID).Scan(&exists); err != nil {
			return err
		}
		if exists > 0 {
			return fmt.Errorf("%s: already on the board", it.Task.ID)
		}
		t := it.Task
		if _, err := tx.Exec(`INSERT INTO tasks(id, plan, seq, type, tier, harness, status,
			card_path, frontmatter_sha, reviews, fixes, generation)
			VALUES (?, ?, ?, ?, ?, ?, 'backlog', ?, ?, ?, ?, ?)`,
			t.ID, t.Plan, t.Seq, t.Type, t.Tier, t.Harness,
			t.CardPath, t.FrontmatterSHA, t.Reviews, t.Fixes, t.Generation); err != nil {
			return err
		}
	}
	for _, it := range batch {
		for _, dep := range it.Deps {
			if !inBatch[dep] {
				var n int
				if err := tx.QueryRow(`SELECT COUNT(*) FROM tasks WHERE id = ?`, dep).Scan(&n); err != nil {
					return err
				}
				if n == 0 {
					return fmt.Errorf("%s: depends_on '%s' exists nowhere - ingest fails closed", it.Task.ID, dep)
				}
			}
			if _, err := tx.Exec(`INSERT INTO deps(task_id, depends_on) VALUES (?, ?)`, it.Task.ID, dep); err != nil {
				return err
			}
		}
	}
	for _, it := range batch {
		if err := appendEventOn(tx, it.Task.ID, actor, "ingest", "", now); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// FixGeneration returns the next generation number for a fix of implID:
// 1 + count of fix tasks already targeting it (the DB is the only counter).
func (s *Store) FixGeneration(implID string) (int, error) {
	var n int
	err := s.db.QueryRow(`SELECT COUNT(*) FROM tasks WHERE type = 'fix' AND fixes = ?`, implID).Scan(&n)
	return n + 1, err
}

// CycleReview is the reject flow's DB half, one transaction: insert the
// stamped fix (status inbox, generation g), flip the review doing -> backlog
// with claim fields cleared, re-block the review on the fix, file the fail
// verdict, and append events for both rows.
func (s *Store) CycleReview(reviewID, reviewer, reason string, fix IngestTask, g int, now string) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	f := fix.Task
	if _, err := tx.Exec(`INSERT INTO tasks(id, plan, seq, type, tier, harness, status,
		card_path, frontmatter_sha, reviews, fixes, generation)
		VALUES (?, ?, ?, ?, ?, ?, 'inbox', ?, ?, ?, ?, ?)`,
		f.ID, f.Plan, f.Seq, f.Type, f.Tier, f.Harness,
		f.CardPath, f.FrontmatterSHA, f.Reviews, f.Fixes, g); err != nil {
		return err
	}
	for _, dep := range fix.Deps {
		if _, err := tx.Exec(`INSERT INTO deps(task_id, depends_on) VALUES (?, ?)`, f.ID, dep); err != nil {
			return err
		}
	}
	res, err := tx.Exec(`UPDATE tasks SET status = 'backlog', head_at_claim = '',
		claimed_at = '', claimed_by = '' WHERE id = ? AND status = 'doing'`, reviewID)
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n != 1 {
		return fmt.Errorf("%s: review is not doing - cannot cycle", reviewID)
	}
	if _, err := tx.Exec(`INSERT INTO deps(task_id, depends_on) VALUES (?, ?)`, reviewID, f.ID); err != nil {
		return err
	}
	if _, err := tx.Exec(`INSERT INTO verdicts(task_id, reviewer, verdict, reason, created_at)
		VALUES (?, ?, 'fail', ?, ?)`, reviewID, reviewer, reason, now); err != nil {
		return err
	}
	if err := appendEventOn(tx, f.ID, reviewer, "ingest", fmt.Sprintf("fix generation %d", g), now); err != nil {
		return err
	}
	if err := appendEventOn(tx, reviewID, reviewer, "reject", fmt.Sprintf("gen%d -> %s", g, f.ID), now); err != nil {
		return err
	}
	return tx.Commit()
}

// Task returns one row, nil when absent.
func (s *Store) Task(id string) (*Task, error) {
	return scanTask(s.db.QueryRow(`SELECT `+taskCols+` FROM tasks WHERE id = ?`, id))
}

// TasksByStatus returns rows in id order.
func (s *Store) TasksByStatus(status string) ([]Task, error) {
	rows, err := s.db.Query(`SELECT `+taskCols+` FROM tasks WHERE status = ? ORDER BY id`, status)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Task
	for rows.Next() {
		t, err := scanTask(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *t)
	}
	return out, rows.Err()
}

// Doing returns the doing rows (the board invariant is 0 or 1; callers refuse on more).
func (s *Store) Doing() ([]Task, error) { return s.TasksByStatus("doing") }

func (s *Store) flip(id, to, actor, verb, detail, now string, clearClaim bool, froms []string) error {
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	set := `status = ?`
	if clearClaim {
		set += `, head_at_claim = '', claimed_at = '', claimed_by = ''`
	}
	args := []any{to, id}
	marks := ""
	for i, f := range froms {
		if i > 0 {
			marks += ","
		}
		marks += "?"
		args = append(args, f)
	}
	res, err := tx.Exec(`UPDATE tasks SET `+set+` WHERE id = ? AND status IN (`+marks+`)`, args...)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n != 1 {
		return fmt.Errorf("%s: cannot flip to %s (status not in %v)", id, to, froms)
	}
	if err := appendEventOn(tx, id, actor, verb, detail, now); err != nil {
		return err
	}
	return tx.Commit()
}

// MarkDone flips doing -> done (done pass path and the claim-time reconciler).
func (s *Store) MarkDone(id, actor, now string) error {
	return s.flip(id, "done", actor, "done", "", now, false, []string{"doing"})
}

// MarkFailed flips doing/inbox/backlog -> failed (terminal verify, review cap,
// human fail verb - including giving up a dead-blocked backlog task).
func (s *Store) MarkFailed(id, actor, detail, now string) error {
	return s.flip(id, "failed", actor, "fail", detail, now, false, []string{"doing", "inbox", "backlog"})
}

// MarkInbox is redo: doing/failed -> inbox with claim fields cleared; the next
// claim event starts a fresh attempt window.
func (s *Store) MarkInbox(id, actor, now string) error {
	return s.flip(id, "inbox", actor, "redo", "", now, true, []string{"doing", "failed"})
}

// InsertVerdict records a review/integration verdict row.
func (s *Store) InsertVerdict(taskID, reviewer, verdict, reason, now string) error {
	_, err := s.db.Exec(`INSERT INTO verdicts(task_id, reviewer, verdict, reason, created_at)
		VALUES (?, ?, ?, ?, ?)`, taskID, reviewer, verdict, reason, now)
	return err
}

// Verdicts returns a task's verdicts in insert order.
func (s *Store) Verdicts(taskID string) ([]Verdict, error) {
	rows, err := s.db.Query(`SELECT task_id, reviewer, verdict, reason, created_at
		FROM verdicts WHERE task_id = ? ORDER BY rowid`, taskID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Verdict
	for rows.Next() {
		var v Verdict
		if err := rows.Scan(&v.TaskID, &v.Reviewer, &v.Verdict, &v.Reason, &v.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, v)
	}
	return out, rows.Err()
}

type Verdict struct {
	TaskID, Reviewer, Verdict, Reason, CreatedAt string
}

// Deps returns a task's dependency ids, sorted.
func (s *Store) Deps(taskID string) ([]string, error) {
	rows, err := s.db.Query(`SELECT depends_on FROM deps WHERE task_id = ?`, taskID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var d string
		if err := rows.Scan(&d); err != nil {
			return nil, err
		}
		out = append(out, d)
	}
	sort.Strings(out)
	return out, rows.Err()
}

// Backup refreshes dst via VACUUM INTO (spec D-v2-4). VACUUM INTO refuses an
// existing target, so stale backups are removed first.
func (s *Store) Backup(dst string) error {
	if err := os.Remove(dst); err != nil && !os.IsNotExist(err) {
		return err
	}
	_, err := s.db.Exec(`VACUUM INTO ?`, dst)
	return err
}
