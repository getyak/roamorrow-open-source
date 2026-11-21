package harness

import (
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
)

func TestFootprintOAuthOriginAndRedirects(t *testing.T) {
	for _, raw := range []string{"http://example.test", "https://user@mcp.example.test", "https://a.test/foo",
		"https://a.test?resource=other", "https://a.test#fragment", "https://a.test\"",
		"https://-a.test", "https://a.test.", "https://a.test:0", "https://a.test:", "https://a.test:70000", "https://[a.test]"} {
		if origin := footprintOAuthOrigin(raw); origin != "" {
			t.Errorf("accepted noncanonical or insecure origin %q", raw)
		}
	}
	if got := footprintOAuthOrigin("https://MCP.EXAMPLE.TEST/"); got != "https://mcp.example.test" {
		t.Fatalf("canonical origin = %q", got)
	}
	for _, raw := range []string{"https://example.test/callback", "http://localhost.evil.test/callback",
		"http://evil@localhost/callback", "http://127.0.0.1:70000/callback", "http://127.0.0.1:1111/callback?",
		"http://127.0.0.1:1111/callback/%61", "http://127.0.0.1:1111/other", "http://[::1]:1111/callback#result"} {
		if _, valid := footprintOAuthRedirect(raw, false); valid {
			t.Errorf("accepted untrusted redirect %q", raw)
		}
	}
	reg := []string{"http://127.0.0.1/callback/session-a"}
	if !footprintRedirectRegistered(reg, "http://localhost:2345/callback/session-a") ||
		footprintRedirectRegistered(reg, "http://localhost:2345/callback/session-b") ||
		footprintRedirectRegistered(reg, "http://localhost/callback/session-a") {
		t.Fatal("redirect binding must allow a loopback port to vary, not the callback path")
	}
}

func TestFootprintOAuthDiscoveryDisabledWithoutCanonicalOrigin(t *testing.T) {
	s := NewServer(Config{}, nil)
	r := gin.New()
	s.Register(r)
	discovery := httptest.NewRecorder()
	r.ServeHTTP(discovery, httptest.NewRequest(http.MethodGet, footprintProtectedPath, nil))
	if discovery.Code != http.StatusNotFound {
		t.Fatalf("unconfigured publication returned %d", discovery.Code)
	}
	challenge := httptest.NewRecorder()
	r.ServeHTTP(challenge, httptest.NewRequest(http.MethodPost, footprintMCPPath, nil))
	if challenge.Code != http.StatusUnauthorized || strings.Contains(challenge.Header().Get("WWW-Authenticate"), "resource_metadata") {
		t.Fatalf("unconfigured footprints returned %d / %q", challenge.Code, challenge.Header().Get("WWW-Authenticate"))
	}
}

func TestFootprintOAuthLiveChain(t *testing.T) {
	dsn := os.Getenv("FOOTPRINTS_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("requires the dedicated footprint PostgreSQL test database with migrations applied")
	}
	db, err := sql.Open("postgres", dsn)
	if err != nil {
		t.Fatal("cannot open footprint test database")
	}
	t.Cleanup(func() { _ = db.Close() })
	const owner = "8b0fe228-f7e8-4c83-bc7e-b4b7bd721ac4"
	const alternate = "2aacc653-e30e-4db3-8b65-ac6db2951a22"
	const email = "traveler@example.test"
	const issuer = "https://roamorrow.example.test"
	const resource = issuer + footprintMCPPath
	const callback = "http://localhost:2345/callback/roamorrow-test"
	stub := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		var body map[string]any
		switch r.URL.Path {
		case "/auth/v1/otp":
			if json.NewDecoder(r.Body).Decode(&body) != nil || body["email"] != email || body["create_user"] != false {
				t.Error("unexpected code request")
			}
			fmt.Fprint(w, "{}")
		case "/auth/v1/verify":
			if json.NewDecoder(r.Body).Decode(&body) != nil || body["email"] != email || body["token"] != "123456" || body["type"] != "email" {
				t.Error("unexpected verification request")
			}
			fmt.Fprint(w, `{"access_token":"account-owner"}`)
		case "/auth/v1/user":
			var id string
			switch r.Header.Get("Authorization") {
			case "Bearer account-owner":
				id = owner
			case "Bearer account-alternate":
				id = alternate
			default:
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			fmt.Fprintf(w, `{"id":%q,"email":%q,"email_confirmed_at":"2020-01-01T00:00:00Z","identities":[{"provider":"email"}]}`, id, email)
		default:
			t.Error("unexpected identity provider route")
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(stub.Close)
	s := NewServer(Config{FootprintOAuthOrigin: issuer, SupabaseURL: stub.URL, SupabaseAnonKey: "example-project-key"}, NewPostgresStore(db))
	now := time.Now().UTC()
	s.now = func() time.Time { return now }
	r := gin.New()
	s.Register(r)
	request := func(method, route, body, contentType, bearer string, cookies ...*http.Cookie) *httptest.ResponseRecorder {
		t.Helper()
		req := httptest.NewRequest(method, issuer+route, strings.NewReader(body))
		req.Header.Set("Content-Type", contentType)
		req.Header.Set("Accept", "application/json, text/event-stream")
		if bearer != "" {
			req.Header.Set("Authorization", "Bearer "+bearer)
		}
		for _, cookie := range cookies {
			req.AddCookie(cookie)
		}
		rec := httptest.NewRecorder()
		r.ServeHTTP(rec, req)
		return rec
	}
	status := func(w *httptest.ResponseRecorder, want int) *httptest.ResponseRecorder {
		t.Helper()
		if w.Code != want {
			t.Fatalf("response status = %d, want %d", w.Code, want)
		}
		return w
	}
	jsonMap := func(w *httptest.ResponseRecorder) map[string]any {
		t.Helper()
		var result map[string]any
		if json.Unmarshal(w.Body.Bytes(), &result) != nil {
			t.Fatal("response was not a JSON object")
		}
		return result
	}
	mcp := func(bearer, requestBody string, want int) *httptest.ResponseRecorder {
		t.Helper()
		return status(request("POST", footprintMCPPath, requestBody, "application/json", bearer), want)
	}
	const ping = `{"jsonrpc":"2.0","id":1,"method":"ping"}`
	challenge := mcp("", ping, 401)
	if !strings.Contains(challenge.Header().Get("WWW-Authenticate"), issuer+footprintProtectedPath) {
		t.Fatal("missing resource metadata in authentication challenge")
	}
	metadata := jsonMap(status(request("GET", footprintProtectedPath, "", "", ""), 200))
	if metadata["resource"] != resource {
		t.Fatal("discovery advertised wrong resource")
	}
	issuerMetadata := jsonMap(status(request("GET", "/.well-known/oauth-authorization-server", "", "", ""), 200))
	if issuerMetadata["issuer"] != issuer || issuerMetadata["token_endpoint"] != issuer+footprintOAuthPath+"/token" {
		t.Fatal("discovery advertised wrong issuer")
	}
	status(request("POST", footprintOAuthPath+"/register", `{"redirect_uris":["https://untrusted.example.test/callback"]}`, "application/json", ""), 400)
	reg := jsonMap(status(request("POST", footprintOAuthPath+"/register",
		`{"redirect_uris":["http://127.0.0.1/callback/roamorrow-test"],"token_endpoint_auth_method":"none"}`, "application/json", ""), 201))
	clientID, ok := reg["client_id"].(string)
	if !ok || clientID == "" {
		t.Fatal("missing dynamically registered public client identity")
	}
	t.Cleanup(func() {
		_, _ = db.Exec(`DELETE FROM harness.footprint_oauth_sessions WHERE user_id=$1`, owner)
		_, _ = db.Exec(`DELETE FROM harness.footprint_oauth_attempts WHERE client_id=$1`, clientID)
		_, _ = db.Exec(`DELETE FROM harness.footprint_oauth_clients WHERE id=$1`, clientID)
	})

	verifier := footprintOAuthSecret("")
	authQuery := url.Values{
		"client_id": {clientID}, "response_type": {"code"}, "redirect_uri": {callback},
		"state": {"/oauth-test"}, "scope": {footprintOAuthScope}, "resource": {resource},
		"code_challenge_method": {"S256"}, "code_challenge": {base64.RawURLEncoding.EncodeToString(footprintOAuthDigest(verifier))},
	}
	start := func() (string, *http.Cookie) {
		t.Helper()
		rec := status(request("GET", footprintOAuthPath+"/authorize?"+authQuery.Encode(), "", "", ""), 200)
		match := regexp.MustCompile(`name="attempt" value="([A-Za-z0-9_-]+)"`).FindStringSubmatch(rec.Body.String())
		if !strings.Contains(rec.Body.String(), `<form method="post" action="/oauth/footprints/authorize">`) {
			t.Fatal("browser form must post to a clean authorization path")
		}
		cookies := rec.Result().Cookies()
		if len(match) != 2 || len(cookies) != 1 || !cookies[0].Secure || !cookies[0].HttpOnly {
			t.Fatal("authorization attempt is not bound to a protected browser cookie")
		}
		return match[1], cookies[0]
	}
	browser := func(attempt string, cookie *http.Cookie, fields url.Values, want int) *httptest.ResponseRecorder {
		t.Helper()
		fields.Set("attempt", attempt)
		return status(request("POST", footprintOAuthPath+"/authorize", fields.Encode(), "application/x-www-form-urlencoded", "", cookie), want)
	}
	allow := func() string {
		t.Helper()
		attempt, cookie := start()
		browser(attempt, cookie, url.Values{"action": {"allow"}}, 400)
		browser(attempt, &http.Cookie{Name: cookie.Name, Value: footprintOAuthSecret("")}, url.Values{"action": {"send"}, "email": {email}}, 410)
		browser(attempt, cookie, url.Values{"action": {"send"}, "email": {email}}, 200)
		consent := browser(attempt, cookie, url.Values{"action": {"verify"}, "code": {"123456"}}, 200)
		if !strings.Contains(consent.Body.String(), "Read footprint summaries") || !strings.Contains(consent.Body.String(), email) {
			t.Fatal("consent must show verified identity and scope")
		}
		approved := browser(attempt, cookie, url.Values{"action": {"allow"}}, 303)
		location, err := url.Parse(approved.Header().Get("Location"))
		if err != nil || !strings.HasPrefix(location.String(), callback+"?") ||
			location.Query().Get("state") != "/oauth-test" || location.Query().Get("iss") != issuer ||
			location.Query().Get("code") == "" {
			t.Fatal("authorization callback failed to preserve state and issuer")
		}
		return location.Query().Get("code")
	}
	token := func(values url.Values, want int) map[string]any {
		t.Helper()
		return jsonMap(status(request("POST", footprintOAuthPath+"/token", values.Encode(), "application/x-www-form-urlencoded", ""), want))
	}
	exchange := func(code string) url.Values {
		return url.Values{"grant_type": {"authorization_code"}, "code": {code}, "code_verifier": {verifier},
			"client_id": {clientID}, "redirect_uri": {callback}, "resource": {resource}}
	}
	firstCode := allow()
	exchangeForm := exchange(firstCode)
	exchangeForm.Set("code_verifier", footprintOAuthSecret(""))
	token(exchangeForm, 400)
	exchangeForm = exchange(firstCode)
	exchangeForm.Set("resource", issuer+"/mcp")
	token(exchangeForm, 400)
	exchangeForm = exchange(firstCode)
	exchangeForm.Set("redirect_uri", "http://127.0.0.1:2345/callback/roamorrow-test")
	token(exchangeForm, 400)
	exchangeForm = exchange(firstCode)
	exchangeForm.Set("client_id", footprintOAuthSecret("rm_client_"))
	token(exchangeForm, 400)
	pair := token(exchange(firstCode), 200)
	access := pair["access_token"].(string)
	refresh := pair["refresh_token"].(string)
	token(exchange(firstCode), 400)
	if !strings.HasPrefix(access, footprintAccessPrefix) || pair["scope"] != footprintOAuthScope {
		t.Fatal("incorrect issued credential scope")
	}
	catalog := mcp(access, `{"jsonrpc":"2.0","id":1,"method":"tools/list"}`, 200)
	tools := jsonMap(catalog)["result"].(map[string]any)["tools"].([]any)
	if len(tools) != 1 || tools[0].(map[string]any)["name"] != "get_footprint_day" {
		t.Fatal("summary token advertised an unauthorized tool")
	}
	denied := mcp(access, `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_visits","arguments":{}}}`, 200)
	if jsonMap(denied)["result"].(map[string]any)["isError"] != true {
		t.Fatal("summary token bypassed catalog scope")
	}
	mcp(refresh, ping, 401)
	ownerStatus := jsonMap(status(request("GET", "/v1/footprints/status", "", "", "account-owner"), 200))
	otherStatus := jsonMap(status(request("GET", "/v1/footprints/status", "", "", "account-alternate"), 200))
	if ownerStatus["oauth_connected"] != true || ownerStatus["agent_access"] != false || otherStatus["oauth_connected"] != false {
		t.Fatal("authorization status crossed an account or grant type")
	}

	now = now.Add(footprintAccessTTL + time.Second)
	mcp(access, ping, 401)
	refreshForm := url.Values{"grant_type": {"refresh_token"}, "client_id": {clientID}, "refresh_token": {refresh}}
	pair = token(refreshForm, 200) // The sole resource is also bound when omitted by the client.
	newAccess, newRefresh := pair["access_token"].(string), pair["refresh_token"].(string)
	if newRefresh == refresh || newAccess == access {
		t.Fatal("refresh did not rotate both credentials")
	}
	mcp(newAccess, ping, 200)
	token(refreshForm, 400)
	mcp(newAccess, ping, 401) // Replay invalidates the token family.

	pair = token(exchange(allow()), 200)
	access = pair["access_token"].(string)
	refreshForm.Set("refresh_token", pair["refresh_token"].(string))
	status(request("DELETE", "/v1/footprints/oauth", "", "", "account-alternate"), 200)
	mcp(access, ping, 200)
	status(request("DELETE", "/v1/footprints/oauth", "", "", "account-owner"), 200)
	mcp(access, ping, 401)
	token(refreshForm, 400)
}
