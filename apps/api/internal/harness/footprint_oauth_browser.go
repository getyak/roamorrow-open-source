package harness

import (
	"bytes"
	"context"
	"database/sql"
	_ "embed"
	"encoding/json"
	"errors"
	"html/template"
	"io"
	"net"
	"net/http"
	"net/mail"
	"net/url"
	"strings"

	"github.com/gin-gonic/gin"
)

//go:embed footprint_oauth_page.html
var footprintOAuthPageHTML string

var footprintOAuthPage = template.Must(template.New("footprintOAuth").Parse(footprintOAuthPageHTML))

type footprintBrowserView struct {
	Chinese bool
	Attempt string
	Email   string
	Stage   string
	Resent  bool
	Error   bool
}

func newFootprintBrowserView(c *gin.Context, attempt, email, stage string) footprintBrowserView {
	language := strings.ToLower(c.GetHeader("Accept-Language"))
	return footprintBrowserView{Chinese: strings.HasPrefix(strings.TrimSpace(language), "zh"), Attempt: attempt, Email: email, Stage: stage}
}

func renderFootprintBrowser(c *gin.Context, status int, view footprintBrowserView) {
	c.Header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; form-action 'self' http://127.0.0.1:* http://localhost:* http://[::1]:*; base-uri 'none'; frame-ancestors 'none'")
	c.Header("X-Frame-Options", "DENY")
	c.Header("X-Content-Type-Options", "nosniff")
	c.Header("X-Robots-Tag", "noindex, nofollow")
	var page bytes.Buffer
	if err := footprintOAuthPage.Execute(&page, view); err != nil {
		c.Status(http.StatusInternalServerError)
		return
	}
	c.Data(status, "text/html; charset=utf-8", page.Bytes())
}

func (s *Server) footprintOAuthAuthorize(c *gin.Context) {
	values, err := url.ParseQuery(c.Request.URL.RawQuery)
	redirect, clientID := values.Get("redirect_uri"), values.Get("client_id")
	if len(c.Request.URL.RawQuery) > 8192 || err != nil || !footprintOAuthUnique(values) ||
		!strings.HasPrefix(clientID, "rm_client_") || len(clientID) != len("rm_client_")+43 ||
		values.Get("response_type") != "code" || values.Get("code_challenge_method") != "S256" ||
		!footprintFlowIDPattern.MatchString(values.Get("code_challenge")) ||
		len(values.Get("state")) > 512 || values.Get("state") == "" ||
		(values.Get("response_mode") != "" && values.Get("response_mode") != "query") {
		renderFootprintBrowser(c, 400, newFootprintBrowserView(c, "", "", "expired"))
		return
	}
	if !s.footprintOAuthResourceParam(values) || (values.Get("scope") != "" && values.Get("scope") != footprintOAuthScope) {
		renderFootprintBrowser(c, 400, newFootprintBrowserView(c, "", "", "expired"))
		return
	}
	db := s.footprintDB(c)
	if db == nil {
		return
	}
	ctx := c.Request.Context()
	now := s.now()
	var encoded []byte
	err = db.QueryRowContext(ctx, `SELECT redirect_uris FROM harness.footprint_oauth_clients WHERE id=$1 AND expires_at>$2`, clientID, now).Scan(&encoded)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		renderFootprintBrowser(c, 503, newFootprintBrowserView(c, "", "", "expired"))
		return
	}
	var uris []string
	if err != nil || json.Unmarshal(encoded, &uris) != nil || !footprintRedirectRegistered(uris, redirect) {
		renderFootprintBrowser(c, 400, newFootprintBrowserView(c, "", "", "expired"))
		return
	}
	browser, _ := c.Cookie(footprintBrowserCookie)
	if !footprintFlowIDPattern.MatchString(browser) {
		browser = footprintOAuthSecret("")
	}
	attempt := footprintOAuthSecret("")
	_, err = db.ExecContext(ctx, `WITH expired AS (
		DELETE FROM harness.footprint_oauth_attempts WHERE id IN
			(SELECT id FROM harness.footprint_oauth_attempts WHERE expires_at<=$8 AND session_id IS NULL ORDER BY expires_at LIMIT 100)),
		expired_sessions AS (
		DELETE FROM harness.footprint_oauth_sessions WHERE id IN
			(SELECT id FROM harness.footprint_oauth_sessions WHERE refresh_expires_at<=$8 ORDER BY refresh_expires_at LIMIT 100))
		INSERT INTO harness.footprint_oauth_attempts
		(id,browser_digest,client_id,resource,redirect_uri,client_state,code_challenge,expires_at)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$9)`,
		footprintOAuthDigest(attempt), footprintOAuthDigest(browser), clientID, s.footprintResource(),
		redirect, values.Get("state"), values.Get("code_challenge"), now, now.Add(footprintAttemptTTL))
	if err != nil {
		renderFootprintBrowser(c, 503, newFootprintBrowserView(c, "", "", "expired"))
		return
	}
	http.SetCookie(c.Writer, &http.Cookie{
		Name: footprintBrowserCookie, Value: browser, Path: footprintOAuthPath, HttpOnly: true,
		MaxAge: int(footprintAttemptTTL.Seconds()), Secure: strings.HasPrefix(s.footprintOAuthIssuer(), "https:"),
		SameSite: http.SameSiteLaxMode,
	})
	renderFootprintBrowser(c, 200, newFootprintBrowserView(c, attempt, "", "email"))
}

type footprintAttempt struct {
	id       []byte
	browser  []byte
	client   string
	redirect string
	state    string
	email    string
	owner    string
}

func (s *Server) footprintOAuthAuthorizeForm(c *gin.Context) {
	form, valid := footprintOAuthParseForm(c)
	browser, _ := c.Cookie(footprintBrowserCookie)
	attemptToken := form.Get("attempt")
	if origin := c.GetHeader("Origin"); origin != "" && origin != s.footprintOAuthIssuer() {
		valid = false
	}
	if !valid || !footprintFlowIDPattern.MatchString(attemptToken) || !footprintFlowIDPattern.MatchString(browser) {
		renderFootprintBrowser(c, 400, newFootprintBrowserView(c, "", "", "expired"))
		return
	}
	db := s.footprintDB(c)
	if db == nil {
		return
	}
	ctx := c.Request.Context()
	a := footprintAttempt{id: footprintOAuthDigest(attemptToken), browser: footprintOAuthDigest(browser)}
	err := db.QueryRowContext(ctx, `SELECT client_id,redirect_uri,client_state,COALESCE(email,''),COALESCE(user_id::text,'')
		FROM harness.footprint_oauth_attempts WHERE id=$1 AND browser_digest=$2 AND resource=$3
		AND expires_at>$4 AND code_digest IS NULL`, a.id, a.browser, s.footprintResource(), s.now()).
		Scan(&a.client, &a.redirect, &a.state, &a.email, &a.owner)
	if err != nil {
		status := http.StatusGone
		if !errors.Is(err, sql.ErrNoRows) {
			status = http.StatusServiceUnavailable
		}
		renderFootprintBrowser(c, status, newFootprintBrowserView(c, "", "", "expired"))
		return
	}

	view := newFootprintBrowserView(c, attemptToken, a.email, "email")
	if a.owner != "" {
		view.Stage = "consent"
	} else if a.email != "" {
		view.Stage = "code"
	}
	switch form.Get("action") {
	case "deny":
		if !s.footprintOAuthDeny(ctx, db, a) {
			renderFootprintBrowser(c, 409, newFootprintBrowserView(c, "", "", "expired"))
			return
		}
		s.footprintOAuthRedirectResult(c, a, "error", "access_denied")
		return
	case "allow":
		if a.owner == "" {
			break
		}
		if code, ok := s.footprintOAuthAllow(c, db, a); ok {
			s.footprintOAuthRedirectResult(c, a, "code", code)
			return
		}
	case "reset":
		if result, err := db.ExecContext(ctx, `UPDATE harness.footprint_oauth_attempts SET email=NULL,user_id=NULL
			WHERE id=$1 AND browser_digest=$2 AND code_digest IS NULL AND expires_at>$3`, a.id, a.browser, s.now()); err == nil && footprintChangedOne(result) {
			view.Stage = "email"
			view.Email = ""
			renderFootprintBrowser(c, 200, view)
			return
		}
	case "password_page":
		if a.owner == "" {
			view.Stage = "password"
			renderFootprintBrowser(c, 200, view)
			return
		}
	case "send":
		view.Email = footprintLoginEmail(form.Get("email"))
		if view.Stage == "email" && s.footprintOAuthSendCode(c, db, a, view.Email) {
			view.Stage = "code"
			renderFootprintBrowser(c, 200, view)
			return
		}
	case "resend":
		if view.Stage == "code" && s.footprintOAuthSendCode(c, db, a, a.email) {
			view.Resent = true
			renderFootprintBrowser(c, 200, view)
			return
		}
	case "verify", "password":
		email := a.email
		path := "verify"
		body := map[string]string{"email": email, "token": form.Get("code"), "type": "email"}
		if form.Get("action") == "password" {
			view.Stage = "password"
			email = footprintLoginEmail(form.Get("email"))
			view.Email = email
			path = "token?grant_type=password"
			body = map[string]string{"email": email, "password": form.Get("password")}
		}
		if a.owner == "" && email != "" && (path != "verify" || footprintLoginCode(body["token"])) &&
			s.footprintOAuthVerify(c, db, a, email, path, body) {
			view.Email = email
			view.Stage = "consent"
			renderFootprintBrowser(c, 200, view)
			return
		}
	}
	view.Error = true
	renderFootprintBrowser(c, 400, view)
}

func footprintChangedOne(result sql.Result) bool {
	n, err := result.RowsAffected()
	return n == 1 && err == nil
}

func footprintLoginEmail(raw string) string {
	raw = strings.ToLower(strings.TrimSpace(raw))
	address, err := mail.ParseAddress(raw)
	if len(raw) > 254 || err != nil || address.Name != "" || address.Address != raw || !strings.Contains(raw, ".") {
		return ""
	}
	return raw
}

func footprintLoginCode(raw string) bool {
	if len(raw) < 6 || len(raw) > 10 {
		return false
	}
	for _, character := range raw {
		if character < '0' || character > '9' {
			return false
		}
	}
	return true
}

func (s *Server) footprintOAuthLoginRequest(c *gin.Context, path string, payload any) ([]byte, error) {
	// Bound request counts before calling Supabase, including repeated sends
	// from the same browser or attempts with another email.
	host, _, err := net.SplitHostPort(c.Request.RemoteAddr)
	if err != nil {
		host = c.Request.RemoteAddr
	}
	bucket := footprintOAuthDigest(host)
	release, err := s.footprintLoginLimiter.Acquire(string(bucket[:1]))
	if err != nil {
		return nil, err
	}
	defer release()
	body, _ := json.Marshal(payload)
	request, err := http.NewRequestWithContext(c.Request.Context(), http.MethodPost,
		strings.TrimRight(s.cfg.SupabaseURL, "/")+"/auth/v1/"+path, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	request.Header.Set("apikey", s.cfg.SupabaseAnonKey)
	request.Header.Set("Content-Type", "application/json")
	response, err := s.footprintLoginClient.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, errors.New("account verification failed")
	}
	return io.ReadAll(io.LimitReader(response.Body, maxAuthBody))
}

func (s *Server) footprintOAuthSendCode(c *gin.Context, db *sql.DB, a footprintAttempt, rawEmail string) bool {
	email := footprintLoginEmail(rawEmail)
	if email == "" {
		return false
	}
	// The website connects existing accounts. Native onboarding owns signup.
	_, requestErr := s.footprintOAuthLoginRequest(c, "otp", map[string]any{"email": email, "create_user": false})
	// Use the same visible result for unknown accounts, provider failures, and
	// accepted sends. The address on the attempt still controls verification.
	// Requests rejected by the local limiter cannot change the attempt.
	if errors.Is(requestErr, ErrRateLimited) || errors.Is(requestErr, ErrConcurrencyLimited) {
		return false
	}
	result, err := db.ExecContext(c.Request.Context(),
		`UPDATE harness.footprint_oauth_attempts SET email=$3 WHERE id=$1 AND browser_digest=$2
		AND expires_at>$4 AND user_id IS NULL AND code_digest IS NULL AND COALESCE(email,'')=$5`,
		a.id, a.browser, email, s.now(), a.email)
	return err == nil && footprintChangedOne(result)
}

func (s *Server) footprintOAuthVerify(c *gin.Context, db *sql.DB, a footprintAttempt, email, path string, body map[string]string) bool {
	data, err := s.footprintOAuthLoginRequest(c, path, body)
	if err != nil {
		return false
	}
	var tokens struct {
		AccessToken string `json:"access_token"`
	}
	if json.Unmarshal(data, &tokens) != nil || tokens.AccessToken == "" || len(tokens.AccessToken) > 8192 {
		return false
	}
	identity, err := s.verifier.Verify(c.Request.Context(), tokens.AccessToken)
	if err != nil || !footprintUUID.MatchString(identity.ID) || !strings.EqualFold(identity.Email, email) {
		return false
	}
	result, err := db.ExecContext(c.Request.Context(), `UPDATE harness.footprint_oauth_attempts SET user_id=$3,email=$4
		WHERE id=$1 AND browser_digest=$2 AND expires_at>$5 AND user_id IS NULL AND code_digest IS NULL
		AND COALESCE(email,'')=$6`, a.id, a.browser, identity.ID, email, s.now(), a.email)
	return err == nil && footprintChangedOne(result)
}

func (s *Server) footprintOAuthDeny(ctx context.Context, db *sql.DB, a footprintAttempt) bool {
	result, err := db.ExecContext(ctx, `DELETE FROM harness.footprint_oauth_attempts WHERE id=$1 AND browser_digest=$2
		AND code_digest IS NULL AND expires_at>$3`, a.id, a.browser, s.now())
	return err == nil && footprintChangedOne(result)
}

func (s *Server) footprintOAuthAllow(c *gin.Context, db *sql.DB, a footprintAttempt) (string, bool) {
	ctx := c.Request.Context()
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return "", false
	}
	defer tx.Rollback()
	now := s.now()
	// Share the owner lock with deletion and revocation. A pending session is
	// immediately revocable even if its authorization code is not exchanged.
	if err = footprintOAuthOwnerLock(ctx, tx, a.owner); err != nil {
		return "", false
	}
	session := footprintOAuthDigest(footprintOAuthSecret(""))
	code := footprintOAuthSecret("")
	if _, err := tx.ExecContext(ctx, `INSERT INTO harness.footprint_oauth_sessions
		(id,client_id,resource,user_id,refresh_expires_at) VALUES ($1,$2,$3,$4,$5)`,
		session, a.client, s.footprintResource(), a.owner, now.Add(footprintAttemptTTL)); err != nil {
		return "", false
	}
	result, err := tx.ExecContext(ctx, `UPDATE harness.footprint_oauth_attempts SET code_digest=$4,code_expires_at=$5,session_id=$6
		WHERE id=$1 AND browser_digest=$2 AND user_id=$3 AND code_digest IS NULL AND expires_at>$7`,
		a.id, a.browser, a.owner, footprintOAuthDigest(code), now.Add(footprintCodeTTL), session, now)
	if err != nil || !footprintChangedOne(result) || tx.Commit() != nil {
		return "", false
	}
	return code, true
}

func footprintOAuthOwnerLock(ctx context.Context, tx *sql.Tx, owner string) error {
	_, err := tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1,623719))`, owner)
	return err
}

func (s *Server) footprintOAuthRedirectResult(c *gin.Context, a footprintAttempt, key, value string) {
	to, ok := footprintOAuthRedirect(a.redirect, true)
	if !ok {
		renderFootprintBrowser(c, 400, newFootprintBrowserView(c, "", "", "expired"))
		return
	}
	to.RawQuery = url.Values{key: {value}, "state": {a.state}, "iss": {s.footprintOAuthIssuer()}}.Encode()
	c.Redirect(http.StatusSeeOther, to.String())
}
