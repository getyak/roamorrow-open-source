package main

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
)

func TestReadinessRequiresPrivateStoreAndSanitizesFailures(t *testing.T) {
	for _, tc := range []struct {
		name   string
		ping   func(context.Context) error
		status int
	}{
		{"missing", nil, 503},
		{"unavailable", func(context.Context) error { return errors.New("private connection detail must not escape") }, 503},
		{"ready", func(ctx context.Context) error {
			if _, ok := ctx.Deadline(); !ok {
				t.Error("readiness query has no deadline")
			}
			return nil
		}, 200},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := gin.New()
			r.GET("/readyz", readiness(tc.ping))
			w := httptest.NewRecorder()
			r.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/readyz", nil))
			if w.Code != tc.status || strings.Contains(w.Body.String(), "private connection") || w.Header().Get("Cache-Control") != "no-store" {
				t.Fatalf("incorrect or unsafe readiness response: %d %s", w.Code, w.Body.String())
			}
		})
	}
}
