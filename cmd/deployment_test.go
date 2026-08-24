package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"
)

func TestDeploymentModesAndMultiUserOperations(t *testing.T) {
	for _, mode := range []string{"browser-local", "single-user", "multi-user"} {
		if got, err := normalizeDeploymentMode(mode); err != nil || got != mode {
			t.Fatalf("normalizeDeploymentMode(%q) = %q, %v", mode, got, err)
		}
	}
	if _, err := normalizeDeploymentMode("unknown"); err == nil {
		t.Fatal("unknown deployment mode accepted")
	}

	s := &server{
		operations:     NewOperationsStore(filepath.Join(t.TempDir(), "operations.json")),
		deploymentMode: deploymentModeMultiUser,
		operatorTokens: map[string]string{"alice": "operator-secret"},
	}
	payload, err := json.Marshal(OperationRecord{Type: operationTypeCheck, AssetCode: "WATER-1", Status: "available", OccurredAt: time.Now().Add(-time.Minute)})
	if err != nil {
		t.Fatal(err)
	}
	unauthorized := httptest.NewRecorder()
	s.handleOperations(unauthorized, httptest.NewRequest(http.MethodPost, "/api/v1/operations", bytes.NewReader(payload)))
	if unauthorized.Code != http.StatusUnauthorized {
		t.Fatalf("unauthorized operation status = %d", unauthorized.Code)
	}

	request := httptest.NewRequest(http.MethodPost, "/api/v1/operations", bytes.NewReader(payload))
	request.Header.Set("Authorization", "Bearer operator-secret")
	created := httptest.NewRecorder()
	s.handleOperations(created, request)
	if created.Code != http.StatusCreated {
		t.Fatalf("operator create status = %d: %s", created.Code, created.Body.String())
	}
	var record OperationRecord
	if err := json.Unmarshal(created.Body.Bytes(), &record); err != nil {
		t.Fatal(err)
	}
	if record.Actor != "alice" {
		t.Fatalf("operation actor = %q, want alice", record.Actor)
	}
}
