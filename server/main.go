package main

import (
	"crypto/subtle"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

// Config holds the relay's runtime configuration, all sourced from env vars.
type Config struct {
	KeyPath    string // APNS_KEY_PATH  — path to the .p8 auth key
	KeyID      string // APNS_KEY_ID    — Key ID from the dev portal
	TeamID     string // APNS_TEAM_ID   — your Apple developer Team ID
	Topic      string // APNS_TOPIC     — bundle id (default com.melissaefoster.Buzzer)
	Env        string // APNS_ENV       — "production" or anything else (= sandbox)
	ListenAddr string // LISTEN_ADDR    — default :8080
	TokensFile string // TOKENS_FILE    — default tokens.json
	AuthToken  string // BUZZER_TOKEN   — bearer token required on /register + /notify (empty = open)
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func loadConfig() Config {
	return Config{
		KeyPath:    os.Getenv("APNS_KEY_PATH"),
		KeyID:      os.Getenv("APNS_KEY_ID"),
		TeamID:     os.Getenv("APNS_TEAM_ID"),
		Topic:      envOr("APNS_TOPIC", "com.melissaefoster.Buzzer"),
		Env:        os.Getenv("APNS_ENV"), // empty => sandbox (see NewPusher)
		ListenAddr: envOr("LISTEN_ADDR", ":8080"),
		TokensFile: envOr("TOKENS_FILE", "tokens.json"),
		AuthToken:  os.Getenv("BUZZER_TOKEN"),
	}
}

// server bundles the dependencies the HTTP handlers need.
type server struct {
	store  *TokenStore
	pusher *Pusher // may be nil if APNs config is incomplete (register/health still work)
	cfg    Config
}

func main() {
	healthcheck := flag.Bool("healthcheck", false,
		"probe the local /health endpoint and exit 0 (healthy) or non-zero — used as the container HEALTHCHECK")
	flag.Parse()

	cfg := loadConfig()

	// Container HEALTHCHECK path: the same binary self-probes /health, so the
	// runtime image needs no shell or curl (it ships as distroless/static). The
	// probe targets the configured LISTEN_ADDR, which the health process inherits
	// from the container's environment.
	if *healthcheck {
		os.Exit(runHealthCheck(cfg.ListenAddr))
	}

	store, err := NewTokenStore(cfg.TokensFile)
	if err != nil {
		log.Fatalf("loading token store: %v", err)
	}

	srv := &server{store: store, cfg: cfg}

	// The relay is useful for /register and /health even before APNs creds are
	// set, which keeps the dev loop unblocked. /notify reports a clear error if
	// the pusher isn't configured.
	if cfg.KeyPath != "" && cfg.KeyID != "" && cfg.TeamID != "" {
		p, err := NewPusher(cfg)
		if err != nil {
			log.Fatalf("configuring APNs pusher: %v", err)
		}
		srv.pusher = p
		log.Printf("APNs pusher ready (env=%s topic=%s)", envOr("APNS_ENV", "sandbox"), cfg.Topic)
	} else {
		log.Printf("APNs creds incomplete (need APNS_KEY_PATH, APNS_KEY_ID, APNS_TEAM_ID) — /notify disabled until set")
	}

	if cfg.AuthToken == "" {
		log.Printf("WARNING: BUZZER_TOKEN is unset — /register and /notify are UNAUTHENTICATED. " +
			"Fine for localhost; set BUZZER_TOKEN before exposing this anywhere.")
	} else {
		log.Printf("bearer-token auth enabled on /register and /notify")
	}

	mux := http.NewServeMux()
	// /health is intentionally open (handy for Traefik / uptime checks).
	mux.HandleFunc("GET /health", srv.handleHealth)
	mux.HandleFunc("POST /register", srv.requireAuth(srv.handleRegister))
	mux.HandleFunc("POST /notify", srv.requireAuth(srv.handleNotify))

	log.Printf("buzzer relay listening on %s", cfg.ListenAddr)
	if err := http.ListenAndServe(cfg.ListenAddr, mux); err != nil {
		log.Fatalf("server error: %v", err)
	}
}

// requireAuth wraps a handler with a bearer-token check. When BUZZER_TOKEN is
// unset the check is skipped (open mode, for local dev). The comparison is
// constant-time to avoid leaking the token via timing.
func (s *server) requireAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if s.cfg.AuthToken != "" {
			provided := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
			if subtle.ConstantTimeCompare([]byte(provided), []byte(s.cfg.AuthToken)) != 1 {
				writeJSON(w, http.StatusUnauthorized, map[string]any{"error": "missing or invalid bearer token"})
				return
			}
		}
		next(w, r)
	}
}

func (s *server) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":           true,
		"tokens":       len(s.store.All()),
		"pusherReady":  s.pusher != nil,
		"env":          envOr("APNS_ENV", "sandbox"),
		"topic":        s.cfg.Topic,
	})
}

type registerRequest struct {
	Token    string `json:"token"`
	Platform string `json:"platform"`
}

// handleRegister stores a device token sent by the app. This is the endpoint
// the Buzzer app POSTs to once APNs hands it a device token.
func (s *server) handleRegister(w http.ResponseWriter, r *http.Request) {
	var req registerRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Token == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "expected JSON body with non-empty 'token'"})
		return
	}
	added, err := s.store.Add(req.Token)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
		return
	}
	log.Printf("registered token (new=%v platform=%s): %s…", added, req.Platform, preview(req.Token))
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "new": added, "tokens": len(s.store.All())})
}

type notifyRequest struct {
	Title             string         `json:"title"`
	Subtitle          string         `json:"subtitle"`
	Body              string         `json:"body"`
	Sound             string         `json:"sound"`
	Badge             *int           `json:"badge"`
	ThreadID          string         `json:"threadId"`          // groups related notifications
	InterruptionLevel string         `json:"interruptionLevel"` // passive|active|time-sensitive|critical
	URL               string         `json:"url"`               // opened by the app when the notification is tapped
	Icon              string         `json:"icon"`              // http(s) URL of an avatar image the app shows as the sender
	Sender            string         `json:"sender"`            // display name shown as the sender (e.g. "Claude · session abc")
	Data              map[string]any `json:"data"`              // arbitrary extra custom keys
	Token             string         `json:"token"`             // optional: target one device; otherwise fan out to all
}

// handleNotify sends a notification. This is the webhook / process entry point:
// any caller POSTs {title, body} and every registered device gets buzzed.
func (s *server) handleNotify(w http.ResponseWriter, r *http.Request) {
	if s.pusher == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{
			"error": "APNs not configured: set APNS_KEY_PATH, APNS_KEY_ID, APNS_TEAM_ID",
		})
		return
	}
	var req notifyRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid JSON body"})
		return
	}
	if req.Title == "" && req.Body == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "provide at least one of 'title' or 'body'"})
		return
	}
	// An icon must be a fetchable http(s) URL: the Notification Service Extension
	// downloads it on the device to use as the sender avatar.
	if req.Icon != "" && !isHTTPURL(req.Icon) {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "'icon' must be an http(s) URL"})
		return
	}

	var targets []string
	if req.Token != "" {
		targets = []string{req.Token}
	} else {
		targets = s.store.All()
	}

	alert := Alert{
		Title:             req.Title,
		Subtitle:          req.Subtitle,
		Body:              req.Body,
		Sound:             req.Sound,
		Badge:             req.Badge,
		ThreadID:          req.ThreadID,
		InterruptionLevel: req.InterruptionLevel,
		URL:               req.URL,
		Icon:              req.Icon,
		Sender:            req.Sender,
		Custom:            req.Data,
	}

	results := make([]PushResult, 0, len(targets))
	for _, t := range targets {
		res := s.pusher.Send(t, alert)
		if ShouldPrune(res) {
			if err := s.store.Remove(t); err == nil {
				res.Pruned = true
			}
		}
		log.Printf("push -> %s… status=%d reason=%s", preview(t), res.Status, res.Reason)
		results = append(results, res)
	}

	writeJSON(w, http.StatusOK, map[string]any{"sent": len(results), "results": results})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// isHTTPURL reports whether s is an absolute http or https URL with a host —
// the shape the on-device extension can actually fetch an icon from.
func isHTTPURL(s string) bool {
	u, err := url.Parse(s)
	return err == nil && (u.Scheme == "http" || u.Scheme == "https") && u.Host != ""
}

// preview returns a short, log-safe prefix of a device token.
func preview(token string) string {
	if len(token) <= 8 {
		return token
	}
	return token[:8]
}

// runHealthCheck is the container HEALTHCHECK probe (see the -healthcheck flag):
// GET /health on the local listener, returning 0 when it answers 200 and 1
// otherwise. Kept dependency-free so the runtime image needs no shell or curl.
func runHealthCheck(addr string) int {
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "healthcheck: bad listen address %q: %v\n", addr, err)
		return 1
	}
	// A wildcard/empty bind host (":8080", "0.0.0.0:8080", "[::]:8080") isn't a
	// valid connect target — probe loopback instead.
	if host == "" || host == "0.0.0.0" || host == "::" {
		host = "127.0.0.1"
	}
	client := &http.Client{Timeout: 4 * time.Second}
	resp, err := client.Get("http://" + net.JoinHostPort(host, port) + "/health")
	if err != nil {
		fmt.Fprintf(os.Stderr, "healthcheck: %v\n", err)
		return 1
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		fmt.Fprintf(os.Stderr, "healthcheck: unexpected status %d\n", resp.StatusCode)
		return 1
	}
	return 0
}
