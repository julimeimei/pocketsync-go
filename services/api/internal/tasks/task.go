package tasks

import (
	"errors"
	"time"
)

var (
	ErrNotFound = errors.New("task not found")
	ErrConflict = errors.New("task version conflict")
)

type Task struct {
	ID          string
	ClientID    string
	Title       string
	Description string
	Completed   bool
	Version     int
	CreatedAt   time.Time
	UpdatedAt   time.Time
	DeletedAt   *time.Time
}

type CreateParams struct {
	ClientID    string
	Title       string
	Description string
	Completed   bool
	UpdatedAt   time.Time
}

type UpdateParams struct {
	ID              string
	Title           string
	Description     string
	Completed       bool
	ExpectedVersion int
	UpdatedAt       time.Time
}

type DeleteParams struct {
	ID              string
	ExpectedVersion int
	DeletedAt       time.Time
}
