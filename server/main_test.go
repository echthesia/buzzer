package main

import (
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
