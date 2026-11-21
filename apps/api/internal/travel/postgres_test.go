package travel

import (
	"context"
	"database/sql"
	"errors"
	"net/url"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"

	_ "github.com/lib/pq"
)

func isolatedPostgres(t *testing.T) *PostgresStore {
	t.Helper()
	raw := os.Getenv("TRAVEL_TEST_DATABASE_URL")
	if raw == "" {
		t.Skip("postgres layer unverified: no isolated TRAVEL_TEST_DATABASE_URL")
	}
	u, err := url.Parse(raw)
	if err != nil || u.Hostname() != "127.0.0.1" || !strings.HasPrefix(strings.TrimPrefix(u.Path, "/"), "travel_eval_") {
		t.Fatal("refusing a non-isolated test database")
	}
	db, err := sql.Open("postgres", raw)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	if _, err = db.Exec(`CREATE SCHEMA IF NOT EXISTS harness`); err != nil {
		t.Fatal(err)
	}
	ddl, err := os.ReadFile("../../migrations/harness/0002_travel_plans.sql")
	if err != nil {
		t.Fatal(err)
	}
	if _, err = db.Exec(string(ddl)); err != nil {
		t.Fatal(err)
	}
	// The app reruns idempotent migrations on boot.
	if _, err = db.Exec(string(ddl)); err != nil {
		t.Fatal(err)
	}
	return NewPostgresStore(db)
}

func TestPostgresA25ServerCASHasExactlyOneConcurrentWinner(t *testing.T) {
	store := isolatedPostgres(t)
	s := NewService(store)
	owner := newID("owner_")
	initial := adopt(t, s, owner, fixturePlan())
	var wait sync.WaitGroup
	var winners atomic.Int32
	var conflicts atomic.Int32
	for i := 0; i < 4; i++ {
		wait.Add(1)
		go func() {
			defer wait.Done()
			input := fixturePlan()
			input.Title = newID("Revision ")
			proposal, err := s.PreviewPlan(context.Background(), owner, PlanPreviewRequest{TargetID: initial.Plan.ID, ExpectedVersion: 1, Plan: input}, newID("preview_"))
			if errors.Is(err, ErrVersionConflict) {
				conflicts.Add(1)
				return
			}
			if err != nil {
				t.Error(err)
				return
			}
			_, err = s.Confirm(context.Background(), owner, ConfirmRequest{ProposalID: proposal.ID, Digest: proposal.Digest, IdempotencyKey: newID("confirm_")})
			if err == nil {
				winners.Add(1)
			} else if errors.Is(err, ErrVersionConflict) {
				conflicts.Add(1)
			} else {
				t.Error(err)
			}
		}()
	}
	wait.Wait()
	if winners.Load() != 1 || conflicts.Load() != 3 {
		t.Fatalf("CAS winners=%d conflicts=%d", winners.Load(), conflicts.Load())
	}
	plan, err := s.GetPlan(context.Background(), owner, initial.Plan.ID)
	if err != nil || plan.Version != 2 {
		t.Fatalf("wrong authoritative revision: %+v %v", plan, err)
	}
}

func TestPostgresA21A36RollbackKeepsReceiptAndPlanAtomic(t *testing.T) {
	store := isolatedPostgres(t)
	owner := newID("owner_")
	sentinel := errors.New("abort transaction")
	err := store.Update(context.Background(), owner, func(state *AccountState) error {
		state.Plans["uncommitted"] = Plan{ID: "uncommitted", Version: 1}
		state.Operations["receipt"] = Operation{ID: "receipt", State: "succeeded"}
		return sentinel
	})
	if !errors.Is(err, sentinel) {
		t.Fatal(err)
	}
	state, err := store.Read(context.Background(), owner)
	if err != nil || len(state.Plans) != 0 || len(state.Operations) != 0 {
		t.Fatalf("rollback leaked mutation/receipt: %+v %v", state, err)
	}
}

func TestPostgresA43A48OwnerScopeAndRLS(t *testing.T) {
	store := isolatedPostgres(t)
	s := NewService(store)
	a, b := newID("owner_"), newID("owner_")
	op := adopt(t, s, a, fixturePlan())
	if _, err := s.GetPlan(context.Background(), b, op.Plan.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("other owner sees plan: %v", err)
	}
	role := "travel_rls_" + hashText(a)[:12]
	// A fresh, task-owned database permits this test-only restricted role.
	if _, err := store.db.Exec(`CREATE ROLE ` + role + ` NOLOGIN; GRANT USAGE ON SCHEMA harness TO ` + role + `; GRANT SELECT ON harness.travel_workspaces TO ` + role); err != nil {
		t.Fatal(err)
	}
	tx, err := store.db.Begin()
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	if _, err = tx.Exec(`SET LOCAL ROLE ` + role); err != nil {
		t.Fatal(err)
	}
	if _, err = tx.Exec(`SELECT set_config('app.travel_owner',$1,true)`, b); err != nil {
		t.Fatal(err)
	}
	var count int
	if err = tx.QueryRow(`SELECT count(*) FROM harness.travel_workspaces WHERE user_id=$1`, a).Scan(&count); err != nil || count != 0 {
		t.Fatalf("RLS leaked owner row: %d %v", count, err)
	}
}

func TestPostgresA49DisconnectedAuthorityDoesNotApplyOnReconnect(t *testing.T) {
	store := isolatedPostgres(t)
	service := NewService(store)
	owner := newID("owner_")
	initial := adopt(t, service, owner, fixturePlan())
	changed := fixturePlan()
	changed.Title = "Explicitly reviewed replacement"
	proposal, err := service.PreviewPlan(context.Background(), owner, PlanPreviewRequest{TargetID: initial.Plan.ID, ExpectedVersion: 1, Plan: changed}, newID("preview_"))
	if err != nil {
		t.Fatal(err)
	}
	if err = store.db.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err = service.Confirm(context.Background(), owner, ConfirmRequest{ProposalID: proposal.ID, Digest: proposal.Digest, IdempotencyKey: newID("offline_")}); err == nil {
		t.Fatal("disconnected authority applied a plan")
	}
	reconnected := NewService(isolatedPostgres(t))
	plan, err := reconnected.GetPlan(context.Background(), owner, initial.Plan.ID)
	if err != nil || plan.Version != 1 || plan.Title != initial.Plan.Title {
		t.Fatalf("reconnection replayed an unconfirmed mutation: %+v %v", plan, err)
	}
	if _, err = reconnected.GetProposalOperation(context.Background(), owner, proposal.ID); !errors.Is(err, ErrUncertain) {
		t.Fatalf("offline attempt falsely has a receipt: %v", err)
	}
	fresh, err := reconnected.PreviewPlan(context.Background(), owner, PlanPreviewRequest{TargetID: plan.ID, ExpectedVersion: plan.Version, Plan: changed}, newID("fresh_"))
	if err != nil || fresh.ID == proposal.ID {
		t.Fatalf("fresh review unavailable: %+v %v", fresh, err)
	}
	still, err := reconnected.GetPlan(context.Background(), owner, plan.ID)
	if err != nil || still.Version != 1 {
		t.Fatal("fresh preview itself wrote the plan")
	}
}
