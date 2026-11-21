package harness

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"
	_ "time/tzdata" // The production Alpine image has no system zoneinfo.

	"github.com/gin-gonic/gin"
)

var footprintDaySchema = gin.H{
	"date":      gin.H{"type": "string", "format": "date", "description": "Calendar date, YYYY-MM-DD"},
	"time_zone": gin.H{"type": "string", "description": "IANA time zone such as Asia/Shanghai"},
	"cursor":    gin.H{"type": "string"},
	"limit":     gin.H{"type": "integer", "minimum": 1, "maximum": 100},
}

type footprintDayQuery struct {
	Date     string `json:"date"`
	TimeZone string `json:"time_zone"`
	Cursor   string `json:"cursor"`
	Limit    int    `json:"limit"`
}

type footprintDayVisit struct {
	Arrival     time.Time  `json:"arrival"`
	Departure   *time.Time `json:"departure,omitempty"`
	City        string     `json:"city,omitempty"`
	District    string     `json:"district,omitempty"`
	TimeQuality string     `json:"time_quality"`
}

func (q footprintDayQuery) interval() (time.Time, time.Time, error) {
	const format = "2006-01-02"
	invalid := errors.New("provide a valid calendar date and IANA time zone")
	if q.TimeZone == "" || q.TimeZone == "Local" || len(q.TimeZone) > 100 || len(q.Date) != len(format) {
		return time.Time{}, time.Time{}, invalid
	}
	location, err := time.LoadLocation(q.TimeZone)
	if err != nil {
		return time.Time{}, time.Time{}, invalid
	}
	civilDate, err := time.Parse(format, q.Date)
	if err != nil || civilDate.Year() < 1 || civilDate.Year() == 9999 {
		return time.Time{}, time.Time{}, invalid
	}
	start := footprintCivilBoundary(civilDate, location)
	if start.In(location).Format(format) != q.Date {
		return time.Time{}, time.Time{}, invalid
	}
	end := footprintCivilBoundary(civilDate.AddDate(0, 0, 1), location)
	return start, end, nil
}

// civilDate encodes the wall date with a UTC location. Check the constant-offset
// segments near its midnight to handle jumps at midnight and repeated midnights.
func footprintCivilBoundary(civilDate time.Time, location *time.Location) time.Time {
	for current := civilDate.Add(-48 * time.Hour); ; {
		local := current.In(location)
		_, offset := local.Zone()
		_, nextZone := local.ZoneBounds()
		candidate := civilDate.Add(-time.Duration(offset) * time.Second)
		if current.After(candidate) {
			candidate = current
		}
		if nextZone.IsZero() || candidate.Before(nextZone) {
			return candidate.UTC()
		}
		current = nextZone
	}
}

func (s *Server) readFootprintDay(ctx context.Context, db *sql.DB, owner string, args json.RawMessage) (gin.H, error) {
	var input footprintDayQuery
	if json.Unmarshal(args, &input) != nil || input.Limit < 0 || input.Limit > 100 {
		return nil, errors.New("invalid footprint day query")
	}
	start, end, err := input.interval()
	if err != nil {
		return nil, err
	}
	if input.Limit == 0 {
		input.Limit = 50
	}
	var cursorAt *time.Time
	cursorID := "00000000-0000-0000-0000-000000000000"
	if input.Cursor != "" {
		rawTime, id, ok := strings.Cut(input.Cursor, "/")
		at, err := time.Parse(time.RFC3339Nano, rawTime)
		if !ok || err != nil || !footprintUUID.MatchString(id) || !at.Before(end) {
			return nil, errors.New("invalid footprint day cursor")
		}
		cursorAt, cursorID = &at, id
	}
	rows, err := db.QueryContext(ctx, `SELECT id::text, captured_at, (payload->>'end')::bigint,
		COALESCE(payload->>'city', ''), COALESCE(payload->>'district', ''),
		max(received_at) OVER ()
		FROM harness.footprints
		WHERE user_id=$1 AND kind='visit' AND captured_at<$3 AND NOT (payload ? 'deleted')
		AND (captured_at >= $2 OR (payload->>'end')::bigint > $4)
		AND ($5::timestamptz IS NULL OR (captured_at,id)>($5,$6::uuid))
		ORDER BY captured_at,id LIMIT $7`,
		owner, start, end, start.UnixMilli(), cursorAt, cursorID, input.Limit+1)
	if err != nil {
		return nil, errors.New("footprint day unavailable")
	}
	defer rows.Close()
	items := make([]footprintDayVisit, 0, input.Limit)
	var lastArrival time.Time
	var lastID string
	var latestReceived *time.Time
	var nextCursor *string
	for rows.Next() {
		if len(items) == input.Limit {
			cursor := lastArrival.Format(time.RFC3339Nano) + "/" + lastID
			nextCursor = &cursor
			break
		}
		var id string
		var item footprintDayVisit
		var departure sql.NullInt64
		var received time.Time
		if rows.Scan(&id, &item.Arrival, &departure, &item.City, &item.District, &received) != nil {
			return nil, errors.New("footprint day unavailable")
		}
		item.Arrival = item.Arrival.UTC()
		item.TimeQuality = "estimated"
		if departure.Valid {
			end := time.UnixMilli(departure.Int64).UTC()
			item.Departure = &end
		}
		lastID, lastArrival = id, item.Arrival
		receivedUTC := received.UTC()
		latestReceived = &receivedUTC
		items = append(items, item)
	}
	if rows.Err() != nil {
		return nil, errors.New("footprint day unavailable")
	}
	coverage := "unknown"
	if len(items) > 0 {
		coverage = "partial"
	}
	// A server receipt proves arrival of an individual record. It cannot prove
	// that the phone recorded or uploaded an entire day.
	return gin.H{"date": input.Date, "time_zone": input.TimeZone, "visits": items,
		"coverage": coverage, "latest_received_at": latestReceived, "next_cursor": nextCursor}, nil
}

func (s *Server) restoreFootprints(c *gin.Context) {
	var cursor int64
	if raw := c.Query("cursor"); raw != "" {
		value, err := strconv.ParseInt(raw, 10, 64)
		if err != nil || value < 0 {
			failJSON(c, http.StatusBadRequest, "invalid history cursor")
			return
		}
		cursor = value
	}
	limit := 50
	if raw := c.Query("limit"); raw != "" {
		value, err := strconv.Atoi(raw)
		if err != nil || value < 1 || value > 100 {
			failJSON(c, http.StatusBadRequest, "invalid history page size")
			return
		}
		limit = value
	}
	db := s.footprintDB(c)
	if db == nil {
		return
	}
	owner, _ := IdentityFrom(c)
	rows, err := db.QueryContext(c.Request.Context(), `SELECT change_id, payload FROM harness.footprints
		WHERE user_id=$1 AND change_id>$2 ORDER BY change_id LIMIT $3`, owner.ID, cursor, limit+1)
	if err != nil {
		failJSON(c, http.StatusServiceUnavailable, "history unavailable")
		return
	}
	defer rows.Close()
	records := make([]json.RawMessage, 0, limit)
	more := false
	for rows.Next() {
		if len(records) == limit {
			more = true
			break
		}
		var data []byte
		if rows.Scan(&cursor, &data) != nil {
			failJSON(c, http.StatusServiceUnavailable, "history unavailable")
			return
		}
		records = append(records, data)
	}
	if rows.Err() != nil {
		failJSON(c, http.StatusServiceUnavailable, "history unavailable")
		return
	}
	c.JSON(http.StatusOK, gin.H{"records": records, "next_cursor": strconv.FormatInt(cursor, 10), "has_more": more})
}
