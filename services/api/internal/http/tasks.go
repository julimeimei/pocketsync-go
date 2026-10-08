package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/julimeimei/pocketsync-go/services/api/internal/tasks"
)

const (
	maxClientIDLength    = 128
	maxTaskTitleLength   = 200
	maxDescriptionLength = 2000
)

type taskResponse struct {
	ID          string     `json:"id"`
	ClientID    string     `json:"client_id"`
	Title       string     `json:"title"`
	Description string     `json:"description"`
	Completed   bool       `json:"completed"`
	Version     int        `json:"version"`
	CreatedAt   time.Time  `json:"created_at"`
	UpdatedAt   time.Time  `json:"updated_at"`
	DeletedAt   *time.Time `json:"deleted_at,omitempty"`
}

type taskListResponse struct {
	Tasks []taskResponse `json:"tasks"`
}

type createTaskRequest struct {
	ClientID    string    `json:"client_id"`
	Title       string    `json:"title"`
	Description string    `json:"description"`
	Completed   bool      `json:"completed"`
	UpdatedAt   time.Time `json:"updated_at"`
}

type updateTaskRequest struct {
	Title           string    `json:"title"`
	Description     string    `json:"description"`
	Completed       bool      `json:"completed"`
	ExpectedVersion int       `json:"expected_version"`
	UpdatedAt       time.Time `json:"updated_at"`
}

type deleteTaskRequest struct {
	ExpectedVersion int       `json:"expected_version"`
	DeletedAt       time.Time `json:"deleted_at"`
}

func (h *Handler) tasksCollection(w http.ResponseWriter, r *http.Request) {
	if h.tasks == nil {
		writeError(w, http.StatusServiceUnavailable, "not_ready", "task repository is not available")
		return
	}

	switch r.Method {
	case http.MethodPost:
		h.createTask(w, r)
	case http.MethodGet:
		h.listTasks(w, r)
	default:
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
	}
}

func (h *Handler) taskResource(w http.ResponseWriter, r *http.Request) {
	if h.tasks == nil {
		writeError(w, http.StatusServiceUnavailable, "not_ready", "task repository is not available")
		return
	}

	id, ok := taskIDFromPath(r.URL.Path)
	if !ok {
		writeError(w, http.StatusNotFound, "not_found", "route not found")
		return
	}

	switch r.Method {
	case http.MethodGet:
		h.getTask(w, r, id)
	case http.MethodPut:
		h.updateTask(w, r, id)
	case http.MethodDelete:
		h.deleteTask(w, r, id)
	default:
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
	}
}

func (h *Handler) createTask(w http.ResponseWriter, r *http.Request) {
	var request createTaskRequest
	if !decodeJSONRequest(w, r, &request) {
		return
	}

	request.ClientID = strings.TrimSpace(request.ClientID)
	request.Title = strings.TrimSpace(request.Title)
	if !validateClientID(w, request.ClientID) ||
		!validateTitle(w, request.Title) ||
		!validateDescription(w, request.Description) ||
		!validateTimestamp(w, "updated_at", request.UpdatedAt) {
		return
	}

	task, err := h.tasks.Create(r.Context(), tasks.CreateParams{
		ClientID:    request.ClientID,
		Title:       request.Title,
		Description: request.Description,
		Completed:   request.Completed,
		UpdatedAt:   request.UpdatedAt,
	})
	if err != nil {
		h.logger.Error("create task failed", "error", err)
		writeError(w, http.StatusInternalServerError, "internal_error", "internal server error")
		return
	}

	writeJSON(w, http.StatusCreated, toTaskResponse(task))
}

func (h *Handler) listTasks(w http.ResponseWriter, r *http.Request) {
	since, ok := parseOptionalSince(w, r)
	if !ok {
		return
	}

	taskList, err := h.tasks.List(r.Context(), since)
	if err != nil {
		h.logger.Error("list tasks failed", "error", err)
		writeError(w, http.StatusInternalServerError, "internal_error", "internal server error")
		return
	}

	response := taskListResponse{
		Tasks: make([]taskResponse, 0, len(taskList)),
	}
	for _, task := range taskList {
		response.Tasks = append(response.Tasks, toTaskResponse(task))
	}

	writeJSON(w, http.StatusOK, response)
}

func (h *Handler) getTask(w http.ResponseWriter, r *http.Request, id string) {
	task, err := h.tasks.GetByID(r.Context(), id)
	if errors.Is(err, tasks.ErrNotFound) {
		writeError(w, http.StatusNotFound, "not_found", "task not found")
		return
	}
	if err != nil {
		h.logger.Error("get task failed", "error", err)
		writeError(w, http.StatusInternalServerError, "internal_error", "internal server error")
		return
	}

	writeJSON(w, http.StatusOK, toTaskResponse(task))
}

func (h *Handler) updateTask(w http.ResponseWriter, r *http.Request, id string) {
	var request updateTaskRequest
	if !decodeJSONRequest(w, r, &request) {
		return
	}

	request.Title = strings.TrimSpace(request.Title)
	if !validateTitle(w, request.Title) ||
		!validateDescription(w, request.Description) ||
		!validateExpectedVersion(w, request.ExpectedVersion) ||
		!validateTimestamp(w, "updated_at", request.UpdatedAt) {
		return
	}

	task, err := h.tasks.Update(r.Context(), tasks.UpdateParams{
		ID:              id,
		Title:           request.Title,
		Description:     request.Description,
		Completed:       request.Completed,
		ExpectedVersion: request.ExpectedVersion,
		UpdatedAt:       request.UpdatedAt,
	})
	if errors.Is(err, tasks.ErrNotFound) {
		writeError(w, http.StatusNotFound, "not_found", "task not found")
		return
	}
	if errors.Is(err, tasks.ErrConflict) {
		h.writeConflict(w, r.Context(), id)
		return
	}
	if err != nil {
		h.logger.Error("update task failed", "error", err)
		writeError(w, http.StatusInternalServerError, "internal_error", "internal server error")
		return
	}

	writeJSON(w, http.StatusOK, toTaskResponse(task))
}

func (h *Handler) deleteTask(w http.ResponseWriter, r *http.Request, id string) {
	var request deleteTaskRequest
	if !decodeJSONRequest(w, r, &request) {
		return
	}

	if !validateExpectedVersion(w, request.ExpectedVersion) ||
		!validateTimestamp(w, "deleted_at", request.DeletedAt) {
		return
	}

	task, err := h.tasks.Delete(r.Context(), tasks.DeleteParams{
		ID:              id,
		ExpectedVersion: request.ExpectedVersion,
		DeletedAt:       request.DeletedAt,
	})
	if errors.Is(err, tasks.ErrNotFound) {
		writeError(w, http.StatusNotFound, "not_found", "task not found")
		return
	}
	if errors.Is(err, tasks.ErrConflict) {
		h.writeConflict(w, r.Context(), id)
		return
	}
	if err != nil {
		h.logger.Error("delete task failed", "error", err)
		writeError(w, http.StatusInternalServerError, "internal_error", "internal server error")
		return
	}

	writeJSON(w, http.StatusOK, toTaskResponse(task))
}

func (h *Handler) writeConflict(w http.ResponseWriter, ctx context.Context, id string) {
	serverTask, err := h.tasks.GetByID(ctx, id)
	if err != nil {
		h.logger.Warn("failed to load server task for conflict response", "task_id", id, "error", err)
		writeError(w, http.StatusConflict, "conflict", "task has changed on the server")
		return
	}

	writeJSON(w, http.StatusConflict, struct {
		Error struct {
			Code       string       `json:"code"`
			Message    string       `json:"message"`
			ServerTask taskResponse `json:"server_task"`
		} `json:"error"`
	}{
		Error: struct {
			Code       string       `json:"code"`
			Message    string       `json:"message"`
			ServerTask taskResponse `json:"server_task"`
		}{
			Code:       "conflict",
			Message:    "task has changed on the server",
			ServerTask: toTaskResponse(serverTask),
		},
	})
}

func decodeJSONRequest(w http.ResponseWriter, r *http.Request, destination any) bool {
	if r.Body == nil {
		writeError(w, http.StatusBadRequest, "invalid_json", "request body is required")
		return false
	}
	defer r.Body.Close()

	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()

	if err := decoder.Decode(destination); err != nil {
		var maxBytesError *http.MaxBytesError
		if errors.As(err, &maxBytesError) {
			writeError(w, http.StatusRequestEntityTooLarge, "body_too_large", "request body is too large")
			return false
		}

		writeError(w, http.StatusBadRequest, "invalid_json", "request body must be valid json")
		return false
	}

	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		writeError(w, http.StatusBadRequest, "invalid_json", "request body must contain a single json value")
		return false
	}

	return true
}

func taskIDFromPath(path string) (string, bool) {
	id := strings.TrimPrefix(path, "/tasks/")
	if id == "" || strings.Contains(id, "/") {
		return "", false
	}

	return id, true
}

func parseOptionalSince(w http.ResponseWriter, r *http.Request) (*time.Time, bool) {
	value := r.URL.Query().Get("since")
	if value == "" {
		return nil, true
	}

	parsed, err := time.Parse(time.RFC3339Nano, value)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_since", "since must be an RFC3339 timestamp")
		return nil, false
	}

	return &parsed, true
}

func validateClientID(w http.ResponseWriter, clientID string) bool {
	if clientID == "" {
		writeValidationError(w, "client_id is required")
		return false
	}
	if len(clientID) > maxClientIDLength {
		writeValidationError(w, fmt.Sprintf("client_id must be at most %d characters", maxClientIDLength))
		return false
	}

	return true
}

func validateTitle(w http.ResponseWriter, title string) bool {
	if title == "" {
		writeValidationError(w, "title is required")
		return false
	}
	if len(title) > maxTaskTitleLength {
		writeValidationError(w, fmt.Sprintf("title must be at most %d characters", maxTaskTitleLength))
		return false
	}

	return true
}

func validateDescription(w http.ResponseWriter, description string) bool {
	if len(description) > maxDescriptionLength {
		writeValidationError(w, fmt.Sprintf("description must be at most %d characters", maxDescriptionLength))
		return false
	}

	return true
}

func validateExpectedVersion(w http.ResponseWriter, expectedVersion int) bool {
	if expectedVersion <= 0 {
		writeValidationError(w, "expected_version must be greater than zero")
		return false
	}

	return true
}

func validateTimestamp(w http.ResponseWriter, field string, value time.Time) bool {
	if value.IsZero() {
		writeValidationError(w, field+" is required")
		return false
	}

	return true
}

func writeValidationError(w http.ResponseWriter, message string) {
	writeError(w, http.StatusBadRequest, "validation_error", message)
}

func toTaskResponse(task tasks.Task) taskResponse {
	return taskResponse{
		ID:          task.ID,
		ClientID:    task.ClientID,
		Title:       task.Title,
		Description: task.Description,
		Completed:   task.Completed,
		Version:     task.Version,
		CreatedAt:   task.CreatedAt,
		UpdatedAt:   task.UpdatedAt,
		DeletedAt:   task.DeletedAt,
	}
}
