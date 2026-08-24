package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
)

const (
	deploymentModeBrowserLocal = "browser-local"
	deploymentModeSingleUser   = "single-user"
	deploymentModeMultiUser    = "multi-user"
)

func normalizeDeploymentMode(value string) (string, error) {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "", deploymentModeSingleUser:
		return deploymentModeSingleUser, nil
	case deploymentModeBrowserLocal, deploymentModeMultiUser:
		return strings.ToLower(strings.TrimSpace(value)), nil
	default:
		return "", fmt.Errorf("unknown deployment mode %q (choose browser-local, single-user or multi-user)", value)
	}
}

// loadOperatorTokens reads a deliberately small local credential map for a
// trusted multi-user server: {"alice":"secret-token", "bob":"…"}.
// Tokens are never returned by the HTTP API or embedded into the page.
func loadOperatorTokens(path string) (map[string]string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var tokens map[string]string
	if err := json.Unmarshal(data, &tokens); err != nil {
		return nil, fmt.Errorf("decode operators file: %w", err)
	}
	if len(tokens) == 0 {
		return nil, errors.New("operators file contains no tokens")
	}
	for name, token := range tokens {
		if strings.TrimSpace(name) == "" || len(name) > 120 || strings.TrimSpace(token) == "" || len(token) > 512 {
			return nil, errors.New("operators file contains an invalid name or token")
		}
	}
	return tokens, nil
}
