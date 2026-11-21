package harness

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

type travelGoogleFake struct{ *fakeGoogle }

func (f travelGoogleFake) CalendarWriteAuthorizationURL(state, challenge string) string {
	raw := f.AuthorizationURL(state, challenge, true, false)
	u, _ := url.Parse(raw)
	q := u.Query()
	q.Set("scope", q.Get("scope")+" "+ScopeCalendarEventsOwned)
	u.RawQuery = q.Encode()
	return u.String()
}

func TestTravelA31WriteCalendarUsesExplicitSeparateConsent(t *testing.T) {
	h := newTestHarness(t)
	h.auth("tok-a", "user-a", "a@example.test")
	h.srv.google = travelGoogleFake{h.google}
	h.engine = newEngine(h.srv)
	h.google.exchange = func(string, string) (TokenSet, error) {
		return TokenSet{AccessToken: "test-access", RefreshToken: "test-refresh", TokenType: "Bearer", Expiry: time.Now().Add(time.Hour), Scopes: []string{ScopeCalendarReadonly, ScopeCalendarEventsOwned, ScopeGmailReadonly}}, nil
	}
	bad := doJSON(t, h, http.MethodPost, "/v1/travel/google/start", "tok-a", map[string]any{"calendarWrite": false})
	if bad.Code != 400 {
		t.Fatalf("write scope not explicit: %d", bad.Code)
	}
	w := doJSON(t, h, http.MethodPost, "/v1/travel/google/start", "tok-a", map[string]any{"calendarWrite": true})
	if w.Code != 200 {
		t.Fatalf("write consent start: %d %s", w.Code, w.Body.String())
	}
	u, _ := url.Parse(decodeBody(t, w)["authorization_url"].(string))
	scope := u.Query().Get("scope")
	if !strings.Contains(scope, ScopeCalendarEventsOwned) || strings.Contains(scope, ScopeGmailReadonly) {
		t.Fatalf("incorrect requested scope: %s", scope)
	}
	callback := httptest.NewRequest("GET", "/v1/harness/google/callback?code=good-code&state="+url.QueryEscape(u.Query().Get("state")), nil)
	result := httptest.NewRecorder()
	h.engine.ServeHTTP(result, callback)
	stored, err := h.store.GetTokens(context.Background(), "user-a")
	if err != nil {
		t.Fatal(err)
	}
	if !containsScope(stored.Scopes, ScopeCalendarEventsOwned) || containsScope(stored.Scopes, ScopeGmailReadonly) {
		t.Fatal("callback did not enforce the exact write-calendar selection")
	}
}

func TestTravelA31ReadConsentCannotInheritWriteScope(t *testing.T) {
	h := newTestHarness(t)
	h.auth("tok-a", "user-a", "a@example.test")
	h.google.exchange = func(string, string) (TokenSet, error) {
		return TokenSet{AccessToken: "test-access", RefreshToken: "test-refresh", Expiry: time.Now().Add(time.Hour), Scopes: []string{ScopeCalendarReadonly, ScopeCalendarEventsOwned}}, nil
	}
	w := doJSON(t, h, "POST", "/v1/harness/google/start", "tok-a", map[string]any{"calendar": true, "mail": false})
	u, _ := url.Parse(decodeBody(t, w)["authorization_url"].(string))
	request := httptest.NewRequest("GET", "/v1/harness/google/callback?code=good-code&state="+url.QueryEscape(u.Query().Get("state")), nil)
	result := httptest.NewRecorder()
	h.engine.ServeHTTP(result, request)
	stored, err := h.store.GetTokens(context.Background(), "user-a")
	if err != nil {
		t.Fatal(err)
	}
	if containsScope(stored.Scopes, ScopeCalendarEventsOwned) {
		t.Fatal("historic provider grant upgraded a read-only selection")
	}
}

func containsScope(scopes []string, wanted string) bool {
	for _, scope := range scopes {
		if scope == wanted {
			return true
		}
	}
	return false
}

func TestTravelA10AnonymousPublicReaderKeepsAccountRoutesAuthenticated(t *testing.T) {
	h := newTestHarness(t)
	for _, tc := range []struct {
		path, body string
		status     int
	}{
		{"/v1/travel/public-source", `{"url":"http://127.0.0.1/secret"}`, 200},
		{"/v1/travel/public-source", `{"url":"https://example.com","owner":"other","approved":true}`, 400},
		{"/v1/travel/plans/preview", `{}`, 401},
		{"/v1/travel/calendar/confirm", `{}`, 401},
	} {
		request := httptest.NewRequest("POST", tc.path, strings.NewReader(tc.body))
		request.Header.Set("Content-Type", "application/json")
		response := httptest.NewRecorder()
		h.engine.ServeHTTP(response, request)
		if response.Code != tc.status {
			t.Fatalf("route %s: got %d want %d", tc.path, response.Code, tc.status)
		}
		if tc.status == 200 && !strings.Contains(response.Body.String(), `"status":"blocked"`) {
			t.Fatal("anonymous reader did not block internal URL")
		}
	}
}
