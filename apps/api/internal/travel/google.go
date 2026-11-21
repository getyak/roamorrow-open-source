package travel

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"
)

type CalendarTokenProvider func(context.Context, string, bool) (string, error)

// GoogleCalendarProvider is a provider adapter, not an authorization source.
// Tokens come only from the existing verified-owner OAuth/scope/consent gate.
type GoogleCalendarProvider struct {
	baseURL string
	client  *http.Client
	token   CalendarTokenProvider
}

func NewGoogleCalendarProvider(tokens CalendarTokenProvider) *GoogleCalendarProvider {
	return &GoogleCalendarProvider{baseURL: "https://www.googleapis.com/calendar/v3", token: tokens, client: &http.Client{Timeout: 15 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}}
}

func (p *GoogleCalendarProvider) CheckAccess(ctx context.Context, owner string, write bool) error {
	if p.token == nil || owner == "" {
		return ErrPermissionRequired
	}
	token, err := p.token(ctx, owner, write)
	if err != nil {
		return err
	}
	if token == "" {
		return ErrPermissionRequired
	}
	return nil
}

type googleDate struct {
	DateTime string `json:"dateTime,omitempty"`
	Date     string `json:"date,omitempty"`
	Timezone string `json:"timeZone,omitempty"`
}
type googleReminder struct {
	Method  string `json:"method"`
	Minutes int    `json:"minutes"`
}
type googleEvent struct {
	ID                 string            `json:"id,omitempty"`
	ETag               string            `json:"etag,omitempty"`
	Status             string            `json:"status,omitempty"`
	Summary            string            `json:"summary"`
	Location           string            `json:"location"`
	Start              googleDate        `json:"start"`
	End                googleDate        `json:"end"`
	RecurringEventID   string            `json:"recurringEventId,omitempty"`
	Recurrence         []string          `json:"recurrence,omitempty"`
	Attendees          []json.RawMessage `json:"attendees,omitempty"`
	ExtendedProperties struct {
		Private map[string]string `json:"private,omitempty"`
	} `json:"extendedProperties"`
	Reminders struct {
		UseDefault bool             `json:"useDefault"`
		Overrides  []googleReminder `json:"overrides"`
	} `json:"reminders"`
}

func (p *GoogleCalendarProvider) request(ctx context.Context, owner, method, path string, value any, etag string) ([]byte, error) {
	write := method != http.MethodGet
	if p.token == nil {
		return nil, ErrPermissionRequired
	}
	token, err := p.token(ctx, owner, write)
	if err != nil {
		return nil, err
	}
	if token == "" {
		return nil, ErrPermissionRequired
	}
	var body []byte
	if value != nil {
		body, err = json.Marshal(value)
		if err != nil || len(body) > 128<<10 {
			return nil, ErrInvalidArguments
		}
	}
	req, err := http.NewRequestWithContext(ctx, method, p.baseURL+path, bytes.NewReader(body))
	if err != nil {
		return nil, ErrInvalidArguments
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Content-Type", "application/json")
	if etag != "" {
		req.Header.Set("If-Match", etag)
	}
	response, err := p.client.Do(req)
	if err != nil {
		if write {
			return nil, ProviderFailure{Code: "network_unknown", Uncertain: true}
		}
		return nil, ErrUnavailable
	}
	defer response.Body.Close()
	data, err := io.ReadAll(io.LimitReader(response.Body, (512<<10)+1))
	if err != nil || len(data) > 512<<10 {
		if write {
			return nil, ErrUncertain
		}
		return nil, ErrUnavailable
	}
	switch response.StatusCode {
	case 200, 201, 204:
		return data, nil
	case 401, 403:
		return nil, ErrPermissionRequired
	case 404, 410:
		return nil, ErrNotFound
	case 412:
		return nil, ErrVersionConflict
	case 409:
		if write {
			return nil, ErrUncertain
		}
		return nil, ErrVersionConflict
	case 400, 422, 429:
		return nil, ProviderFailure{Code: "provider_rejected"}
	default:
		if write {
			return nil, ProviderFailure{Code: "provider_unknown", Uncertain: true}
		}
		return nil, ErrUnavailable
	}
}

func googlePath(calendarRef, eventID string) string {
	path := "/calendars/" + url.PathEscape(calendarRef) + "/events"
	if eventID != "" {
		path += "/" + url.PathEscape(eventID)
	}
	return path
}

func fromGoogle(value googleEvent, fallbackZone string) (CalendarEvent, error) {
	// Deleted events only guarantee an ID; they may omit the active-event ETag.
	if value.ID != "" && value.Status == "cancelled" {
		return CalendarEvent{}, ErrNotFound
	}
	if value.ID == "" || value.ETag == "" {
		return CalendarEvent{}, ErrUnavailable
	}
	start, end := value.Start.DateTime, value.End.DateTime
	allDay := value.Start.Date != ""
	if allDay {
		start, end = value.Start.Date, value.End.Date
	}
	zone := value.Start.Timezone
	if zone == "" {
		zone = fallbackZone
	}
	reminders := []int{}
	for _, r := range value.Reminders.Overrides {
		if r.Method == "popup" {
			reminders = append(reminders, r.Minutes)
		}
	}
	return CalendarEvent{ID: value.ID, Title: value.Summary, Start: start, End: end, Timezone: zone, AllDay: allDay, Location: value.Location, Version: value.ETag, HasAttendees: len(value.Attendees) > 0, Recurring: value.RecurringEventID != "" || len(value.Recurrence) > 0, Private: value.ExtendedProperties.Private, ReminderMinutes: reminders, UseDefaultReminders: value.Reminders.UseDefault}, nil
}

func (p *GoogleCalendarProvider) List(ctx context.Context, owner, calendarRef string, rangeValue CalendarRange) (CalendarPage, error) {
	page := CalendarPage{Events: []CalendarEvent{}, QueriedRange: rangeValue, Coverage: Coverage{Kind: "unknown", Missing: []string{"provider"}}}
	if err := ValidateCalendarRange(rangeValue); err != nil {
		return page, err
	}
	if calendarRef == "" || len(calendarRef) > 256 {
		return page, ErrInvalidArguments
	}
	query := url.Values{"timeMin": {rangeValue.Start}, "timeMax": {rangeValue.End}, "timeZone": {rangeValue.Timezone}, "singleEvents": {"true"}, "orderBy": {"startTime"}, "maxResults": {"20"}, "fields": {"items(id,etag,start,end),nextPageToken,timeZone"}}
	data, err := p.request(ctx, owner, http.MethodGet, googlePath(calendarRef, "")+"?"+query.Encode(), nil, "")
	if err != nil {
		return page, err
	}
	var raw struct {
		Items         []googleEvent `json:"items"`
		NextPageToken string        `json:"nextPageToken"`
		Timezone      string        `json:"timeZone"`
	}
	if json.Unmarshal(data, &raw) != nil {
		return page, ErrUnavailable
	}
	page.Coverage = Coverage{Kind: "complete", Missing: []string{}}
	page.HasMore = raw.NextPageToken != "" || len(raw.Items) > 20
	if page.HasMore {
		page.Coverage = Coverage{Kind: "partial", Missing: []string{"additional_events"}}
	}
	if raw.Timezone == "" {
		raw.Timezone = rangeValue.Timezone
	}
	for index, value := range raw.Items {
		if index >= 20 {
			break
		}
		event, err := fromGoogle(value, raw.Timezone)
		if err != nil {
			page.Coverage = Coverage{Kind: "partial", Missing: []string{"unreadable_event"}}
			continue
		}
		// Busy-window retrieval never exports private titles, notes, locations,
		// attendee identities, or extended properties to a model.
		event.Title = ""
		event.Location = ""
		event.Private = nil
		event.ReminderMinutes = nil
		page.Events = append(page.Events, event)
	}
	return page, nil
}

func (p *GoogleCalendarProvider) Read(ctx context.Context, owner, calendarRef, eventID string) (CalendarEvent, error) {
	if calendarRef == "" || eventID == "" || len(calendarRef) > 256 || len(eventID) > 1024 {
		return CalendarEvent{}, ErrInvalidArguments
	}
	data, err := p.request(ctx, owner, http.MethodGet, googlePath(calendarRef, eventID), nil, "")
	if err != nil {
		return CalendarEvent{}, err
	}
	var event googleEvent
	if json.Unmarshal(data, &event) != nil {
		return CalendarEvent{}, ErrUnavailable
	}
	return fromGoogle(event, "")
}

func toGoogle(event CalendarEvent, create bool) (googleEvent, error) {
	if event.Title == "" || len([]rune(event.Title)) > 300 || event.AllDay || event.HasAttendees || event.Recurring {
		return googleEvent{}, ErrUnsupported
	}
	start, e1 := time.Parse(time.RFC3339, event.Start)
	end, e2 := time.Parse(time.RFC3339, event.End)
	if e1 != nil || e2 != nil || !end.After(start) || end.Sub(start) > 24*time.Hour {
		return googleEvent{}, ErrInvalidArguments
	}
	if _, err := time.LoadLocation(event.Timezone); err != nil || event.Timezone == "" || strings.EqualFold(event.Timezone, "Local") {
		return googleEvent{}, ErrInvalidArguments
	}
	value := googleEvent{Summary: event.Title, Location: event.Location, Start: googleDate{DateTime: event.Start, Timezone: event.Timezone}, End: googleDate{DateTime: event.End, Timezone: event.Timezone}}
	if create {
		if len(event.ID) < 5 || len(event.ID) > 1024 || !regexp.MustCompile(`^[0-9a-v]+$`).MatchString(event.ID) {
			return value, ErrInvalidArguments
		}
		value.ID = event.ID
	}
	value.ExtendedProperties.Private = event.Private
	value.Reminders.UseDefault = event.UseDefaultReminders
	value.Reminders.Overrides = []googleReminder{}
	for _, minutes := range event.ReminderMinutes {
		if minutes < 0 || minutes > 40320 || len(value.Reminders.Overrides) >= 5 {
			return value, ErrInvalidArguments
		}
		value.Reminders.Overrides = append(value.Reminders.Overrides, googleReminder{Method: "popup", Minutes: minutes})
	}
	return value, nil
}

func (p *GoogleCalendarProvider) Create(ctx context.Context, owner, calendarRef string, event CalendarEvent) (CalendarEvent, error) {
	value, err := toGoogle(event, true)
	if err != nil {
		return CalendarEvent{}, err
	}
	data, err := p.request(ctx, owner, http.MethodPost, googlePath(calendarRef, "")+"?sendUpdates=none", value, "")
	if err != nil {
		return CalendarEvent{}, err
	}
	var result googleEvent
	if json.Unmarshal(data, &result) != nil {
		return CalendarEvent{}, ErrUncertain
	}
	return fromGoogle(result, "")
}

func (p *GoogleCalendarProvider) Update(ctx context.Context, owner, calendarRef string, event CalendarEvent, version string) (CalendarEvent, error) {
	if version == "" || event.ID == "" {
		return CalendarEvent{}, ErrInvalidArguments
	}
	value, err := toGoogle(event, false)
	if err != nil {
		return CalendarEvent{}, err
	}
	data, err := p.request(ctx, owner, http.MethodPatch, googlePath(calendarRef, event.ID)+"?sendUpdates=none", value, version)
	if err != nil {
		return CalendarEvent{}, err
	}
	var result googleEvent
	if json.Unmarshal(data, &result) != nil {
		return CalendarEvent{}, ErrUncertain
	}
	return fromGoogle(result, "")
}

func (p *GoogleCalendarProvider) Delete(ctx context.Context, owner, calendarRef, eventID, version string) error {
	if version == "" || eventID == "" {
		return ErrInvalidArguments
	}
	_, err := p.request(ctx, owner, http.MethodDelete, googlePath(calendarRef, eventID)+"?sendUpdates=none", nil, version)
	return err
}
