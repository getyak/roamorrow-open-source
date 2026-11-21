package travel

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
)

func googleFixture(t *testing.T, handler http.HandlerFunc) *GoogleCalendarProvider {
	t.Helper()
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	p := NewGoogleCalendarProvider(func(ctx context.Context, owner string, write bool) (string, error) {
		if owner != "verified-owner" {
			return "", ErrPermissionRequired
		}
		return "test-token", nil
	})
	p.baseURL = server.URL
	p.client.Transport = server.Client().Transport
	return p
}

func TestGoogleA32BoundedListReportsPartialAndRedactsDetails(t *testing.T) {
	p := googleFixture(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer test-token" || r.URL.Query().Get("maxResults") != "20" || r.URL.Query().Get("timeMin") != "2026-11-02T00:00:00Z" {
			t.Fatal("wrong authorized bounded query")
		}
		fmt.Fprint(w, `{"timeZone":"Asia/Tokyo","nextPageToken":"more","items":[{"id":"private-event","etag":"v1","summary":"Private medical appointment","start":{"dateTime":"2026-11-02T09:00:00Z","timeZone":"Asia/Tokyo"},"end":{"dateTime":"2026-11-02T10:00:00Z","timeZone":"Asia/Tokyo"}}]}`)
	})
	page, err := p.List(context.Background(), "verified-owner", "primary", CalendarRange{Start: "2026-11-02T00:00:00Z", End: "2026-11-03T00:00:00Z", Timezone: "Asia/Tokyo"})
	if err != nil || !page.HasMore || page.Coverage.Kind != "partial" || len(page.Events) != 1 || page.Events[0].Title != "" {
		t.Fatalf("calendar coverage/details wrong: %+v %v", page, err)
	}
}

func TestGoogleA34PatchUsesProviderETag(t *testing.T) {
	p := googleFixture(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "PATCH" || r.Header.Get("If-Match") != "original-etag" || r.URL.Query().Get("sendUpdates") != "none" {
			t.Fatal("conditional non-notifying patch missing")
		}
		w.WriteHeader(412)
	})
	_, err := p.Update(context.Background(), "verified-owner", "primary", CalendarEvent{ID: "event-id", Title: "Visit", Start: "2026-11-02T09:00:00Z", End: "2026-11-02T10:00:00Z", Timezone: "Asia/Tokyo"}, "original-etag")
	if !errors.Is(err, ErrVersionConflict) {
		t.Fatalf("provider conflict hidden: %v", err)
	}
}

func TestGoogleA41NeverFollowsCredentialBearingRedirect(t *testing.T) {
	var leaked atomic.Int32
	destination := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { leaked.Add(1); w.WriteHeader(200) }))
	defer destination.Close()
	p := googleFixture(t, func(w http.ResponseWriter, r *http.Request) { http.Redirect(w, r, destination.URL, 302) })
	_, err := p.Read(context.Background(), "verified-owner", "primary", "event-id")
	if err == nil || leaked.Load() != 0 {
		t.Fatal("Google access token followed a redirect")
	}
}

func TestGoogleA42AllDayBusyWindowsStayLocalDates(t *testing.T) {
	p := googleFixture(t, func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"timeZone":"America/New_York","items":[{"id":"day","etag":"v1","start":{"date":"2026-11-02"},"end":{"date":"2026-11-03"}}]}`)
	})
	page, err := p.List(context.Background(), "verified-owner", "primary", CalendarRange{Start: "2026-11-02T00:00:00Z", End: "2026-11-04T00:00:00Z", Timezone: "America/New_York"})
	if err != nil || !page.Events[0].AllDay || page.Events[0].Start != "2026-11-02" || page.Events[0].End != "2026-11-03" {
		t.Fatalf("all-day date shifted: %+v %v", page, err)
	}
}

func TestGoogleA33CreatedEventIsVerifiedThroughRealAdapterReadback(t *testing.T) {
	var saved googleEvent
	var writes int
	p := googleFixture(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost {
			writes++
			if json.NewDecoder(r.Body).Decode(&saved) != nil {
				t.Fatal("invalid Google request")
			}
			saved.ETag = "v1"
		}
		_ = json.NewEncoder(w).Encode(saved)
	})
	s, _ := testService()
	s.calendar = p
	proposal, err := s.PreviewCalendar(context.Background(), "verified-owner", calendarFixture(), "preview")
	if err != nil {
		t.Fatal(err)
	}
	op, err := s.ConfirmCalendar(context.Background(), "verified-owner", ConfirmRequest{ProposalID: proposal.ID, Digest: proposal.Digest, IdempotencyKey: "confirm"})
	if err != nil || op.State != "succeeded" || op.ReadbackStatus != "verified" || writes != 1 {
		t.Fatalf("real HTTP adapter could not verify its own create: %+v %v", op, err)
	}
}

func TestGoogleCancelledTombstoneWithoutETag(t *testing.T) {
	p := googleFixture(t, func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, `{"id":"gone","status":"cancelled"}`) })
	_, err := p.Read(context.Background(), "verified-owner", "primary", "gone")
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("tombstone: %v", err)
	}
}
func TestGoogleDeleteRecoversFromCancelledTombstone(t *testing.T) {
	var saved googleEvent
	deleted := false
	p := googleFixture(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodPost:
			_ = json.NewDecoder(r.Body).Decode(&saved)
			saved.ETag = "v1"
		case http.MethodDelete:
			deleted = true
			w.WriteHeader(http.StatusNoContent)
			return
		}
		if deleted {
			_ = json.NewEncoder(w).Encode(googleEvent{ID: saved.ID, Status: "cancelled"})
			return
		}
		_ = json.NewEncoder(w).Encode(saved)
	})
	s, store := testService()
	s.calendar = p
	input := calendarFixture()
	confirmTestCalendar(t, s, "verified-owner", previewTestCalendar(t, s, "verified-owner", input, "create"), "create")
	input.Changes[0].Action = "delete"
	proposal := previewTestCalendar(t, s, "verified-owner", input, "delete")
	// Lose the deletion response receipt, then recover through the HTTP tombstone.
	original := p.client.Transport
	p.client.Transport = roundTripCalendarFunc(func(r *http.Request) (*http.Response, error) {
		resp, err := original.RoundTrip(r)
		if r.Method == http.MethodDelete {
			store.fail = true
		}
		return resp, err
	})
	op, err := s.ConfirmCalendar(context.Background(), "verified-owner", ConfirmRequest{ProposalID: proposal.ID, Digest: proposal.Digest, IdempotencyKey: "delete"})
	if err != nil || op.State != "uncertain" {
		t.Fatalf("receipt: %s %v", op.State, err)
	}
	store.fail = false
	op, err = s.Reconcile(context.Background(), "verified-owner", op.ID)
	if err != nil || op.State != "succeeded" {
		t.Fatalf("delete recovery: %s %v", op.State, err)
	}
}

type roundTripCalendarFunc func(*http.Request) (*http.Response, error)

func (f roundTripCalendarFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
