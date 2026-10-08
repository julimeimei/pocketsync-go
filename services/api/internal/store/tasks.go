package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/julimeimei/pocketsync-go/services/api/internal/tasks"
)

type TaskStore struct {
	db *sql.DB
}

func NewTaskStore(db *sql.DB) *TaskStore {
	return &TaskStore{db: db}
}

func (s *TaskStore) Create(ctx context.Context, params tasks.CreateParams) (tasks.Task, error) {
	row := s.db.QueryRowContext(ctx, `
		INSERT INTO tasks (
			client_id,
			title,
			description,
			completed,
			created_at,
			updated_at
		)
		VALUES ($1, $2, $3, $4, $5, $5)
		ON CONFLICT (client_id) DO UPDATE
		SET client_id = EXCLUDED.client_id
		RETURNING id, client_id, title, description, completed, version, created_at, updated_at, deleted_at
	`,
		params.ClientID,
		params.Title,
		params.Description,
		params.Completed,
		params.UpdatedAt,
	)

	return scanTask(row)
}

func (s *TaskStore) GetByID(ctx context.Context, id string) (tasks.Task, error) {
	row := s.db.QueryRowContext(ctx, `
		SELECT id, client_id, title, description, completed, version, created_at, updated_at, deleted_at
		FROM tasks
		WHERE id = $1
	`, id)

	return scanTask(row)
}

func (s *TaskStore) GetByClientID(ctx context.Context, clientID string) (tasks.Task, error) {
	row := s.db.QueryRowContext(ctx, `
		SELECT id, client_id, title, description, completed, version, created_at, updated_at, deleted_at
		FROM tasks
		WHERE client_id = $1
	`, clientID)

	return scanTask(row)
}

func (s *TaskStore) List(ctx context.Context, since *time.Time) ([]tasks.Task, error) {
	query := `
		SELECT id, client_id, title, description, completed, version, created_at, updated_at, deleted_at
		FROM tasks
	`
	args := []any{}
	if since != nil {
		query += ` WHERE updated_at > $1`
		args = append(args, *since)
	}
	query += ` ORDER BY updated_at ASC, id ASC`

	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("list tasks: %w", err)
	}
	defer rows.Close()

	var taskList []tasks.Task
	for rows.Next() {
		task, err := scanTask(rows)
		if err != nil {
			return nil, err
		}

		taskList = append(taskList, task)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate tasks: %w", err)
	}

	return taskList, nil
}

func (s *TaskStore) Update(ctx context.Context, params tasks.UpdateParams) (tasks.Task, error) {
	row := s.db.QueryRowContext(ctx, `
		UPDATE tasks
		SET title = $2,
			description = $3,
			completed = $4,
			version = version + 1,
			updated_at = $5,
			deleted_at = NULL
		WHERE id = $1
			AND version = $6
		RETURNING id, client_id, title, description, completed, version, created_at, updated_at, deleted_at
	`,
		params.ID,
		params.Title,
		params.Description,
		params.Completed,
		params.UpdatedAt,
		params.ExpectedVersion,
	)

	updated, err := scanTask(row)
	if err == nil {
		return updated, nil
	}
	if !errors.Is(err, tasks.ErrNotFound) {
		return tasks.Task{}, err
	}

	if _, getErr := s.GetByID(ctx, params.ID); getErr != nil {
		return tasks.Task{}, getErr
	}

	return tasks.Task{}, tasks.ErrConflict
}

func (s *TaskStore) Delete(ctx context.Context, params tasks.DeleteParams) (tasks.Task, error) {
	row := s.db.QueryRowContext(ctx, `
		UPDATE tasks
		SET version = version + 1,
			updated_at = $2,
			deleted_at = $2
		WHERE id = $1
			AND version = $3
		RETURNING id, client_id, title, description, completed, version, created_at, updated_at, deleted_at
	`,
		params.ID,
		params.DeletedAt,
		params.ExpectedVersion,
	)

	deleted, err := scanTask(row)
	if err == nil {
		return deleted, nil
	}
	if !errors.Is(err, tasks.ErrNotFound) {
		return tasks.Task{}, err
	}

	if _, getErr := s.GetByID(ctx, params.ID); getErr != nil {
		return tasks.Task{}, getErr
	}

	return tasks.Task{}, tasks.ErrConflict
}

type taskScanner interface {
	Scan(dest ...any) error
}

func scanTask(scanner taskScanner) (tasks.Task, error) {
	var task tasks.Task
	err := scanner.Scan(
		&task.ID,
		&task.ClientID,
		&task.Title,
		&task.Description,
		&task.Completed,
		&task.Version,
		&task.CreatedAt,
		&task.UpdatedAt,
		&task.DeletedAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return tasks.Task{}, tasks.ErrNotFound
	}
	if err != nil {
		return tasks.Task{}, fmt.Errorf("scan task: %w", err)
	}

	return task, nil
}
