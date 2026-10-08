package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/julimeimei/pocketsync-go/services/api/internal/config"
	"github.com/julimeimei/pocketsync-go/services/api/internal/tasks"
)

func TestCreateTask(t *testing.T) {
	now := fixedTime()
	repository := &fakeTaskRepository{
		createFunc: func(_ context.Context, params tasks.CreateParams) (tasks.Task, error) {
			if params.ClientID != "local-1" {
				t.Fatalf("client id = %q, want local-1", params.ClientID)
			}
			if params.Title != "Buy milk" {
				t.Fatalf("title = %q, want trimmed title", params.Title)
			}

			return taskFixture("task-1", "local-1", "Buy milk", 1, now), nil
		},
	}
	handler := testHandlerWithTasks(repository)

	response := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/tasks", strings.NewReader(`{
		"client_id": "local-1",
		"title": "  Buy milk  ",
		"description": "2L",
		"completed": false,
		"updated_at": "`+now.Format(time.RFC3339Nano)+`"
	}`))

	handler.ServeHTTP(response, request)

	assertStatus(t, response, http.StatusCreated)

	var payload taskResponse
	decodeResponse(t, response.Body.Bytes(), &payload)
	if payload.ID != "task-1" || payload.Version != 1 {
		t.Fatalf("unexpected task response: %+v", payload)
	}
}

func TestCreateTaskRejectsUnknownJSONField(t *testing.T) {
	handler := testHandlerWithTasks(&fakeTaskRepository{})

	response := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/tasks", strings.NewReader(`{
		"client_id": "local-1",
		"title": "Buy milk",
		"description": "",
		"completed": false,
		"updated_at": "2026-08-14T21:00:00Z",
		"unexpected": true
	}`))

	handler.ServeHTTP(response, request)

	assertStatus(t, response, http.StatusBadRequest)
	assertJSONError(t, response.Body.Bytes(), "invalid_json")
}

func TestCreateTaskValidatesTitle(t *testing.T) {
	handler := testHandlerWithTasks(&fakeTaskRepository{})

	response := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/tasks", strings.NewReader(`{
		"client_id": "local-1",
		"title": "   ",
		"description": "",
		"completed": false,
		"updated_at": "2026-08-14T21:00:00Z"
	}`))

	handler.ServeHTTP(response, request)

	assertStatus(t, response, http.StatusBadRequest)
	assertJSONError(t, response.Body.Bytes(), "validation_error")
}

func TestCreateTaskRejectsBodyTooLarge(t *testing.T) {
	handler := testHandlerWithTasks(&fakeTaskRepository{})

	response := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPost, "/tasks", strings.NewReader(`{
		"client_id": "local-1",
		"title": "`+strings.Repeat("a", 2048)+`",
		"description": "",
		"completed": false,
		"updated_at": "2026-08-14T21:00:00Z"
	}`))

	handler.ServeHTTP(response, request)

	assertStatus(t, response, http.StatusRequestEntityTooLarge)
	assertJSONError(t, response.Body.Bytes(), "body_too_large")
}

func TestListTasks(t *testing.T) {
	now := fixedTime()
	repository := &fakeTaskRepository{
		listFunc: func(_ context.Context, since *time.Time) ([]tasks.Task, error) {
			if since == nil {
				t.Fatal("since should be parsed")
			}

			return []tasks.Task{
				taskFixture("task-1", "local-1", "First", 1, now),
				taskFixture("task-2", "local-2", "Second", 2, now.Add(time.Minute)),
			}, nil
		},
	}
	handler := testHandlerWithTasks(repository)

	response := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/tasks?since="+now.Format(time.RFC3339Nano), nil)

	handler.ServeHTTP(response, request)

	assertStatus(t, response, http.StatusOK)

	var payload taskListResponse
	decodeResponse(t, response.Body.Bytes(), &payload)
	if len(payload.Tasks) != 2 {
		t.Fatalf("tasks length = %d, want 2", len(payload.Tasks))
	}
}

func TestListTasksRejectsInvalidSince(t *testing.T) {
	handler := testHandlerWithTasks(&fakeTaskRepository{})

	response := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/tasks?since=not-a-date", nil)

	handler.ServeHTTP(response, request)

	assertStatus(t, response, http.StatusBadRequest)
	assertJSONError(t, response.Body.Bytes(), "invalid_since")
}

func TestGetTaskNotFound(t *testing.T) {
	repository := &fakeTaskRepository{
		getByIDFunc: func(context.Context, string) (tasks.Task, error) {
			return tasks.Task{}, tasks.ErrNotFound
		},
	}
	handler := testHandlerWithTasks(repository)

	response := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/tasks/missing", nil)

	handler.ServeHTTP(response, request)

	assertStatus(t, response, http.StatusNotFound)
	assertJSONError(t, response.Body.Bytes(), "not_found")
}

func TestUpdateTaskConflict(t *testing.T) {
	now := fixedTime()
	serverTask := taskFixture("task-1", "local-1", "Server title", 2, now)
	repository := &fakeTaskRepository{
		updateFunc: func(context.Context, tasks.UpdateParams) (tasks.Task, error) {
			return tasks.Task{}, tasks.ErrConflict
		},
		getByIDFunc: func(context.Context, string) (tasks.Task, error) {
			return serverTask, nil
		},
	}
	handler := testHandlerWithTasks(repository)

	response := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPut, "/tasks/task-1", strings.NewReader(`{
		"title": "Client title",
		"description": "",
		"completed": false,
		"expected_version": 1,
		"updated_at": "`+now.Format(time.RFC3339Nano)+`"
	}`))

	handler.ServeHTTP(response, request)

	assertStatus(t, response, http.StatusConflict)

	var payload struct {
		Error struct {
			Code       string       `json:"code"`
			ServerTask taskResponse `json:"server_task"`
		} `json:"error"`
	}
	decodeResponse(t, response.Body.Bytes(), &payload)
	if payload.Error.Code != "conflict" || payload.Error.ServerTask.Version != 2 {
		t.Fatalf("unexpected conflict response: %+v", payload)
	}
}

func TestUpdateTaskRejectsInvalidExpectedVersion(t *testing.T) {
	handler := testHandlerWithTasks(&fakeTaskRepository{})
	now := fixedTime()

	response := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodPut, "/tasks/task-1", strings.NewReader(`{
		"title": "Client title",
		"description": "",
		"completed": false,
		"expected_version": 0,
		"updated_at": "`+now.Format(time.RFC3339Nano)+`"
	}`))

	handler.ServeHTTP(response, request)

	assertStatus(t, response, http.StatusBadRequest)
	assertJSONError(t, response.Body.Bytes(), "validation_error")
}

func TestDeleteTask(t *testing.T) {
	now := fixedTime()
	deletedAt := now.Add(time.Minute)
	deleted := taskFixture("task-1", "local-1", "Buy milk", 2, deletedAt)
	deleted.DeletedAt = &deletedAt
	repository := &fakeTaskRepository{
		deleteFunc: func(_ context.Context, params tasks.DeleteParams) (tasks.Task, error) {
			if params.ExpectedVersion != 1 {
				t.Fatalf("expected version = %d, want 1", params.ExpectedVersion)
			}

			return deleted, nil
		},
	}
	handler := testHandlerWithTasks(repository)

	response := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodDelete, "/tasks/task-1", strings.NewReader(`{
		"expected_version": 1,
		"deleted_at": "`+deletedAt.Format(time.RFC3339Nano)+`"
	}`))

	handler.ServeHTTP(response, request)

	assertStatus(t, response, http.StatusOK)

	var payload taskResponse
	decodeResponse(t, response.Body.Bytes(), &payload)
	if payload.DeletedAt == nil {
		t.Fatal("deleted_at should be present")
	}
}

func testHandlerWithTasks(repository TaskRepository) http.Handler {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))

	return NewHandler(config.Config{
		Environment:         "test",
		HTTPAddress:         ":0",
		DatabasePingTimeout: time.Second,
		MaxRequestBodyBytes: 1024,
	}, logger, nil, repository)
}

func fixedTime() time.Time {
	return time.Date(2026, 8, 14, 21, 0, 0, 0, time.UTC)
}

func taskFixture(id, clientID, title string, version int, updatedAt time.Time) tasks.Task {
	return tasks.Task{
		ID:          id,
		ClientID:    clientID,
		Title:       title,
		Description: "",
		Completed:   false,
		Version:     version,
		CreatedAt:   updatedAt.Add(-time.Hour),
		UpdatedAt:   updatedAt,
	}
}

func decodeResponse(t *testing.T, body []byte, destination any) {
	t.Helper()

	if err := json.Unmarshal(body, destination); err != nil {
		t.Fatalf("decode response: %v; body = %s", err, string(body))
	}
}

type fakeTaskRepository struct {
	createFunc  func(context.Context, tasks.CreateParams) (tasks.Task, error)
	listFunc    func(context.Context, *time.Time) ([]tasks.Task, error)
	getByIDFunc func(context.Context, string) (tasks.Task, error)
	updateFunc  func(context.Context, tasks.UpdateParams) (tasks.Task, error)
	deleteFunc  func(context.Context, tasks.DeleteParams) (tasks.Task, error)
}

func (f *fakeTaskRepository) Create(ctx context.Context, params tasks.CreateParams) (tasks.Task, error) {
	if f.createFunc == nil {
		return tasks.Task{}, errors.New("Create not implemented")
	}

	return f.createFunc(ctx, params)
}

func (f *fakeTaskRepository) List(ctx context.Context, since *time.Time) ([]tasks.Task, error) {
	if f.listFunc == nil {
		return nil, errors.New("List not implemented")
	}

	return f.listFunc(ctx, since)
}

func (f *fakeTaskRepository) GetByID(ctx context.Context, id string) (tasks.Task, error) {
	if f.getByIDFunc == nil {
		return tasks.Task{}, errors.New("GetByID not implemented")
	}

	return f.getByIDFunc(ctx, id)
}

func (f *fakeTaskRepository) Update(ctx context.Context, params tasks.UpdateParams) (tasks.Task, error) {
	if f.updateFunc == nil {
		return tasks.Task{}, errors.New("Update not implemented")
	}

	return f.updateFunc(ctx, params)
}

func (f *fakeTaskRepository) Delete(ctx context.Context, params tasks.DeleteParams) (tasks.Task, error) {
	if f.deleteFunc == nil {
		return tasks.Task{}, errors.New("Delete not implemented")
	}

	return f.deleteFunc(ctx, params)
}
