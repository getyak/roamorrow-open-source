package harness

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strconv"
	"sync/atomic"
	"testing"
	"time"
)

func TestAuthenticationAdmissionBoundsInvalidTokensBeforeVerification(t *testing.T) {
	h := newTestHarness(t)
	limited := false
	for i := 0; i < 130; i++ {
		req := httptest.NewRequest(http.MethodGet, "/v1/harness/profile", nil)
		req.RemoteAddr = "192.0.2.1:4000"
		req.Header.Set("Authorization", "Bearer invalid-local-fixture")
		req.Header.Set("X-Forwarded-For", "198.51.100."+strconv.Itoa(i))
		w := httptest.NewRecorder()
		h.engine.ServeHTTP(w, req)
		if w.Code == http.StatusTooManyRequests {
			limited = true
			break
		}
		if w.Code != http.StatusUnauthorized {
			t.Fatalf("unexpected response: %d", w.Code)
		}
	}
	if !limited || h.verify.calls > 120 {
		t.Fatalf("invalid tokens bypassed bounded authentication admission: calls=%d", h.verify.calls)
	}
}

type admissionVerifier struct {
	calls   atomic.Int32
	entered chan struct{}
}

func (v *admissionVerifier) Verify(ctx context.Context, _ string) (Identity, error) {
	if v.calls.Add(1) == 1 {
		close(v.entered)
		<-ctx.Done()
		return Identity{}, ctx.Err()
	}
	return Identity{ID: "admission-fixture", Email: "fixture@example.test"}, nil
}

func TestAuthenticationAdmissionReleasesOnCancelledVerification(t *testing.T) {
	h := newTestHarness(t)
	v := &admissionVerifier{entered: make(chan struct{})}
	h.srv.verifier = v
	h.srv.authLimiter = NewLimiter(120, 1, 1)
	request := func(peer string) *http.Request {
		r := httptest.NewRequest(http.MethodGet, "/v1/harness/profile", nil)
		r.RemoteAddr = peer
		r.Header.Set("Authorization", "Bearer local-fixture")
		return r
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan struct{})
	go func() {
		defer close(done)
		h.engine.ServeHTTP(httptest.NewRecorder(), request("192.0.2.1:4000").WithContext(ctx))
	}()
	select {
	case <-v.entered:
	case <-time.After(2 * time.Second):
		t.Fatal("verification did not enter")
	}
	w := httptest.NewRecorder()
	h.engine.ServeHTTP(w, request("198.51.100.1:5000"))
	if w.Code != http.StatusTooManyRequests || v.calls.Load() != 1 {
		t.Fatal("global verification admission was bypassed")
	}
	cancel()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("cancellation did not release verification")
	}
	w = httptest.NewRecorder()
	h.engine.ServeHTTP(w, request("198.51.100.1:5000"))
	if w.Code != http.StatusOK || v.calls.Load() != 2 {
		t.Fatalf("verification slot leaked after cancellation: %d", w.Code)
	}
}
