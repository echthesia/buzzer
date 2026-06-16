package main

import (
	"encoding/json"
	"os"
	"sync"
)

// TokenStore is a mutex-guarded, file-backed set of APNs device tokens.
// It's deliberately tiny: this relay only needs to remember which devices to
// push to, and a JSON file is plenty for a personal "buzz my phone" setup.
type TokenStore struct {
	path string
	mu   sync.Mutex
	set  map[string]struct{}
}

// NewTokenStore loads any previously persisted tokens from path. A missing
// file is not an error — it just means no devices have registered yet.
func NewTokenStore(path string) (*TokenStore, error) {
	s := &TokenStore{path: path, set: map[string]struct{}{}}
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return s, nil
		}
		return nil, err
	}
	var tokens []string
	if err := json.Unmarshal(data, &tokens); err != nil {
		return nil, err
	}
	for _, t := range tokens {
		s.set[t] = struct{}{}
	}
	return s, nil
}

// Add records a token (deduped) and persists the store. Returns true if the
// token was newly added.
func (s *TokenStore) Add(token string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.set[token]; ok {
		return false, nil
	}
	s.set[token] = struct{}{}
	return true, s.persistLocked()
}

// Remove deletes a token and persists. Used to prune tokens APNs reports as
// permanently gone (410 Unregistered) — see apns.go for why we only prune then.
func (s *TokenStore) Remove(token string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.set[token]; !ok {
		return nil
	}
	delete(s.set, token)
	return s.persistLocked()
}

// All returns a snapshot of the current tokens.
func (s *TokenStore) All() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]string, 0, len(s.set))
	for t := range s.set {
		out = append(out, t)
	}
	return out
}

// persistLocked writes the set to disk. Caller must hold s.mu.
func (s *TokenStore) persistLocked() error {
	tokens := make([]string, 0, len(s.set))
	for t := range s.set {
		tokens = append(tokens, t)
	}
	data, err := json.MarshalIndent(tokens, "", "  ")
	if err != nil {
		return err
	}
	// Write via a temp file + rename so a crash mid-write can't corrupt the store.
	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.path)
}
