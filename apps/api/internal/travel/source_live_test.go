package travel

import (
	"context"
	"os"
	"testing"
)

// Opt-in real-source evidence, deliberately separate from deterministic fixtures.
func TestRealSourceA01OfficialTravelArticle(t *testing.T) {
	if os.Getenv("TRAVEL_REAL_SOURCE_EVAL") != "1" {
		t.Skip("real source opt-in is not enabled")
	}
	result := NewSourceReader().Read(context.Background(), SourceRequest{URL: "https://www.japan.travel/en/destinations/kansai/kyoto/"})
	if result.Status == "blocked" || result.Status == "unavailable" || len(result.Data.Blocks) == 0 {
		t.Skipf("official source access unverified: %s/%s", result.Status, result.Coverage.Kind)
	}
	if result.Data.ContentHash == "" || result.Data.Blocks[0].ExcerptHash == "" {
		t.Fatal("live body lacks provenance")
	}
	t.Logf("live official article: %s, blocks=%d", result.Coverage.Kind, len(result.Data.Blocks))
}
func TestRealSourceA03MuseAccessBoundary(t *testing.T) {
	raw := os.Getenv("TRAVEL_EVAL_MUSE_URL")
	if os.Getenv("TRAVEL_REAL_SOURCE_EVAL") != "1" || raw == "" {
		t.Skip("private source opt-in is not enabled")
	}
	result := NewSourceReader().Read(context.Background(), SourceRequest{URL: raw})
	if result.Status == "unavailable" {
		t.Skip("source network access unavailable")
	}
	if result.Status != "blocked" {
		t.Skipf("source no longer matches blocked-access scenario: %s/%s", result.Status, result.Coverage.Kind)
	}
	if len(result.Data.Blocks) != 0 || result.Coverage.Kind != "metadata_only" {
		t.Fatal("blocked source falsely supplied body")
	}
	t.Log("real shared source blocked; metadata retained without invented body")
}
