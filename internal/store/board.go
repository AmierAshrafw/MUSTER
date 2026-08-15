package store

import "sort"

// Promote lifts every backlog task whose dependencies are all done (spec 4.4
// re-homed: a status flip, no file moves, no commit). Idempotent; one
// transaction; one promote event per lifted task. Returns lifted ids sorted.
func (s *Store) Promote(actor, now string) ([]string, error) {
	tx, err := s.db.Begin()
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	rows, err := tx.Query(`SELECT id FROM tasks t WHERE status = 'backlog'
		AND NOT EXISTS (
			SELECT 1 FROM deps d JOIN tasks dt ON dt.id = d.depends_on
			WHERE d.task_id = t.id AND dt.status != 'done')
		ORDER BY id`)
	if err != nil {
		return nil, err
	}
	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return nil, err
		}
		ids = append(ids, id)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	for _, id := range ids {
		if _, err := tx.Exec(`UPDATE tasks SET status = 'inbox' WHERE id = ? AND status = 'backlog'`, id); err != nil {
			return nil, err
		}
		if err := appendEventOn(tx, id, actor, "promote", "", now); err != nil {
			return nil, err
		}
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	if ids == nil {
		ids = []string{}
	}
	sort.Strings(ids)
	return ids, nil
}

// DeadBlocked lists backlog tasks stuck behind a failed dependency (D12):
// "<id> behind failed <dep>", first failed dep per task, id order.
func (s *Store) DeadBlocked() ([]string, error) {
	rows, err := s.db.Query(`SELECT t.id, MIN(d.depends_on) FROM tasks t
		JOIN deps d ON d.task_id = t.id
		JOIN tasks f ON f.id = d.depends_on AND f.status = 'failed'
		WHERE t.status = 'backlog' GROUP BY t.id ORDER BY t.id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var id, dep string
		if err := rows.Scan(&id, &dep); err != nil {
			return nil, err
		}
		out = append(out, id+" behind failed "+dep)
	}
	return out, rows.Err()
}

type BoardCounts struct {
	InboxRun, InboxReview, Backlog, Done, Failed int
	InboxIDs, FailedIDs                          []string
	Doing                                        []Task
	Dead                                         []string
}

func (b *BoardCounts) Total() int {
	return b.InboxRun + b.InboxReview + b.Backlog + b.Done + b.Failed + len(b.Doing)
}

// Board gathers everything the status block and board line print.
func (s *Store) Board() (*BoardCounts, error) {
	b := &BoardCounts{InboxIDs: []string{}, FailedIDs: []string{}}
	inbox, err := s.TasksByStatus("inbox")
	if err != nil {
		return nil, err
	}
	for _, t := range inbox {
		b.InboxIDs = append(b.InboxIDs, t.ID)
		if t.Tier == "strong" {
			b.InboxReview++
		} else {
			b.InboxRun++
		}
	}
	if b.Doing, err = s.Doing(); err != nil {
		return nil, err
	}
	for status, dst := range map[string]*int{"backlog": &b.Backlog, "done": &b.Done, "failed": &b.Failed} {
		ts, err := s.TasksByStatus(status)
		if err != nil {
			return nil, err
		}
		*dst = len(ts)
		if status == "failed" {
			for _, t := range ts {
				b.FailedIDs = append(b.FailedIDs, t.ID)
			}
		}
	}
	if b.Dead, err = s.DeadBlocked(); err != nil {
		return nil, err
	}
	return b, nil
}
