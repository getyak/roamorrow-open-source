package travel

import (
	"context"
	"time"
)

type CalendarEvent struct {
	ID                  string            `json:"id"`
	Title               string            `json:"title"`
	Start               string            `json:"start"`
	End                 string            `json:"end"`
	Timezone            string            `json:"timezone"`
	Location            string            `json:"location"`
	Version             string            `json:"version"`
	HasAttendees        bool              `json:"hasAttendees"`
	AllDay              bool              `json:"allDay"`
	Recurring           bool              `json:"recurring"`
	Private             map[string]string `json:"private,omitempty"`
	ReminderMinutes     []int             `json:"reminderMinutes"`
	UseDefaultReminders bool              `json:"useDefaultReminders"`
}

type CalendarRange struct {
	Start    string `json:"start"`
	End      string `json:"end"`
	Timezone string `json:"timezone"`
}

type CalendarPage struct {
	Events       []CalendarEvent `json:"events"`
	Coverage     Coverage        `json:"coverage"`
	QueriedRange CalendarRange   `json:"queriedRange"`
	HasMore      bool            `json:"hasMore"`
}

type CalendarChange struct {
	StopID                  string `json:"stopId"`
	Action                  string `json:"action"`
	EventRef                string `json:"eventRef,omitempty"`
	ExpectedProviderVersion string `json:"expectedProviderVersion,omitempty"`
}

type CalendarItem struct {
	CreationGeneration uint64         `json:"creationGeneration,omitempty"`
	Change             CalendarChange `json:"change"`
	Before             *CalendarEvent `json:"before,omitempty"`
	After              *CalendarEvent `json:"after,omitempty"`
	State              string         `json:"state"`
	EventRef           string         `json:"eventRef,omitempty"`
	ProviderVersion    string         `json:"providerVersion,omitempty"`
	ErrorCode          string         `json:"errorCode,omitempty"`
	ReadbackStatus     string         `json:"readbackStatus"`
}

type CalendarPlan struct {
	StablePlanID  string         `json:"stablePlanId"`
	SourceKind    string         `json:"sourceKind"`
	SourceID      string         `json:"sourceId"`
	SourceVersion int64          `json:"sourceVersion"`
	CalendarRef   string         `json:"calendarRef"`
	Items         []CalendarItem `json:"items"`
}

type CalendarBinding struct {
	StablePlanID     string `json:"stablePlanId"`
	SourceKind       string `json:"sourceKind"`
	SourceID         string `json:"sourceId"`
	SourceVersion    int64  `json:"sourceVersion"`
	StopID           string `json:"stopId"`
	CalendarRef      string `json:"calendarRef"`
	ProviderEventRef string `json:"providerEventRef"`
	ProviderVersion  string `json:"providerVersion"`
	OperationID      string `json:"operationId"`
}

type CalendarProvider interface {
	CheckAccess(context.Context, string, bool) error
	List(context.Context, string, string, CalendarRange) (CalendarPage, error)
	Read(context.Context, string, string, string) (CalendarEvent, error)
	Create(context.Context, string, string, CalendarEvent) (CalendarEvent, error)
	Update(context.Context, string, string, CalendarEvent, string) (CalendarEvent, error)
	Delete(context.Context, string, string, string, string) error
}

type CalendarPreviewRequest struct {
	SourceKind      string           `json:"sourceKind"`
	SourceID        string           `json:"sourceId"`
	SourceVersion   int64            `json:"sourceVersion"`
	ContextRevision int64            `json:"contextRevision"`
	Plan            PlanInput        `json:"plan"`
	CalendarRef     string           `json:"calendarRef"`
	Changes         []CalendarChange `json:"changes"`
}

// The provider distinguishes a definite rejection from an outcome whose
// request may already have reached Google. Unknown writes must reconcile.
type ProviderFailure struct {
	Code      string
	Uncertain bool
}

func (e ProviderFailure) Error() string { return e.Code }

func calendarBindingKey(stablePlanID, stopID, calendarRef string) string {
	return hashText(stablePlanID + "\x00" + stopID + "\x00" + calendarRef)
}

func eventFromStop(stop PlanStop) (CalendarEvent, error) {
	if stop.Time.Kind != "fixed" || stop.DurationMinutes == nil {
		return CalendarEvent{}, ErrInvalidArguments
	}
	start, err := time.Parse(time.RFC3339, stop.Time.Instant)
	if err != nil {
		return CalendarEvent{}, ErrInvalidArguments
	}
	location := ""
	if stop.Place != nil {
		location = stop.Place.Name
	}
	return CalendarEvent{Title: stop.Title, Start: start.UTC().Format(time.RFC3339), End: start.Add(time.Duration(*stop.DurationMinutes) * time.Minute).UTC().Format(time.RFC3339), Timezone: stop.Time.Timezone, Location: location, Private: map[string]string{}}, nil
}
