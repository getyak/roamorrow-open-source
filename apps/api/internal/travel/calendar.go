package travel

import (
	"context"
	"errors"
	"strconv"
	"strings"
	"time"
)

func (s *Service) SetCalendarProvider(provider CalendarProvider) { s.calendar = provider }

func (s *Service) PreviewCalendar(ctx context.Context, owner string, request CalendarPreviewRequest, key string) (Proposal, error) {
	var result Proposal
	if owner == "" || s.store == nil || s.calendar == nil {
		return result, ErrUnavailable
	}
	if !validKey(key) || ValidatePlan(request.Plan) != nil || request.SourceID == "" || request.SourceVersion < 1 || (request.SourceKind != "draft" && request.SourceKind != "itinerary" && request.SourceKind != "binding") || request.CalendarRef == "" || len(request.CalendarRef) > 256 || len(request.Changes) < 1 || len(request.Changes) > 10 {
		return result, ErrInvalidArguments
	}
	if err := s.calendar.CheckAccess(ctx, owner, true); err != nil {
		return result, err
	}
	state, err := s.store.Read(ctx, owner)
	if err != nil {
		return result, err
	}
	state.initialize()
	hash := canonicalHash(request)
	if old, ok := state.Keys["calendar_preview:"+key]; ok {
		if old.Hash != hash {
			return result, ErrIdempotencyConflict
		}
		return state.Proposals[old.Ref], nil
	}
	if request.SourceKind == "itinerary" {
		plan, ok := state.Plans[request.SourceID]
		if !ok {
			return result, ErrNotFound
		}
		if plan.Version != request.SourceVersion || canonicalHash(plan.PlanInput) != canonicalHash(request.Plan) {
			return result, ErrVersionConflict
		}
	}
	if request.SourceKind == "binding" {
		binding, ok := state.Bindings[request.SourceID]
		operation, exists := state.Operations[binding.OperationID]
		original, present := state.Proposals[operation.ProposalID]
		if !ok || !exists || !present || original.Calendar == nil || request.SourceVersion != 1 || len(request.Changes) != 1 || request.Changes[0].Action != "delete" || request.Changes[0].StopID != binding.StopID || request.CalendarRef != binding.CalendarRef || canonicalHash(request.Plan) != canonicalHash(original.After) {
			return result, ErrNotFound
		}
	}
	stops := map[string]PlanStop{}
	for _, day := range request.Plan.Days {
		for _, stop := range day.Stops {
			stops[stop.ID] = stop
		}
	}
	items := []CalendarItem{}
	seen := map[string]bool{}
	for _, change := range request.Changes {
		stop, ok := stops[change.StopID]
		if !ok || seen[change.StopID] {
			return result, ErrInvalidArguments
		}
		seen[change.StopID] = true
		if change.Action != "create" && change.Action != "update" && change.Action != "delete" {
			return result, ErrInvalidArguments
		}
		bindingKey := calendarBindingKey(request.Plan.StablePlanID, change.StopID, request.CalendarRef)
		binding, bound := state.Bindings[bindingKey]
		for _, operation := range state.Operations {
			previous := state.Proposals[operation.ProposalID]
			if previous.Calendar == nil || previous.Calendar.StablePlanID != request.Plan.StablePlanID || previous.Calendar.CalendarRef != request.CalendarRef {
				continue
			}
			for _, item := range operation.Items {
				if item.Change.StopID == change.StopID && (item.State == "pending" || item.State == "started" || item.State == "uncertain") {
					return result, ErrUncertain
				}
			}
		}
		item := CalendarItem{Change: change, State: "pending", ReadbackStatus: "pending"}
		if bound {
			if change.EventRef != "" && change.EventRef != binding.ProviderEventRef {
				return result, ErrNotFound
			}
			before, readErr := s.calendar.Read(ctx, owner, request.CalendarRef, binding.ProviderEventRef)
			if readErr != nil {
				return result, readErr
			}
			if before.HasAttendees || before.Recurring {
				return result, ErrUnsupported
			}
			if change.ExpectedProviderVersion != "" && change.ExpectedProviderVersion != before.Version {
				return result, ErrVersionConflict
			}
			item.Before = &before
			item.EventRef = before.ID
			item.Change.EventRef = before.ID
			item.Change.ExpectedProviderVersion = before.Version
			if change.Action == "create" {
				item.Change.Action = "update"
			}
		} else if change.Action != "create" {
			return result, ErrUnsupported
		}
		if item.Change.Action != "delete" {
			after, buildErr := eventFromStop(stop)
			if buildErr != nil {
				return result, buildErr
			}
			if item.Before != nil {
				after.ID = item.Before.ID
				after.Private = item.Before.Private
				after.ReminderMinutes = item.Before.ReminderMinutes
				after.UseDefaultReminders = item.Before.UseDefaultReminders
			} else {
				item.CreationGeneration = state.CalendarGenerations[bindingKey] + 1
				if item.CreationGeneration == 0 {
					return result, ErrVersionConflict
				}
				after.ID = "rr" + hashText(owner + "\x00" + bindingKey + "\x00" + strconv.FormatUint(item.CreationGeneration, 10))[:40]
			}
			item.After = &after
			item.EventRef = after.ID
			if item.Before != nil && sameCalendarFields(*item.Before, after) {
				item.Change.Action = "noop"
			}
		}
		items = append(items, item)
	}
	calendar := CalendarPlan{StablePlanID: request.Plan.StablePlanID, SourceKind: request.SourceKind, SourceID: request.SourceID, SourceVersion: request.SourceVersion, CalendarRef: request.CalendarRef, Items: items}
	result = Proposal{ID: newID("proposal_"), Kind: "calendar", ContextRevision: request.ContextRevision, DraftVersion: request.SourceVersion, After: request.Plan, Calendar: &calendar, ExpiresAt: s.now().Add(15 * time.Minute)}
	result.Digest = canonicalHash(struct {
		Owner    string
		Proposal Proposal
	}{owner, result})
	err = s.store.Update(ctx, owner, func(current *AccountState) error {
		current.initialize()
		if old, ok := current.Keys["calendar_preview:"+key]; ok {
			if old.Hash != hash {
				return ErrIdempotencyConflict
			}
			result = current.Proposals[old.Ref]
			return nil
		}
		if request.SourceKind == "itinerary" {
			plan, ok := current.Plans[request.SourceID]
			if !ok || plan.Version != request.SourceVersion {
				return ErrVersionConflict
			}
		}
		// The binding may have changed while provider evidence was being read.
		for _, item := range items {
			bindingKey := calendarBindingKey(calendar.StablePlanID, item.Change.StopID, calendar.CalendarRef)
			binding, ok := current.Bindings[bindingKey]
			old, wasBound := state.Bindings[bindingKey]
			if current.CalendarGenerations[bindingKey] != state.CalendarGenerations[bindingKey] || ok != wasBound || ok && binding != old {
				return ErrVersionConflict
			}
		}
		current.Proposals[result.ID] = result
		current.Keys["calendar_preview:"+key] = IdempotencyRecord{Hash: hash, Ref: result.ID}
		return nil
	})
	return result, err
}

func (s *Service) ConfirmCalendar(ctx context.Context, owner string, request ConfirmRequest) (Operation, error) {
	var operation Operation
	if s.store == nil || s.calendar == nil || owner == "" {
		return operation, ErrUnavailable
	}
	if !validKey(request.IdempotencyKey) || request.ProposalID == "" || request.Digest == "" {
		return operation, ErrInvalidArguments
	}
	if err := s.calendar.CheckAccess(ctx, owner, true); err != nil {
		return operation, err
	}
	fresh := false
	var calendar CalendarPlan
	err := s.store.Update(ctx, owner, func(state *AccountState) error {
		state.initialize()
		hash := canonicalHash(request)
		if previous, ok := state.Keys["calendar_confirm:"+request.IdempotencyKey]; ok {
			if previous.Hash != hash {
				return ErrIdempotencyConflict
			}
			operation = state.Operations[previous.Ref]
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
			operation = state.Operations[proposal.OperationID]
			return nil
		}
		if proposal.Kind != "calendar" || proposal.Calendar == nil {
			return ErrUnsupported
		}
		if !s.now().Before(proposal.ExpiresAt) {
			return ErrProposalExpired
		}
		if request.ContextRevision != 0 && request.ContextRevision != proposal.ContextRevision {
			return ErrVersionConflict
		}
		calendar = *proposal.Calendar
		if calendar.SourceKind == "itinerary" {
			plan, ok := state.Plans[calendar.SourceID]
			if !ok || plan.Version != calendar.SourceVersion {
				return ErrVersionConflict
			}
		}
		// Claim all creation generations atomically with confirmation consumption.
		// Competing previews must fail before either can dispatch the same stop.
		for _, item := range calendar.Items {
			bindingKey := calendarBindingKey(calendar.StablePlanID, item.Change.StopID, calendar.CalendarRef)
			binding, bound := state.Bindings[bindingKey]
			if item.Change.Action == "create" {
				generation := state.CalendarGenerations[bindingKey]
				if bound || generation == ^uint64(0) || (item.CreationGeneration == 0 && generation != 0) || (item.CreationGeneration != 0 && item.CreationGeneration != generation+1) {
					return ErrVersionConflict
				}
			} else if !bound || item.Before == nil || binding.ProviderEventRef != item.Before.ID {
				return ErrVersionConflict
			}
			// Also protect pre-generation operations restored from old owner JSON.
			for _, previous := range state.Operations {
				intent := state.Proposals[previous.ProposalID]
				if intent.Calendar == nil || intent.Calendar.StablePlanID != calendar.StablePlanID || intent.Calendar.CalendarRef != calendar.CalendarRef {
					continue
				}
				for _, claimed := range previous.Items {
					if claimed.Change.StopID == item.Change.StopID && (claimed.State == "pending" || claimed.State == "started" || claimed.State == "uncertain") {
						return ErrVersionConflict
					}
				}
			}
		}
		for _, item := range calendar.Items {
			if item.Change.Action == "create" {
				key := calendarBindingKey(calendar.StablePlanID, item.Change.StopID, calendar.CalendarRef)
				// Legacy previews keep their original provider ID, consuming generation 1.
				generation := item.CreationGeneration
				if generation == 0 {
					generation = 1
				}
				state.CalendarGenerations[key] = generation
			}
		}
		operation = Operation{ID: newID("operation_"), ProposalID: proposal.ID, Digest: proposal.Digest, State: "executing", ReadbackStatus: "pending", Items: append([]CalendarItem{}, calendar.Items...), AuthorizedTill: proposal.ExpiresAt}
		proposal.OperationID = operation.ID
		state.Proposals[proposal.ID] = proposal
		state.Operations[operation.ID] = operation
		state.Keys["calendar_confirm:"+request.IdempotencyKey] = IdempotencyRecord{Hash: hash, Ref: operation.ID}
		fresh = true
		return nil
	})
	if err != nil || !fresh {
		return operation, err
	}
	for index := range operation.Items {
		if ctx.Err() != nil {
			operation.State = "uncertain"
			return operation, nil
		}
		if !s.now().Before(operation.AuthorizedTill) {
			operation.Items[index].State = "failed"
			operation.Items[index].ErrorCode = "proposal_expired"
			continue
		}
		if err = s.calendar.CheckAccess(ctx, owner, true); err != nil {
			operation.Items[index].State = "failed"
			operation.Items[index].ErrorCode = "permission_required"
			continue
		}
		// Claim before dispatch. A started item is never dispatched by a retry.
		err = s.store.Update(ctx, owner, func(state *AccountState) error {
			stored := state.Operations[operation.ID]
			if index >= len(stored.Items) || stored.Items[index].State != "pending" {
				return ErrUncertain
			}
			stored.Items[index].State = "started"
			state.Operations[stored.ID] = stored
			return nil
		})
		if err != nil {
			operation.State = "uncertain"
			return operation, nil
		}
		operation.Items[index].State = "started"
		observed := s.executeCalendarItem(ctx, owner, calendar.CalendarRef, operation.ID, operation.Items[index])
		operation.Items[index] = observed
		if err = s.persistCalendarReceipt(ctx, owner, operation, calendar); err != nil {
			operation.State = "uncertain"
			operation.ReadbackStatus = "pending"
			return operation, nil
		}
	}
	normalizeCalendarOperation(&operation)
	if err = s.persistCalendarReceipt(ctx, owner, operation, calendar); err != nil {
		operation.State = "uncertain"
		operation.ReadbackStatus = "pending"
	}
	return operation, nil
}

func (s *Service) executeCalendarItem(ctx context.Context, owner, calendarRef, operationID string, item CalendarItem) CalendarItem {
	fail := func(err error) CalendarItem {
		var provider ProviderFailure
		if errors.As(err, &provider) && !provider.Uncertain || errors.Is(err, ErrVersionConflict) || errors.Is(err, ErrPermissionRequired) || errors.Is(err, ErrNotFound) || errors.Is(err, ErrUnsupported) {
			item.State = "failed"
			item.ReadbackStatus = "unavailable"
		} else {
			item.State = "uncertain"
			item.ReadbackStatus = "pending"
		}
		switch {
		case errors.Is(err, ErrVersionConflict):
			item.ErrorCode = "version_conflict"
		case errors.Is(err, ErrPermissionRequired):
			item.ErrorCode = "permission_required"
		default:
			item.ErrorCode = "provider_unavailable"
		}
		return item
	}
	if item.Before != nil {
		current, err := s.calendar.Read(ctx, owner, calendarRef, item.Before.ID)
		if err != nil {
			return fail(err)
		}
		if current.Version != item.Change.ExpectedProviderVersion || current.HasAttendees || current.Recurring {
			return fail(ErrVersionConflict)
		}
	}
	if item.Change.Action == "noop" {
		item.State = "succeeded"
		item.ReadbackStatus = "verified"
		item.ProviderVersion = item.Before.Version
		return item
	}
	if item.Change.Action == "delete" {
		if err := s.calendar.Delete(ctx, owner, calendarRef, item.Before.ID, item.Change.ExpectedProviderVersion); err != nil {
			return fail(err)
		}
		_, err := s.calendar.Read(ctx, owner, calendarRef, item.Before.ID)
		if !errors.Is(err, ErrNotFound) {
			return fail(ErrUncertain)
		}
		item.State = "succeeded"
		item.ReadbackStatus = "verified"
		return item
	}
	after := *item.After
	after.Private = cloneStrings(after.Private)
	after.Private["roamorrow_operation"] = operationID
	item.After = &after
	var err error
	if item.Change.Action == "create" {
		_, err = s.calendar.Create(ctx, owner, calendarRef, after)
	} else {
		_, err = s.calendar.Update(ctx, owner, calendarRef, after, item.Change.ExpectedProviderVersion)
	}
	if err != nil {
		return fail(err)
	}
	current, err := s.calendar.Read(ctx, owner, calendarRef, after.ID)
	if err != nil || !sameCalendarFields(current, after) || current.Private["roamorrow_operation"] != operationID {
		return fail(ErrUncertain)
	}
	item.State = "succeeded"
	item.ReadbackStatus = "verified"
	item.ProviderVersion = current.Version
	return item
}

func (s *Service) persistCalendarReceipt(ctx context.Context, owner string, operation Operation, calendar CalendarPlan) error {
	// An observed external result is retained under its original identity even
	// when cancellation happened while the provider request was in flight.
	writeContext, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	defer cancel()
	normalizeCalendarOperation(&operation)
	return s.store.Update(writeContext, owner, func(state *AccountState) error {
		stored, ok := state.Operations[operation.ID]
		if !ok || stored.Digest != operation.Digest {
			return ErrNotFound
		}
		for i, item := range operation.Items {
			// A concurrent reconciliation cannot be overwritten by an older
			// nonterminal snapshot from another item in this batch.
			if i < len(stored.Items) && calendarStateRank(stored.Items[i].State) > calendarStateRank(item.State) {
				operation.Items[i] = stored.Items[i]
				continue
			}
			if item.State != "succeeded" || i < len(stored.Items) && stored.Items[i].State == "succeeded" {
				// Binding changes commit with the first successful receipt. A
				// duplicate/late receipt must not undo a later adoption/removal.
				continue
			}
			key := calendarBindingKey(calendar.StablePlanID, item.Change.StopID, calendar.CalendarRef)
			if item.Change.Action == "delete" {
				delete(state.Bindings, key)
				continue
			}
			state.Bindings[key] = CalendarBinding{StablePlanID: calendar.StablePlanID, SourceKind: calendar.SourceKind, SourceID: calendar.SourceID, SourceVersion: calendar.SourceVersion, StopID: item.Change.StopID, CalendarRef: calendar.CalendarRef, ProviderEventRef: item.EventRef, ProviderVersion: item.ProviderVersion, OperationID: operation.ID}
		}
		normalizeCalendarOperation(&operation)
		state.Operations[operation.ID] = operation
		return nil
	})
}

func (s *Service) Reconcile(ctx context.Context, owner, operationID string) (Operation, error) {
	op, err := s.GetOperation(ctx, owner, operationID)
	if err != nil {
		return op, err
	}
	if s.calendar == nil {
		return op, ErrUnavailable
	}
	if err = s.calendar.CheckAccess(ctx, owner, false); err != nil {
		return op, err
	}
	state, err := s.store.Read(ctx, owner)
	if err != nil {
		return op, err
	}
	proposal, ok := state.Proposals[op.ProposalID]
	if !ok || proposal.Calendar == nil {
		return op, ErrUnsupported
	}
	// Close only items which are still undispatched under the same owner lock
	// used by Confirm's pending -> started claim. A concurrent dispatcher that
	// already claimed an item must retain its started/uncertain recovery path.
	err = s.store.Update(ctx, owner, func(current *AccountState) error {
		stored, exists := current.Operations[op.ID]
		if !exists || stored.Digest != op.Digest {
			return ErrNotFound
		}
		for i, item := range stored.Items {
			if item.State == "pending" {
				item.State = "failed"
				item.ReadbackStatus = "unavailable"
				item.ErrorCode = "not_dispatched"
				stored.Items[i] = item
			}
		}
		normalizeCalendarOperation(&stored)
		current.Operations[stored.ID] = stored
		op = stored
		return nil
	})
	if err != nil {
		return op, err
	}
	for index, item := range op.Items {
		if item.State != "uncertain" && item.State != "started" {
			continue
		}
		current, readErr := s.calendar.Read(ctx, owner, proposal.Calendar.CalendarRef, item.EventRef)
		if item.Change.Action == "delete" && errors.Is(readErr, ErrNotFound) {
			item.State = "succeeded"
			item.ReadbackStatus = "verified"
		} else if item.Change.Action == "noop" && (readErr == nil || errors.Is(readErr, ErrNotFound)) && item.Before != nil && item.After != nil {
			// Noop performs no provider write and therefore retains the previous
			// operation marker. Its authority is the original preview snapshot.
			if readErr == nil && current.Version == item.Before.Version && sameCalendarFields(current, *item.After) {
				item.State = "succeeded"
				item.ReadbackStatus = "verified"
				item.ProviderVersion = current.Version
			} else {
				item.State = "failed"
				item.ReadbackStatus = "unavailable"
				item.ErrorCode = "version_conflict"
			}
		} else if readErr == nil && item.After != nil && sameCalendarFields(current, *item.After) && current.Private["roamorrow_operation"] == op.ID {
			item.State = "succeeded"
			item.ReadbackStatus = "verified"
			item.ProviderVersion = current.Version
		} else {
			item.State = "uncertain"
			item.ReadbackStatus = "pending"
		}
		op.Items[index] = item
	}
	normalizeCalendarOperation(&op)
	return op, s.persistCalendarReceipt(ctx, owner, op, *proposal.Calendar)
}

func normalizeCalendarOperation(operation *Operation) {
	succeeded, failed, unknown := 0, 0, 0
	for _, item := range operation.Items {
		switch item.State {
		case "succeeded":
			succeeded++
		case "failed":
			failed++
		default:
			unknown++
		}
	}
	switch {
	case unknown > 0:
		operation.State = "uncertain"
		operation.ReadbackStatus = "pending"
	case failed == 0:
		operation.State = "succeeded"
		operation.ReadbackStatus = "verified"
	case succeeded > 0:
		operation.State = "partial"
		operation.ReadbackStatus = "unavailable"
	default:
		operation.State = "failed"
		operation.ReadbackStatus = "unavailable"
	}
}

func calendarStateRank(state string) int {
	switch state {
	case "pending":
		return 0
	case "started":
		return 1
	case "uncertain":
		return 2
	case "failed":
		return 3
	case "succeeded":
		return 4
	default:
		return -1
	}
}
func sameInstant(a, b string) bool {
	x, err := time.Parse(time.RFC3339Nano, a)
	if err != nil {
		return false
	}
	y, err := time.Parse(time.RFC3339Nano, b)
	return err == nil && x.Equal(y)
}

func sameCalendarFields(a, b CalendarEvent) bool {
	// Provider ETags and private operation metadata are checked separately.
	if a.ID != b.ID || a.Title != b.Title || !sameInstant(a.Start, b.Start) || !sameInstant(a.End, b.End) || a.Timezone != b.Timezone || a.Location != b.Location || a.UseDefaultReminders != b.UseDefaultReminders || a.HasAttendees || b.HasAttendees || a.Recurring || b.Recurring || a.AllDay != b.AllDay || len(a.ReminderMinutes) != len(b.ReminderMinutes) {
		return false
	}
	for index, minutes := range a.ReminderMinutes {
		if b.ReminderMinutes[index] != minutes {
			return false
		}
	}
	return true
}

func cloneStrings(input map[string]string) map[string]string {
	out := map[string]string{}
	for k, v := range input {
		out[k] = v
	}
	return out
}

func ValidateCalendarRange(value CalendarRange) error {
	start, err := time.Parse(time.RFC3339, value.Start)
	if err != nil {
		return ErrInvalidArguments
	}
	end, err := time.Parse(time.RFC3339, value.End)
	if err != nil || !end.After(start) || end.Sub(start) > 14*24*time.Hour {
		return ErrInvalidArguments
	}
	if value.Timezone == "" || strings.EqualFold(value.Timezone, "Local") {
		return ErrInvalidArguments
	}
	_, err = time.LoadLocation(value.Timezone)
	if err != nil {
		return ErrInvalidArguments
	}
	return nil
}

// PreviewBoundCalendarDelete keeps calendar cleanup available after the local
// research/draft was deleted. The original server intent is the source of truth.
func (s *Service) PreviewBoundCalendarDelete(ctx context.Context, owner string, selected CalendarBinding, idempotencyKey string) (Proposal, error) {
	if s.store == nil {
		return Proposal{}, ErrUnavailable
	}
	state, err := s.store.Read(ctx, owner)
	if err != nil {
		return Proposal{}, err
	}
	key := calendarBindingKey(selected.StablePlanID, selected.StopID, selected.CalendarRef)
	binding, ok := state.Bindings[key]
	if !ok || binding.ProviderEventRef != selected.ProviderEventRef {
		return Proposal{}, ErrNotFound
	}
	operation, ok := state.Operations[binding.OperationID]
	if !ok {
		return Proposal{}, ErrNotFound
	}
	original, ok := state.Proposals[operation.ProposalID]
	if !ok || original.Calendar == nil {
		return Proposal{}, ErrNotFound
	}
	return s.PreviewCalendar(ctx, owner, CalendarPreviewRequest{SourceKind: "binding", SourceID: key, SourceVersion: 1, ContextRevision: 1, Plan: original.After, CalendarRef: binding.CalendarRef, Changes: []CalendarChange{{StopID: binding.StopID, Action: "delete", EventRef: binding.ProviderEventRef}}}, idempotencyKey)
}
