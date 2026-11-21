package travel

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"strings"
	"time"
	"unicode/utf8"

	"golang.org/x/net/html"
)

var errUnsafeSource = errors.New("unsafe source")

// SourceReader uses its own credential-free transport. Every connection is
// pinned to the DNS addresses which passed validation, including redirects.
type SourceReader struct {
	lookupIP    func(context.Context, string) ([]net.IPAddr, error)
	dialContext func(context.Context, string, string) (net.Conn, error)
	slots       chan struct{}
}

func NewSourceReader() *SourceReader {
	dialer := &net.Dialer{Timeout: 8 * time.Second}
	return &SourceReader{lookupIP: net.DefaultResolver.LookupIPAddr, dialContext: dialer.DialContext, slots: make(chan struct{}, 3)}
}

func hashText(s string) string {
	v := sha256.Sum256([]byte(s))
	return hex.EncodeToString(v[:])
}

// DisplayURL must be used for logs, cards, exports, and calendar descriptions.
// Fetching the original user-supplied link never grants permission to forward
// authentication headers or browser cookies to that host.
func DisplayURL(raw string) string {
	if len(raw) > 4096 {
		return ""
	}
	u, err := url.Parse(raw)
	if err != nil {
		return ""
	}
	u.User, u.Fragment = nil, ""
	if strings.EqualFold(u.Hostname(), "muse.ai") && strings.HasPrefix(u.Path, "/s/") {
		u.Path, u.RawPath = "/s/", ""
	}
	if len(u.Path) > 1024 {
		u.Path, u.RawPath = "/", ""
	}
	q := u.Query()
	for key := range q {
		k := strings.ToLower(key)
		if strings.Contains(k, "token") || strings.Contains(k, "key") || strings.Contains(k, "secret") || strings.Contains(k, "signature") || k == "code" || k == "auth" || k == "password" || k == "state" {
			q.Del(key)
		}
	}
	u.RawQuery = q.Encode()
	return u.String()
}

func safeSourceURL(raw string) (*url.URL, error) {
	u, err := url.Parse(raw)
	if err != nil || len(raw) > 4096 || u.User != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Hostname() == "" {
		return nil, errUnsafeSource
	}
	if p := u.Port(); p != "" && !((u.Scheme == "http" && p == "80") || (u.Scheme == "https" && p == "443")) {
		return nil, errUnsafeSource
	}
	host := strings.ToLower(strings.TrimSuffix(u.Hostname(), "."))
	if host == "localhost" || strings.HasSuffix(host, ".localhost") || strings.HasSuffix(host, ".local") || strings.Contains(host, "%") {
		return nil, errUnsafeSource
	}
	if ip, err := netip.ParseAddr(host); err == nil && !publicSourceIP(ip) {
		return nil, errUnsafeSource
	}
	u.Fragment = ""
	return u, nil
}

func publicSourceIP(ip netip.Addr) bool {
	ip = ip.Unmap()
	if !ip.IsGlobalUnicast() || ip.IsPrivate() || ip.IsLoopback() || ip.IsLinkLocalUnicast() || ip.IsUnspecified() {
		return false
	}
	// CGNAT, benchmark and protocol-assignment ranges are not public origins.
	for _, raw := range []string{"100.64.0.0/10", "192.0.0.0/24", "198.18.0.0/15", "240.0.0.0/4", "64:ff9b::/96", "64:ff9b:1::/48", "2001::/32", "2002::/16"} {
		if netip.MustParsePrefix(raw).Contains(ip) {
			return false
		}
	}
	return true
}

func (r *SourceReader) pinnedDial(ctx context.Context, network, address string) (net.Conn, error) {
	host, port, err := net.SplitHostPort(address)
	if err != nil {
		return nil, errUnsafeSource
	}
	if port != "80" && port != "443" {
		return nil, errUnsafeSource
	}
	var addresses []net.IPAddr
	if ip := net.ParseIP(host); ip != nil {
		addresses = []net.IPAddr{{IP: ip}}
	} else {
		addresses, err = r.lookupIP(ctx, host)
	}
	if err != nil || len(addresses) == 0 || len(addresses) > 16 {
		return nil, errUnsafeSource
	}
	for _, a := range addresses {
		ip, ok := netip.AddrFromSlice(a.IP)
		if !ok || !publicSourceIP(ip) {
			return nil, errUnsafeSource
		}
	}
	// No second hostname resolution occurs after validation.
	return r.dialContext(ctx, network, net.JoinHostPort(addresses[0].IP.String(), port))
}

type sourceReadLimitKey struct{}

func (r *SourceReader) Read(ctx context.Context, req SourceRequest) Result[SourceDocument] {
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	limit := req.MaxCharacters
	if limit == 0 {
		limit = 16000
	}
	if limit < 1000 || limit > 24000 {
		return sourceFailure(req.URL, "invalid_arguments", "blocked", "none")
	}
	maxReads := req.MaxSourceReads
	if maxReads == 0 {
		maxReads = 8
	}
	if maxReads < 1 || maxReads > 8 {
		return sourceFailure(req.URL, "invalid_arguments", "blocked", "none")
	}
	ctx = context.WithValue(ctx, sourceReadLimitKey{}, maxReads)
	visited := map[string]bool{}
	reads := 0
	result := r.read(ctx, req.URL, "", limit, 0, visited, &reads)
	result.Usage = &SourceUsage{SourceReads: reads}
	boundSourceMetadata(&result.Data)
	if len(result.Data.Blocks) > 128 {
		result.Data.Blocks = result.Data.Blocks[:128]
		result.Status = "partial"
		result.Coverage = Coverage{Kind: "partial", Missing: []string{"truncated_blocks"}}
	}
	for i := range result.Data.Blocks {
		result.Data.Blocks[i].ExcerptHash = hashText(result.Data.Blocks[i].Text)
	}
	// Bound the entire JSON envelope, including UTF-8/JSON escaping and block metadata.
	for {
		raw, _ := json.Marshal(result)
		if len(raw) <= 64000 {
			break
		}
		result.Status = "partial"
		result.Coverage = Coverage{Kind: "partial", Missing: []string{"truncated_envelope"}}
		if n := len(result.Data.Blocks); n > 0 {
			last := &result.Data.Blocks[n-1]
			runes := []rune(last.Text)
			if len(runes) > 128 {
				last.Text = string(runes[:len(runes)/2])
			} else {
				result.Data.Blocks = result.Data.Blocks[:n-1]
			}
		} else if len(result.Data.Children) > 0 {
			result.Data.Children = result.Data.Children[:len(result.Data.Children)-1]
		} else {
			break
		}
	}
	for i := range result.Data.Blocks {
		result.Data.Blocks[i].ExcerptHash = hashText(result.Data.Blocks[i].Text)
	}
	return result
}

func sourceFailure(raw, code, status, action string) Result[SourceDocument] {
	return Result[SourceDocument]{ContractVersion: 1, Status: status,
		Data:     SourceDocument{ID: "src_" + hashText(raw)[:24], DisplayURL: DisplayURL(raw), AccessStatus: status, Trust: "untrusted_source", Blocks: []SourceBlock{}, References: []string{}, Children: []SourceDocument{}},
		Coverage: Coverage{Kind: "metadata_only", Missing: []string{"body"}}, Warnings: []Problem{},
		Error: &Problem{Code: code, Message: "Source content could not be fully read.", NextAction: action, Retryable: status == "unavailable"}, ObservedAt: time.Now().UTC().Format(time.RFC3339)}
}

func (r *SourceReader) read(ctx context.Context, raw, parent string, limit, depth int, visited map[string]bool, reads *int) Result[SourceDocument] {
	u, err := safeSourceURL(raw)
	if err != nil {
		return sourceFailure(raw, "source_blocked", "blocked", "provide_content")
	}
	maxReads, ok := ctx.Value(sourceReadLimitKey{}).(int)
	if !ok {
		maxReads = 8
	}
	if depth > 2 || *reads >= maxReads || visited[u.String()] {
		return sourceFailure(raw, "budget_exhausted", "partial", "provide_content")
	}
	visited[u.String()] = true
	*reads++
	select {
	case r.slots <- struct{}{}:
	case <-ctx.Done():
		return sourceFailure(raw, "provider_unavailable", "unavailable", "retry_read")
	}
	transport := &http.Transport{Proxy: nil, DialContext: r.pinnedDial, DisableKeepAlives: true, TLSHandshakeTimeout: 8 * time.Second, ResponseHeaderTimeout: 8 * time.Second, MaxResponseHeaderBytes: 64 << 10}
	client := &http.Client{Transport: transport, Timeout: 15 * time.Second, CheckRedirect: func(req *http.Request, via []*http.Request) error {
		if len(via) > 5 {
			return errUnsafeSource
		}
		_, err := safeSourceURL(req.URL.String())
		// Redirects never receive credential-bearing headers from a previous hop.
		req.Header.Del("Authorization")
		req.Header.Del("Cookie")
		req.Header.Del("Referer")
		return err
	}}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		<-r.slots
		return sourceFailure(raw, "invalid_arguments", "blocked", "provide_content")
	}
	req.Header.Set("User-Agent", "RoamorrowSourceReader/1.0")
	req.Header.Set("Accept", "text/html, application/xhtml+xml, text/plain")
	response, err := client.Do(req)
	var body []byte
	if err == nil {
		body, err = io.ReadAll(io.LimitReader(response.Body, (5<<20)+1))
		response.Body.Close()
	}
	transport.CloseIdleConnections()
	<-r.slots
	if err != nil {
		if errors.Is(err, errUnsafeSource) {
			return sourceFailure(raw, "source_blocked", "blocked", "provide_content")
		}
		return sourceFailure(raw, "provider_unavailable", "unavailable", "retry_read")
	}
	if response.StatusCode == 401 || response.StatusCode == 403 {
		return sourceFailure(raw, "source_blocked", "blocked", "provide_content")
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return sourceFailure(raw, "provider_unavailable", "unavailable", "retry_read")
	}
	contentType := response.Header.Get("Content-Type")
	if contentType != "" && !strings.Contains(contentType, "text/") && !strings.Contains(contentType, "application/xhtml+xml") {
		return sourceFailure(raw, "extraction_incomplete", "partial", "provide_content")
	}
	tooLarge := len(body) > 5<<20
	if tooLarge {
		body = body[:5<<20]
	}
	var truncatedHTML bool
	body, truncatedHTML = boundedHTML(body)
	tooLarge = tooLarge || truncatedHTML
	doc, err := html.Parse(strings.NewReader(string(body)))
	if err != nil {
		return sourceFailure(raw, "extraction_incomplete", "partial", "provide_content")
	}
	data := SourceDocument{ID: "src_" + hashText(u.String() + string(body))[:24], ContentHash: hashText(string(body)), DisplayURL: DisplayURL(raw), ParentSourceID: parent, AccessStatus: "read", Trust: "untrusted_source", Blocks: []SourceBlock{}, References: []string{}, Children: []SourceDocument{}}
	var main *html.Node
	var frames []string
	omittedFrames := false
	var scan func(*html.Node)
	scan = func(n *html.Node) {
		if n.Type == html.ElementNode {
			if n.Data == "title" {
				data.Title = strings.TrimSpace(nodeText(n))
			}
			if main == nil && (n.Data == "article" || n.Data == "main") {
				main = n
			}
			if n.Data == "iframe" {
				for _, a := range n.Attr {
					if a.Key == "src" && a.Val != "" {
						if ref, e := url.Parse(a.Val); e == nil {
							if len(frames) < 8 {
								frames = append(frames, response.Request.URL.ResolveReference(ref).String())
							} else {
								omittedFrames = true
							}
						}
					}
				}
			}
			if n.Data == "a" && len(data.References) < 30 {
				for _, a := range n.Attr {
					if a.Key == "href" {
						if ref, e := url.Parse(a.Val); e == nil {
							resolved := response.Request.URL.ResolveReference(ref)
							if resolved.Scheme == "https" || resolved.Scheme == "http" {
								data.References = append(data.References, DisplayURL(resolved.String()))
							}
						}
					}
				}
			}
		}
		for c := n.FirstChild; c != nil; c = c.NextSibling {
			scan(c)
		}
	}
	scan(doc)
	explicitBody := main != nil
	if main == nil {
		main = doc
	}
	text := nodeText(main)
	// An interactive shell with an iframe is metadata until its actual body is
	// available. This also handles a JS-inserted iframe with no src in the HTML.
	hasFrame := len(frames) > 0 || containsElement(doc, "iframe")
	metadataOnly := !explicitBody && (hasFrame || utf8.RuneCountInString(text) < 160)
	if !metadataOnly {
		for _, part := range strings.Split(text, "\n") {
			part = strings.TrimSpace(part)
			if part != "" {
				if len(data.Blocks) >= 128 {
					tooLarge = true
					break
				}
				data.Blocks = append(data.Blocks, SourceBlock{ID: "b_" + hashText(part)[:20], SourceID: data.ID, Text: part})
			}
		}
	}
	incompleteEmbed := omittedFrames
	for _, frame := range frames {
		child := r.read(ctx, frame, data.ID, limit, depth+1, visited, reads)
		if child.Coverage.Kind != "complete" {
			incompleteEmbed = true
		}
		if child.Coverage.Kind == "complete" || child.Coverage.Kind == "partial" && len(child.Data.Blocks) > 0 {
			data.Blocks = append(data.Blocks, child.Data.Blocks...)
			metadataOnly = false
			if child.Coverage.Kind == "partial" {
				tooLarge = true
			}
		}
		// Aggregated blocks retain sourceRef; children retain metadata, without
		// recursively duplicating the same body in the model envelope.
		child.Data.Blocks = []SourceBlock{}
		data.Children = append(data.Children, child.Data)
	}
	result := Result[SourceDocument]{ContractVersion: 1, Status: "ok", Data: data, Coverage: Coverage{Kind: "complete", Missing: []string{}}, Warnings: []Problem{}, ObservedAt: time.Now().UTC().Format(time.RFC3339)}
	if metadataOnly {
		result.Status, result.Coverage = "blocked", Coverage{Kind: "metadata_only", Missing: []string{"body"}}
		result.Data.AccessStatus = "blocked"
		result.Error = &Problem{Code: "source_blocked", Message: "Only the share-page metadata is available.", NextAction: "provide_content"}
	}
	remaining := limit
	for i := range result.Data.Blocks {
		runes := []rune(result.Data.Blocks[i].Text)
		if len(runes) > remaining {
			result.Data.Blocks[i].Text = string(runes[:remaining])
			result.Data.Blocks = result.Data.Blocks[:i+1]
			tooLarge = true
			break
		}
		remaining -= len(runes) + 1
		if remaining < 0 {
			remaining = 0
		}
	}
	if incompleteEmbed && !metadataOnly {
		result.Status, result.Coverage = "partial", Coverage{Kind: "partial", Missing: []string{"unread_embedded_content"}}
	}
	if tooLarge && !metadataOnly {
		result.Status, result.Coverage = "partial", Coverage{Kind: "partial", Missing: []string{"truncated_body"}}
	}
	return result
}

func containsElement(n *html.Node, tag string) bool {
	if n.Type == html.ElementNode && n.Data == tag {
		return true
	}
	for c := n.FirstChild; c != nil; c = c.NextSibling {
		if containsElement(c, tag) {
			return true
		}
	}
	return false
}

func nodeText(n *html.Node) string {
	var b strings.Builder
	var walk func(*html.Node)
	walk = func(n *html.Node) {
		if n.Type == html.ElementNode {
			switch n.Data {
			case "script", "style", "noscript", "header", "nav", "footer", "title":
				return
			}
		}
		if n.Type == html.TextNode {
			b.WriteString(n.Data)
			b.WriteByte(' ')
		}
		for c := n.FirstChild; c != nil; c = c.NextSibling {
			walk(c)
		}
		if n.Type == html.ElementNode {
			switch n.Data {
			case "p", "h1", "h2", "h3", "li", "div", "section", "br":
				b.WriteByte('\n')
			}
		}
	}
	// A title node is intentionally traversed only when requested directly.
	if n.Type == html.ElementNode && n.Data == "title" {
		for c := n.FirstChild; c != nil; c = c.NextSibling {
			walk(c)
		}
	} else {
		walk(n)
	}
	parts := strings.Split(b.String(), "\n")
	for i := range parts {
		parts[i] = strings.Join(strings.Fields(parts[i]), " ")
	}
	return strings.TrimSpace(strings.Join(parts, "\n"))
}

func boundSourceMetadata(d *SourceDocument) {
	d.Title = string([]rune(d.Title)[:min(512, utf8.RuneCountInString(d.Title))])
	if len(d.References) > 10 {
		d.References = d.References[:10]
	}
	for i, ref := range d.References {
		if len(ref) > 1024 {
			if u, err := url.Parse(ref); err == nil {
				d.References[i] = u.Scheme + "://" + u.Hostname()
			} else {
				d.References[i] = ""
			}
		}
	}
	if len(d.Children) > 8 {
		d.Children = d.Children[:8]
	}
	for i := range d.Children {
		boundSourceMetadata(&d.Children[i])
	}
}

// Bound DOM construction before parsing. A small public response may otherwise
// expand into hundreds of thousands of nodes and iframe failure documents.
func boundedHTML(body []byte) ([]byte, bool) {
	tokenizer := html.NewTokenizer(strings.NewReader(string(body)))
	consumed, depth := 0, 0
	for count := 0; ; count++ {
		kind := tokenizer.Next()
		if kind == html.ErrorToken {
			return body, false
		}
		consumed += len(tokenizer.Raw())
		if kind == html.StartTagToken {
			name, _ := tokenizer.TagName()
			switch string(name) {
			case "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr":
			default:
				depth++
			}
		} else if kind == html.EndTagToken && depth > 0 {
			depth--
		}
		if count >= 50000 || depth > 256 {
			return body[:min(consumed, len(body))], true
		}
	}
}
