// Package travel contains the bounded research and confirmed-action domain.
// It has no implicit identity, UI authority, or permission to contact a provider.
package travel

import "strings"

type Coverage struct {
	Kind    string   `json:"kind"`
	Missing []string `json:"missing"`
}

type Problem struct {
	Code       string `json:"code"`
	Message    string `json:"message"`
	Retryable  bool   `json:"retryable"`
	NextAction string `json:"nextAction"`
}

type SourceUsage struct {
	SourceReads int `json:"sourceReads"`
}

type Result[T any] struct {
	ContractVersion int          `json:"contractVersion"`
	Status          string       `json:"status"`
	Data            T            `json:"data"`
	Coverage        Coverage     `json:"coverage"`
	Warnings        []Problem    `json:"warnings"`
	Error           *Problem     `json:"error"`
	Usage           *SourceUsage `json:"usage,omitempty"`
	ObservedAt      string       `json:"observedAt"`
}

type SourceRequest struct {
	URL            string `json:"url"`
	MaxSourceReads int    `json:"maxSourceReads,omitempty"`
	MaxCharacters  int    `json:"maxCharacters,omitempty"`
}

type SourceBlock struct {
	ID          string `json:"blockId"`
	SourceID    string `json:"sourceRef"`
	Text        string `json:"text"`
	ExcerptHash string `json:"excerptHash"`
}

type SourceDocument struct {
	ID             string           `json:"id"`
	Title          string           `json:"title"`
	DisplayURL     string           `json:"displayURL"`
	ContentHash    string           `json:"contentHash"`
	ParentSourceID string           `json:"parentSourceId,omitempty"`
	AccessStatus   string           `json:"accessStatus"`
	Trust          string           `json:"trust"`
	Blocks         []SourceBlock    `json:"contentBlocks"`
	References     []string         `json:"outboundReferences"`
	Children       []SourceDocument `json:"children"`
}

func (d SourceDocument) Text() string {
	parts := make([]string, 0, len(d.Blocks))
	for _, b := range d.Blocks {
		parts = append(parts, b.Text)
	}
	return strings.Join(parts, "\n")
}
