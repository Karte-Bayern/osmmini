package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
)

func TestConfidentialObjectStoreCRUDAndPersistence(t *testing.T) {
	path := filepath.Join(t.TempDir(), "confidential-objects.json")
	store := NewConfidentialObjectStore(path)

	obj, err := store.create("Point", json.RawMessage(`[12.5,48.5]`), map[string]string{"note": "Zugangscode 1234"})
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if obj.ID == "" {
		t.Fatal("create did not assign an ID")
	}
	if got := store.list(); len(got) != 1 {
		t.Fatalf("list() = %d objects, want 1", len(got))
	}

	if _, err := store.update(obj.ID, "Point", json.RawMessage(`[12.6,48.6]`), map[string]string{"note": "verschoben"}); err != nil {
		t.Fatalf("update: %v", err)
	}
	updated, ok := store.get(obj.ID)
	if !ok || string(updated.Coordinates) != "[12.6,48.6]" {
		t.Fatalf("get after update = %+v", updated)
	}
	if !updated.UpdatedAt.After(updated.CreatedAt) && updated.UpdatedAt != updated.CreatedAt {
		t.Fatalf("UpdatedAt %v should not be before CreatedAt %v", updated.UpdatedAt, updated.CreatedAt)
	}

	// A fresh store loading the same file must see the same data --
	// confirms the atomic-write persistence actually lands on disk.
	// (Coordinates are compared semantically, not byte-for-byte: saveLocked
	// uses json.MarshalIndent, which reformats the embedded RawMessage's
	// whitespace on every round trip.)
	reloaded := NewConfidentialObjectStore(path)
	if err := reloaded.Load(); err != nil {
		t.Fatalf("Load: %v", err)
	}
	got, ok := reloaded.get(obj.ID)
	if !ok {
		t.Fatalf("reloaded object missing, ok=%v", ok)
	}
	var coords []float64
	if err := json.Unmarshal(got.Coordinates, &coords); err != nil {
		t.Fatalf("reloaded coordinates are not valid JSON: %v", err)
	}
	if len(coords) != 2 || coords[0] != 12.6 || coords[1] != 48.6 {
		t.Fatalf("reloaded coordinates = %v, want [12.6 48.6]", coords)
	}

	if err := store.delete(obj.ID); err != nil {
		t.Fatalf("delete: %v", err)
	}
	if _, ok := store.get(obj.ID); ok {
		t.Fatal("object still present after delete")
	}
	if err := store.delete(obj.ID); err == nil {
		t.Fatal("deleting an already-removed object should error")
	}
}

func newConfidentialTestServer(t *testing.T, adminToken string) *server {
	t.Helper()
	return &server{
		adminToken:   adminToken,
		confidential: NewConfidentialObjectStore(filepath.Join(t.TempDir(), "confidential-objects.json")),
	}
}

func TestConfidentialObjectsFailClosedWithoutAdminToken(t *testing.T) {
	s := newConfidentialTestServer(t, "") // no -admin-token configured

	for _, req := range []*http.Request{
		httptest.NewRequest(http.MethodGet, "/api/v1/confidential-objects", nil),
		httptest.NewRequest(http.MethodPost, "/api/v1/confidential-objects", bytes.NewReader([]byte(`{}`))),
	} {
		rec := httptest.NewRecorder()
		s.handleConfidentialObjects(rec, req)
		if rec.Code != http.StatusServiceUnavailable {
			t.Fatalf("%s without -admin-token = %d, want 503 (fail closed, not open like requireSettingsAdmin)", req.Method, rec.Code)
		}
	}
}

func TestConfidentialObjectsRequireTokenForReadAndWrite(t *testing.T) {
	s := newConfidentialTestServer(t, "secret-token")

	// No Authorization header at all: unauthorized for both read and write --
	// unlike fire-stations, where only writes are gated.
	getNoAuth := httptest.NewRecorder()
	s.handleConfidentialObjects(getNoAuth, httptest.NewRequest(http.MethodGet, "/api/v1/confidential-objects", nil))
	if getNoAuth.Code != http.StatusUnauthorized {
		t.Fatalf("GET without a token = %d, want 401", getNoAuth.Code)
	}

	// Wrong token.
	wrong := httptest.NewRequest(http.MethodGet, "/api/v1/confidential-objects", nil)
	wrong.Header.Set("Authorization", "Bearer wrong-token")
	wrongRec := httptest.NewRecorder()
	s.handleConfidentialObjects(wrongRec, wrong)
	if wrongRec.Code != http.StatusUnauthorized {
		t.Fatalf("GET with wrong token = %d, want 401", wrongRec.Code)
	}
}

func TestConfidentialObjectsHTTPLifecycle(t *testing.T) {
	s := newConfidentialTestServer(t, "secret-token")
	authed := func(method, path string, body []byte) *httptest.ResponseRecorder {
		var r *http.Request
		if body != nil {
			r = httptest.NewRequest(method, path, bytes.NewReader(body))
		} else {
			r = httptest.NewRequest(method, path, nil)
		}
		r.Header.Set("Authorization", "Bearer secret-token")
		rec := httptest.NewRecorder()
		if strings.HasPrefix(path, "/api/v1/confidential-objects/") {
			s.handleConfidentialObjectByID(rec, r)
		} else {
			s.handleConfidentialObjects(rec, r)
		}
		return rec
	}

	create := authed(http.MethodPost, "/api/v1/confidential-objects", []byte(`{"geometry_type":"Point","coordinates":[12.5,48.5],"tags":{"name":"Löschplan Halle 3"}}`))
	if create.Code != http.StatusCreated {
		t.Fatalf("create status = %d: %s", create.Code, create.Body.String())
	}
	var created ConfidentialObject
	if err := json.Unmarshal(create.Body.Bytes(), &created); err != nil {
		t.Fatal(err)
	}
	if created.Tags["name"] != "Löschplan Halle 3" {
		t.Fatalf("created tags = %v", created.Tags)
	}

	list := authed(http.MethodGet, "/api/v1/confidential-objects", nil)
	if list.Code != http.StatusOK || !bytes.Contains(list.Body.Bytes(), []byte(created.ID)) {
		t.Fatalf("list status=%d body=%s", list.Code, list.Body.String())
	}

	update := authed(http.MethodPut, "/api/v1/confidential-objects/"+created.ID, []byte(`{"geometry_type":"Point","coordinates":[12.6,48.6],"tags":{"name":"Löschplan Halle 3 (aktualisiert)"}}`))
	if update.Code != http.StatusOK {
		t.Fatalf("update status = %d: %s", update.Code, update.Body.String())
	}

	del := authed(http.MethodDelete, "/api/v1/confidential-objects/"+created.ID, nil)
	if del.Code != http.StatusNoContent {
		t.Fatalf("delete status = %d: %s", del.Code, del.Body.String())
	}
	missing := authed(http.MethodDelete, "/api/v1/confidential-objects/"+created.ID, nil)
	if missing.Code != http.StatusNotFound {
		t.Fatalf("deleting an already-removed object = %d, want 404", missing.Code)
	}
}

func TestConfidentialObjectRequestValidation(t *testing.T) {
	cases := []confidentialObjectRequest{
		{GeometryType: "Circle", Coordinates: json.RawMessage(`[1,2]`)},
		{GeometryType: "Point"},
		{GeometryType: "Point", Coordinates: json.RawMessage(`[1,2]`), Tags: map[string]string{"": "x"}},
	}
	for i, c := range cases {
		if err := c.validate(); err == nil {
			t.Fatalf("case %d: expected a validation error for %+v", i, c)
		}
	}
	valid := confidentialObjectRequest{GeometryType: "LineString", Coordinates: json.RawMessage(`[[1,2],[3,4]]`), Tags: map[string]string{"note": "ok"}}
	if err := valid.validate(); err != nil {
		t.Fatalf("valid request rejected: %v", err)
	}
}
