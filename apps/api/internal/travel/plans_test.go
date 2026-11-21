package travel

import (
	"context"
	"encoding/json"
	"errors"
	"sync"
	"testing"
	"time"
)

// The store double replaces only PostgreSQL transactions. The real service
// validates proposals, calculates digests, consumes confirmation and applies CAS.
type testPlanStore struct {
	mu   sync.Mutex
	rows map[string]AccountState
	fail bool
}

func cloneAccount(s AccountState) AccountState {
	b, _ := json.Marshal(s)
	var out AccountState
	_ = json.Unmarshal(b, &out)
	return out
}

func (s *testPlanStore) Read(ctx context.Context, owner string) (AccountState, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.fail {
		return AccountState{}, errors.New("disk unavailable")
	}
	return cloneAccount(s.rows[owner]), nil
}

func (s *testPlanStore) Update(ctx context.Context, owner string, update func(*AccountState) error) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.fail {
		return errors.New("disk unavailable")
	}
	copy := cloneAccount(s.rows[owner])
	copy.initialize()
	if err := update(&copy); err != nil {
		return err
	}
	s.rows[owner] = copy
	return nil
}

func testService() (*Service, *testPlanStore) {
	store := &testPlanStore{rows: map[string]AccountState{}}
	s := NewService(store)
	s.now = func() time.Time { return time.Date(2026, 11, 2, 9, 0, 0, 0, time.UTC) }
	return s, store
}

func fixturePlan() PlanInput {
	return PlanInput{StablePlanID: "stable_weekend", Title: "A quiet weekend",
		DateScope: DateScope{Kind: "undated"},
		Days:      []PlanDay{{ID: "day_1", Label: "First day", Stops: []PlanStop{{ID: "stop_1", CandidateRef: "candidate_1", Title: "Visit the garden", Time: StopTime{Kind: "unscheduled"}, ClaimRefs: []string{"claim_address"}}}}}}
}

func adopt(t *testing.T, s *Service, owner string, input PlanInput) Operation {
	t.Helper()
	p, err := s.PreviewPlan(context.Background(), owner, PlanPreviewRequest{Plan: input}, "preview-create")
	if err != nil {
		t.Fatal(err)
	}
	op, err := s.Confirm(context.Background(), owner, ConfirmRequest{ProposalID: p.ID, Digest: p.Digest, IdempotencyKey: "confirm-create"})
	if err != nil {
		t.Fatal(err)
	}
	return op
}

func TestPlanA18A28PreviewAndRejectionNeverChangeExistingPlan(t *testing.T) {
	s, _ := testService()
	op := adopt(t, s, "owner-a", fixturePlan())
	before, _ := s.GetPlan(context.Background(), "owner-a", op.Plan.ID)
	changed := fixturePlan()
	changed.Title = "An active weekend"
	p, err := s.PreviewPlan(context.Background(), "owner-a", PlanPreviewRequest{TargetID: before.ID, ExpectedVersion: 1, Plan: changed}, "preview-change")
	if err != nil {
		t.Fatal(err)
	}
	after, _ := s.GetPlan(context.Background(), "owner-a", before.ID)
	if p.Before == nil || p.Before.Title != "A quiet weekend" || p.After.Title != "An active weekend" || after.Title != before.Title || after.Version != 1 {
		t.Fatal("preview modified the formal record or omitted before/after")
	}
}

func TestPlanA25ConcurrentChangesUseVersionCAS(t *testing.T) {
	s, _ := testService()
	op := adopt(t, s, "owner-a", fixturePlan())
	change := fixturePlan()
	change.Title = "First revision"
	p1, _ := s.PreviewPlan(context.Background(), "owner-a", PlanPreviewRequest{TargetID: op.Plan.ID, ExpectedVersion: 1, Plan: change}, "preview-one")
	change.Title = "Other device revision"
	p2, _ := s.PreviewPlan(context.Background(), "owner-a", PlanPreviewRequest{TargetID: op.Plan.ID, ExpectedVersion: 1, Plan: change}, "preview-two")
	if _, err := s.Confirm(context.Background(), "owner-a", ConfirmRequest{ProposalID: p1.ID, Digest: p1.Digest, IdempotencyKey: "confirm-one"}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Confirm(context.Background(), "owner-a", ConfirmRequest{ProposalID: p2.ID, Digest: p2.Digest, IdempotencyKey: "confirm-two"}); !errors.Is(err, ErrVersionConflict) {
		t.Fatalf("stale overwrite not rejected: %v", err)
	}
	got, _ := s.GetPlan(context.Background(), "owner-a", op.Plan.ID)
	if got.Version != 2 || got.Title != "First revision" {
		t.Fatal("CAS lost a committed revision")
	}
}

func TestPlanA26A43OwnerAndDigestAreRequired(t *testing.T) {
	s, _ := testService()
	p, _ := s.PreviewPlan(context.Background(), "owner-a", PlanPreviewRequest{Plan: fixturePlan()}, "preview")
	if _, err := s.Confirm(context.Background(), "owner-b", ConfirmRequest{ProposalID: p.ID, Digest: p.Digest, IdempotencyKey: "confirm"}); !errors.Is(err, ErrNotFound) {
		t.Fatalf("cross-owner proposal: %v", err)
	}
	if _, err := s.Confirm(context.Background(), "owner-a", ConfirmRequest{ProposalID: p.ID, Digest: "tampered", IdempotencyKey: "confirm"}); !errors.Is(err, ErrDigestMismatch) {
		t.Fatalf("tampered digest: %v", err)
	}
	op, err := s.Confirm(context.Background(), "owner-a", ConfirmRequest{ProposalID: p.ID, Digest: p.Digest, IdempotencyKey: "confirm"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.GetPlan(context.Background(), "owner-b", op.Plan.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("cross-owner plan: %v", err)
	}
	if _, err := s.GetOperation(context.Background(), "owner-b", op.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("cross-owner operation: %v", err)
	}
}

func TestPlanA17A24A43ConfirmationRetriesReuseReceipt(t *testing.T) {
	s, _ := testService()
	p, _ := s.PreviewPlan(context.Background(), "owner-a", PlanPreviewRequest{Plan: fixturePlan()}, "preview")
	request := ConfirmRequest{ProposalID: p.ID, Digest: p.Digest, IdempotencyKey: "confirm"}
	a, err := s.Confirm(context.Background(), "owner-a", request)
	if err != nil {
		t.Fatal(err)
	}
	b, err := s.Confirm(context.Background(), "owner-a", request)
	if err != nil {
		t.Fatal(err)
	}
	if a.ID != b.ID || a.Plan.ID != b.Plan.ID || b.Plan.Version != 1 {
		t.Fatal("confirmation retry duplicated formal plan")
	}
	request.Digest = "different"
	if _, err := s.Confirm(context.Background(), "owner-a", request); !errors.Is(err, ErrIdempotencyConflict) {
		t.Fatalf("changed payload reused key: %v", err)
	}
}

func TestPlanA27ExpiredProposalCannotWrite(t *testing.T) {
	s, store := testService()
	p, _ := s.PreviewPlan(context.Background(), "owner-a", PlanPreviewRequest{Plan: fixturePlan()}, "preview")
	s.now = func() time.Time { return time.Date(2026, 11, 2, 9, 16, 0, 0, time.UTC) }
	if _, err := s.Confirm(context.Background(), "owner-a", ConfirmRequest{ProposalID: p.ID, Digest: p.Digest, IdempotencyKey: "confirm"}); !errors.Is(err, ErrProposalExpired) {
		t.Fatalf("expired proposal applied: %v", err)
	}
	state, _ := store.Read(context.Background(), "owner-a")
	if len(state.Plans) != 0 || len(state.Operations) != 0 {
		t.Fatal("expired proposal caused a mutation")
	}
}

func TestPlanA21A36TransactionFailureDoesNotConsumeOrWrite(t *testing.T) {
	s, store := testService()
	p, _ := s.PreviewPlan(context.Background(), "owner-a", PlanPreviewRequest{Plan: fixturePlan()}, "preview")
	store.fail = true
	request := ConfirmRequest{ProposalID: p.ID, Digest: p.Digest, IdempotencyKey: "confirm"}
	if _, err := s.Confirm(context.Background(), "owner-a", request); err == nil {
		t.Fatal("storage failure hidden")
	}
	store.fail = false
	op, err := s.Confirm(context.Background(), "owner-a", request)
	if err != nil || op.State != "succeeded" {
		t.Fatalf("atomic recovery failed: %+v %v", op, err)
	}
	state, _ := store.Read(context.Background(), "owner-a")
	if len(state.Plans) != 1 || len(state.Operations) != 1 {
		t.Fatal("transaction failure duplicated mutation")
	}
}

func TestPlanA11A20A42UndatedCandidateNeedsNoFabricatedExperience(t *testing.T) {
	s, _ := testService()
	op := adopt(t, s, "owner-a", fixturePlan())
	stop := op.Plan.Days[0].Stops[0]
	if op.Plan.DateScope.Kind != "undated" || stop.Time.Kind != "unscheduled" || stop.ExperienceRef != "" || stop.Place != nil || stop.CandidateRef != "candidate_1" || op.Plan.SchemaVersion != 2 {
		t.Fatal("adoption fabricated date, place or public experience")
	}
	invalid := fixturePlan()
	invalid.Days[0].Stops[0].Time = StopTime{Kind: "fixed", Instant: "2026-11-02T09:00:00Z", Timezone: "Asia/Tokyo"}
	if _, err := s.PreviewPlan(context.Background(), "owner-a", PlanPreviewRequest{Plan: invalid}, "bad-date"); !errors.Is(err, ErrInvalidArguments) {
		t.Fatalf("undated fixed time allowed: %v", err)
	}
}

func TestPlanA19LockedOrderCannotMoveToAnotherUndatedDay(t *testing.T) {
	s, _ := testService()
	input := fixturePlan()
	input.Days[0].Stops[0].LockedFields = []string{"order"}
	op := adopt(t, s, "owner", input)
	stop := input.Days[0].Stops[0]
	input.Days[0].Stops = []PlanStop{}
	input.Days = append(input.Days, PlanDay{ID: "day_2", Label: "Second day", Stops: []PlanStop{stop}})
	_, err := s.PreviewPlan(context.Background(), "owner", PlanPreviewRequest{TargetID: op.Plan.ID, ExpectedVersion: 1, Plan: input}, "move")
	if !errors.Is(err, ErrLockedField) {
		t.Fatalf("locked stop moved to another day: %v", err)
	}
}

func TestPlanA19NativeTitleAndPlaceLocksSurviveAuthority(t *testing.T) {
	p := fixturePlan()
	p.Days[0].Stops[0].LockedFields = []string{"title", "place", "time", "order"}
	p.Days[0].Stops[0].Place = &PlanPlace{Ref: "real", Name: "Garden", Coordinates: [2]float64{139, 35}}
	if err := ValidatePlan(p); err != nil {
		t.Fatal("native lock schema rejected:", err)
	}
	changed := p
	changed.Days = append([]PlanDay{}, p.Days...)
	changed.Days[0].Stops = append([]PlanStop{}, p.Days[0].Stops...)
	changed.Days[0].Stops[0].Title = "Replaced"
	if err := checkLocked(p, changed); !errors.Is(err, ErrLockedField) {
		t.Fatal("title lock not enforced", err)
	}
	changed.Days[0].Stops[0].Title = p.Days[0].Stops[0].Title
	place := *p.Days[0].Stops[0].Place
	place.Coordinates[0] = 140
	changed.Days[0].Stops[0].Place = &place
	if err := checkLocked(p, changed); !errors.Is(err, ErrLockedField) {
		t.Fatal("place lock not enforced", err)
	}
}

func TestPlanA24A33ProposalLookupRecoversLostConfirmationReceipt(t *testing.T) {
	s, _ := testService()
	ctx := context.Background()
	proposal, err := s.PreviewPlan(ctx, "owner", PlanPreviewRequest{Plan: fixturePlan()}, "lookup-preview")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.GetProposalOperation(ctx, "owner", proposal.ID); !errors.Is(err, ErrUncertain) {
		t.Fatal("unsubmitted preview claimed a result", err)
	}
	confirmed, err := s.Confirm(ctx, "owner", ConfirmRequest{ProposalID: proposal.ID, Digest: proposal.Digest, IdempotencyKey: "lookup-confirm"})
	if err != nil {
		t.Fatal(err)
	}
	recovered, err := s.GetProposalOperation(ctx, "owner", proposal.ID)
	if err != nil || recovered.ID != confirmed.ID {
		t.Fatal("lost response cannot be resolved by proposal", err)
	}
	if _, err := s.GetProposalOperation(ctx, "other", proposal.ID); !errors.Is(err, ErrNotFound) {
		t.Fatal("lookup disclosed other owner", err)
	}
}

func TestPlanA19OnlyTrustedUserPreviewCanChangeLockedFields(t *testing.T) {
	s, _ := testService()
	ctx := context.Background()
	p := fixturePlan()
	p.Days[0].Stops[0].LockedFields = []string{"title"}
	old := adopt(t, s, "owner", p)
	changed := fixturePlan()
	changed.Days[0].Stops[0].Title = "User edited title"
	changed.Days[0].Stops[0].LockedFields = []string{"title"}
	request := PlanPreviewRequest{TargetID: old.Plan.ID, ExpectedVersion: old.Plan.Version, Plan: changed}
	if _, err := s.PreviewPlan(ctx, "owner", request, "model-locked"); !errors.Is(err, ErrLockedField) {
		t.Fatal("model bypassed lock", err)
	}
	proposal, err := s.PreviewUserPlan(ctx, "owner", request, "user-locked")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Confirm(ctx, "owner", ConfirmRequest{ProposalID: proposal.ID, Digest: proposal.Digest, IdempotencyKey: "user-confirm"}); err != nil {
		t.Fatal("trusted preview could not apply explicit user edit", err)
	}
}

func TestPlanA42KnownPlaceTimezoneCannotBecomeDeviceTimezone(t *testing.T) {
	s, _ := testService()
	p := fixturePlan()
	p.Days[0].Stops[0].Place = &PlanPlace{Ref: "kyoto", Name: "EVAL Kyoto place", Coordinates: [2]float64{135.76, 35.01}, Timezone: "Asia/Tokyo"}
	p.Days[0].Stops[0].Time = StopTime{Kind: "window", StartLocal: "09:00", EndLocal: "12:00", Timezone: "Asia/Shanghai"}
	if _, err := s.PreviewPlan(context.Background(), "owner", PlanPreviewRequest{Plan: p}, "wrong-zone"); !errors.Is(err, ErrInvalidArguments) {
		t.Fatalf("accepted wrong destination zone: %v", err)
	}
	p.Days[0].Stops[0].Time.Timezone = "Asia/Tokyo"
	if _, err := s.PreviewPlan(context.Background(), "owner", PlanPreviewRequest{Plan: p}, "right-zone"); err != nil {
		t.Fatal(err)
	}
}
