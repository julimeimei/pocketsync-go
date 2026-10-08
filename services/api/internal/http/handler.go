package httpapi

import (
	"context"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/julimeimei/pocketsync-go/services/api/internal/config"
	"github.com/julimeimei/pocketsync-go/services/api/internal/tasks"
)

type Pinger interface {
	PingContext(ctx context.Context) error
}

type TaskRepository interface {
	Create(ctx context.Context, params tasks.CreateParams) (tasks.Task, error)
	List(ctx context.Context, since *time.Time) ([]tasks.Task, error)
	GetByID(ctx context.Context, id string) (tasks.Task, error)
	Update(ctx context.Context, params tasks.UpdateParams) (tasks.Task, error)
	Delete(ctx context.Context, params tasks.DeleteParams) (tasks.Task, error)
}

type Handler struct {
	logger              *slog.Logger
	pinger              Pinger
	tasks               TaskRepository
	allowedOrigins      map[string]struct{}
	readinessTimeout    time.Duration
	maxRequestBodyBytes int64
	webApp              http.Handler
}

func NewHandler(cfg config.Config, logger *slog.Logger, pinger Pinger, taskRepository TaskRepository) http.Handler {
	handler := &Handler{
		logger:              logger,
		pinger:              pinger,
		tasks:               taskRepository,
		allowedOrigins:      allowedOriginSet(cfg.AllowedOrigins),
		readinessTimeout:    cfg.DatabasePingTimeout,
		maxRequestBodyBytes: cfg.MaxRequestBodyBytes,
	}
	if strings.TrimSpace(cfg.WebDistDir) != "" {
		handler.webApp = http.FileServer(http.Dir(cfg.WebDistDir))
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/health", handler.health)
	mux.HandleFunc("/ready", handler.ready)
	mux.HandleFunc("/tasks", handler.tasksCollection)
	mux.HandleFunc("/tasks/", handler.taskResource)
	mux.HandleFunc("/", handler.webOrNotFound)

	return handler.recoverPanic(handler.requestLogger(handler.crossOriginIsolation(handler.cors(handler.limitRequestBody(mux)))))
}

func (h *Handler) health(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{
		"status": "ok",
	})
}

func (h *Handler) ready(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}

	if h.pinger != nil {
		ctx, cancel := context.WithTimeout(r.Context(), h.readinessTimeout)
		defer cancel()

		if err := h.pinger.PingContext(ctx); err != nil {
			h.logger.Warn("readiness check failed", "error", err)
			writeError(w, http.StatusServiceUnavailable, "not_ready", "service dependencies are not ready")
			return
		}
	}

	writeJSON(w, http.StatusOK, map[string]string{
		"status": "ready",
	})
}

func (h *Handler) notFound(w http.ResponseWriter, _ *http.Request) {
	writeError(w, http.StatusNotFound, "not_found", "route not found")
}

func (h *Handler) webOrNotFound(w http.ResponseWriter, r *http.Request) {
	if h.webApp == nil {
		h.notFound(w, r)
		return
	}

	h.webApp.ServeHTTP(w, r)
}
