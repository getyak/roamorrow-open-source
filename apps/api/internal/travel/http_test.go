package travel

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestHTTPA26A43RejectsMissingIdentityAndUnknownOwnerFields(t *testing.T) {
	s, _ := testService()
	h := NewHTTP(s, NewSourceReader())
	for _, test := range []struct {
		owner, body string
		status      int
	}{
		{"", `{"url":"https://example.com"}`, 401},
		{"verified-a", `{"url":"https://example.com","owner":"verified-b"}`, 400},
		{"verified-a", `{"url":"https://example.com"} {}`, 400},
	} {
		request := httptest.NewRequest("POST", "/v1/travel/source", strings.NewReader(test.body))
		response := httptest.NewRecorder()
		h.ServeOwner(response, request, test.owner)
		if response.Code != test.status {
			t.Fatalf("got %d want %d", response.Code, test.status)
		}
	}
}

func TestHTTPA26ModelToolRouteCannotConfirmChanges(t *testing.T) {
	s, store := testService()
	h := NewHTTP(s, NewSourceReader())
	request := httptest.NewRequest("POST", "/v1/travel/tools/call", bytes.NewBufferString(`{"name":"apply_itinerary_change","arguments":{}}`))
	response := httptest.NewRecorder()
	h.ServeOwner(response, request, "verified-a")
	if response.Code != http.StatusForbidden {
		t.Fatalf("mutation exposed through model registry: %d", response.Code)
	}
	if len(store.rows) != 0 {
		t.Fatal("rejected model tool changed storage")
	}
}

func TestHTTPA49AbsentAuthorityCannotSilentlySaveAnAccountPlan(t *testing.T) {
	h := NewHTTP(nil, NewSourceReader())
	request := httptest.NewRequest("POST", "/v1/travel/plans/preview", strings.NewReader(`{}`))
	response := httptest.NewRecorder()
	h.ServeOwner(response, request, "verified-a")
	if response.Code != 503 {
		t.Fatalf("absent authoritative repository falsely saved: %d", response.Code)
	}
}

func TestHTTPA10PublicSourceCannotReachAccountCommands(t *testing.T) {
	h := NewHTTP(nil, nil)
	request := httptest.NewRequest(http.MethodPost, "/v1/travel/public-source", strings.NewReader(`{"url":"https://example.com","owner":"other"}`))
	response := httptest.NewRecorder()
	h.ServePublicSource(response, request)
	if response.Code != 400 {
		t.Fatal("public source accepted account fields", response.Code)
	}
}
