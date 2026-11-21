package travel

import (
	"context"
	"errors"
	"testing"
	"time"
)

type testCalendar struct {
	events     map[string]CalendarEvent
	creates    int
	updates    int
	readOnly   bool
	onCreate   func(CalendarEvent) error
	onRead     func()
	tombstones map[string]bool
}

func (p *testCalendar) CheckAccess(_ context.Context, _ string, write bool) error {
	if write && p.readOnly {
		return ErrPermissionRequired
	}
	return nil
}
func (p *testCalendar) List(_ context.Context, _ string, _ string, r CalendarRange) (CalendarPage, error) {
	return CalendarPage{Events: []CalendarEvent{}, Coverage: Coverage{Kind: "complete"}, QueriedRange: r}, nil
}
func (p *testCalendar) Read(_ context.Context, _ string, _ string, id string) (CalendarEvent, error) {
	if p.onRead != nil {
		p.onRead()
	}
	e, ok := p.events[id]
	if !ok {
		return e, ErrNotFound
	}
	return e, nil
}
func (p *testCalendar) Create(_ context.Context, _ string, _ string, e CalendarEvent) (CalendarEvent, error) {
	p.creates++
	if _, exists := p.events[e.ID]; exists || p.tombstones[e.ID] {
		return CalendarEvent{}, ErrUncertain
	}
	if p.onCreate != nil {
		if err := p.onCreate(e); err != nil {
			return CalendarEvent{}, err
		}
	}
	e.Version = "v1"
	p.events[e.ID] = e
	return e, nil
}
func (p *testCalendar) Update(_ context.Context, _ string, _ string, e CalendarEvent, version string) (CalendarEvent, error) {
	p.updates++
	old, ok := p.events[e.ID]
	if !ok {
		return CalendarEvent{}, ErrNotFound
	}
	if old.Version != version {
		return CalendarEvent{}, ErrVersionConflict
	}
	e.Version = "v2"
	p.events[e.ID] = e
	return e, nil
}
func (p *testCalendar) Delete(_ context.Context, _ string, _ string, id, version string) error {
	old, ok := p.events[id]
	if !ok {
		return ErrNotFound
	}
	if old.Version != version {
		return ErrVersionConflict
	}
	if p.tombstones == nil {
		p.tombstones = map[string]bool{}
	}
	p.tombstones[id] = true
	delete(p.events, id)
	return nil
}

func calendarFixture() CalendarPreviewRequest {
	p := fixturePlan()
	p.DateScope = DateScope{Kind: "dated", StartDate: "2026-11-02", EndDate: "2026-11-02", Timezone: "Asia/Tokyo"}
	p.Days[0].Date = "2026-11-02"
	minutes := 30
	p.Days[0].Stops[0].Time = StopTime{Kind: "fixed", Instant: "2026-11-02T09:00:00Z", Timezone: "Asia/Tokyo"}
	p.Days[0].Stops[0].DurationMinutes = &minutes
	return CalendarPreviewRequest{SourceKind: "draft", SourceID: "draft_1", SourceVersion: 1, ContextRevision: 1, Plan: p, CalendarRef: "primary", Changes: []CalendarChange{{StopID: "stop_1", Action: "create"}}}
}

func calendarService() (*Service, *testPlanStore, *testCalendar) {
	s, store := testService()
	p := &testCalendar{events: map[string]CalendarEvent{}}
	s.calendar = p
	return s, store, p
}

func TestCalendarA31ReadOnlyPermissionCannotProduceWriteProposal(t *testing.T) {
	s, store, p := calendarService()
	p.readOnly = true
	if _, err := s.PreviewCalendar(context.Background(), "owner", calendarFixture(), "preview"); !errors.Is(err, ErrPermissionRequired) {
		t.Fatalf("read-only scope upgraded: %v", err)
	}
	state, _ := store.Read(context.Background(), "owner")
	if len(state.Proposals) != 0 || p.creates != 0 {
		t.Fatal("read-only permission caused a write")
	}
}

func TestCalendarA33LostCreateResponseReconcilesWithoutDuplicate(t *testing.T) {
	s, _, p := calendarService()
	p.onCreate = func(e CalendarEvent) error {
		e.Version = "v1"
		p.events[e.ID] = e
		return ProviderFailure{Code: "network_unknown", Uncertain: true}
	}
	proposal, err := s.PreviewCalendar(context.Background(), "owner", calendarFixture(), "preview")
	if err != nil {
		t.Fatal(err)
	}
	request := ConfirmRequest{ProposalID: proposal.ID, Digest: proposal.Digest, IdempotencyKey: "confirm"}
	op, err := s.ConfirmCalendar(context.Background(), "owner", request)
	if err != nil {
		t.Fatal(err)
	}
	if op.State != "uncertain" || op.ReadbackStatus != "pending" {
		t.Fatalf("lost response falsely completed: %+v", op)
	}
	retried, err := s.ConfirmCalendar(context.Background(), "owner", request)
	if err != nil || retried.ID != op.ID || p.creates != 1 {
		t.Fatal("confirmation retry repeated an unknown write")
	}
	op, err = s.Reconcile(context.Background(), "owner", op.ID)
	if err != nil || op.State != "succeeded" || p.creates != 1 {
		t.Fatalf("reconciliation failed: %+v %v", op, err)
	}
}

func TestCalendarA35PartialBatchRetainsEachReceipt(t *testing.T) {
	s, _, p := calendarService()
	input := calendarFixture()
	second := input.Plan.Days[0].Stops[0]
	second.ID = "stop_2"
	second.Title = "Second stop"
	input.Plan.Days[0].Stops = append(input.Plan.Days[0].Stops, second)
	input.Changes = append(input.Changes, CalendarChange{StopID: "stop_2", Action: "create"})
	p.onCreate = func(e CalendarEvent) error {
		if e.Title == "Second stop" {
			return ProviderFailure{Code: "provider_rejected"}
		}
		return nil
	}
	proposal, err := s.PreviewCalendar(context.Background(), "owner", input, "preview")
	if err != nil {
		t.Fatal(err)
	}
	request := ConfirmRequest{ProposalID: proposal.ID, Digest: proposal.Digest, IdempotencyKey: "confirm"}
	op, err := s.ConfirmCalendar(context.Background(), "owner", request)
	if err != nil {
		t.Fatal(err)
	}
	if op.State != "partial" || op.Items[0].State != "succeeded" || op.Items[1].State != "failed" || len(p.events) != 1 {
		t.Fatalf("partial batch misreported: %+v", op)
	}
	_, _ = s.ConfirmCalendar(context.Background(), "owner", request)
	if p.creates != 2 {
		t.Fatal("completed or rejected items replayed")
	}
}

func TestCalendarA36ReceiptFailureReconcilesOriginalOperation(t *testing.T) {
	s, store, p := calendarService()
	p.onCreate = func(e CalendarEvent) error { store.fail = true; return nil }
	proposal, err := s.PreviewCalendar(context.Background(), "owner", calendarFixture(), "preview")
	if err != nil {
		t.Fatal(err)
	}
	op, err := s.ConfirmCalendar(context.Background(), "owner", ConfirmRequest{ProposalID: proposal.ID, Digest: proposal.Digest, IdempotencyKey: "confirm"})
	if op.ID == "" || op.State != "uncertain" {
		t.Fatalf("lost receipt has no recoverable operation: %+v %v", op, err)
	}
	store.fail = false
	op, err = s.Reconcile(context.Background(), "owner", op.ID)
	if err != nil || op.State != "succeeded" || p.creates != 1 {
		t.Fatalf("receipt recovery dispatched duplicate: %+v %v", op, err)
	}
}

func TestCalendarA50DraftAdoptionRetainsBinding(t *testing.T) {
	s, _, p := calendarService()
	input := calendarFixture()
	proposal, err := s.PreviewCalendar(context.Background(), "owner", input, "calendar-preview")
	if err != nil {
		t.Fatal(err)
	}
	op, err := s.ConfirmCalendar(context.Background(), "owner", ConfirmRequest{ProposalID: proposal.ID, Digest: proposal.Digest, IdempotencyKey: "calendar-confirm"})
	if err != nil || op.State != "succeeded" {
		t.Fatalf("calendar create: %v", err)
	}
	formal := adopt(t, s, "owner", input.Plan)
	input.SourceKind = "itinerary"
	input.SourceID = formal.Plan.ID
	input.SourceVersion = formal.Plan.Version
	again, err := s.PreviewCalendar(context.Background(), "owner", input, "calendar-again")
	if err != nil {
		t.Fatal(err)
	}
	if again.Calendar.Items[0].Change.Action != "noop" {
		t.Fatal("adoption lost existing binding")
	}
	_, err = s.ConfirmCalendar(context.Background(), "owner", ConfirmRequest{ProposalID: again.ID, Digest: again.Digest, IdempotencyKey: "again-confirm"})
	if err != nil || p.creates != 1 || p.updates != 0 {
		t.Fatal("adopted draft exported a duplicate event")
	}
}

func TestCalendarA34A37ETagChangeDoesNotOverwriteManualEdit(t *testing.T) {
	s, _, p := calendarService()
	input := calendarFixture()
	proposal, _ := s.PreviewCalendar(context.Background(), "owner", input, "create-preview")
	op, err := s.ConfirmCalendar(context.Background(), "owner", ConfirmRequest{ProposalID: proposal.ID, Digest: proposal.Digest, IdempotencyKey: "create-confirm"})
	if err != nil {
		t.Fatal(err)
	}
	id := op.Items[0].EventRef
	input.Plan.Days[0].Stops[0].Title = "Changed visit"
	input.Changes[0] = CalendarChange{StopID: "stop_1", Action: "update", EventRef: id, ExpectedProviderVersion: "v1"}
	proposal, err = s.PreviewCalendar(context.Background(), "owner", input, "update-preview")
	if err != nil {
		t.Fatal(err)
	}
	manual := p.events[id]
	manual.Title = "My manual edit"
	manual.Version = "manual-v2"
	p.events[id] = manual
	op, err = s.ConfirmCalendar(context.Background(), "owner", ConfirmRequest{ProposalID: proposal.ID, Digest: proposal.Digest, IdempotencyKey: "update-confirm"})
	if err != nil || op.State != "failed" || p.events[id].Title != "My manual edit" || p.updates != 0 {
		t.Fatalf("manual edit overwritten: %+v %v", op, err)
	}
}

func TestCalendarA52ExpiredFailedOperationNeedsNewPreview(t *testing.T) {
	s, _, p := calendarService()
	p.onCreate = func(CalendarEvent) error { return ProviderFailure{Code: "provider_rejected"} }
	proposal, _ := s.PreviewCalendar(context.Background(), "owner", calendarFixture(), "preview")
	request := ConfirmRequest{ProposalID: proposal.ID, Digest: proposal.Digest, IdempotencyKey: "confirm"}
	op, err := s.ConfirmCalendar(context.Background(), "owner", request)
	if err != nil || op.State != "failed" {
		t.Fatalf("unexpected initial state: %+v %v", op, err)
	}
	s.now = func() time.Time { return time.Date(2026, 11, 2, 10, 0, 0, 0, time.UTC) }
	p.onCreate = nil
	_, _ = s.ConfirmCalendar(context.Background(), "owner", request)
	if p.creates != 1 || len(p.events) != 0 {
		t.Fatal("used/expired confirmation retried provider write")
	}
}

func TestCalendarA33A36LateReceiptCannotRegressStartedItemToPending(t *testing.T) {
	s, store, _ := calendarService()
	intent := calendarFixture()
	calendar := CalendarPlan{StablePlanID: intent.Plan.StablePlanID, SourceKind: "draft", SourceID: "d", SourceVersion: 1, CalendarRef: "primary"}
	old := Operation{ID: "op", Digest: "digest", Items: []CalendarItem{{State: "uncertain", Change: CalendarChange{StopID: "s1"}}, {State: "pending", Change: CalendarChange{StopID: "s2"}}}}
	if err := store.Update(context.Background(), "owner", func(st *AccountState) error {
		latest := old
		latest.Items = append([]CalendarItem{}, old.Items...)
		latest.Items[1].State = "started"
		st.Operations["op"] = latest
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if err := s.persistCalendarReceipt(context.Background(), "owner", old, calendar); err != nil {
		t.Fatal(err)
	}
	got, err := s.GetOperation(context.Background(), "owner", "op")
	if err != nil || got.Items[1].State != "started" {
		t.Fatalf("late reconciliation lost dispatched claim: %+v %v", got, err)
	}
}

func TestCalendarA33EquivalentProviderTimestampFormatsAreVerified(t *testing.T) {
	a := CalendarEvent{ID: "e", Title: "Visit", Start: "2026-11-02T09:00:00Z", End: "2026-11-02T10:00:00Z", Timezone: "Asia/Tokyo"}
	b := a
	b.Start = "2026-11-02T18:00:00.000+09:00"
	b.End = "2026-11-02T19:00:00+09:00"
	if !sameCalendarFields(a, b) {
		t.Fatal("equivalent normalized provider instants falsely uncertain")
	}
	b.End = "2026-11-02T19:01:00+09:00"
	if sameCalendarFields(a, b) {
		t.Fatal("changed instant falsely verified")
	}
}

func TestCalendarA51DeletedDraftKeepsBindingAndSeparateRemovalPreview(t *testing.T) {
	s, store, p := calendarService()
	ctx := context.Background()
	proposal, err := s.PreviewCalendar(ctx, "owner", calendarFixture(), "initial-preview")
	if err != nil {
		t.Fatal(err)
	}
	op, err := s.ConfirmCalendar(ctx, "owner", ConfirmRequest{ProposalID: proposal.ID, Digest: proposal.Digest, IdempotencyKey: "initial-confirm"})
	if err != nil || op.State != "succeeded" {
		t.Fatal(err, op.State)
	}
	state, _ := store.Read(ctx, "owner")
	var binding CalendarBinding
	for _, b := range state.Bindings {
		binding = b
	}
	removal, err := s.PreviewBoundCalendarDelete(ctx, "owner", binding, "remove-preview")
	if err != nil || removal.Calendar.Items[0].Before == nil || removal.Calendar.Items[0].After != nil || len(p.events) != 1 {
		t.Fatal("removal preview changed or lost external event", err)
	}
	if _, err := s.PreviewBoundCalendarDelete(ctx, "other", binding, "remove-other"); !errors.Is(err, ErrNotFound) {
		t.Fatal("binding leaked across owner", err)
	}
	removed, err := s.ConfirmCalendar(ctx, "owner", ConfirmRequest{ProposalID: removal.ID, Digest: removal.Digest, ContextRevision: removal.ContextRevision, IdempotencyKey: "remove-confirm"})
	if err != nil || removed.State != "succeeded" || len(p.events) != 0 {
		t.Fatal("separately confirmed removal failed", err, removed.State)
	}
	if err := s.persistCalendarReceipt(ctx, "owner", op, *proposal.Calendar); err != nil {
		t.Fatal(err)
	}
	latest, _ := store.Read(ctx, "owner")
	if len(latest.Bindings) != 0 {
		t.Fatal("late original receipt resurrected deleted calendar binding")
	}
}

func previewTestCalendar(t *testing.T, s *Service, owner string, input CalendarPreviewRequest, key string) Proposal {
	t.Helper()
	proposal, err := s.PreviewCalendar(context.Background(), owner, input, key)
	if err != nil {
		t.Fatal(err)
	}
	return proposal
}
func confirmTestCalendar(t *testing.T, s *Service, owner string, proposal Proposal, key string) Operation {
	t.Helper()
	op, err := s.ConfirmCalendar(context.Background(), owner, ConfirmRequest{ProposalID: proposal.ID, Digest: proposal.Digest, IdempotencyKey: key})
	if err != nil || op.State != "succeeded" {
		t.Fatalf("confirm: %s %v", op.State, err)
	}
	return op
}
func TestCalendarRecreateAfterDeleteUsesNewIDAndRejectsStalePreview(t *testing.T) {
	s, _, p := calendarService()
	input := calendarFixture()
	stale := previewTestCalendar(t, s, "owner", input, "stale")
	first := confirmTestCalendar(t, s, "owner", previewTestCalendar(t, s, "owner", input, "first"), "first")
	input.Changes[0].Action = "delete"
	confirmTestCalendar(t, s, "owner", previewTestCalendar(t, s, "owner", input, "delete"), "delete")
	_, err := s.ConfirmCalendar(context.Background(), "owner", ConfirmRequest{ProposalID: stale.ID, Digest: stale.Digest, IdempotencyKey: "stale"})
	if !errors.Is(err, ErrVersionConflict) {
		t.Errorf("stale generation accepted: %v", err)
	}
	input.Changes[0].Action = "create"
	next := confirmTestCalendar(t, s, "owner", previewTestCalendar(t, s, "owner", input, "next"), "next")
	if next.Items[0].EventRef == first.Items[0].EventRef || p.creates != 2 {
		t.Fatal("deleted ID reused or stale preview dispatched")
	}
}
func TestCalendarConcurrentCreatePreviewsClaimOnce(t *testing.T) {
	s, _, p := calendarService()
	input := calendarFixture()
	a := previewTestCalendar(t, s, "owner", input, "a")
	b := previewTestCalendar(t, s, "owner", input, "b")
	// The competing confirmation runs after A's owner transaction, before its provider response.
	p.onCreate = func(CalendarEvent) error {
		p.onCreate = nil
		_, err := s.ConfirmCalendar(context.Background(), "owner", ConfirmRequest{ProposalID: b.ID, Digest: b.Digest, IdempotencyKey: "b"})
		if !errors.Is(err, ErrVersionConflict) {
			t.Errorf("competing preview dispatched: %v", err)
		}
		return nil
	}
	confirmTestCalendar(t, s, "owner", a, "a")
	if p.creates != 1 {
		t.Fatal("duplicate provider write")
	}
}
func TestCalendarNoopReceiptRecovery(t *testing.T) {
	for _, change := range []string{"none", "version", "fields", "deleted"} {
		t.Run(change, func(t *testing.T) {
			s, store, p := calendarService()
			input := calendarFixture()
			first := confirmTestCalendar(t, s, "owner", previewTestCalendar(t, s, "owner", input, "first"), "first")
			proposal := previewTestCalendar(t, s, "owner", input, "noop")
			if proposal.Calendar.Items[0].Change.Action != "noop" {
				t.Fatal("expected noop")
			}
			p.onRead = func() { store.fail = true }
			op, err := s.ConfirmCalendar(context.Background(), "owner", ConfirmRequest{ProposalID: proposal.ID, Digest: proposal.Digest, IdempotencyKey: "noop"})
			if err != nil || op.State != "uncertain" {
				t.Fatalf("receipt loss: %s %v", op.State, err)
			}
			p.onRead = nil
			store.fail = false
			e := p.events[first.Items[0].EventRef]
			if change == "version" {
				e.Version = "manual"
			}
			if change == "fields" {
				e.Title = "manual"
			}
			p.events[e.ID] = e
			if change == "deleted" {
				delete(p.events, e.ID)
			}
			op, err = s.Reconcile(context.Background(), "owner", op.ID)
			expected := "succeeded"
			if change != "none" {
				expected = "failed"
			}
			if err != nil || op.State != expected || p.creates != 1 || p.updates != 0 {
				t.Fatalf("noop recovery: %s %v, writes %d/%d", op.State, err, p.creates, p.updates)
			}
			if change != "none" && op.Items[0].ErrorCode != "version_conflict" {
				t.Fatal("changed snapshot did not report conflict")
			}
		})
	}
}

func TestCalendarLegacyDeletedGenerationCannotBeReused(t *testing.T) {
	s, store, p := calendarService()
	ctx := context.Background()
	input := calendarFixture()
	legacy := previewTestCalendar(t, s, "owner", input, "legacy")
	legacyID := "rr" + hashText("owner" + "\x00" + calendarBindingKey(input.Plan.StablePlanID, "stop_1", "primary"))[:40]
	// Old owner JSON contains no generation map or item generation, but retains operations.
	if err := store.Update(ctx, "owner", func(st *AccountState) error {
		st.CalendarGenerations = nil
		old := legacy
		old.ID = "old"
		old.Calendar = &CalendarPlan{StablePlanID: input.Plan.StablePlanID, CalendarRef: "primary"}
		st.Proposals[old.ID] = old
		st.Operations["old-op"] = Operation{ID: "old-op", ProposalID: old.ID, State: "succeeded", Items: []CalendarItem{{Change: CalendarChange{Action: "create", StopID: "stop_1"}, EventRef: legacyID, State: "succeeded"}}}
		legacy.Calendar.Items[0].CreationGeneration = 0
		legacy.Calendar.Items[0].After.ID = legacyID
		legacy.Calendar.Items[0].EventRef = legacyID
		st.Proposals[legacy.ID] = legacy
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	p.tombstones = map[string]bool{legacyID: true}
	_, err := s.ConfirmCalendar(ctx, "owner", ConfirmRequest{ProposalID: legacy.ID, Digest: legacy.Digest, IdempotencyKey: "legacy"})
	if !errors.Is(err, ErrVersionConflict) || p.creates != 0 {
		t.Fatalf("legacy deleted generation reused: %v writes %d", err, p.creates)
	}
	next := confirmTestCalendar(t, s, "owner", previewTestCalendar(t, s, "owner", input, "new"), "new")
	if next.Items[0].EventRef == legacyID {
		t.Fatal("new preview reused legacy ID")
	}
}

func TestCalendarCreationGenerationIsolation(t *testing.T) {
	s, store, _ := calendarService()
	input := calendarFixture()
	a := confirmTestCalendar(t, s, "owner", previewTestCalendar(t, s, "owner", input, "a"), "a")
	ids := map[string]bool{a.Items[0].EventRef: true}
	for _, scope := range []string{"owner", "calendar", "stop"} {
		other := calendarFixture()
		owner := "owner"
		switch scope {
		case "owner":
			owner = "other"
		case "calendar":
			other.CalendarRef = "other"
		case "stop":
			other.Plan.Days[0].Stops[0].ID = "stop_2"
			other.Changes[0].StopID = "stop_2"
		}
		op := confirmTestCalendar(t, s, owner, previewTestCalendar(t, s, owner, other, scope), scope)
		if ids[op.Items[0].EventRef] {
			t.Fatal("creation identity crossed scope")
		}
		ids[op.Items[0].EventRef] = true
	}
	state, _ := store.Read(context.Background(), "owner")
	if len(state.Bindings) != 3 {
		t.Fatal("scope binding lost")
	}
}

func TestCalendarLegacyPreviewAndPendingReceiptKeepOriginalIdentity(t *testing.T) {
	s, store, p := calendarService()
	ctx := context.Background()
	input := calendarFixture()
	proposal := previewTestCalendar(t, s, "owner", input, "legacy")
	legacyID := "rr" + hashText("owner" + "\x00" + calendarBindingKey(input.Plan.StablePlanID, "stop_1", "primary"))[:40]
	if err := store.Update(ctx, "owner", func(st *AccountState) error {
		proposal.Calendar.Items[0].CreationGeneration = 0
		proposal.Calendar.Items[0].After.ID = legacyID
		proposal.Calendar.Items[0].EventRef = legacyID
		st.Proposals[proposal.ID] = proposal
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	p.onCreate = func(e CalendarEvent) error {
		e.Version = "v1"
		p.events[e.ID] = e
		return ProviderFailure{Code: "network_unknown", Uncertain: true}
	}
	request := ConfirmRequest{ProposalID: proposal.ID, Digest: proposal.Digest, IdempotencyKey: "legacy"}
	op, err := s.ConfirmCalendar(ctx, "owner", request)
	if err != nil || op.State != "uncertain" || op.Items[0].EventRef != legacyID {
		t.Fatalf("legacy confirmation: %+v %v", op, err)
	}
	// Reload an old pending owner record without the new JSON map.
	if err = store.Update(ctx, "owner", func(st *AccountState) error { st.CalendarGenerations = nil; return nil }); err != nil {
		t.Fatal(err)
	}
	replay, err := s.ConfirmCalendar(ctx, "owner", request)
	if err != nil || replay.ID != op.ID || p.creates != 1 {
		t.Fatal("legacy replay dispatched")
	}
	if _, err = s.PreviewCalendar(ctx, "owner", input, "blocked"); !errors.Is(err, ErrUncertain) {
		t.Fatalf("legacy unresolved claim not blocked: %v", err)
	}
	op, err = s.Reconcile(ctx, "owner", op.ID)
	if err != nil || op.State != "succeeded" || p.creates != 1 || op.Items[0].EventRef != legacyID {
		t.Fatalf("legacy reconcile: %+v %v", op, err)
	}
}

func calendarBatchFixture() CalendarPreviewRequest {
	input := calendarFixture()
	second := input.Plan.Days[0].Stops[0]
	second.ID = "stop_2"
	second.Title = "Second stop"
	input.Plan.Days[0].Stops = append(input.Plan.Days[0].Stops, second)
	input.Changes = append(input.Changes, CalendarChange{StopID: "stop_2", Action: "create"})
	return input
}
func TestCalendarCancelledBatchReconcilesUnsentItemsForNewPreview(t *testing.T) {
	s, _, p := calendarService()
	input := calendarBatchFixture()
	proposal := previewTestCalendar(t, s, "owner", input, "batch")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	p.onCreate = func(CalendarEvent) error { cancel(); return nil }
	op, err := s.ConfirmCalendar(ctx, "owner", ConfirmRequest{ProposalID: proposal.ID, Digest: proposal.Digest, IdempotencyKey: "batch"})
	if err != nil || op.State != "uncertain" || p.creates != 1 {
		t.Fatalf("cancelled batch: %+v %v", op, err)
	}
	op, err = s.Reconcile(context.Background(), "owner", op.ID)
	if err != nil || op.State != "partial" || op.Items[1].State != "failed" || op.Items[1].ErrorCode != "not_dispatched" {
		t.Fatalf("unsent item remains blocked: %+v %v", op, err)
	}
	p.onCreate = nil
	input.Changes = input.Changes[1:]
	confirmTestCalendar(t, s, "owner", previewTestCalendar(t, s, "owner", input, "remaining"), "remaining")
	if p.creates != 2 {
		t.Fatal("remaining item replayed earlier successful item")
	}
}
func TestCalendarReconcileTerminatesPendingBeforeConcurrentConfirmDispatch(t *testing.T) {
	s, _, p := calendarService()
	input := calendarBatchFixture()
	proposal := previewTestCalendar(t, s, "owner", input, "batch")
	p.onCreate = func(CalendarEvent) error {
		p.onCreate = nil
		state, _ := s.store.Read(context.Background(), "owner")
		var id string
		for key := range state.Operations {
			id = key
		}
		op, err := s.Reconcile(context.Background(), "owner", id)
		if err != nil || op.Items[1].State != "failed" {
			t.Errorf("pending not terminated: %+v %v", op, err)
		}
		return nil
	}
	op, err := s.ConfirmCalendar(context.Background(), "owner", ConfirmRequest{ProposalID: proposal.ID, Digest: proposal.Digest, IdempotencyKey: "batch"})
	if err != nil {
		t.Fatal(err)
	}
	stored, err := s.GetOperation(context.Background(), "owner", op.ID)
	if err != nil || p.creates != 1 || stored.Items[0].State != "succeeded" || stored.Items[1].State != "failed" {
		t.Fatalf("terminated item dispatched or state regressed: %+v %v creates=%d", stored, err, p.creates)
	}
}
