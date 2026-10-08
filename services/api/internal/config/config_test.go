package config

import (
	"reflect"
	"testing"
	"time"
)

func TestLoadParsesEnvironmentValues(t *testing.T) {
	t.Setenv("API_ENV", "test")
	t.Setenv("API_HTTP_ADDRESS", ":9090")
	t.Setenv("API_DATABASE_URL", "postgres://example")
	t.Setenv("API_ALLOWED_ORIGINS", " http://localhost:8081, http://127.0.0.1:8081, ")
	t.Setenv("API_WEB_DIST_DIR", "../../apps/mobile/build/web")
	t.Setenv("API_DATABASE_CONNECT_TIMEOUT", "3s")
	t.Setenv("API_DATABASE_PING_TIMEOUT", "4s")
	t.Setenv("API_READ_HEADER_TIMEOUT", "5s")
	t.Setenv("API_SHUTDOWN_TIMEOUT", "6s")
	t.Setenv("API_MAX_REQUEST_BODY_BYTES", "2048")

	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load returned error: %v", err)
	}

	if cfg.Environment != "test" {
		t.Fatalf("Environment = %q, want test", cfg.Environment)
	}
	if cfg.HTTPAddress != ":9090" {
		t.Fatalf("HTTPAddress = %q, want :9090", cfg.HTTPAddress)
	}
	if cfg.DatabaseURL != "postgres://example" {
		t.Fatalf("DatabaseURL = %q, want postgres://example", cfg.DatabaseURL)
	}
	if cfg.WebDistDir != "../../apps/mobile/build/web" {
		t.Fatalf("WebDistDir = %q, want ../../apps/mobile/build/web", cfg.WebDistDir)
	}

	wantOrigins := []string{"http://localhost:8081", "http://127.0.0.1:8081"}
	if !reflect.DeepEqual(cfg.AllowedOrigins, wantOrigins) {
		t.Fatalf("AllowedOrigins = %#v, want %#v", cfg.AllowedOrigins, wantOrigins)
	}

	if cfg.DatabaseConnectTimeout != 3*time.Second ||
		cfg.DatabasePingTimeout != 4*time.Second ||
		cfg.ReadHeaderTimeout != 5*time.Second ||
		cfg.ShutdownTimeout != 6*time.Second {
		t.Fatalf("unexpected timeouts: %+v", cfg)
	}

	if cfg.MaxRequestBodyBytes != 2048 {
		t.Fatalf("MaxRequestBodyBytes = %d, want 2048", cfg.MaxRequestBodyBytes)
	}
}

func TestLoadRejectsInvalidDuration(t *testing.T) {
	t.Setenv("API_DATABASE_CONNECT_TIMEOUT", "not-a-duration")

	_, err := Load()
	if err == nil {
		t.Fatal("Load should reject invalid duration")
	}
}

func TestLoadRejectsNonPositiveRequestBodyLimit(t *testing.T) {
	t.Setenv("API_MAX_REQUEST_BODY_BYTES", "0")

	_, err := Load()
	if err == nil {
		t.Fatal("Load should reject non-positive request body limit")
	}
}

func TestLoadRejectsMissingDatabaseURL(t *testing.T) {
	_, err := Load()
	if err == nil {
		t.Fatal("Load should reject missing API_DATABASE_URL")
	}
}

func TestLoadReturnsCopyOfDefaultAllowedOrigins(t *testing.T) {
	t.Setenv("API_DATABASE_URL", "postgres://example")

	first, err := Load()
	if err != nil {
		t.Fatalf("Load returned error: %v", err)
	}
	first.AllowedOrigins[0] = "https://mutated.example"

	second, err := Load()
	if err != nil {
		t.Fatalf("Load returned error: %v", err)
	}

	if second.AllowedOrigins[0] != "http://localhost:8081" {
		t.Fatalf("default allowed origins were mutated: %#v", second.AllowedOrigins)
	}
}
