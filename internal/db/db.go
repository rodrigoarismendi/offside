package db

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5/pgxpool"
)

// New opens a connection pool to Postgres and verifies it's reachable.
// The caller is responsible for calling pool.Close() when done.
func New(ctx context.Context, databaseURL string) (*pgxpool.Pool, error) {
	pool, err := pgxpool.New(ctx, databaseURL)
	if err != nil {
		return nil, fmt.Errorf("creating pool: %w", err)
	}

	// pgxpool.New is lazy — it doesn't actually connect until first use.
	// Ping forces one connection now, so we fail fast if the DB is down
	// or the credentials are wrong, instead of much later mid-insert.
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("pinging database: %w", err)
	}

	return pool, nil
}