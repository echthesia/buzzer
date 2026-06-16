package main

import (
	"fmt"

	"github.com/sideshow/apns2"
	"github.com/sideshow/apns2/payload"
	"github.com/sideshow/apns2/token"
)

// Pusher wraps an apns2 token-authenticated client plus the bits of config
// every push needs (the topic / bundle id).
type Pusher struct {
	client *apns2.Client
	topic  string
}

// NewPusher builds a JWT/token-based APNs client from a .p8 auth key.
//
// IMPORTANT: apns2 clients default to the PRODUCTION endpoint. Development
// (Xcode) builds produce *sandbox* device tokens, which only work against the
// sandbox endpoint. So sandbox is the default here and must be set actively —
// only an explicit "production" env opts into the production endpoint.
func NewPusher(cfg Config) (*Pusher, error) {
	authKey, err := token.AuthKeyFromFile(cfg.KeyPath)
	if err != nil {
		return nil, fmt.Errorf("loading APNs auth key from %s: %w", cfg.KeyPath, err)
	}
	tok := &token.Token{
		AuthKey: authKey,
		KeyID:   cfg.KeyID,
		TeamID:  cfg.TeamID,
	}
	client := apns2.NewTokenClient(tok)
	if cfg.Env == "production" {
		client.Production()
	} else {
		client.Development() // sandbox — the default for dev builds
	}
	return &Pusher{client: client, topic: cfg.Topic}, nil
}

// PushResult is the per-device outcome returned to the /notify caller.
type PushResult struct {
	Token  string `json:"token"`
	Status int    `json:"status"`
	Reason string `json:"reason,omitempty"`
	ApnsID string `json:"apnsId,omitempty"`
	Pruned bool   `json:"pruned,omitempty"`
	Error  string `json:"error,omitempty"`
}

// Alert describes one notification to deliver. Empty fields are omitted from
// the payload.
type Alert struct {
	Title             string
	Subtitle          string
	Body              string
	Sound             string
	Badge             *int
	ThreadID          string         // groups related notifications
	InterruptionLevel string         // passive | active | time-sensitive | critical
	URL               string         // custom key the app opens on tap
	Custom            map[string]any // any extra custom keys (outside aps)
}

// interruptionLevel maps a request string to the apns2 constant, returning ""
// for empty/unknown values (so the field is simply omitted).
func interruptionLevel(s string) payload.EInterruptionLevel {
	switch s {
	case "passive":
		return payload.InterruptionLevelPassive
	case "active":
		return payload.InterruptionLevelActive
	case "time-sensitive":
		return payload.InterruptionLevelTimeSensitive
	case "critical":
		return payload.InterruptionLevelCritical
	default:
		return ""
	}
}

// Send delivers one alert notification to a single device token.
func (p *Pusher) Send(deviceToken string, a Alert) PushResult {
	pl := payload.NewPayload()
	if a.Title != "" {
		pl = pl.AlertTitle(a.Title)
	}
	if a.Subtitle != "" {
		pl = pl.AlertSubtitle(a.Subtitle)
	}
	if a.Body != "" {
		pl = pl.AlertBody(a.Body)
	}
	sound := a.Sound
	if sound == "" {
		sound = "default"
	}
	pl = pl.Sound(sound)
	if a.Badge != nil {
		pl = pl.Badge(*a.Badge)
	}
	if a.ThreadID != "" {
		pl = pl.ThreadID(a.ThreadID)
	}
	if lvl := interruptionLevel(a.InterruptionLevel); lvl != "" {
		pl = pl.InterruptionLevel(lvl)
	}
	// The app reads this custom key in its tap handler and opens the URL.
	if a.URL != "" {
		pl = pl.Custom("url", a.URL)
	}
	for k, v := range a.Custom {
		pl = pl.Custom(k, v)
	}

	n := &apns2.Notification{
		DeviceToken: deviceToken,
		Topic:       p.topic,
		Payload:     pl,
	}

	res, err := p.client.Push(n)
	if err != nil {
		return PushResult{Token: deviceToken, Error: err.Error()}
	}
	return PushResult{
		Token:  deviceToken,
		Status: res.StatusCode,
		Reason: res.Reason,
		ApnsID: res.ApnsID,
	}
}

// ShouldPrune reports whether a push result means the token is permanently dead
// and should be dropped from the store.
//
// We prune ONLY on Unregistered (HTTP 410) — the device genuinely uninstalled
// or the token rotated. We deliberately do NOT prune on BadDeviceToken: that
// almost always signals a sandbox/production environment mismatch, not a dead
// device, and pruning it would silently delete a freshly-registered token.
func ShouldPrune(r PushResult) bool {
	return r.Reason == apns2.ReasonUnregistered
}
