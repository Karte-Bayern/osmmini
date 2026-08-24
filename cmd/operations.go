package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	operationTypePOD         = "pod"
	operationTypeMaintenance = "maintenance"
	operationTypeCheck       = "check"
)

// OperationRecord is a compact local audit entry. A POD identifies the
// delivered asset and recipient; a maintenance record identifies the serviced
// asset, work performed, and current state. Coordinates are optional because
// indoor maintenance must work without GPS.
type OperationRecord struct {
	ID         string    `json:"id"`
	Type       string    `json:"type"`
	Actor      string    `json:"actor,omitempty"`
	AssetCode  string    `json:"asset_code"`
	Status     string    `json:"status"`
	Recipient  string    `json:"recipient,omitempty"`
	Reference  string    `json:"reference,omitempty"`
	Technician string    `json:"technician,omitempty"`
	WorkType   string    `json:"work_type,omitempty"`
	Notes      string    `json:"notes,omitempty"`
	Latitude   *float64  `json:"latitude,omitempty"`
	Longitude  *float64  `json:"longitude,omitempty"`
	OccurredAt time.Time `json:"occurred_at"`
	CreatedAt  time.Time `json:"created_at"`
}

type OperationsStore struct {
	mu      sync.RWMutex
	path    string
	records []OperationRecord
}

func NewOperationsStore(path string) *OperationsStore { return &OperationsStore{path: path} }

func (s *OperationsStore) Load() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	data, err := os.ReadFile(s.path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if err := json.Unmarshal(data, &s.records); err != nil {
		return fmt.Errorf("decode operations log: %w", err)
	}
	return nil
}

func (s *OperationsStore) Create(input OperationRecord) (OperationRecord, error) {
	if err := validateOperation(&input); err != nil {
		return OperationRecord{}, err
	}
	id, err := operationID()
	if err != nil {
		return OperationRecord{}, err
	}
	input.ID = id
	if input.OccurredAt.IsZero() {
		input.OccurredAt = time.Now().UTC()
	} else {
		input.OccurredAt = input.OccurredAt.UTC()
	}
	input.CreatedAt = time.Now().UTC()

	s.mu.Lock()
	defer s.mu.Unlock()
	s.records = append(s.records, input)
	if err := s.saveLocked(); err != nil {
		s.records = s.records[:len(s.records)-1]
		return OperationRecord{}, err
	}
	return input, nil
}

func (s *OperationsStore) List(kind string, limit int) []OperationRecord {
	if limit <= 0 || limit > 500 {
		limit = 100
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	result := make([]OperationRecord, 0, min(limit, len(s.records)))
	for i := len(s.records) - 1; i >= 0 && len(result) < limit; i-- {
		record := s.records[i]
		if kind != "" && record.Type != kind {
			continue
		}
		result = append(result, record)
	}
	// Existing manually edited JSON files can be unordered. Keep the HTTP
	// contract newest-first without mutating the persisted audit history.
	sort.SliceStable(result, func(i, j int) bool { return result[i].CreatedAt.After(result[j].CreatedAt) })
	return result
}

func (s *OperationsStore) saveLocked() error {
	if err := os.MkdirAll(filepath.Dir(s.path), 0o755); err != nil && filepath.Dir(s.path) != "." {
		return err
	}
	data, err := json.MarshalIndent(s.records, "", "  ")
	if err != nil {
		return err
	}
	temporary := s.path + ".tmp"
	if err := os.WriteFile(temporary, data, 0o600); err != nil {
		return err
	}
	return os.Rename(temporary, s.path)
}

func validateOperation(record *OperationRecord) error {
	record.Type = strings.ToLower(strings.TrimSpace(record.Type))
	record.Actor = strings.TrimSpace(record.Actor)
	record.AssetCode = strings.TrimSpace(record.AssetCode)
	record.Status = strings.TrimSpace(record.Status)
	record.Recipient = strings.TrimSpace(record.Recipient)
	record.Reference = strings.TrimSpace(record.Reference)
	record.Technician = strings.TrimSpace(record.Technician)
	record.WorkType = strings.TrimSpace(record.WorkType)
	record.Notes = strings.TrimSpace(record.Notes)
	if record.Type != operationTypePOD && record.Type != operationTypeMaintenance && record.Type != operationTypeCheck {
		return errors.New("operation type must be pod, maintenance or check")
	}
	if record.AssetCode == "" || len(record.AssetCode) > 160 {
		return errors.New("asset_code is required and must be at most 160 characters")
	}
	if len(record.Actor) > 120 {
		return errors.New("actor must be at most 120 characters")
	}
	if record.Status == "" || len(record.Status) > 80 {
		return errors.New("status is required and must be at most 80 characters")
	}
	if record.Type == operationTypePOD && record.Recipient == "" {
		return errors.New("recipient is required for pod")
	}
	if record.Type == operationTypeMaintenance && record.WorkType == "" {
		return errors.New("work_type is required for maintenance")
	}
	for _, field := range []string{record.Recipient, record.Reference, record.Technician, record.WorkType} {
		if len(field) > 240 {
			return errors.New("operation field must be at most 240 characters")
		}
	}
	if len(record.Notes) > 4<<10 {
		return errors.New("notes must be at most 4096 characters")
	}
	if !record.OccurredAt.IsZero() && (record.OccurredAt.Before(time.Date(2000, 1, 1, 0, 0, 0, 0, time.UTC)) || record.OccurredAt.After(time.Now().Add(5*time.Minute))) {
		return errors.New("occurred_at is outside the accepted time range")
	}
	if (record.Latitude == nil) != (record.Longitude == nil) {
		return errors.New("latitude and longitude must be supplied together")
	}
	if record.Latitude != nil && (*record.Latitude < -90 || *record.Latitude > 90 || *record.Longitude < -180 || *record.Longitude > 180) {
		return errors.New("invalid coordinates")
	}
	return nil
}

func operationID() (string, error) {
	bytes := make([]byte, 8)
	if _, err := rand.Read(bytes); err != nil {
		return "", fmt.Errorf("generate operation id: %w", err)
	}
	return "op_" + time.Now().UTC().Format("20060102T150405.000000000Z") + "_" + hex.EncodeToString(bytes), nil
}
