package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/julimeimei/pocketsync-go/services/api/internal/config"
	httpapi "github.com/julimeimei/pocketsync-go/services/api/internal/http"
	"github.com/julimeimei/pocketsync-go/services/api/internal/platform/postgres"
	"github.com/julimeimei/pocketsync-go/services/api/internal/store"
	"github.com/julimeimei/pocketsync-go/services/api/internal/store/migrations"
)

func main() {
	logger := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	}))

	cfg, err := config.Load()
	if err != nil {
		logger.Error("failed to load configuration", "error", err)
		os.Exit(1)
	}

	dbConnectCtx, dbConnectCancel := context.WithTimeout(context.Background(), cfg.DatabaseConnectTimeout)
	defer dbConnectCancel()

	db, err := postgres.Open(dbConnectCtx, cfg.DatabaseURL)
	if err != nil {
		logger.Error("failed to connect to database", "error", err)
		os.Exit(1)
	}
	defer db.Close()

	migrationCtx, migrationCancel := context.WithTimeout(context.Background(), cfg.DatabaseConnectTimeout)
	defer migrationCancel()

	if err := migrations.Run(migrationCtx, db); err != nil {
		logger.Error("failed to run database migrations", "error", err)
		os.Exit(1)
	}

	taskStore := store.NewTaskStore(db)

	server := &http.Server{
		Addr:              cfg.HTTPAddress,
		Handler:           httpapi.NewHandler(cfg, logger, db, taskStore),
		ReadHeaderTimeout: cfg.ReadHeaderTimeout,
	}

	serverErrors := make(chan error, 1)
	go func() {
		logger.Info("starting api server", "addr", cfg.HTTPAddress, "env", cfg.Environment)
		serverErrors <- server.ListenAndServe()
	}()

	shutdownSignals := make(chan os.Signal, 1)
	signal.Notify(shutdownSignals, os.Interrupt, syscall.SIGTERM)

	select {
	case err := <-serverErrors:
		if !errors.Is(err, http.ErrServerClosed) {
			logger.Error("api server failed", "error", err)
			os.Exit(1)
		}
	case sig := <-shutdownSignals:
		logger.Info("shutdown signal received", "signal", sig.String())
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), cfg.ShutdownTimeout)
	defer cancel()

	if err := server.Shutdown(shutdownCtx); err != nil {
		logger.Error("graceful shutdown failed", "error", err)

		forceCtx, forceCancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer forceCancel()

		if closeErr := server.Shutdown(forceCtx); closeErr != nil {
			logger.Error("forced shutdown failed", "error", closeErr)
		}

		os.Exit(1)
	}

	logger.Info("api server stopped")
}
