package main

import (
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestRequireAuth(t *testing.T) {
	ok := func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusOK) }
	cases := []struct {
		name       string
		token      string // server-side BUZZER_TOKEN ("" = open mode)
		authHeader string
		want       int
	}{
		{"open mode allows no header", "", "", http.StatusOK},
		{"token set, no header", "s3cr3t", "", http.StatusUnauthorized},
		{"token set, wrong token", "s3cr3t", "Bearer nope", http.StatusUnauthorized},
		// The relay only strips an optional "Bearer " prefix, so a bare token
		// (no scheme) is also accepted — lenient but still requires the exact secret.
		{"token set, bare value without Bearer", "s3cr3t", "s3cr3t", http.StatusOK},
		{"token set, correct token", "s3cr3t", "Bearer s3cr3t", http.StatusOK},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s := &server{cfg: Config{AuthToken: tc.token}}
			h := s.requireAuth(ok)
			req := httptest.NewRequest(http.MethodPost, "/register", nil)
			if tc.authHeader != "" {
				req.Header.Set("Authorization", tc.authHeader)
			}
			rr := httptest.NewRecorder()
			h(rr, req)
			if rr.Code != tc.want {
				t.Fatalf("status = %d, want %d", rr.Code, tc.want)
			}
		})
	}
}

func TestIsHTTPURL(t *testing.T) {
	cases := []struct {
		in   string
		want bool
	}{
		{"https://example.com/icon.png", true},
		{"http://example.com/icon.png", true},
		{"https://host", true},
		{"", false},
		{"ftp://example.com/icon.png", false},
		{"file:///etc/passwd", false},
		{"/relative/icon.png", false},
		{"example.com/icon.png", false}, // no scheme
		{"https://", false},             // no host
	}
	for _, tc := range cases {
		if got := isHTTPURL(tc.in); got != tc.want {
			t.Errorf("isHTTPURL(%q) = %v, want %v", tc.in, got, tc.want)
		}
	}
}

// marshalPayload renders an Alert's APNs payload to a generic map for assertions.
func marshalPayload(t *testing.T, a Alert) map[string]any {
	t.Helper()
	raw, err := json.Marshal(buildPayload(a))
	if err != nil {
		t.Fatalf("marshal payload: %v", err)
	}
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatalf("unmarshal payload: %v", err)
	}
	return m
}

func TestBuildPayloadCommunicationKeys(t *testing.T) {
	// A plain alert carries no mutable-content flag and no icon/sender keys.
	t.Run("plain alert omits comms keys", func(t *testing.T) {
		m := marshalPayload(t, Alert{Title: "Buzz", Body: "hi"})
		aps := m["aps"].(map[string]any)
		if _, ok := aps["mutable-content"]; ok {
			t.Error("mutable-content set on a plain alert")
		}
		if _, ok := m["icon"]; ok {
			t.Error("icon key present on a plain alert")
		}
		if _, ok := m["sender"]; ok {
			t.Error("sender key present on a plain alert")
		}
	})

	// An icon (or sender) flips mutable-content on and surfaces the custom keys at
	// the top level, where the Notification Service Extension reads them.
	t.Run("icon+sender set comms keys", func(t *testing.T) {
		m := marshalPayload(t, Alert{
			Title:  "Build done",
			Body:   "CI passed",
			Icon:   "https://example.com/claude.png",
			Sender: "Claude · session abc",
		})
		aps := m["aps"].(map[string]any)
		if aps["mutable-content"] != float64(1) {
			t.Errorf("mutable-content = %v, want 1", aps["mutable-content"])
		}
		if m["icon"] != "https://example.com/claude.png" {
			t.Errorf("icon = %v, want the URL", m["icon"])
		}
		if m["sender"] != "Claude · session abc" {
			t.Errorf("sender = %v, want the display name", m["sender"])
		}
	})

	// Sender alone is enough to require the extension (avatar-less comms notif).
	t.Run("sender alone sets mutable-content", func(t *testing.T) {
		m := marshalPayload(t, Alert{Body: "hi", Sender: "cron"})
		aps := m["aps"].(map[string]any)
		if aps["mutable-content"] != float64(1) {
			t.Errorf("mutable-content = %v, want 1", aps["mutable-content"])
		}
	})
}

func TestRunHealthCheck(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusOK) })
	ts := httptest.NewServer(mux)
	defer ts.Close()

	addr := strings.TrimPrefix(ts.URL, "http://") // 127.0.0.1:port
	if got := runHealthCheck(addr); got != 0 {
		t.Fatalf("healthy server: runHealthCheck = %d, want 0", got)
	}
	// The container's default bind address is wildcard (":8080"); the probe must
	// rewrite an empty/wildcard host to loopback and still reach the server.
	_, port, err := net.SplitHostPort(addr)
	if err != nil {
		t.Fatalf("SplitHostPort(%q): %v", addr, err)
	}
	for _, a := range []string{":" + port, "0.0.0.0:" + port} {
		if got := runHealthCheck(a); got != 0 {
			t.Fatalf("wildcard addr %q: runHealthCheck = %d, want 0", a, got)
		}
	}
	// Nothing listening on this port -> probe should fail.
	if got := runHealthCheck("127.0.0.1:1"); got == 0 {
		t.Fatal("unreachable server: runHealthCheck = 0, want non-zero")
	}
}
