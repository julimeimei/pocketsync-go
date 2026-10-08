package store

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/julimeimei/pocketsync-go/services/api/internal/platform/postgres"
	"github.com/julimeimei/pocketsync-go/services/api/internal/store/migrations"
	"github.com/julimeimei/pocketsync-go/services/api/internal/tasks"
)

func TestTaskStoreIntegration(t *testing.T) {
	databaseURL := os.Getenv("POCKETSYNC_TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("set POCKETSYNC_TEST_DATABASE_URL to run PostgreSQL integration tests")
	}

	ctx := context.Background()
	db, err := postgres.Open(ctx, databaseURL)
	if err != nil {
		t.Fatalf("open database: %v", err)
	}
	defer db.Close()

	if err := migrations.Run(ctx, db); err != nil {
		t.Fatalf("run migrations: %v", err)
	}

	store := NewTaskStore(db)
	now := time.Now().UTC().Truncate(time.Microsecond)

	created, err := store.Create(ctx, tasks.CreateParams{
		ClientID:    "integration-client-id",
		Title:       "Write integration test",
		Description: "Cover persistence behavior",
		Completed:   false,
		UpdatedAt:   now,
	})
	if err != nil {
		t.Fatalf("create task: %v", err)
	}

	duplicate, err := store.Create(ctx, tasks.CreateParams{
		ClientID:    created.ClientID,
		Title:       "Ignored duplicate title",
		Description: "Duplicate create should return existing row",
		Completed:   true,
		UpdatedAt:   now.Add(time.Minute),
	})
	if err != nil {
		t.Fatalf("create duplicate task: %v", err)
	}
	if duplicate.ID != created.ID {
		t.Fatalf("duplicate id = %q, want %q", duplicate.ID, created.ID)
	}

	updated, err := store.Update(ctx, tasks.UpdateParams{
		ID:              created.ID,
		Title:           "Updated task",
		Description:     "Updated description",
		Completed:       true,
		ExpectedVersion: created.Version,
		UpdatedAt:       now.Add(time.Minute),
	})
	if err != nil {
		t.Fatalf("update task: %v", err)
	}
	if updated.Version != created.Version+1 {
		t.Fatalf("updated version = %d, want %d", updated.Version, created.Version+1)
	}

	_, err = store.Update(ctx, tasks.UpdateParams{
		ID:              created.ID,
		Title:           "Stale update",
		Description:     "",
		Completed:       false,
		ExpectedVersion: created.Version,
		UpdatedAt:       now.Add(2 * time.Minute),
	})
	if err != tasks.ErrConflict {
		t.Fatalf("stale update error = %v, want %v", err, tasks.ErrConflict)
	}

	deleted, err := store.Delete(ctx, tasks.DeleteParams{
		ID:              created.ID,
		ExpectedVersion: updated.Version,
		DeletedAt:       now.Add(3 * time.Minute),
	})
	if err != nil {
		t.Fatalf("delete task: %v", err)
	}
	if deleted.DeletedAt == nil {
		t.Fatal("deleted task should have DeletedAt set")
	}
}
