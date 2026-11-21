package travel

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
)

// PostgresStore is the authority for account plans. It never uses the legacy
// timestamp/LWW sync table, and every transaction sets and filters its owner.
type PostgresStore struct{ db *sql.DB }

func NewPostgresStore(db *sql.DB) *PostgresStore { return &PostgresStore{db: db} }

func (s *PostgresStore) Read(ctx context.Context, owner string) (AccountState, error) {
	var state AccountState
	if s.db == nil || owner == "" {
		return state, ErrUnavailable
	}
	tx, err := s.db.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
	if err != nil {
		return state, err
	}
	defer tx.Rollback()
	if _, err = tx.ExecContext(ctx, `SELECT set_config('app.travel_owner',$1,true)`, owner); err != nil {
		return state, err
	}
	var payload []byte
	err = tx.QueryRowContext(ctx, `SELECT payload FROM harness.travel_workspaces WHERE user_id=$1`, owner).Scan(&payload)
	if errors.Is(err, sql.ErrNoRows) {
		state.initialize()
		return state, tx.Commit()
	}
	if err != nil {
		return state, err
	}
	if err = json.Unmarshal(payload, &state); err != nil {
		return state, err
	}
	state.initialize()
	return state, tx.Commit()
}

func (s *PostgresStore) Update(ctx context.Context, owner string, update func(*AccountState) error) error {
	if s.db == nil || owner == "" {
		return ErrUnavailable
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err = tx.ExecContext(ctx, `SELECT set_config('app.travel_owner',$1,true)`, owner); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, `INSERT INTO harness.travel_workspaces(user_id) VALUES($1) ON CONFLICT(user_id) DO NOTHING`, owner); err != nil {
		return err
	}
	var payload []byte
	if err = tx.QueryRowContext(ctx, `SELECT payload FROM harness.travel_workspaces WHERE user_id=$1 FOR UPDATE`, owner).Scan(&payload); err != nil {
		return err
	}
	var state AccountState
	if err = json.Unmarshal(payload, &state); err != nil {
		return err
	}
	state.initialize()
	if err = update(&state); err != nil {
		return err
	}
	payload, err = json.Marshal(state)
	if err != nil {
		return err
	}
	if len(payload) > 8<<20 {
		return errors.New("workspace_capacity_reached")
	}
	if _, err = tx.ExecContext(ctx, `UPDATE harness.travel_workspaces SET payload=$2::jsonb, revision=revision+1, updated_at=NOW() WHERE user_id=$1`, owner, payload); err != nil {
		return err
	}
	return tx.Commit()
}
