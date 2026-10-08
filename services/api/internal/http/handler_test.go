package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/julimeimei/pocketsync-go/services/api/internal/config"
)

func TestHealth(t *testing.T) {
	handler := testHandler()

	response := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/health", nil)

	handler.ServeHTTP(response, request)

	assertStatus(t, response, http.StatusOK)
	assertJSONField(t, response.Body.Bytes(), "status", "ok")
}

func TestReady(t *testing.T) {
	handler := testHandler()

	response := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/ready", nil)

	handler.ServeHTTP(response, request)

	assertStatus(t, response, http.StatusOK)
	assertJSONField(t, response.Body.Bytes(), "status", "ready")
}

func TestReadyWhenDependencyFails(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	handler := NewHandler(config.Config{
		Environment:         "test",
		HTTPAddress:         ":0",
		DatabasePingTimeout: time.Second,
		MaxRequestBodyBytes: 1024,
	}, logger, failingPinger{}, nil)

	response := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/ready", nil)

	handler.ServeHTTP(response, request)

	assertStatus(t, response, http.StatusServiceUnavailable)
	assertJSONError(t, response.Body.Bytes(), "not_ready")
}

func TestMethodNotAllowed(t *testing.T) {
	handler := testHandler()

	response := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/health", nil)

	handler.ServeHTTP(response, request)

	assertStatus(t, response, http.StatusMethodNotAllowed)
	assertJSONError(t, response.Body.Bytes(), "method_not_allowed")
}

func TestNotFound(t *testing.T) {
	handler := testHandler()

	response := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/missing", nil)

	handler.ServeHTTP(response, request)

	assertStatus(t, response, http.StatusNotFound)
	assertJSONError(t, response.Body.Bytes(), "not_found")
}

func TestServesWebBuildWhenConfigured(t *testing.T) {
	webDistDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(webDistDir, "index.html"), []byte("<h1>PocketSync</h1>"), 0o600); err != nil {
		t.Fatalf("write test web build: %v", err)
	}

	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	handler := NewHandler(config.Config{
		Environment:         "test",
		HTTPAddress:         ":0",
		WebDistDir:          webDistDir,
		DatabasePingTimeout: time.Second,
		MaxRequestBodyBytes: 1024,
	}, logger, nil, nil)

	response := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/", nil)

	handler.ServeHTTP(response, request)

	assertStatus(t, response, http.StatusOK)
	if got := response.Body.String(); got != "<h1>PocketSync</h1>" {
		t.Fatalf("web build response = %q", got)
	}
	assertHeader(t, response, "Cross-Origin-Opener-Policy", "same-origin")
	assertHeader(t, response, "Cross-Origin-Embedder-Policy", "require-corp")
}

func TestCORSAllowedOrigin(t *testing.T) {
	handler := testHandler()

	response := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/health", nil)
	request.Header.Set("Origin", "http://localhost:8081")

	handler.ServeHTTP(response, request)

	assertStatus(t, response, http.StatusOK)
	assertHeader(t, response, "Access-Control-Allow-Origin", "http://localhost:8081")
	assertHeader(t, response, "Vary", "Origin")
	assertHeader(t, response, "Cross-Origin-Opener-Policy", "same-origin")
	assertHeader(t, response, "Cross-Origin-Embedder-Policy", "require-corp")
	assertHeader(t, response, "Cross-Origin-Resource-Policy", "same-origin")
	assertHeader(t, response, "X-Content-Type-Options", "nosniff")
}

func TestCORSPreflightForAllowedOrigin(t *testing.T) {
	handler := testHandler()

	response := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodOptions, "/tasks", nil)
	request.Header.Set("Origin", "http://localhost:8081")
	request.Header.Set("Access-Control-Request-Method", http.MethodPost)

	handler.ServeHTTP(response, request)

	assertStatus(t, response, http.StatusNoContent)
	assertHeader(t, response, "Access-Control-Allow-Origin", "http://localhost:8081")
	assertHeader(t, response, "Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
	assertHeader(t, response, "Access-Control-Allow-Headers", "Content-Type")
}

func TestCORSDisallowedOrigin(t *testing.T) {
	handler := testHandler()

	response := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/health", nil)
	request.Header.Set("Origin", "https://example.com")

	handler.ServeHTTP(response, request)

	assertStatus(t, response, http.StatusOK)
	assertHeader(t, response, "Access-Control-Allow-Origin", "")
	assertHeader(t, response, "Vary", "Origin")
}

func testHandler() http.Handler {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))

	return NewHandler(config.Config{
		Environment:         "test",
		HTTPAddress:         ":0",
		AllowedOrigins:      []string{"http://localhost:8081"},
		DatabasePingTimeout: time.Second,
		MaxRequestBodyBytes: 1024,
	}, logger, nil, nil)
}

type failingPinger struct{}

func (failingPinger) PingContext(context.Context) error {
	return errors.New("dependency unavailable")
}

func assertStatus(t *testing.T, response *httptest.ResponseRecorder, want int) {
	t.Helper()

	if response.Code != want {
		t.Fatalf("status = %d, want %d; body = %s", response.Code, want, response.Body.String())
	}
}

func assertJSONField(t *testing.T, body []byte, field, want string) {
	t.Helper()

	var payload map[string]string
	if err := json.Unmarshal(body, &payload); err != nil {
		t.Fatalf("decode json response: %v", err)
	}

	if payload[field] != want {
		t.Fatalf("%s = %q, want %q", field, payload[field], want)
	}
}

func assertJSONError(t *testing.T, body []byte, wantCode string) {
	t.Helper()

	var payload errorResponse
	if err := json.Unmarshal(body, &payload); err != nil {
		t.Fatalf("decode json error response: %v", err)
	}

	if payload.Error.Code != wantCode {
		t.Fatalf("error code = %q, want %q", payload.Error.Code, wantCode)
	}
}

func assertHeader(t *testing.T, response *httptest.ResponseRecorder, key, want string) {
	t.Helper()

	if got := response.Header().Get(key); got != want {
		t.Fatalf("header %s = %q, want %q", key, got, want)
	}
}
