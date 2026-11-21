package harness

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

const (
	footprintMCPPath         = "/mcp/footprints"
	footprintProtectedPath   = "/.well-known/oauth-protected-resource" + footprintMCPPath
	footprintOAuthPath       = "/oauth/footprints"
	footprintOAuthScope      = "footprints:read"
	footprintAccessPrefix    = "rm_access_"
	footprintRefreshPrefix   = "rm_refresh_"
	footprintBrowserCookie   = "rm_footprints_login"
	footprintAccessTTL       = 60 * time.Minute
	footprintRefreshTTL      = 180 * 24 * time.Hour
	footprintAttemptTTL      = 15 * time.Minute
	footprintCodeTTL         = 2 * time.Minute
	footprintRegistrationTTL = 24 * time.Hour
)

var (
	footprintDNSLabel        = regexp.MustCompile(`^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$`)
	footprintFlowIDPattern   = regexp.MustCompile(`^[A-Za-z0-9_-]{43}$`)
	footprintVerifierPattern = regexp.MustCompile(`^[A-Za-z0-9_.~-]{43,128}$`)
	footprintCallbackPattern = regexp.MustCompile(`^/callback(?:/[A-Za-z0-9_-]{1,100})?/?$`)
)

func footprintOAuthOrigin(raw string) string {
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" || u.User != nil || u.RawQuery != "" || u.ForceQuery ||
		u.Fragment != "" || u.RawPath != "" || (u.Path != "" && u.Path != "/") {
		return ""
	}
	host := u.Hostname()
	if u.Scheme != "https" && !(u.Scheme == "http" && footprintLoopback(host)) {
		return ""
	}
	if net.ParseIP(host) == nil {
		if len(host) > 253 || strings.HasPrefix(u.Host, "[") {
			return ""
		}
		for _, label := range strings.Split(host, ".") {
			if !footprintDNSLabel.MatchString(label) {
				return ""
			}
		}
	}
	if port := u.Port(); port != "" {
		number, err := strconv.Atoi(port)
		if err != nil || number < 1 || number > 65535 {
			return ""
		}
	} else if strings.HasSuffix(u.Host, ":") {
		return ""
	}
	return u.Scheme + "://" + strings.ToLower(u.Host)
}

func footprintLoopback(host string) bool {
	return host == "127.0.0.1" || host == "::1" || host == "localhost"
}

func (s *Server) footprintOAuthReady() bool {
	store, ok := s.store.(*PostgresStore)
	return ok && store != nil && store.db != nil && s.verifier != nil &&
		s.footprintOAuthIssuer() != "" && s.cfg.SupabaseURL != "" && s.cfg.SupabaseAnonKey != ""
}

func (s *Server) footprintOAuthIssuer() string {
	return footprintOAuthOrigin(s.cfg.FootprintOAuthOrigin)
}

func (s *Server) footprintResource() string { return s.footprintOAuthIssuer() + footprintMCPPath }

func (s *Server) registerFootprintOAuth(r *gin.Engine) {
	r.GET(footprintProtectedPath, s.footprintOAuthProtected)
	r.GET("/.well-known/oauth-protected-resource", s.footprintOAuthProtected)
	r.GET("/.well-known/oauth-authorization-server", s.footprintOAuthMetadata)
	group := r.Group(footprintOAuthPath, s.footprintOAuthAdmission)
	group.POST("/register", s.footprintOAuthRegisterClient)
	group.GET("/authorize", s.footprintOAuthAuthorize)
	group.POST("/authorize", s.footprintOAuthAuthorizeForm)
	group.POST("/token", s.footprintOAuthToken)
}

func (s *Server) footprintOAuthAdmission(c *gin.Context) {
	if !s.footprintOAuthReady() {
		c.AbortWithStatusJSON(503, gin.H{"error": "temporarily_unavailable"})
		return
	}
	host, _, err := net.SplitHostPort(c.Request.RemoteAddr)
	if err != nil {
		host = c.Request.RemoteAddr
	}
	bucket := sha256.Sum256([]byte(host))
	release, err := s.footprintOAuthLimiter.Acquire(fmt.Sprintf("footprint-oauth:%02x", bucket[0]))
	if err != nil {
		c.AbortWithStatusJSON(429, gin.H{"error": "temporarily_unavailable"})
		return
	}
	defer release()
	c.Header("Cache-Control", "no-store")
	c.Header("Referrer-Policy", "no-referrer")
	c.Next()
}

func (s *Server) footprintOAuthProtected(c *gin.Context) {
	if !s.footprintOAuthReady() {
		c.Status(http.StatusNotFound)
		return
	}
	c.JSON(http.StatusOK, gin.H{
		"resource":                 s.footprintResource(),
		"authorization_servers":    []string{s.footprintOAuthIssuer()},
		"scopes_supported":         []string{footprintOAuthScope},
		"bearer_methods_supported": []string{"header"},
		"resource_name":            "Roamorrow Footprints",
	})
}

func (s *Server) footprintOAuthMetadata(c *gin.Context) {
	if !s.footprintOAuthReady() {
		c.Status(http.StatusNotFound)
		return
	}
	issuer := s.footprintOAuthIssuer()
	c.JSON(http.StatusOK, gin.H{
		"issuer":                                         issuer,
		"authorization_endpoint":                         issuer + footprintOAuthPath + "/authorize",
		"token_endpoint":                                 issuer + footprintOAuthPath + "/token",
		"registration_endpoint":                          issuer + footprintOAuthPath + "/register",
		"response_types_supported":                       []string{"code"},
		"response_modes_supported":                       []string{"query"},
		"grant_types_supported":                          []string{"authorization_code", "refresh_token"},
		"code_challenge_methods_supported":               []string{"S256"},
		"token_endpoint_auth_methods_supported":          []string{"none"},
		"scopes_supported":                               []string{footprintOAuthScope},
		"authorization_response_iss_parameter_supported": true,
	})
}

func (s *Server) footprintOAuthChallenge(c *gin.Context) {
	challenge := `Bearer realm="roamorrow-footprints"`
	if s.footprintOAuthReady() {
		challenge += `, resource_metadata="` + s.footprintOAuthIssuer() + footprintProtectedPath +
			`", scope="` + footprintOAuthScope + `"`
	}
	c.Header("WWW-Authenticate", challenge)
	failJSON(c, http.StatusUnauthorized, "authorization required")
}

func footprintOAuthSecret(prefix string) string {
	var raw [32]byte
	rand.Read(raw[:]) // crypto/rand.Read is guaranteed to fill the buffer.
	return prefix + base64.RawURLEncoding.EncodeToString(raw[:])
}

func footprintOAuthDigest(raw string) []byte {
	value := sha256.Sum256([]byte(raw))
	return value[:]
}

func footprintOAuthRedirect(raw string, requirePort bool) (*url.URL, bool) {
	u, err := url.Parse(raw)
	if err != nil || u.User != nil || u.Scheme != "http" || !footprintLoopback(u.Hostname()) ||
		u.Fragment != "" || u.RawPath != "" || u.RawQuery != "" || u.ForceQuery ||
		!footprintCallbackPattern.MatchString(u.Path) {
		return nil, false
	}
	if port := u.Port(); port == "" {
		return u, !requirePort
	} else if number, err := strconv.Atoi(port); err != nil || number < 1 || number > 65535 {
		return nil, false
	}
	return u, true
}

func footprintRedirectRegistered(registered []string, actual string) bool {
	got, valid := footprintOAuthRedirect(actual, true)
	if !valid {
		return false
	}
	for _, raw := range registered {
		allowed, valid := footprintOAuthRedirect(raw, false)
		if !valid {
			continue
		}
		// Native loopback callbacks may select any ephemeral port. Codex can
		// register the IP literal and use localhost for the same listener.
		sameHost := allowed.Hostname() == got.Hostname() ||
			(allowed.Hostname() == "127.0.0.1" && got.Hostname() == "localhost") ||
			(allowed.Hostname() == "localhost" && got.Hostname() == "127.0.0.1")
		if sameHost && allowed.Path == got.Path {
			return true
		}
	}
	return false
}

func (s *Server) footprintOAuthRegisterClient(c *gin.Context) {
	var input struct {
		RedirectURIs  []string `json:"redirect_uris"`
		TokenMethod   string   `json:"token_endpoint_auth_method"`
		GrantTypes    []string `json:"grant_types"`
		ResponseTypes []string `json:"response_types"`
	}
	c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, 8192)
	decoder := json.NewDecoder(c.Request.Body)
	if decoder.Decode(&input) != nil {
		c.JSON(400, gin.H{"error": "invalid_client_metadata"})
		return
	}
	// Reject multiple JSON values without rejecting standard optional fields.
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		c.JSON(400, gin.H{"error": "invalid_client_metadata"})
		return
	}
	if len(input.RedirectURIs) == 0 || len(input.RedirectURIs) > 4 ||
		(input.TokenMethod != "" && input.TokenMethod != "none") {
		c.JSON(400, gin.H{"error": "invalid_client_metadata"})
		return
	}
	for _, grant := range input.GrantTypes {
		if grant != "authorization_code" && grant != "refresh_token" {
			c.JSON(400, gin.H{"error": "invalid_client_metadata"})
			return
		}
	}
	for _, response := range input.ResponseTypes {
		if response != "code" {
			c.JSON(400, gin.H{"error": "invalid_client_metadata"})
			return
		}
	}
	for _, redirect := range input.RedirectURIs {
		if _, valid := footprintOAuthRedirect(redirect, false); !valid {
			c.JSON(400, gin.H{"error": "invalid_redirect_uri"})
			return
		}
	}
	db := s.footprintDB(c)
	if db == nil {
		return
	}
	id := footprintOAuthSecret("rm_client_")
	data, _ := json.Marshal(input.RedirectURIs)
	if _, err := db.ExecContext(c.Request.Context(), `WITH expired AS (
		DELETE FROM harness.footprint_oauth_clients WHERE id IN
			(SELECT id FROM harness.footprint_oauth_clients WHERE expires_at<=$3 ORDER BY expires_at LIMIT 100))
		INSERT INTO harness.footprint_oauth_clients(id,redirect_uris,expires_at) VALUES ($1,$2,$4)`,
		id, string(data), s.now(), s.now().Add(footprintRegistrationTTL)); err != nil {
		c.JSON(503, gin.H{"error": "temporarily_unavailable"})
		return
	}
	c.JSON(201, gin.H{
		"client_id": id, "client_id_issued_at": s.now().Unix(), "redirect_uris": input.RedirectURIs,
		"token_endpoint_auth_method": "none", "grant_types": []string{"authorization_code", "refresh_token"},
		"response_types": []string{"code"},
	})
}

func (s *Server) footprintOAuthResourceParam(form url.Values) bool {
	values := form["resource"]
	// Some Codex versions omit the RFC 8707 indicator on refresh/exchange.
	// This issuer has one resource. An explicit indicator must match exactly.
	return len(values) == 0 || (len(values) == 1 && values[0] == s.footprintResource())
}

func footprintOAuthUnique(form url.Values) bool {
	for _, values := range form {
		if len(values) != 1 {
			return false
		}
	}
	return true
}

func footprintOAuthParseForm(c *gin.Context) (url.Values, bool) {
	if c.Request.URL.RawQuery != "" ||
		!strings.HasPrefix(strings.ToLower(c.GetHeader("Content-Type")), "application/x-www-form-urlencoded") {
		return nil, false
	}
	c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, 8192)
	if err := c.Request.ParseForm(); err != nil || !footprintOAuthUnique(c.Request.PostForm) {
		return nil, false
	}
	return c.Request.PostForm, true
}

type footprintOAuthPair struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	TokenType    string `json:"token_type"`
	ExpiresIn    int    `json:"expires_in"`
	Scope        string `json:"scope"`
}

func (s *Server) footprintOAuthToken(c *gin.Context) {
	form, valid := footprintOAuthParseForm(c)
	if !valid || c.GetHeader("Authorization") != "" || form.Get("client_secret") != "" {
		c.JSON(400, gin.H{"error": "invalid_request"})
		return
	}
	if !s.footprintOAuthResourceParam(form) {
		c.JSON(400, gin.H{"error": "invalid_target"})
		return
	}
	if scope := form.Get("scope"); scope != "" && scope != footprintOAuthScope {
		c.JSON(400, gin.H{"error": "invalid_scope"})
		return
	}
	db := s.footprintDB(c)
	if db == nil {
		return
	}
	ctx := c.Request.Context()
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		c.JSON(503, gin.H{"error": "temporarily_unavailable"})
		return
	}
	defer tx.Rollback()
	now := s.now()
	var session []byte
	switch form.Get("grant_type") {
	case "authorization_code":
		session, err = s.footprintExchangeCode(ctx, tx, form, now)
	case "refresh_token":
		session, err = s.footprintExchangeRefresh(ctx, tx, form, now)
	default:
		c.JSON(400, gin.H{"error": "unsupported_grant_type"})
		return
	}
	if errors.Is(err, sql.ErrNoRows) {
		c.JSON(400, gin.H{"error": "invalid_grant"})
		return
	}
	if errors.Is(err, footprintRefreshReplayed) {
		if tx.Commit() != nil {
			c.JSON(503, gin.H{"error": "temporarily_unavailable"})
		} else {
			c.JSON(400, gin.H{"error": "invalid_grant"})
		}
		return
	}
	if err != nil {
		c.JSON(503, gin.H{"error": "temporarily_unavailable"})
		return
	}
	pair := footprintOAuthPair{
		AccessToken: footprintOAuthSecret(footprintAccessPrefix), RefreshToken: footprintOAuthSecret(footprintRefreshPrefix),
		TokenType: "Bearer", ExpiresIn: int(footprintAccessTTL.Seconds()), Scope: footprintOAuthScope,
	}
	refreshDigest := footprintOAuthDigest(pair.RefreshToken)
	if _, err = tx.ExecContext(ctx, `UPDATE harness.footprint_oauth_sessions SET
		access_digest=$2,access_expires_at=$3,refresh_digest=$4,refresh_expires_at=$5 WHERE id=$1`,
		session, footprintOAuthDigest(pair.AccessToken), now.Add(footprintAccessTTL), refreshDigest, now.Add(footprintRefreshTTL)); err != nil {
		c.JSON(503, gin.H{"error": "temporarily_unavailable"})
		return
	}
	if _, err = tx.ExecContext(ctx, `INSERT INTO harness.footprint_oauth_refresh_history (digest,session_id) VALUES ($1,$2)`,
		refreshDigest, session); err != nil || tx.Commit() != nil {
		c.JSON(503, gin.H{"error": "temporarily_unavailable"})
		return
	}
	c.JSON(200, pair)
}

func (s *Server) footprintExchangeCode(ctx context.Context, tx *sql.Tx, form url.Values, now time.Time) ([]byte, error) {
	verifier := form.Get("code_verifier")
	code := form.Get("code")
	if !footprintVerifierPattern.MatchString(verifier) || !footprintFlowIDPattern.MatchString(code) {
		return nil, sql.ErrNoRows
	}
	challenge := base64.RawURLEncoding.EncodeToString(footprintOAuthDigest(verifier))
	var session []byte
	err := tx.QueryRowContext(ctx, `SELECT g.id FROM harness.footprint_oauth_attempts a
		JOIN harness.footprint_oauth_sessions g ON g.id=a.session_id AND g.revoked_at IS NULL
		WHERE a.code_digest=$1 AND a.client_id=$2 AND a.redirect_uri=$3 AND a.resource=$4
		AND a.code_challenge=$5 AND a.code_expires_at>$6 FOR UPDATE OF a,g`,
		footprintOAuthDigest(code), form.Get("client_id"), form.Get("redirect_uri"), s.footprintResource(), challenge, now).Scan(&session)
	if err != nil {
		return nil, err
	}
	if _, err = tx.ExecContext(ctx, `DELETE FROM harness.footprint_oauth_attempts WHERE code_digest=$1`, footprintOAuthDigest(code)); err != nil {
		return nil, err
	}
	return session, nil
}

var footprintRefreshReplayed = errors.New("footprint refresh replay")

func (s *Server) footprintExchangeRefresh(ctx context.Context, tx *sql.Tx, form url.Values, now time.Time) ([]byte, error) {
	token, ok := strings.CutPrefix(form.Get("refresh_token"), footprintRefreshPrefix)
	if !ok || !footprintFlowIDPattern.MatchString(token) {
		return nil, sql.ErrNoRows
	}
	var id, current []byte
	digest := footprintOAuthDigest(form.Get("refresh_token"))
	err := tx.QueryRowContext(ctx, `SELECT g.id,g.refresh_digest FROM harness.footprint_oauth_refresh_history h
		JOIN harness.footprint_oauth_sessions g ON g.id=h.session_id
		WHERE h.digest=$1 AND g.client_id=$2 AND g.resource=$3 AND g.refresh_expires_at>$4 AND g.revoked_at IS NULL FOR UPDATE OF g`,
		digest, form.Get("client_id"), s.footprintResource(), now).Scan(&id, &current)
	if err != nil {
		return nil, err
	}
	if !bytes.Equal(current, digest) {
		_, err = tx.ExecContext(ctx, `UPDATE harness.footprint_oauth_sessions SET revoked_at=$2 WHERE id=$1`, id, now)
		if err != nil {
			return nil, err
		}
		return nil, footprintRefreshReplayed
	}
	return id, nil
}

func (s *Server) revokeFootprintOAuth(c *gin.Context) {
	db := s.footprintDB(c)
	if db == nil {
		return
	}
	owner, _ := IdentityFrom(c)
	ctx := c.Request.Context()
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		failJSON(c, 503, "revoke unavailable")
		return
	}
	defer tx.Rollback()
	if err = footprintOAuthOwnerLock(ctx, tx, owner.ID); err != nil {
		failJSON(c, 503, "revoke unavailable")
		return
	}
	if _, err = tx.ExecContext(ctx,
		`UPDATE harness.footprint_oauth_sessions SET revoked_at=$2 WHERE user_id=$1 AND revoked_at IS NULL`,
		owner.ID, s.now()); err != nil || tx.Commit() != nil {
		failJSON(c, 503, "revoke unavailable")
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true})
}
