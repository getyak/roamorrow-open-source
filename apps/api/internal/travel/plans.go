package travel

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"math"
	"strings"
	"time"
	_ "time/tzdata" // Alpine runtime has no host zoneinfo; keep IANA validation self-contained.
)

var (
	ErrNotFound            = errors.New("not_found")
	ErrInvalidArguments    = errors.New("invalid_arguments")
	ErrVersionConflict     = errors.New("version_conflict")
	ErrDigestMismatch      = errors.New("digest_mismatch")
	ErrIdempotencyConflict = errors.New("idempotency_conflict")
	ErrProposalExpired     = errors.New("proposal_expired")
	ErrPermissionRequired  = errors.New("permission_required")
	ErrUnavailable         = errors.New("provider_unavailable")
	ErrUnsupported         = errors.New("capability_unsupported")
	ErrUncertain           = errors.New("operation_uncertain")
	ErrLockedField         = errors.New("locked_field")
)

type DateScope struct {
	Kind      string `json:"kind"`
	StartDate string `json:"startDate,omitempty"`
	EndDate   string `json:"endDate,omitempty"`
	Timezone  string `json:"timezone,omitempty"`
}

type StopTime struct {
	Kind       string `json:"kind"`
	Instant    string `json:"instant,omitempty"`
	Timezone   string `json:"timezone,omitempty"`
	StartLocal string `json:"startLocal,omitempty"`
	EndLocal   string `json:"endLocal,omitempty"`
}

type PlanPlace struct {
	Ref         string     `json:"ref"`
	Name        string     `json:"name"`
	Coordinates [2]float64 `json:"coordinates"`
	Timezone    string     `json:"timezone,omitempty"`
}

type PlanStop struct {
	ID              string     `json:"id"`
	Title           string     `json:"title"`
	CandidateRef    string     `json:"candidateRef,omitempty"`
	ExperienceRef   string     `json:"experienceRef,omitempty"`
	Place           *PlanPlace `json:"place,omitempty"`
	Time            StopTime   `json:"time"`
	DurationMinutes *int       `json:"durationMinutes,omitempty"`
	ClaimRefs       []string   `json:"claimRefs"`
	LockedFields    []string   `json:"lockedFields"`
}

type PlanDay struct {
	ID    string     `json:"id"`
	Date  string     `json:"date,omitempty"`
	Label string     `json:"label"`
	Stops []PlanStop `json:"stops"`
}

type PlanInput struct {
	StablePlanID string    `json:"stablePlanId"`
	Title        string    `json:"title"`
	DateScope    DateScope `json:"dateScope"`
	Days         []PlanDay `json:"days"`
	Assumptions  []string  `json:"assumptions"`
}

type Plan struct {
	PlanInput
	ID            string `json:"id"`
	Version       int64  `json:"version"`
	SchemaVersion int    `json:"planSchemaVersion"`
	UpdatedAt     string `json:"updatedAt"`
}

type PlanPreviewRequest struct {
	TargetID        string    `json:"targetId,omitempty"`
	ExpectedVersion int64     `json:"expectedVersion,omitempty"`
	ContextRevision int64     `json:"contextRevision"`
	DraftVersion    int64     `json:"draftVersion"`
	Plan            PlanInput `json:"plan"`
}

type Proposal struct {
	UserEdit        bool          `json:"userEdit,omitempty"`
	ID              string        `json:"id"`
	Kind            string        `json:"kind"`
	Digest          string        `json:"digest"`
	TargetID        string        `json:"targetId,omitempty"`
	BaseVersion     int64         `json:"baseVersion"`
	ContextRevision int64         `json:"contextRevision"`
	DraftVersion    int64         `json:"draftVersion"`
	Before          *Plan         `json:"before,omitempty"`
	After           PlanInput     `json:"after"`
	ExpiresAt       time.Time     `json:"expiresAt"`
	OperationID     string        `json:"operationId,omitempty"`
	Calendar        *CalendarPlan `json:"calendar,omitempty"`
}

type ConfirmRequest struct {
	ProposalID      string `json:"proposalId"`
	Digest          string `json:"digest"`
	ContextRevision int64  `json:"contextRevision,omitempty"`
	IdempotencyKey  string `json:"idempotencyKey"`
}

type Operation struct {
	ID             string         `json:"id"`
	ProposalID     string         `json:"proposalId"`
	Digest         string         `json:"digest"`
	State          string         `json:"state"`
	ReadbackStatus string         `json:"readbackStatus"`
	Plan           *Plan          `json:"plan,omitempty"`
	Items          []CalendarItem `json:"items"`
	AuthorizedTill time.Time      `json:"authorizedTill"`
}

type IdempotencyRecord struct {
	Hash string `json:"hash"`
	Ref  string `json:"ref"`
}

// AccountState is a private aggregate. The PostgreSQL adapter takes the owner
// row lock for every update, including receipt/confirmation consumption.
type AccountState struct {
	// Creation generations are retained after bindings are removed.
	CalendarGenerations map[string]uint64            `json:"calendarGenerations,omitempty"`
	Plans               map[string]Plan              `json:"plans"`
	Proposals           map[string]Proposal          `json:"proposals"`
	Operations          map[string]Operation         `json:"operations"`
	Keys                map[string]IdempotencyRecord `json:"keys"`
	Bindings            map[string]CalendarBinding   `json:"bindings"`
}

func (a *AccountState) initialize() {
	if a.CalendarGenerations == nil {
		a.CalendarGenerations = map[string]uint64{}
	}
	if a.Plans == nil {
		a.Plans = map[string]Plan{}
	}
	if a.Proposals == nil {
		a.Proposals = map[string]Proposal{}
	}
	if a.Operations == nil {
		a.Operations = map[string]Operation{}
	}
	if a.Keys == nil {
		a.Keys = map[string]IdempotencyRecord{}
	}
	if a.Bindings == nil {
		a.Bindings = map[string]CalendarBinding{}
	}
	// Old JSON has no generation counters. Retained creation claims reserve
	// their legacy identity even after the binding was successfully deleted.
	for _, op := range a.Operations {
		proposal := a.Proposals[op.ProposalID]
		if proposal.Calendar == nil {
			continue
		}
		for _, item := range op.Items {
			if item.Change.Action != "create" {
				continue
			}
			generation := item.CreationGeneration
			if generation == 0 {
				generation = 1
			}
			key := calendarBindingKey(proposal.Calendar.StablePlanID, item.Change.StopID, proposal.Calendar.CalendarRef)
			if a.CalendarGenerations[key] < generation {
				a.CalendarGenerations[key] = generation
			}
		}
	}
}

type Store interface {
	Read(context.Context, string) (AccountState, error)
	Update(context.Context, string, func(*AccountState) error) error
}

type Service struct {
	store    Store
	now      func() time.Time
	calendar CalendarProvider
}

func NewService(store Store) *Service { return &Service{store: store, now: time.Now} }

func newID(prefix string) string {
	var value [16]byte
	if _, err := rand.Read(value[:]); err != nil {
		panic("secure randomness unavailable")
	}
	return prefix + hex.EncodeToString(value[:])
}

func canonicalHash(value any) string {
	data, err := json.Marshal(value)
	if err != nil {
		return ""
	}
	return hashText(string(data))
}

func validKey(key string) bool {
	return len(key) >= 1 && len(key) <= 128 && strings.TrimSpace(key) == key
}

func (s *Service) PreviewPlan(ctx context.Context, owner string, request PlanPreviewRequest, key string) (Proposal, error) {
	return s.previewPlan(ctx, owner, request, key, false)
}

// PreviewUserPlan is a trusted host-only preview for explicit native edits or
// unlocking. Models use PreviewPlan and cannot bypass inherited field locks.
func (s *Service) PreviewUserPlan(ctx context.Context, owner string, request PlanPreviewRequest, key string) (Proposal, error) {
	return s.previewPlan(ctx, owner, request, key, true)
}
func (s *Service) previewPlan(ctx context.Context, owner string, request PlanPreviewRequest, key string, userEdit bool) (Proposal, error) {
	var result Proposal
	if owner == "" || s.store == nil {
		return result, ErrUnavailable
	}
	if !validKey(key) || ValidatePlan(request.Plan) != nil {
		return result, ErrInvalidArguments
	}
	hash := canonicalHash(struct {
		Request  PlanPreviewRequest
		UserEdit bool
	}{request, userEdit})
	err := s.store.Update(ctx, owner, func(state *AccountState) error {
		state.initialize()
		if previous, ok := state.Keys["preview:"+key]; ok {
			if previous.Hash != hash {
				return ErrIdempotencyConflict
			}
			var exists bool
			result, exists = state.Proposals[previous.Ref]
			if !exists {
				return ErrNotFound
			}
			return nil
		}
		result = Proposal{ID: newID("proposal_"), Kind: "itinerary", UserEdit: userEdit, TargetID: request.TargetID, BaseVersion: request.ExpectedVersion, After: request.Plan, ExpiresAt: s.now().Add(15 * time.Minute), ContextRevision: request.ContextRevision, DraftVersion: request.DraftVersion}
		if request.TargetID != "" {
			before, ok := state.Plans[request.TargetID]
			if !ok {
				return ErrNotFound
			}
			if before.Version != request.ExpectedVersion || before.StablePlanID != request.Plan.StablePlanID {
				return ErrVersionConflict
			}
			if err := checkLocked(before.PlanInput, request.Plan); err != nil && !userEdit {
				return err
			}
			result.Before = &before
		} else {
			if request.ExpectedVersion != 0 {
				return ErrInvalidArguments
			}
			for _, existing := range state.Plans {
				if existing.StablePlanID == request.Plan.StablePlanID {
					return ErrVersionConflict
				}
			}
		}
		result.Digest = canonicalHash(struct {
			Owner    string
			Proposal Proposal
		}{owner, result})
		state.Proposals[result.ID] = result
		state.Keys["preview:"+key] = IdempotencyRecord{Hash: hash, Ref: result.ID}
		return nil
	})
	return result, err
}

// Confirm is a trusted UI command, never a model tool. The exact immutable
// proposal, its one-use consumption, plan CAS and receipt share one transaction.
func (s *Service) Confirm(ctx context.Context, owner string, request ConfirmRequest) (Operation, error) {
	var result Operation
	if owner == "" || s.store == nil {
		return result, ErrUnavailable
	}
	if !validKey(request.IdempotencyKey) || request.ProposalID == "" || request.Digest == "" {
		return result, ErrInvalidArguments
	}
	hash := canonicalHash(request)
	err := s.store.Update(ctx, owner, func(state *AccountState) error {
		state.initialize()
		if previous, ok := state.Keys["confirm:"+request.IdempotencyKey]; ok {
			if previous.Hash != hash {
				return ErrIdempotencyConflict
			}
			var exists bool
			result, exists = state.Operations[previous.Ref]
			if !exists {
				return ErrNotFound
			}
			return nil
		}
		proposal, ok := state.Proposals[request.ProposalID]
		if !ok {
			return ErrNotFound
		}
		if proposal.Digest != request.Digest {
			return ErrDigestMismatch
		}
		if proposal.OperationID != "" {
			result = state.Operations[proposal.OperationID]
			return nil
		}
		if !s.now().Before(proposal.ExpiresAt) {
			return ErrProposalExpired
		}
		if request.ContextRevision != 0 && request.ContextRevision != proposal.ContextRevision {
			return ErrVersionConflict
		}
		if proposal.Kind != "itinerary" {
			return ErrUnsupported
		}
		id, version := proposal.TargetID, proposal.BaseVersion+1
		if id != "" {
			old, found := state.Plans[id]
			if !found {
				return ErrNotFound
			}
			if old.Version != proposal.BaseVersion {
				return ErrVersionConflict
			}
			if err := checkLocked(old.PlanInput, proposal.After); err != nil && !proposal.UserEdit {
				return err
			}
		} else {
			for _, old := range state.Plans {
				if old.StablePlanID == proposal.After.StablePlanID {
					return ErrVersionConflict
				}
			}
			id = newID("plan_")
		}
		plan := Plan{PlanInput: proposal.After, ID: id, Version: version, SchemaVersion: 2, UpdatedAt: s.now().UTC().Format(time.RFC3339)}
		result = Operation{ID: newID("operation_"), ProposalID: proposal.ID, Digest: proposal.Digest, State: "succeeded", ReadbackStatus: "verified", Plan: &plan, Items: []CalendarItem{}, AuthorizedTill: proposal.ExpiresAt}
		proposal.OperationID = result.ID
		state.Plans[id], state.Proposals[proposal.ID], state.Operations[result.ID] = plan, proposal, result
		for key, binding := range state.Bindings {
			if binding.StablePlanID == plan.StablePlanID {
				binding.SourceKind = "itinerary"
				binding.SourceID = plan.ID
				// Adoption preserves the binding, but does not itself read the
				// provider back against this newly committed plan revision.
				binding.SourceVersion = 0
				state.Bindings[key] = binding
			}
		}
		state.Keys["confirm:"+request.IdempotencyKey] = IdempotencyRecord{Hash: hash, Ref: result.ID}
		return nil
	})
	return result, err
}

func (s *Service) GetPlan(ctx context.Context, owner, id string) (Plan, error) {
	if owner == "" || s.store == nil {
		return Plan{}, ErrUnavailable
	}
	state, err := s.store.Read(ctx, owner)
	if err != nil {
		return Plan{}, err
	}
	plan, ok := state.Plans[id]
	if !ok {
		return Plan{}, ErrNotFound
	}
	return plan, nil
}

func (s *Service) GetOperation(ctx context.Context, owner, id string) (Operation, error) {
	if owner == "" || s.store == nil {
		return Operation{}, ErrUnavailable
	}
	state, err := s.store.Read(ctx, owner)
	if err != nil {
		return Operation{}, err
	}
	op, ok := state.Operations[id]
	if !ok {
		return Operation{}, ErrNotFound
	}
	return op, nil
}

func ValidatePlan(p PlanInput) error {
	if strings.TrimSpace(p.Title) == "" || len([]rune(p.Title)) > 160 || len(p.StablePlanID) < 1 || len(p.StablePlanID) > 128 || len(p.Days) < 1 || len(p.Days) > 14 || len(p.Assumptions) > 10 {
		return ErrInvalidArguments
	}
	var start, end time.Time
	switch p.DateScope.Kind {
	case "undated":
		if p.DateScope.StartDate != "" || p.DateScope.EndDate != "" {
			return ErrInvalidArguments
		}
	case "dated":
		var err error
		start, err = time.Parse(time.DateOnly, p.DateScope.StartDate)
		if err != nil {
			return ErrInvalidArguments
		}
		end, err = time.Parse(time.DateOnly, p.DateScope.EndDate)
		if err != nil || end.Before(start) {
			return ErrInvalidArguments
		}
		if _, err = time.LoadLocation(p.DateScope.Timezone); err != nil || p.DateScope.Timezone == "" {
			return ErrInvalidArguments
		}
	default:
		return ErrInvalidArguments
	}
	seen := map[string]bool{}
	count := 0
	for _, day := range p.Days {
		if day.ID == "" || len(day.ID) > 128 || seen["day:"+day.ID] || len(day.Label) > 500 {
			return ErrInvalidArguments
		}
		seen["day:"+day.ID] = true
		if p.DateScope.Kind == "undated" && day.Date != "" {
			return ErrInvalidArguments
		}
		if p.DateScope.Kind == "dated" {
			d, e := time.Parse(time.DateOnly, day.Date)
			if e != nil || d.Before(start) || d.After(end) {
				return ErrInvalidArguments
			}
		}
		for _, stop := range day.Stops {
			count++
			if count > 50 || stop.ID == "" || len(stop.ID) > 128 || seen["stop:"+stop.ID] || strings.TrimSpace(stop.Title) == "" || len([]rune(stop.Title)) > 300 || (stop.CandidateRef == "" && stop.ExperienceRef == "") || len(stop.ClaimRefs) > 40 {
				return ErrInvalidArguments
			}
			seen["stop:"+stop.ID] = true
			if stop.Place != nil {
				if stop.Place.Timezone != "" {
					if _, err := time.LoadLocation(stop.Place.Timezone); err != nil || stop.Time.Kind != "unscheduled" && stop.Time.Timezone != stop.Place.Timezone {
						return ErrInvalidArguments
					}
				}
				lng, lat := stop.Place.Coordinates[0], stop.Place.Coordinates[1]
				if stop.Place.Ref == "" || math.IsNaN(lng) || math.IsInf(lng, 0) || math.IsNaN(lat) || math.IsInf(lat, 0) || lng < -180 || lng > 180 || lat < -90 || lat > 90 {
					return ErrInvalidArguments
				}
			}
			if stop.DurationMinutes != nil && (*stop.DurationMinutes < 1 || *stop.DurationMinutes > 1440) {
				return ErrInvalidArguments
			}
			switch stop.Time.Kind {
			case "unscheduled":
				if stop.Time.Instant != "" || stop.Time.StartLocal != "" || stop.Time.EndLocal != "" {
					return ErrInvalidArguments
				}
			case "window":
				if stop.Time.Instant != "" {
					return ErrInvalidArguments
				}
				if _, err := time.Parse("15:04", stop.Time.StartLocal); err != nil {
					return ErrInvalidArguments
				}
				if _, err := time.Parse("15:04", stop.Time.EndLocal); err != nil || stop.Time.EndLocal <= stop.Time.StartLocal {
					return ErrInvalidArguments
				}
				if _, err := time.LoadLocation(stop.Time.Timezone); err != nil || stop.Time.Timezone == "" {
					return ErrInvalidArguments
				}
			case "fixed":
				if p.DateScope.Kind != "dated" || stop.Time.StartLocal != "" || stop.Time.EndLocal != "" {
					return ErrInvalidArguments
				}
				instant, err := time.Parse(time.RFC3339, stop.Time.Instant)
				if err != nil || !strings.HasSuffix(stop.Time.Instant, "Z") {
					return ErrInvalidArguments
				}
				zone, err := time.LoadLocation(stop.Time.Timezone)
				if err != nil || stop.Time.Timezone == "" || instant.In(zone).Format(time.DateOnly) != day.Date {
					return ErrInvalidArguments
				}
			default:
				return ErrInvalidArguments
			}
			for _, key := range stop.LockedFields {
				if key != "time" && key != "date" && key != "order" && key != "title" && key != "place" {
					return ErrInvalidArguments
				}
			}
		}
	}
	return nil
}

func samePlace(a, b *PlanPlace) bool {
	if a == nil || b == nil {
		return a == b
	}
	return *a == *b
}

func checkLocked(before, after PlanInput) error {
	type position struct {
		day   string
		dayID string
		index int
		stop  PlanStop
	}
	next := map[string]position{}
	for _, day := range after.Days {
		for i, stop := range day.Stops {
			next[stop.ID] = position{day.Date, day.ID, i, stop}
		}
	}
	for _, day := range before.Days {
		for i, stop := range day.Stops {
			value, ok := next[stop.ID]
			for _, key := range stop.LockedFields {
				if !ok {
					return ErrLockedField
				}
				if !containsString(value.stop.LockedFields, key) {
					return ErrLockedField
				}
				if key == "title" && value.stop.Title != stop.Title || key == "place" && !samePlace(value.stop.Place, stop.Place) || key == "time" && (value.stop.Time != stop.Time || value.stop.DurationMinutes != nil && stop.DurationMinutes != nil && *value.stop.DurationMinutes != *stop.DurationMinutes || (value.stop.DurationMinutes == nil) != (stop.DurationMinutes == nil)) || key == "date" && value.day != day.Date || key == "order" && (value.index != i || value.dayID != day.ID) {
					return ErrLockedField
				}
			}
		}
	}
	return nil
}

func containsString(values []string, value string) bool {
	for _, v := range values {
		if v == value {
			return true
		}
	}
	return false
}

// GetProposalOperation is a read-only recovery path when confirmation reached
// the server but its response never returned an operation ID to the client.
func (s *Service) GetProposalOperation(ctx context.Context, owner, proposalID string) (Operation, error) {
	if s.store == nil {
		return Operation{}, ErrUnavailable
	}
	state, err := s.store.Read(ctx, owner)
	if err != nil {
		return Operation{}, err
	}
	proposal, ok := state.Proposals[proposalID]
	if !ok {
		return Operation{}, ErrNotFound
	}
	if proposal.OperationID == "" {
		return Operation{}, ErrUncertain
	}
	operation, ok := state.Operations[proposal.OperationID]
	if !ok || operation.Digest != proposal.Digest {
		return Operation{}, ErrUncertain
	}
	return operation, nil
}
