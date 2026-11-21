package harness

import (
	"bytes"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"image"
	"image/jpeg"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
)

func TestFootprintsLiveChain(t *testing.T) {
	dsn := os.Getenv("FOOTPRINTS_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("requires a dedicated PostgreSQL database with footprint migrations")
	}
	db, err := sql.Open("postgres", dsn)
	if err != nil {
		t.Fatal("cannot open test database")
	}
	defer db.Close()
	gin.SetMode(gin.TestMode)
	const owner = "c52f1cf1-c17e-455c-a88e-b91220140294"
	const other = "01e77b6b-1b47-4fad-a7e0-ceaf676ec967"
	const entry = "d8209ac2-336a-46c2-a741-06c1dee02322"
	const photo = "c4222f44-4960-4b74-8c84-5a09551a8f6a"
	const segment = "0a9873c2-cc3a-4604-874a-7eccd2ab47c5"
	t.Cleanup(func() {
		for _, table := range []string{"harness.footprint_grants", "harness.footprints"} {
			cleanup, err := sql.Open("postgres", dsn)
			if err == nil {
				_, _ = cleanup.Exec("DELETE FROM "+table+" WHERE user_id IN ($1,$2)", owner, other)
				_ = cleanup.Close()
			}
		}
	})
	s := NewServer(Config{}, NewPostgresStore(db))
	s.verifier = &fakeVerifier{tokens: map[string]Identity{"owner": {ID: owner}, "other": {ID: other}}}
	r := gin.New()
	s.Register(r)
	post := func(method, path, auth string, body any, status int) map[string]any {
		t.Helper()
		input, err := json.Marshal(body)
		if err != nil {
			t.Fatal(err)
		}
		req := httptest.NewRequest(method, path, bytes.NewReader(input))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Accept", "application/json, text/event-stream")
		req.Header.Set("Authorization", "Bearer "+auth)
		out := httptest.NewRecorder()
		r.ServeHTTP(out, req)
		if out.Code != status {
			t.Fatalf("%s %s returned %d, expected %d", method, path, out.Code, status)
		}
		var decoded map[string]any
		if err := json.Unmarshal(out.Body.Bytes(), &decoded); err != nil {
			t.Fatal(err)
		}
		return decoded
	}
	grant := func(auth string, raw bool) string {
		return post("POST", "/v1/footprints/grant", auth, gin.H{"raw_tracks": raw, "photo_previews": raw}, 200)["token"].(string)
	}
	rpc := func(auth, tool string, args any) map[string]any {
		return post("POST", "/mcp/footprints", auth, gin.H{"jsonrpc": "2.0", "id": 1, "method": "tools/call",
			"params": gin.H{"name": tool, "arguments": args}}, 200)["result"].(map[string]any)
	}
	now := time.Now().UTC().Truncate(time.Millisecond)
	millis := now.Add(-time.Minute).UnixMilli()
	lat, lon := 18.79, 98.99
	point := footprint{ID: entry, Kind: "point", At: millis, Latitude: &lat, Longitude: &lon, Segment: segment, Version: 1}
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, image.NewRGBA(image.Rect(0, 0, 8, 8)), nil); err != nil {
		t.Fatal(err)
	}
	p := footprint{ID: photo, Kind: "photo", At: -86400000, Preview: buf.Bytes(), Version: 1}
	batch := gin.H{"records": []footprint{point, p}}
	post("POST", "/v1/footprints/sync", "owner", batch, 200)
	post("POST", "/v1/footprints/sync", "owner", batch, 200)
	read := gin.H{"from": now.Add(-time.Hour), "to": now.Add(time.Hour)}
	post("GET", "/v1/footprints/status", "invalid", nil, 401)
	status := post("GET", "/v1/footprints/status", "owner", nil, 200)
	if status["track_points"] != float64(1) || status["visits"] != float64(0) ||
		status["favorite_photos"] != float64(1) || status["latest_received_at_ms"] == nil ||
		status["agent_access"] != false {
		t.Fatalf("unexpected owner status: %v", status)
	}
	first := grant("owner", false)
	limitedCatalog := post("POST", "/mcp/footprints", first, gin.H{"jsonrpc": "2.0", "id": 1, "method": "tools/list"}, 200)
	for _, tool := range limitedCatalog["result"].(map[string]any)["tools"].([]any) {
		name := tool.(map[string]any)["name"]
		if name == "list_track_points" || name == "get_photo_preview" {
			t.Fatal("limited grant advertised tools outside its scope")
		}
	}
	otherStatus := post("GET", "/v1/footprints/status", "other", nil, 200)
	if otherStatus["track_points"] != float64(0) || otherStatus["favorite_photos"] != float64(0) ||
		otherStatus["latest_received_at_ms"] != nil || otherStatus["agent_access"] != false {
		t.Fatalf("status crossed the account boundary: %v", otherStatus)
	}
	firstFeed := rpc(first, "list_footprint_changes", gin.H{"cursor": "0"})["structuredContent"].(map[string]any)
	firstRecords := firstFeed["records"].([]any)
	if len(firstRecords) != 1 || firstRecords[0].(map[string]any)["id"] != photo || firstRecords[0].(map[string]any)["preview"] != nil {
		t.Fatal("default feed crossed its grant scope or included thumbnail bytes")
	}
	if rpc(first, "list_track_points", read)["isError"] != true {
		t.Fatal("default grant exposed exact track points")
	}
	if rpc(first, "get_photo_preview", gin.H{"id": photo})["isError"] != true {
		t.Fatal("default grant exposed image")
	}
	second := grant("owner", true)
	digest := sha256.Sum256([]byte(second))
	var persistent bool
	if err := db.QueryRow(`SELECT expires_at IS NULL FROM harness.footprint_grants WHERE digest=$1`, digest[:]).Scan(&persistent); err != nil || !persistent {
		t.Fatal("grant must survive calendar expiry and process restart")
	}
	page := rpc(second, "list_footprint_changes", gin.H{"cursor": "0", "limit": 1})["structuredContent"].(map[string]any)
	if len(page["records"].([]any)) != 1 || page["has_more"] != true {
		t.Fatal("feed must page without losing later changes")
	}
	snapshot := rpc(second, "list_footprint_changes", gin.H{})["structuredContent"].(map[string]any)
	if len(snapshot["records"].([]any)) != 0 {
		t.Fatal("a new live reader must start at the current cursor")
	}
	rows := rpc(second, "list_track_points", read)["structuredContent"].(map[string]any)["records"].([]any)
	if len(rows) != 1 || rows[0].(map[string]any)["id"] != entry {
		t.Fatal("track sync or replay failed")
	}
	content := rpc(second, "get_photo_preview", gin.H{"id": photo})["content"].([]any)
	if len(content) != 2 || content[1].(map[string]any)["data"] != base64.StdEncoding.EncodeToString(buf.Bytes()) {
		t.Fatal("photo preview did not round-trip")
	}
	otherGrant := grant("other", true)
	otherFeed := rpc(otherGrant, "list_footprint_changes", gin.H{"cursor": "0"})["structuredContent"].(map[string]any)
	if len(otherFeed["records"].([]any)) != 0 {
		t.Fatal("feed crossed owner boundary")
	}
	if rpc(otherGrant, "get_photo_preview", gin.H{"id": photo})["isError"] != true {
		t.Fatal("photo crossed owner boundary")
	}
	p.Deleted, p.Version, p.Preview = true, 2, nil
	post("POST", "/v1/footprints/sync", "owner", gin.H{"records": []footprint{p}}, 200)
	post("POST", "/v1/footprints/sync", "owner", batch, 200)
	status = post("GET", "/v1/footprints/status", "owner", nil, 200)
	if status["favorite_photos"] != float64(0) || status["agent_access"] != true {
		t.Fatalf("status did not reflect the tombstone and active grant: %v", status)
	}
	updates := rpc(second, "list_footprint_changes", gin.H{"cursor": snapshot["next_cursor"]})["structuredContent"].(map[string]any)
	changes := updates["records"].([]any)
	if len(changes) != 1 || changes[0].(map[string]any)["deleted"] != true || changes[0].(map[string]any)["id"] != photo {
		t.Fatal("resuming from cursor missed the photo removal or emitted a replay")
	}
	if rpc(second, "get_photo_preview", gin.H{"id": photo})["isError"] != true {
		t.Fatal("old upload resurrected the photo")
	}
	dayArgs := gin.H{"date": "2024-04-20", "time_zone": "Asia/Shanghai", "limit": 1}
	arrival := time.Date(2024, 4, 19, 15, 45, 0, 0, time.UTC).UnixMilli()
	departure := time.Date(2024, 4, 19, 16, 15, 0, 0, time.UTC).UnixMilli()
	firstVisit := footprint{ID: "50000000-0000-4000-8000-000000000001", Kind: "visit",
		At: arrival, End: &departure, Latitude: &lat, Longitude: &lon, City: "杭州", District: "西湖区",
		Label: "Private journal label", Version: 1}
	secondVisit := firstVisit
	secondVisit.ID = "50000000-0000-4000-8000-000000000002"
	secondVisit.At, secondVisit.End = departure, nil
	post("POST", "/v1/footprints/sync", "owner", gin.H{"records": []footprint{firstVisit, secondVisit}}, 200)
	day := rpc(second, "get_footprint_day", dayArgs)["structuredContent"].(map[string]any)
	dayVisits := day["visits"].([]any)
	if day["coverage"] != "partial" || len(dayVisits) != 1 || day["next_cursor"] == nil {
		t.Fatalf("expected the first visit and a continuation: %v", day)
	}
	firstSummary := dayVisits[0].(map[string]any)
	if firstSummary["arrival"] != "2024-04-19T15:45:00Z" || firstSummary["district"] != "西湖区" {
		t.Fatalf("cross-midnight visit lost its original timestamp or district: %v", firstSummary)
	}
	for _, key := range []string{"latitude", "longitude", "label", "device_id", "id"} {
		if _, ok := firstSummary[key]; ok {
			t.Fatalf("summary exposed %s", key)
		}
	}
	otherDay := rpc(otherGrant, "get_footprint_day", dayArgs)["structuredContent"].(map[string]any)
	if otherDay["coverage"] != "unknown" || len(otherDay["visits"].([]any)) != 0 {
		t.Fatal("empty result inferred completeness or crossed the owner boundary")
	}
	dayArgs["cursor"] = day["next_cursor"]
	nextDay := rpc(second, "get_footprint_day", dayArgs)["structuredContent"].(map[string]any)
	if len(nextDay["visits"].([]any)) != 1 || nextDay["next_cursor"] != nil {
		t.Fatalf("next visit not found: %v", nextDay)
	}
	firstRestore := post("GET", "/v1/footprints/history?limit=1", "owner", nil, 200)
	if len(firstRestore["records"].([]any)) != 1 || firstRestore["has_more"] != true {
		t.Fatal("owner history failed to page")
	}
	restored := post("GET", "/v1/footprints/history?cursor="+firstRestore["next_cursor"].(string), "owner", nil, 200)
	restoreRecords := restored["records"].([]any)
	if len(restoreRecords) != 3 || restored["has_more"] != false || restoreRecords[0].(map[string]any)["deleted"] != true {
		t.Fatal("restoring did not include subsequent records and tombstones")
	}
	isolated := post("GET", "/v1/footprints/history", "other", nil, 200)
	if len(isolated["records"].([]any)) != 0 {
		t.Fatal("owner history crossed the account boundary")
	}
	post("POST", "/mcp/footprints", first, gin.H{"jsonrpc": "2.0", "id": 1, "method": "ping"}, 401)
	post("DELETE", "/v1/footprints/grant", "owner", nil, 200)
	if post("GET", "/v1/footprints/status", "owner", nil, 200)["agent_access"] != false {
		t.Fatal("status retained a revoked grant")
	}
	post("POST", "/mcp/footprints", second, gin.H{"jsonrpc": "2.0", "id": 1, "method": "ping"}, 401)
}

func TestFootprintDayInterval(t *testing.T) {
	for _, test := range []struct {
		date  string
		zone  string
		hours int
	}{
		{"2024-03-10", "America/New_York", 23},
		{"2024-11-03", "America/New_York", 25},
		{"2024-03-10", "Asia/Shanghai", 24},
		{"2018-11-03", "America/Sao_Paulo", 24},
		{"2018-11-04", "America/Sao_Paulo", 23},
		{"2011-12-29", "Pacific/Apia", 24},
		{"2011-12-30", "Pacific/Apia", 0},
		{"2024-02-31", "Asia/Shanghai", 0},
		{"2024-03-10", "Local", 0},
		{"2024-03-10", "not/a/zone", 0},
	} {
		t.Run(test.date+"/"+test.zone, func(t *testing.T) {
			start, end, err := (footprintDayQuery{Date: test.date, TimeZone: test.zone}).interval()
			if test.hours == 0 {
				if err == nil {
					t.Fatal("invalid date or zone was accepted")
				}
				return
			}
			if err != nil || end.Sub(start) != time.Duration(test.hours)*time.Hour {
				t.Fatalf("wrong civil-day bounds: %s to %s (%v)", start, end, err)
			}
		})
	}
}
