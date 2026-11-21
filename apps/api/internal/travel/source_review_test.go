package travel

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"
)

func TestSourceA02A06BlockedChildRemainsPartial(t *testing.T) {
	r := sourceFixture(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/blocked" {
			w.WriteHeader(403)
			return
		}
		if r.URL.Path == "/read" {
			fmt.Fprint(w, "<article><p>A public body with real source content.</p></article>")
			return
		}
		fmt.Fprint(w, `<body><iframe src="/read"></iframe><iframe src="/blocked"></iframe></body>`)
	})
	got := r.Read(context.Background(), SourceRequest{URL: "http://travel.example/share"})
	if got.Coverage.Kind != "partial" {
		t.Fatalf("blocked embedded body reported %s/%s", got.Status, got.Coverage.Kind)
	}
}
func TestSourceA06EnvelopeIsBounded(t *testing.T) {
	r := sourceFixture(t, func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, "<title>"+strings.Repeat("x", 600000)+"</title><article><p>Useful travel content.</p></article>")
	})
	got := r.Read(context.Background(), SourceRequest{URL: "http://travel.example/large"})
	raw, err := json.Marshal(got)
	if err != nil {
		t.Fatal(err)
	}
	if len(raw) > 64000 {
		t.Fatalf("bounded source result produced %d bytes from unbounded title", len(raw))
	}
}
func TestSourceA41MuseSecretPathIsRedacted(t *testing.T) {
	got := DisplayURL("https://muse.ai/s/weekend-dashboard/secret-token-value")
	if strings.Contains(got, "secret-token-value") {
		t.Fatal("signed share path leaked through DisplayURL")
	}
}

func TestSourceA06EnvelopeIncludesExcerptHashes(t *testing.T) {
	r := sourceFixture(t, func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, "<article>"+strings.Repeat("<p>A short travel detail.</p>", 500)+"</article>")
	})
	result := r.Read(context.Background(), SourceRequest{URL: "http://travel.example/many-blocks"})
	raw, _ := json.Marshal(result)
	if len(raw) > 64000 {
		t.Fatalf("final envelope including hashes is %d bytes", len(raw))
	}
}

func TestSourceA22ConstructionStopsAtFrameAndBlockBudgets(t *testing.T) {
	r := sourceFixture(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/child" {
			fmt.Fprint(w, "<article><p>Child body.</p></article>")
			return
		}
		fmt.Fprint(w, "<article>"+strings.Repeat("<p>Paragraph.</p>", 500)+strings.Repeat(`<iframe src="/child"></iframe>`, 500)+"</article>")
	})
	reads := 0
	got := r.read(context.Background(), "http://travel.example/root", "", 16000, 0, map[string]bool{}, &reads)
	if len(got.Data.Children) > 8 || len(got.Data.Blocks) > 1024 || got.Coverage.Kind != "partial" {
		t.Fatalf("construction escaped budget: children=%d blocks=%d coverage=%s", len(got.Data.Children), len(got.Data.Blocks), got.Coverage.Kind)
	}
}

func TestSourceA22EmbeddedReadsConsumeOneSharedBudget(t *testing.T) {
	r := sourceFixture(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			fmt.Fprint(w, "<article><p>Readable child.</p></article>")
			return
		}
		fmt.Fprint(w, `<iframe src="/a"></iframe><iframe src="/b"></iframe><iframe src="/c"></iframe>`)
	})
	result := r.Read(context.Background(), SourceRequest{URL: "http://travel.example/", MaxSourceReads: 2})
	if result.Usage == nil || result.Usage.SourceReads != 2 || result.Coverage.Kind != "partial" {
		t.Fatalf("embedded read usage lost budget: %+v", result.Usage)
	}
}
