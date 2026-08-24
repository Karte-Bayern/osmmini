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

func TestOperationsStorePersistsPODAndMaintenance(t *testing.T) {
	path := filepath.Join(t.TempDir(), "operations.json")
	store := NewOperationsStore(path)
	latitude, longitude := 48.5667, 13.4319
	pod, err := store.Create(OperationRecord{
		Type: operationTypePOD, AssetCode: "PKG-4711", Status: "delivered", Recipient: "Max Mustermann",
		Latitude: &latitude, Longitude: &longitude, OccurredAt: time.Now().Add(-time.Minute),
	})
	if err != nil {
		t.Fatalf("create pod: %v", err)
	}
	if pod.ID == "" || pod.CreatedAt.IsZero() || pod.OccurredAt.IsZero() {
		t.Fatalf("created pod = %#v", pod)
	}
	if _, err := store.Create(OperationRecord{Type: operationTypeMaintenance, AssetCode: "PUMP-4", Status: "completed", WorkType: "inspection"}); err != nil {
		t.Fatalf("create maintenance: %v", err)
	}
	if _, err := store.Create(OperationRecord{Type: operationTypeCheck, AssetCode: "SHELTER-NORTH", Status: "available", Reference: "Abschnitt Nord"}); err != nil {
		t.Fatalf("create check: %v", err)
	}

	reloaded := NewOperationsStore(path)
	if err := reloaded.Load(); err != nil {
		t.Fatalf("load operations: %v", err)
	}
	all := reloaded.List("", 10)
	if len(all) != 3 || all[0].Type != operationTypeCheck || all[2].AssetCode != "PKG-4711" {
		t.Fatalf("reloaded records = %#v", all)
	}
}

func TestOperationsHandlerValidatesAndCreates(t *testing.T) {
	s := &server{operations: NewOperationsStore(filepath.Join(t.TempDir(), "operations.json"))}
	payload, err := json.Marshal(OperationRecord{Type: operationTypePOD, AssetCode: "QR-42", Status: "delivered", Recipient: "Empfang", OccurredAt: time.Now().Add(-time.Minute)})
	if err != nil {
		t.Fatal(err)
	}
	created := httptest.NewRecorder()
	s.handleOperations(created, httptest.NewRequest(http.MethodPost, "/api/v1/operations", bytes.NewReader(payload)))
	if created.Code != http.StatusCreated {
		t.Fatalf("create status = %d: %s", created.Code, created.Body.String())
	}
	var record OperationRecord
	if err := json.Unmarshal(created.Body.Bytes(), &record); err != nil {
		t.Fatal(err)
	}
	if record.ID == "" || record.AssetCode != "QR-42" {
		t.Fatalf("created operation = %#v", record)
	}

	list := httptest.NewRecorder()
	s.handleOperations(list, httptest.NewRequest(http.MethodGet, "/api/v1/operations?type=pod", nil))
	if list.Code != http.StatusOK || !bytes.Contains(list.Body.Bytes(), []byte("QR-42")) {
		t.Fatalf("list status = %d: %s", list.Code, list.Body.String())
	}

	invalid := httptest.NewRecorder()
	s.handleOperations(invalid, httptest.NewRequest(http.MethodPost, "/api/v1/operations", bytes.NewBufferString(`{"type":"pod","asset_code":"QR-42","status":"delivered"}`)))
	if invalid.Code != http.StatusBadRequest {
		t.Fatalf("missing recipient status = %d: %s", invalid.Code, invalid.Body.String())
	}
}
