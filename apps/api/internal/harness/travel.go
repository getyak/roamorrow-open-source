package harness

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"github.com/getyak/solo-compass/api/internal/travel"
	"github.com/gin-gonic/gin"
	"net/http"
	"net/url"
	"time"
)

const ScopeCalendarEventsOwned = "https://www.googleapis.com/auth/calendar.events.owned"

func (s *Server) registerTravel(r *gin.Engine) {
	var service *travel.Service
	if store, ok := s.store.(*PostgresStore); ok && store != nil {
		service = travel.NewService(travel.NewPostgresStore(store.db))
		if s.google != nil && s.crypto != nil {
			service.SetCalendarProvider(travel.NewGoogleCalendarProvider(func(ctx context.Context, owner string, write bool) (string, error) {
				scope := ScopeCalendarReadonly
				if write {
					scope = ScopeCalendarEventsOwned
				}
				environment := &toolEnv{s: s, ident: Identity{ID: owner}, forModel: true}
				token, err := environment.googleReady(ctx, scope)
				if err != nil {
					return "", travel.ErrPermissionRequired
				}
				return token.AccessToken, nil
			}))
		}
	}
	handler := travel.NewHTTP(service, travel.NewSourceReader())
	// Public links also work for a device-only traveler. This endpoint cannot read
	// or mutate account state and never forwards credentials to source websites.
	r.POST("/v1/travel/public-source", func(c *gin.Context) {
		// 256 fixed IP groups keep anonymous limiter memory bounded. Group
		// collisions share a conservative budget; all use the same global cap.
		group := sha256.Sum256([]byte(c.RemoteIP()))
		release, err := s.limiter.Acquire("public-source:" + base64.RawURLEncoding.EncodeToString(group[:1]))
		if err != nil {
			c.Header("Retry-After", "60")
			failJSON(c, 429, "rate limit exceeded")
			return
		}
		defer release()
		handler.ServePublicSource(c.Writer, c.Request)
	})
	group := r.Group("/v1/travel", s.AuthMiddleware)
	group.POST("/google/start", s.handleTravelGoogleStart)
	serve := func(c *gin.Context) {
		identity, ok := IdentityFrom(c)
		if !ok {
			c.AbortWithStatus(401)
			return
		}
		release, err := s.limiter.Acquire(identity.ID)
		if err != nil {
			c.Header("Retry-After", "60")
			failJSON(c, 429, "rate limit exceeded")
			return
		}
		defer release()
		handler.ServeOwner(c.Writer, c.Request, identity.ID)
	}
	for _, route := range []struct{ method, path string }{
		{"GET", "/capabilities"}, {"POST", "/source"}, {"POST", "/tools/call"},
		{"POST", "/plans/preview-user-edit"}, {"POST", "/plans/preview"}, {"POST", "/proposals/confirm"}, {"GET", "/plans"}, {"GET", "/plans/:id"},
		{"POST", "/calendar/bindings/preview-delete"}, {"POST", "/calendar/list"}, {"POST", "/calendar/preview"}, {"POST", "/calendar/confirm"}, {"GET", "/calendar/bindings"},
		{"GET", "/proposals/:id/operation"}, {"GET", "/operations"}, {"GET", "/operations/:id"}, {"POST", "/operations/:id/reconcile"},
	} {
		group.Handle(route.method, route.path, serve)
	}
}

func (g *googleAPI) CalendarWriteAuthorizationURL(state, challenge string) string {
	u, _ := url.Parse(g.AuthorizationURL(state, challenge, true, false))
	q := u.Query()
	q.Set("scope", q.Get("scope")+" "+ScopeCalendarEventsOwned)
	u.RawQuery = q.Encode()
	return u.String()
}

// Only this explicit UI flow requests calendar write access. The existing
// onboarding flow remains read-only even if Google returns historical grants.
func (s *Server) handleTravelGoogleStart(c *gin.Context) {
	identity, _ := IdentityFrom(c)
	if s.store == nil || s.google == nil || s.crypto == nil || !s.cfg.googleConfigured() {
		failJSON(c, 503, "google not configured")
		return
	}
	provider, ok := s.google.(interface{ CalendarWriteAuthorizationURL(string, string) string })
	if !ok {
		failJSON(c, 503, "calendar write authorization unavailable")
		return
	}
	var body struct {
		CalendarWrite *bool `json:"calendarWrite"`
	}
	if decodeStrict(c, &body, maxBodyJSON) != nil || body.CalendarWrite == nil || !*body.CalendarWrite {
		failJSON(c, 400, "explicit calendar write selection required")
		return
	}
	release, err := s.limiter.Acquire(identity.ID)
	if err != nil {
		failJSON(c, 429, "rate limit exceeded")
		return
	}
	defer release()
	state, err := randomToken(32)
	if err != nil {
		failJSON(c, 503, "authorization unavailable")
		return
	}
	verifier, err := randomToken(64)
	if err != nil {
		failJSON(c, 503, "authorization unavailable")
		return
	}
	sealed, err := s.crypto.SealToken(identity.ID, purposePKCEVerifier, []byte(verifier))
	if err != nil {
		failJSON(c, 503, "authorization unavailable")
		return
	}
	sum := sha256.Sum256([]byte(verifier))
	challenge := base64.RawURLEncoding.EncodeToString(sum[:])
	expiry := s.now().Add(stateTTL)
	if err = s.store.CreateState(c.Request.Context(), StateRecord{State: state, UserID: identity.ID, VerifierEnc: sealed, WantCalendar: true, WantCalendarWrite: true, ExpiresAt: expiry}); err != nil {
		failJSON(c, 503, "store unavailable")
		return
	}
	c.JSON(http.StatusOK, gin.H{"authorization_url": provider.CalendarWriteAuthorizationURL(state, challenge), "expires_at": expiry.UTC().Format(time.RFC3339)})
}
