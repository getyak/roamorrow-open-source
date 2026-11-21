package travel

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"sort"
	"strings"
)

type HTTP struct {
	service *Service
	sources *SourceReader
}

func NewHTTP(service *Service, sources *SourceReader) *HTTP {
	return &HTTP{service: service, sources: sources}
}

func decodeRequest(w http.ResponseWriter, r *http.Request, destination any) error {
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 256<<10))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(destination); err != nil {
		return ErrInvalidArguments
	}
	if err := decoder.Decode(new(any)); !errors.Is(err, io.EOF) {
		return ErrInvalidArguments
	}
	return nil
}

func travelJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func travelError(w http.ResponseWriter, err error) {
	status, code := http.StatusServiceUnavailable, "provider_unavailable"
	switch {
	case errors.Is(err, ErrInvalidArguments):
		status, code = 400, "invalid_arguments"
	case errors.Is(err, ErrNotFound):
		status, code = 404, "not_found"
	case errors.Is(err, ErrDigestMismatch):
		status, code = 403, "digest_mismatch"
	case errors.Is(err, ErrPermissionRequired):
		status, code = 403, "permission_required"
	case errors.Is(err, ErrUnsupported):
		status, code = 409, "capability_unsupported"
	case errors.Is(err, ErrVersionConflict):
		status, code = 409, "version_conflict"
	case errors.Is(err, ErrIdempotencyConflict):
		status, code = 409, "idempotency_conflict"
	case errors.Is(err, ErrProposalExpired):
		status, code = 409, "proposal_expired"
	case errors.Is(err, ErrLockedField):
		status, code = 409, "locked_field"
	case errors.Is(err, ErrUncertain):
		status, code = 409, "operation_uncertain"
	}
	travelJSON(w, status, map[string]any{"error": map[string]string{"code": code, "message": "The requested travel action could not be completed."}})
}

// ServeOwner accepts identity only from the project's verified auth adapter.
// This method is not registered directly as an unauthenticated HTTP handler.
func (h *HTTP) ServeOwner(w http.ResponseWriter, r *http.Request, owner string) {
	if owner == "" {
		travelJSON(w, 401, map[string]string{"error": "unauthorized"})
		return
	}
	path := strings.TrimPrefix(r.URL.Path, "/v1/travel")
	if r.Method == http.MethodGet && path == "/capabilities" {
		readCalendar, writeCalendar := false, false
		if h.service != nil && h.service.calendar != nil {
			readCalendar = h.service.calendar.CheckAccess(r.Context(), owner, false) == nil
			writeCalendar = h.service.calendar.CheckAccess(r.Context(), owner, true) == nil
		}
		travelJSON(w, 200, map[string]bool{"source_read": h.sources != nil, "account_plans": h.service != nil, "calendar_read": readCalendar, "calendar_write": writeCalendar})
		return
	}
	if r.Method == http.MethodPost && path == "/tools/call" {
		var body struct {
			Name      string          `json:"name"`
			Arguments json.RawMessage `json:"arguments"`
		}
		if err := decodeRequest(w, r, &body); err != nil {
			travelError(w, err)
			return
		}
		// Confirmation/apply commands are intentionally absent from the model registry.
		if body.Name != "read_source" {
			travelJSON(w, 403, map[string]string{"error": "tool_not_allowed"})
			return
		}
		var args SourceRequest
		decoder := json.NewDecoder(strings.NewReader(string(body.Arguments)))
		decoder.DisallowUnknownFields()
		if decoder.Decode(&args) != nil {
			travelError(w, ErrInvalidArguments)
			return
		}
		if h.sources == nil {
			travelError(w, ErrUnavailable)
			return
		}
		travelJSON(w, 200, h.sources.Read(r.Context(), args))
		return
	}
	if r.Method == http.MethodPost && path == "/source" {
		var body SourceRequest
		if err := decodeRequest(w, r, &body); err != nil {
			travelError(w, err)
			return
		}
		if h.sources == nil {
			travelError(w, ErrUnavailable)
			return
		}
		travelJSON(w, 200, h.sources.Read(r.Context(), body))
		return
	}
	if h.service == nil {
		travelError(w, ErrUnavailable)
		return
	}
	if r.Method == http.MethodPost && path == "/calendar/list" {
		var body struct {
			CalendarRef string        `json:"calendarRef"`
			Range       CalendarRange `json:"range"`
		}
		if err := decodeRequest(w, r, &body); err != nil {
			travelError(w, err)
			return
		}
		if h.service.calendar == nil {
			travelError(w, ErrUnavailable)
			return
		}
		if err := h.service.calendar.CheckAccess(r.Context(), owner, false); err != nil {
			travelError(w, err)
			return
		}
		page, err := h.service.calendar.List(r.Context(), owner, body.CalendarRef, body.Range)
		if err != nil {
			travelError(w, err)
			return
		}
		travelJSON(w, 200, page)
		return
	}
	if r.Method == http.MethodPost && path == "/calendar/bindings/preview-delete" {
		var body struct {
			Binding        CalendarBinding `json:"binding"`
			IdempotencyKey string          `json:"idempotencyKey"`
		}
		if err := decodeRequest(w, r, &body); err != nil {
			travelError(w, err)
			return
		}
		proposal, err := h.service.PreviewBoundCalendarDelete(r.Context(), owner, body.Binding, body.IdempotencyKey)
		if err != nil {
			travelError(w, err)
			return
		}
		travelJSON(w, 200, proposal)
		return
	}
	if r.Method == http.MethodPost && path == "/calendar/preview" {
		var body struct {
			CalendarPreviewRequest
			IdempotencyKey string `json:"idempotencyKey"`
		}
		if err := decodeRequest(w, r, &body); err != nil {
			travelError(w, err)
			return
		}
		proposal, err := h.service.PreviewCalendar(r.Context(), owner, body.CalendarPreviewRequest, body.IdempotencyKey)
		if err != nil {
			travelError(w, err)
			return
		}
		travelJSON(w, 200, proposal)
		return
	}
	if r.Method == http.MethodPost && path == "/calendar/confirm" {
		var body ConfirmRequest
		if err := decodeRequest(w, r, &body); err != nil {
			travelError(w, err)
			return
		}
		op, err := h.service.ConfirmCalendar(r.Context(), owner, body)
		if err != nil {
			travelError(w, err)
			return
		}
		travelJSON(w, 200, op)
		return
	}
	if r.Method == http.MethodGet && path == "/calendar/bindings" {
		state, err := h.service.store.Read(r.Context(), owner)
		if err != nil {
			travelError(w, err)
			return
		}
		bindings := []CalendarBinding{}
		for _, binding := range state.Bindings {
			bindings = append(bindings, binding)
		}
		travelJSON(w, 200, map[string]any{"bindings": bindings})
		return
	}
	if r.Method == http.MethodPost && strings.HasPrefix(path, "/operations/") && strings.HasSuffix(path, "/reconcile") {
		id := strings.TrimSuffix(strings.TrimPrefix(path, "/operations/"), "/reconcile")
		op, err := h.service.Reconcile(r.Context(), owner, id)
		if err != nil {
			travelError(w, err)
			return
		}
		travelJSON(w, 200, op)
		return
	}
	if r.Method == http.MethodPost && (path == "/plans/preview" || path == "/plans/preview-user-edit") {
		var body struct {
			PlanPreviewRequest
			IdempotencyKey string `json:"idempotencyKey"`
		}
		if err := decodeRequest(w, r, &body); err != nil {
			travelError(w, err)
			return
		}
		var proposal Proposal
		var err error
		if path == "/plans/preview-user-edit" {
			proposal, err = h.service.PreviewUserPlan(r.Context(), owner, body.PlanPreviewRequest, body.IdempotencyKey)
		} else {
			proposal, err = h.service.PreviewPlan(r.Context(), owner, body.PlanPreviewRequest, body.IdempotencyKey)
		}
		if err != nil {
			travelError(w, err)
			return
		}
		travelJSON(w, 200, proposal)
		return
	}
	if r.Method == http.MethodPost && path == "/proposals/confirm" {
		var body ConfirmRequest
		if err := decodeRequest(w, r, &body); err != nil {
			travelError(w, err)
			return
		}
		operation, err := h.service.Confirm(r.Context(), owner, body)
		if err != nil {
			travelError(w, err)
			return
		}
		travelJSON(w, 200, operation)
		return
	}
	if r.Method == http.MethodGet && strings.HasPrefix(path, "/plans/") {
		plan, err := h.service.GetPlan(r.Context(), owner, strings.TrimPrefix(path, "/plans/"))
		if err != nil {
			travelError(w, err)
			return
		}
		travelJSON(w, 200, plan)
		return
	}
	if r.Method == http.MethodGet && path == "/plans" {
		state, err := h.service.store.Read(r.Context(), owner)
		if err != nil {
			travelError(w, err)
			return
		}
		plans := []Plan{}
		for _, plan := range state.Plans {
			plans = append(plans, plan)
		}
		sort.Slice(plans, func(i, j int) bool {
			if plans[i].UpdatedAt == plans[j].UpdatedAt {
				return plans[i].ID < plans[j].ID
			}
			return plans[i].UpdatedAt > plans[j].UpdatedAt
		})
		travelJSON(w, 200, map[string]any{"plans": plans})
		return
	}
	if r.Method == http.MethodGet && strings.HasPrefix(path, "/proposals/") && strings.HasSuffix(path, "/operation") {
		id := strings.TrimSuffix(strings.TrimPrefix(path, "/proposals/"), "/operation")
		operation, err := h.service.GetProposalOperation(r.Context(), owner, id)
		if err != nil {
			travelError(w, err)
			return
		}
		travelJSON(w, 200, operation)
		return
	}
	if r.Method == http.MethodGet && path == "/operations" {
		state, err := h.service.store.Read(r.Context(), owner)
		if err != nil {
			travelError(w, err)
			return
		}
		operations := []map[string]string{}
		for _, op := range state.Operations {
			if op.State == "uncertain" || op.State == "executing" || op.State == "partial" {
				operations = append(operations, map[string]string{"id": op.ID, "proposalId": op.ProposalID, "state": op.State, "readbackStatus": op.ReadbackStatus})
			}
		}
		sort.Slice(operations, func(i, j int) bool { return operations[i]["id"] < operations[j]["id"] })
		hasMore := len(operations) > 100
		if hasMore {
			operations = operations[:100]
		}
		travelJSON(w, 200, map[string]any{"operations": operations, "hasMore": hasMore})
		return
	}
	if r.Method == http.MethodGet && strings.HasPrefix(path, "/operations/") {
		op, err := h.service.GetOperation(r.Context(), owner, strings.TrimPrefix(path, "/operations/"))
		if err != nil {
			travelError(w, err)
			return
		}
		travelJSON(w, 200, op)
		return
	}
	travelJSON(w, 404, map[string]string{"error": "not_found"})
}

// ServePublicSource reads only caller-supplied public content. It has no account
// repository access; its host route must enforce per-IP and global read limits.
func (h *HTTP) ServePublicSource(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	var body SourceRequest
	if err := decodeRequest(w, r, &body); err != nil {
		travelError(w, err)
		return
	}
	if h.sources == nil {
		travelError(w, ErrUnavailable)
		return
	}
	travelJSON(w, http.StatusOK, h.sources.Read(r.Context(), body))
}
