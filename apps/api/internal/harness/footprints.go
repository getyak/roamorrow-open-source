package harness

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"image/jpeg"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
)

var oldestFootprintPhoto = time.Date(1, 1, 1, 0, 0, 0, 0, time.UTC).UnixMilli()

var footprintUUID = regexp.MustCompile("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")

type footprint struct {
	ID        string   `json:"id"`
	Kind      string   `json:"kind"`
	At        int64    `json:"at"`
	End       *int64   `json:"end,omitempty"`
	Latitude  *float64 `json:"latitude,omitempty"`
	Longitude *float64 `json:"longitude,omitempty"`
	Accuracy  *float64 `json:"accuracy,omitempty"`
	Segment   string   `json:"segment,omitempty"`
	Label     string   `json:"label,omitempty"`
	City      string   `json:"city,omitempty"`
	District  string   `json:"district,omitempty"`
	Preview   []byte   `json:"preview,omitempty"`
	Deleted   bool     `json:"deleted,omitempty"`
	Version   int64    `json:"version"`
}

func (p footprint) valid(now time.Time) bool {
	if len(p.City) > 120 || len(p.District) > 120 ||
		(p.City != "" || p.District != "") && p.Kind != "visit" {
		return false
	}
	if len(p.Label) > 800 || (p.Label != "" && p.Kind != "visit") || !footprintUUID.MatchString(p.ID) || p.Version < 1 || p.At > now.Add(10*time.Minute).UnixMilli() {
		return false
	}
	// A scanned or imported favorite can legitimately predate the Unix epoch.
	if p.At < oldestFootprintPhoto || (p.At < 1 && p.Kind != "photo") {
		return false
	}
	hasLocation := p.Latitude != nil && p.Longitude != nil
	if (p.Latitude != nil) != (p.Longitude != nil) || hasLocation &&
		!(*p.Latitude >= -90 && *p.Latitude <= 90 && *p.Longitude >= -180 && *p.Longitude <= 180) {
		return false
	}
	if p.Accuracy != nil && (*p.Accuracy < 0 || *p.Accuracy > 100000) {
		return false
	}
	switch p.Kind {
	case "point":
		return hasLocation && footprintUUID.MatchString(p.Segment) && p.End == nil && len(p.Preview) == 0 && !p.Deleted
	case "visit":
		return hasLocation && p.Segment == "" && len(p.Preview) == 0 && !p.Deleted &&
			(p.End == nil || *p.End >= p.At && *p.End <= now.Add(10*time.Minute).UnixMilli())
	case "photo":
		if p.Segment != "" || p.End != nil || len(p.Preview) > 72<<10 {
			return false
		}
		if p.Deleted {
			return !hasLocation && len(p.Preview) == 0
		}
		config, err := jpeg.DecodeConfig(bytes.NewReader(p.Preview))
		return err == nil && config.Width > 0 && config.Width <= 512 && config.Height > 0 && config.Height <= 512
	}
	return false
}

func (s *Server) registerFootprints(r *gin.Engine) {
	group := r.Group("/v1/footprints", s.AuthMiddleware)
	group.POST("/sync", s.syncFootprints)
	group.GET("/status", s.footprintStatus)
	group.GET("/history", s.restoreFootprints)
	group.POST("/grant", s.grantFootprints)
	group.DELETE("/grant", s.revokeFootprints)
	group.DELETE("/oauth", s.revokeFootprintOAuth)
	group.DELETE("/history", s.deleteFootprints)
	r.POST(footprintMCPPath, s.checkOrigin, s.footprintMCP)
	r.GET(footprintMCPPath, s.checkOrigin, s.footprintMCP)
	r.DELETE(footprintMCPPath, s.checkOrigin, s.footprintMCP)
}

func (s *Server) footprintDB(c *gin.Context) *sql.DB {
	store, ok := s.store.(*PostgresStore)
	if !ok || store == nil || store.db == nil {
		failJSON(c, http.StatusServiceUnavailable, "footprints unavailable")
		return nil
	}
	c.Header("Cache-Control", "no-store")
	return store.db
}

func (s *Server) footprintStatus(c *gin.Context) {
	db := s.footprintDB(c)
	if db == nil {
		return
	}
	owner, _ := IdentityFrom(c)
	var points, visits, photos int64
	var latest sql.NullTime
	var agentAccess, oauthConnected bool
	err := db.QueryRowContext(c.Request.Context(), `SELECT
		count(*) FILTER (WHERE kind='point'),
		count(*) FILTER (WHERE kind='visit'),
		count(*) FILTER (WHERE kind='photo' AND NOT (payload ? 'deleted')),
		max(received_at),
		EXISTS (SELECT 1 FROM harness.footprint_grants WHERE user_id=$1 AND (expires_at IS NULL OR expires_at>$2)),
		EXISTS (SELECT 1 FROM harness.footprint_oauth_sessions WHERE user_id=$1 AND refresh_expires_at>$2
			AND refresh_digest IS NOT NULL AND revoked_at IS NULL AND resource=$3)
		FROM harness.footprints WHERE user_id=$1`, owner.ID, s.now(), s.footprintResource()).Scan(
		&points, &visits, &photos, &latest, &agentAccess, &oauthConnected,
	)
	if err != nil {
		failJSON(c, http.StatusServiceUnavailable, "footprint status unavailable")
		return
	}
	var receivedAt any
	if latest.Valid {
		receivedAt = latest.Time.UnixMilli()
	}
	c.JSON(http.StatusOK, gin.H{
		"track_points": points, "visits": visits, "favorite_photos": photos,
		"latest_received_at_ms": receivedAt, "agent_access": agentAccess,
		"oauth_available": s.footprintOAuthReady(), "oauth_connected": oauthConnected,
	})
}

func (s *Server) syncFootprints(c *gin.Context) {
	var input struct {
		Records []footprint `json:"records"`
	}
	if decodeStrict(c, &input, 2<<20) != nil || len(input.Records) == 0 || len(input.Records) > 100 {
		failJSON(c, 400, "invalid batch")
		return
	}
	for _, p := range input.Records {
		if !p.valid(s.now()) {
			failJSON(c, 400, "invalid footprint")
			return
		}
	}
	db := s.footprintDB(c)
	if db == nil {
		return
	}
	owner, _ := IdentityFrom(c)
	ctx := c.Request.Context()
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		failJSON(c, 503, "sync unavailable")
		return
	}
	defer tx.Rollback()
	// Serialize sequence assignment and commit per owner, so a reader can
	// advance its cursor without missing an earlier concurrent upload.
	if _, err = tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(hashtextextended($1, 623718))`, owner.ID); err != nil {
		failJSON(c, 503, "sync unavailable")
		return
	}
	for _, p := range input.Records {
		data, _ := json.Marshal(p)
		_, err = tx.ExecContext(ctx, `INSERT INTO harness.footprints AS f
			(user_id,id,kind,captured_at,version,payload,change_id)
			VALUES ($1,$2,$3,$4,$5,$6::jsonb,nextval('harness.footprint_change_seq'))
			ON CONFLICT (user_id,id) DO UPDATE SET payload=EXCLUDED.payload,
			version=EXCLUDED.version,captured_at=EXCLUDED.captured_at,received_at=clock_timestamp(),change_id=EXCLUDED.change_id
			WHERE f.kind=EXCLUDED.kind AND EXCLUDED.version>f.version`,
			owner.ID, p.ID, p.Kind, time.UnixMilli(p.At), p.Version, string(data))
		if err != nil {
			failJSON(c, 503, "sync unavailable")
			return
		}
	}
	if tx.Commit() != nil {
		failJSON(c, 503, "sync unavailable")
		return
	}
	c.JSON(200, gin.H{"received": len(input.Records)})
}

func (s *Server) grantFootprints(c *gin.Context) {
	var input struct {
		RawTracks     bool `json:"raw_tracks"`
		PhotoPreviews bool `json:"photo_previews"`
	}
	if decodeStrict(c, &input, 2048) != nil {
		failJSON(c, 400, "invalid grant")
		return
	}
	db := s.footprintDB(c)
	if db == nil {
		return
	}
	owner, _ := IdentityFrom(c)
	key := make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		failJSON(c, 503, "grant unavailable")
		return
	}
	token := base64.RawURLEncoding.EncodeToString(key)
	digest := sha256.Sum256([]byte(token))
	_, err := db.ExecContext(c.Request.Context(), `INSERT INTO harness.footprint_grants
		(user_id,digest,raw_tracks,photo_previews,expires_at) VALUES ($1,$2,$3,$4,NULL)
		ON CONFLICT (user_id) DO UPDATE SET digest=EXCLUDED.digest,raw_tracks=EXCLUDED.raw_tracks,
		photo_previews=EXCLUDED.photo_previews,expires_at=EXCLUDED.expires_at`,
		owner.ID, digest[:], input.RawTracks, input.PhotoPreviews)
	if err != nil {
		failJSON(c, 503, "grant unavailable")
		return
	}
	c.JSON(200, gin.H{"token": token, "expires_at": nil})
}

func (s *Server) revokeFootprints(c *gin.Context) {
	db := s.footprintDB(c)
	if db == nil {
		return
	}
	owner, _ := IdentityFrom(c)
	if _, err := db.ExecContext(c.Request.Context(), `DELETE FROM harness.footprint_grants WHERE user_id=$1`, owner.ID); err != nil {
		failJSON(c, 503, "revoke unavailable")
		return
	}
	c.JSON(200, gin.H{"ok": true})
}

func (s *Server) deleteFootprints(c *gin.Context) {
	db := s.footprintDB(c)
	if db == nil {
		return
	}
	owner, _ := IdentityFrom(c)
	ctx := c.Request.Context()
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		failJSON(c, 503, "delete unavailable")
		return
	}
	defer tx.Rollback()
	if err = footprintOAuthOwnerLock(ctx, tx, owner.ID); err != nil {
		failJSON(c, 503, "delete unavailable")
		return
	}
	if _, err = tx.ExecContext(ctx, `DELETE FROM harness.footprint_oauth_sessions WHERE user_id=$1`, owner.ID); err != nil {
		failJSON(c, 503, "delete unavailable")
		return
	}
	for _, query := range []string{`DELETE FROM harness.footprint_grants WHERE user_id=$1`, `DELETE FROM harness.footprints WHERE user_id=$1`} {
		if _, err = tx.ExecContext(ctx, query, owner.ID); err != nil {
			failJSON(c, 503, "delete unavailable")
			return
		}
	}
	if tx.Commit() != nil {
		failJSON(c, 503, "delete unavailable")
		return
	}
	c.JSON(200, gin.H{"ok": true})
}

func footprintTool(name, description string, props gin.H, required ...string) gin.H {
	schema := gin.H{"type": "object", "properties": props, "additionalProperties": false}
	if len(required) > 0 {
		schema["required"] = required
	}
	return gin.H{"name": name, "description": description, "inputSchema": schema, "annotations": gin.H{"readOnlyHint": true, "openWorldHint": false}}
}

var historySchema = gin.H{"from": gin.H{"type": "string", "format": "date-time"}, "to": gin.H{"type": "string", "format": "date-time"},
	"cursor": gin.H{"type": "string"}, "limit": gin.H{"type": "integer", "minimum": 1, "maximum": 200}}
var footprintTools = []gin.H{
	footprintTool("get_footprint_day", "Read confirmed visit summaries for a calendar day in an IANA time zone. Report unknown or partial coverage explicitly.", footprintDaySchema, "date", "time_zone"),
	footprintTool("list_visits", "Estimated arrival and departure observations in the authorized travel history.", historySchema, "from", "to"),
	footprintTool("list_track_points", "Recorded samples with segment identifiers and accuracy. Missing samples remain gaps.", historySchema, "from", "to"),
	footprintTool("list_favorite_photos", "Favorite photo timestamps and available capture locations.", historySchema, "from", "to"),
	footprintTool("get_photo_preview", "Read one authorized favorite photo thumbnail.", gin.H{"id": gin.H{"type": "string"}}, "id"),
	footprintTool("list_footprint_changes", "Read new or changed authorized records, including removed favorites. Save next_cursor and pass it on the next call. Omit cursor to start at the current position, or pass 0 to read the current history. wait_seconds can wait for the next upload.", gin.H{
		"cursor": gin.H{"type": "string"}, "limit": gin.H{"type": "integer", "minimum": 1, "maximum": 200},
		"wait_seconds": gin.H{"type": "integer", "minimum": 0, "maximum": 10},
	}),
}

func (s *Server) footprintMCP(c *gin.Context) {
	token, ok := strings.CutPrefix(c.GetHeader("Authorization"), "Bearer ")
	oauthToken, summaryOnly := strings.CutPrefix(token, footprintAccessPrefix)
	if !ok || !footprintFlowIDPattern.MatchString(oauthToken) || summaryOnly && !s.footprintOAuthReady() {
		s.footprintOAuthChallenge(c)
		return
	}
	db := s.footprintDB(c)
	if db == nil {
		return
	}
	ctx := c.Request.Context()
	digest := sha256.Sum256([]byte(token))
	var owner string
	var raw, previews bool
	var err error
	if summaryOnly {
		err = db.QueryRowContext(ctx, `SELECT user_id::text FROM harness.footprint_oauth_sessions
			WHERE access_digest=$1 AND resource=$2 AND access_expires_at>$3 AND revoked_at IS NULL`,
			digest[:], s.footprintResource(), s.now()).Scan(&owner)
	} else {
		err = db.QueryRowContext(ctx, `SELECT user_id::text,raw_tracks,photo_previews FROM harness.footprint_grants
			WHERE digest=$1 AND (expires_at IS NULL OR expires_at>$2)`, digest[:], s.now()).Scan(&owner, &raw, &previews)
	}
	if errors.Is(err, sql.ErrNoRows) {
		s.footprintOAuthChallenge(c)
		return
	}
	if err != nil {
		failJSON(c, 503, "footprints unavailable")
		return
	}
	if c.Request.Method != http.MethodPost {
		s.handleMCPMethodNotAllowed(c)
		return
	}
	var req struct {
		JSONRPC string          `json:"jsonrpc"`
		ID      json.RawMessage `json:"id"`
		Method  string          `json:"method"`
		Params  json.RawMessage `json:"params"`
	}
	if decodeStrict(c, &req, 32<<10) != nil || req.JSONRPC != "2.0" {
		failJSON(c, 400, "invalid JSON-RPC request")
		return
	}
	if len(req.ID) == 0 {
		c.Status(202)
		return
	}
	var result any
	switch req.Method {
	case "initialize":
		result = gin.H{"protocolVersion": mcpProtocolVersion, "serverInfo": gin.H{"name": "roamorrow-footprints", "version": "1.0.0"}, "capabilities": gin.H{"tools": gin.H{}}}
	case "ping":
		result = gin.H{}
	case "tools/list":
		tools := make([]gin.H, 0, len(footprintTools))
		for _, tool := range footprintTools {
			if summaryOnly && tool["name"] != "get_footprint_day" ||
				tool["name"] == "list_track_points" && !raw || tool["name"] == "get_photo_preview" && !previews {
				continue
			}
			tools = append(tools, tool)
		}
		result = gin.H{"tools": tools}
	case "tools/call":
		var input struct {
			Name string          `json:"name"`
			Args json.RawMessage `json:"arguments"`
		}
		if json.Unmarshal(req.Params, &input) != nil {
			failJSON(c, 400, "invalid tool call")
			return
		}
		var value any
		var image []byte
		var err error
		if summaryOnly && input.Name != "get_footprint_day" {
			err = errors.New("tool is outside the authorized footprint summary scope")
		} else if input.Name == "list_footprint_changes" {
			value, err = s.readFootprintChanges(c, db, owner, digest, raw, input.Args)
		} else {
			value, image, err = s.readFootprints(c, db, owner, raw, previews, input.Name, input.Args)
		}
		if err != nil {
			result = gin.H{"isError": true, "content": []gin.H{{"type": "text", "text": err.Error()}}}
		} else {
			data, _ := json.Marshal(value)
			content := []gin.H{{"type": "text", "text": string(data)}}
			if len(image) > 0 {
				content = append(content, gin.H{"type": "image", "mimeType": "image/jpeg", "data": base64.StdEncoding.EncodeToString(image)})
			}
			result = gin.H{"structuredContent": value, "content": content}
		}
	default:
		s.mcpWrite(c, rpcResponse{JSONRPC: "2.0", ID: req.ID, Error: &rpcErrorBody{Code: rpcMethodNotFound, Message: "method not found"}})
		return
	}
	s.mcpWrite(c, rpcResponse{JSONRPC: "2.0", ID: req.ID, Result: result})
}

func (s *Server) readFootprintChanges(c *gin.Context, db *sql.DB, owner string, digest [32]byte, raw bool, args json.RawMessage) (any, error) {
	var input struct {
		Cursor      string `json:"cursor"`
		Limit       int    `json:"limit"`
		WaitSeconds int    `json:"wait_seconds"`
	}
	if len(args) > 0 && json.Unmarshal(args, &input) != nil || input.Limit < 0 || input.Limit > 200 || input.WaitSeconds < 0 || input.WaitSeconds > 10 {
		return nil, errors.New("invalid change query")
	}
	if input.Limit == 0 {
		input.Limit = 100
	}
	ctx := c.Request.Context()
	var cursor int64
	if input.Cursor == "" {
		if err := db.QueryRowContext(ctx, `SELECT COALESCE(max(change_id),0) FROM harness.footprints
			WHERE user_id=$1 AND ($2 OR kind<>'point')`, owner, raw).Scan(&cursor); err != nil {
			return nil, errors.New("changes unavailable")
		}
	} else {
		var err error
		cursor, err = strconv.ParseInt(input.Cursor, 10, 64)
		if err != nil || cursor < 0 {
			return nil, errors.New("invalid cursor")
		}
	}
	deadline := time.NewTimer(time.Duration(input.WaitSeconds) * time.Second)
	defer deadline.Stop()
	tick := time.NewTicker(time.Second)
	defer tick.Stop()
	for {
		items, next, more, err := footprintChangePage(c, db, owner, digest, raw, cursor, input.Limit, s.now())
		if err != nil {
			return nil, err
		}
		result := gin.H{"records": items, "next_cursor": strconv.FormatInt(next, 10), "has_more": more}
		if len(items) > 0 || input.WaitSeconds == 0 {
			return result, nil
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-deadline.C:
			return result, nil
		case <-tick.C:
		}
	}
}

func footprintChangePage(c *gin.Context, db *sql.DB, owner string, digest [32]byte, raw bool, cursor int64, limit int, now time.Time) ([]json.RawMessage, int64, bool, error) {
	rows, err := db.QueryContext(c.Request.Context(), `SELECT f.change_id, (f.payload - 'preview') ||
		jsonb_build_object('received_at', f.received_at) FROM harness.footprints f
		JOIN harness.footprint_grants g ON g.user_id=f.user_id AND g.digest=$2 AND (g.expires_at IS NULL OR g.expires_at>$3)
		WHERE f.user_id=$1 AND ($4 AND g.raw_tracks OR f.kind<>'point') AND f.change_id>$5
		ORDER BY f.change_id LIMIT $6`, owner, digest[:], now, raw, cursor, limit+1)
	if err != nil {
		return nil, cursor, false, errors.New("changes unavailable")
	}
	defer rows.Close()
	items := []json.RawMessage{}
	next := cursor
	for rows.Next() {
		if len(items) == limit {
			return items, next, true, nil
		}
		var data []byte
		if err := rows.Scan(&next, &data); err != nil {
			return nil, cursor, false, errors.New("changes unavailable")
		}
		items = append(items, data)
	}
	if rows.Err() != nil {
		return nil, cursor, false, errors.New("changes unavailable")
	}
	return items, next, false, nil
}

func (s *Server) readFootprints(c *gin.Context, db *sql.DB, owner string, raw, previews bool, name string, args json.RawMessage) (any, []byte, error) {
	ctx := c.Request.Context()
	if name == "get_footprint_day" {
		value, err := s.readFootprintDay(ctx, db, owner, args)
		return value, nil, err
	}
	if name == "get_photo_preview" {
		var input struct {
			ID string `json:"id"`
		}
		if !previews {
			return nil, nil, errors.New("photo previews require authorization")
		}
		if json.Unmarshal(args, &input) != nil || !footprintUUID.MatchString(input.ID) {
			return nil, nil, errors.New("invalid photo ID")
		}
		var data []byte
		var item footprint
		if db.QueryRowContext(ctx, `SELECT payload FROM harness.footprints WHERE user_id=$1 AND id=$2 AND kind='photo'
			AND NOT (payload ? 'deleted')`, owner, input.ID).Scan(&data) != nil || json.Unmarshal(data, &item) != nil {
			return nil, nil, errors.New("photo unavailable")
		}
		image := item.Preview
		item.Preview = nil
		return item, image, nil
	}
	kinds := map[string]string{"list_visits": "visit", "list_track_points": "point", "list_favorite_photos": "photo"}
	kind := kinds[name]
	if kind == "" || kind == "point" && !raw {
		return nil, nil, errors.New("tool unavailable for this authorization")
	}
	var input struct {
		From   time.Time `json:"from"`
		To     time.Time `json:"to"`
		Cursor string    `json:"cursor"`
		Limit  int       `json:"limit"`
	}
	if json.Unmarshal(args, &input) != nil || input.From.IsZero() || !input.To.After(input.From) || input.To.Sub(input.From) > 31*24*time.Hour ||
		input.Limit < 0 || input.Limit > 200 {
		return nil, nil, errors.New("choose a date range up to 31 days and a limit up to 200")
	}
	if input.Limit == 0 {
		input.Limit = 100
	}
	cursorAt := input.From
	cursorID := "00000000-0000-0000-0000-000000000000"
	if input.Cursor != "" {
		a, id, ok := strings.Cut(input.Cursor, "/")
		t, err := time.Parse(time.RFC3339Nano, a)
		if !ok || err != nil || !footprintUUID.MatchString(id) || t.Before(input.From) || !t.Before(input.To) {
			return nil, nil, errors.New("invalid cursor")
		}
		cursorAt, cursorID = t, id
	}
	rows, err := db.QueryContext(ctx, `SELECT payload - 'preview' FROM harness.footprints
		WHERE user_id=$1 AND kind=$2 AND captured_at >= $3 AND captured_at < $4
		AND (captured_at,id)>($5,$6::uuid) AND NOT (payload ? 'deleted')
		ORDER BY captured_at,id LIMIT $7`, owner, kind, input.From, input.To, cursorAt, cursorID, input.Limit+1)
	if err != nil {
		return nil, nil, errors.New("history unavailable")
	}
	defer rows.Close()
	items := []footprint{}
	for rows.Next() {
		var data []byte
		var item footprint
		if rows.Scan(&data) != nil || json.Unmarshal(data, &item) != nil {
			return nil, nil, errors.New("history unavailable")
		}
		items = append(items, item)
	}
	if rows.Err() != nil {
		return nil, nil, errors.New("history unavailable")
	}
	var cursor string
	if len(items) > input.Limit {
		items = items[:input.Limit]
		end := items[len(items)-1]
		cursor = time.UnixMilli(end.At).UTC().Format(time.RFC3339Nano) + "/" + end.ID
	}
	var recordedThrough, receivedAt sql.NullTime
	if err := db.QueryRowContext(ctx, `SELECT max(captured_at), max(received_at) FROM harness.footprints WHERE user_id=$1 AND kind=$2
		AND NOT (payload ? 'deleted')`, owner, kind).Scan(&recordedThrough, &receivedAt); err != nil {
		return nil, nil, errors.New("history unavailable")
	}
	var observed, received any
	if recordedThrough.Valid {
		observed = recordedThrough.Time
	}
	if receivedAt.Valid {
		received = receivedAt.Time
	}
	return gin.H{"records": items, "next_cursor": cursor, "recorded_through": observed, "latest_received_at": received}, nil, nil
}
