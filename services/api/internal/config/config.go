package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

const (
	defaultEnvironment         = "development"
	defaultHTTPAddress         = ":8080"
	defaultDatabaseConnectTime = 5 * time.Second
	defaultDatabasePingTimeout = 2 * time.Second
	defaultReadHeaderTimeout   = 5 * time.Second
	defaultShutdownTimeout     = 10 * time.Second
	defaultMaxRequestBodyBytes = 1 << 20
)

var defaultAllowedOrigins = []string{
	"http://localhost:8081",
	"http://127.0.0.1:8081",
}

type Config struct {
	Environment            string
	HTTPAddress            string
	DatabaseURL            string
	AllowedOrigins         []string
	WebDistDir             string
	DatabaseConnectTimeout time.Duration
	DatabasePingTimeout    time.Duration
	ReadHeaderTimeout      time.Duration
	ShutdownTimeout        time.Duration
	MaxRequestBodyBytes    int64
}

func Load() (Config, error) {
	databaseConnectTimeout, err := durationFromEnv("API_DATABASE_CONNECT_TIMEOUT", defaultDatabaseConnectTime)
	if err != nil {
		return Config{}, err
	}

	databasePingTimeout, err := durationFromEnv("API_DATABASE_PING_TIMEOUT", defaultDatabasePingTimeout)
	if err != nil {
		return Config{}, err
	}

	readHeaderTimeout, err := durationFromEnv("API_READ_HEADER_TIMEOUT", defaultReadHeaderTimeout)
	if err != nil {
		return Config{}, err
	}

	shutdownTimeout, err := durationFromEnv("API_SHUTDOWN_TIMEOUT", defaultShutdownTimeout)
	if err != nil {
		return Config{}, err
	}

	maxRequestBodyBytes, err := int64FromEnv("API_MAX_REQUEST_BODY_BYTES", defaultMaxRequestBodyBytes)
	if err != nil {
		return Config{}, err
	}

	databaseURL, err := requiredStringFromEnv("API_DATABASE_URL")
	if err != nil {
		return Config{}, err
	}

	return Config{
		Environment:            stringFromEnv("API_ENV", defaultEnvironment),
		HTTPAddress:            stringFromEnv("API_HTTP_ADDRESS", defaultHTTPAddress),
		DatabaseURL:            databaseURL,
		AllowedOrigins:         stringSliceFromEnv("API_ALLOWED_ORIGINS", defaultAllowedOrigins),
		WebDistDir:             stringFromEnv("API_WEB_DIST_DIR", ""),
		DatabaseConnectTimeout: databaseConnectTimeout,
		DatabasePingTimeout:    databasePingTimeout,
		ReadHeaderTimeout:      readHeaderTimeout,
		ShutdownTimeout:        shutdownTimeout,
		MaxRequestBodyBytes:    maxRequestBodyBytes,
	}, nil
}

func requiredStringFromEnv(key string) (string, error) {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return "", fmt.Errorf("%s is required", key)
	}

	return value, nil
}

func stringFromEnv(key, fallback string) string {
	value := strings.TrimSpace(os.Getenv(key))
	if value == "" {
		return fallback
	}

	return value
}

func stringSliceFromEnv(key string, fallback []string) []string {
	value := os.Getenv(key)
	if value == "" {
		return append([]string(nil), fallback...)
	}

	parts := strings.Split(value, ",")
	result := make([]string, 0, len(parts))
	for _, part := range parts {
		trimmed := strings.TrimSpace(part)
		if trimmed != "" {
			result = append(result, trimmed)
		}
	}

	return result
}

func durationFromEnv(key string, fallback time.Duration) (time.Duration, error) {
	value := os.Getenv(key)
	if value == "" {
		return fallback, nil
	}

	duration, err := time.ParseDuration(value)
	if err != nil {
		return 0, fmt.Errorf("parse %s as duration: %w", key, err)
	}

	return duration, nil
}

func int64FromEnv(key string, fallback int64) (int64, error) {
	value := os.Getenv(key)
	if value == "" {
		return fallback, nil
	}

	parsed, err := strconv.ParseInt(value, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("parse %s as int64: %w", key, err)
	}

	if parsed <= 0 {
		return 0, fmt.Errorf("%s must be greater than zero", key)
	}

	return parsed, nil
}
