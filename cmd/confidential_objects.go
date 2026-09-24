package main

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

// ConfidentialObject is a point/line/polygon object created through the OSM
// editor's "vertraulich speichern" toggle. It is never part of an OSM
// draft, never enters osc()/the .osc export, and never leaves this server:
// see the guarantee documented next to save()'s confidential branch in
// cmd/web/osm-editor.js. Geometry follows plain GeoJSON coordinate
// conventions ([lon,lat] pairs, nested one level deeper per type) so the
// browser can render it with the exact same code path used for imported
// layers (imported_layers.go) without any server-side reprojection.
type ConfidentialObject struct {
	ID           string            `json:"id"`
	GeometryType string            `json:"geometry_type"` // "Point" | "LineString" | "Polygon"
	Coordinates  json.RawMessage   `json:"coordinates"`
	Tags         map[string]string `json:"tags"`
	CreatedAt    time.Time         `json:"created_at"`
	UpdatedAt    time.Time         `json:"updated_at"`
}

var confidentialGeometryTypes = map[string]bool{"Point": true, "LineString": true, "Polygon": true}

// ConfidentialObjectStore persists confidential objects to a local JSON
// file (gitignored — this is the user's own, often sensitive, local data,
// never meant for the repository), mirroring FireStationStore's exact
// persistence pattern (in-memory map + mutex, atomic temp-file rename).
type ConfidentialObjectStore struct {
	mu   sync.RWMutex
	path string
	v    map[string]ConfidentialObject
	seq  int
}

func NewConfidentialObjectStore(path string) *ConfidentialObjectStore {
	return &ConfidentialObjectStore{path: path, v: map[string]ConfidentialObject{}}
}

func (s *ConfidentialObjectStore) Load() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	b, err := os.ReadFile(s.path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	var v map[string]ConfidentialObject
	if err := json.Unmarshal(b, &v); err != nil {
		return err
	}
	s.v = v
	return nil
}

func (s *ConfidentialObjectStore) saveLocked() error {
	tmp := s.path + ".tmp"
	b, err := json.MarshalIndent(s.v, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.path)
}

func (s *ConfidentialObjectStore) list() []ConfidentialObject {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]ConfidentialObject, 0, len(s.v))
	for _, obj := range s.v {
		out = append(out, obj)
	}
	return out
}

func (s *ConfidentialObjectStore) get(id string) (ConfidentialObject, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	obj, ok := s.v[id]
	return obj, ok
}

func newConfidentialID() (string, error) {
	buf := make([]byte, 12)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return "co-" + hex.EncodeToString(buf), nil
}

func (s *ConfidentialObjectStore) create(geometryType string, coordinates json.RawMessage, tags map[string]string) (ConfidentialObject, error) {
	id, err := newConfidentialID()
	if err != nil {
		return ConfidentialObject{}, err
	}
	now := time.Now().UTC()
	obj := ConfidentialObject{ID: id, GeometryType: geometryType, Coordinates: coordinates, Tags: tags, CreatedAt: now, UpdatedAt: now}
	s.mu.Lock()
	s.v[id] = obj
	err = s.saveLocked()
	s.mu.Unlock()
	return obj, err
}

func (s *ConfidentialObjectStore) update(id string, geometryType string, coordinates json.RawMessage, tags map[string]string) (ConfidentialObject, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	existing, ok := s.v[id]
	if !ok {
		return ConfidentialObject{}, errNotFound
	}
	existing.GeometryType = geometryType
	existing.Coordinates = coordinates
	existing.Tags = tags
	existing.UpdatedAt = time.Now().UTC()
	s.v[id] = existing
	if err := s.saveLocked(); err != nil {
		return ConfidentialObject{}, err
	}
	return existing, nil
}

func (s *ConfidentialObjectStore) delete(id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.v[id]; !ok {
		return errNotFound
	}
	delete(s.v, id)
	return s.saveLocked()
}

var errNotFound = errors.New("not found")

// requireConfidentialAccess gates every /api/v1/confidential-objects*
// route, for reads as well as writes. Unlike requireSettingsAdmin (which
// stays open when no -admin-token is configured, matching this app's
// "works out of the box" default for non-sensitive settings), this fails
// CLOSED: confidential objects are meaningless without access control, so
// an operator who forgot to set -admin-token gets a clear 503 instead of
// an accidentally public store.
func (s *server) requireConfidentialAccess(w http.ResponseWriter, r *http.Request) bool {
	if s.adminToken == "" {
		writeJSONError(w, http.StatusServiceUnavailable, "vertrauliche Objekte erfordern einen gesetzten -admin-token")
		return false
	}
	expected := "Bearer " + s.adminToken
	provided := r.Header.Get("Authorization")
	if len(provided) != len(expected) || subtle.ConstantTimeCompare([]byte(provided), []byte(expected)) != 1 {
		w.Header().Set("WWW-Authenticate", `Bearer realm="osmmini confidential objects"`)
		writeJSONError(w, http.StatusUnauthorized, "ein gültiger Admin-Token ist erforderlich")
		return false
	}
	return true
}

type confidentialObjectRequest struct {
	GeometryType string            `json:"geometry_type"`
	Coordinates  json.RawMessage   `json:"coordinates"`
	Tags         map[string]string `json:"tags"`
}

func (req confidentialObjectRequest) validate() error {
	if !confidentialGeometryTypes[req.GeometryType] {
		return errors.New("geometry_type must be Point, LineString or Polygon")
	}
	if len(req.Coordinates) == 0 {
		return errors.New("coordinates is required")
	}
	if len(req.Tags) > 200 {
		return errors.New("at most 200 tags per object")
	}
	for k, v := range req.Tags {
		if strings.TrimSpace(k) == "" {
			return errors.New("a tag key must not be blank")
		}
		if len([]rune(k)) > 255 || len([]rune(v)) > 255 {
			return errors.New("tag keys and values are limited to 255 characters")
		}
	}
	return nil
}

// handleConfidentialObjects: GET lists every confidential object, POST
// creates one. Both require requireConfidentialAccess.
func (s *server) handleConfidentialObjects(w http.ResponseWriter, r *http.Request) {
	if !s.requireConfidentialAccess(w, r) {
		return
	}
	switch r.Method {
	case http.MethodGet:
		writeJSON(w, http.StatusOK, map[string]any{"objects": s.confidential.list()})
	case http.MethodPost:
		var req confidentialObjectRequest
		if err := readJSON(w, r, &req, 1<<20); err != nil {
			writeJSONError(w, http.StatusBadRequest, "invalid json: "+err.Error())
			return
		}
		if err := req.validate(); err != nil {
			writeJSONError(w, http.StatusBadRequest, err.Error())
			return
		}
		obj, err := s.confidential.create(req.GeometryType, req.Coordinates, req.Tags)
		if err != nil {
			writeJSONError(w, http.StatusInternalServerError, "save confidential object: "+err.Error())
			return
		}
		writeJSON(w, http.StatusCreated, obj)
	default:
		w.Header().Set("Allow", http.MethodGet+", "+http.MethodPost)
		writeJSONError(w, http.StatusMethodNotAllowed, "method not allowed")
	}
}

// handleConfidentialObjectByID: PUT updates, DELETE removes one object by
// ID. Both require requireConfidentialAccess.
func (s *server) handleConfidentialObjectByID(w http.ResponseWriter, r *http.Request) {
	if !s.requireConfidentialAccess(w, r) {
		return
	}
	id := strings.TrimPrefix(r.URL.Path, "/api/v1/confidential-objects/")
	if id == "" || strings.Contains(id, "/") {
		writeJSONError(w, http.StatusNotFound, "object not found")
		return
	}
	switch r.Method {
	case http.MethodPut:
		var req confidentialObjectRequest
		if err := readJSON(w, r, &req, 1<<20); err != nil {
			writeJSONError(w, http.StatusBadRequest, "invalid json: "+err.Error())
			return
		}
		if err := req.validate(); err != nil {
			writeJSONError(w, http.StatusBadRequest, err.Error())
			return
		}
		obj, err := s.confidential.update(id, req.GeometryType, req.Coordinates, req.Tags)
		if err != nil {
			if errors.Is(err, errNotFound) {
				writeJSONError(w, http.StatusNotFound, "object not found")
				return
			}
			writeJSONError(w, http.StatusInternalServerError, "update confidential object: "+err.Error())
			return
		}
		writeJSON(w, http.StatusOK, obj)
	case http.MethodDelete:
		if err := s.confidential.delete(id); err != nil {
			if errors.Is(err, errNotFound) {
				writeJSONError(w, http.StatusNotFound, "object not found")
				return
			}
			writeJSONError(w, http.StatusInternalServerError, "delete confidential object: "+err.Error())
			return
		}
		w.WriteHeader(http.StatusNoContent)
	default:
		w.Header().Set("Allow", http.MethodPut+", "+http.MethodDelete)
		writeJSONError(w, http.StatusMethodNotAllowed, "method not allowed")
	}
}
