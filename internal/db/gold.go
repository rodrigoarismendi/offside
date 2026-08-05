package db

import (
	"context"
	"embed"
	"fmt"
	"io/fs"
	"sort"

	"github.com/jackc/pgx/v5/pgxpool"
)

//go:embed gold/*.sql
var goldSQL embed.FS

// MergeGold runs every embedded gold/*.sql transform in one transaction.
func MergeGold(ctx context.Context, pool *pgxpool.Pool) error {
	files, err := fs.Glob(goldSQL, "gold/*.sql")
	if err != nil {
		return err
	}
	sort.Strings(files) // deterministic order (prefix filenames if order matters)

	tx, err := pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin tx: %w", err)
	}
	defer tx.Rollback(ctx)

	for _, name := range files {
		stmt, err := goldSQL.ReadFile(name)
		if err != nil {
			return fmt.Errorf("reading %s: %w", name, err)
		}
		if _, err := tx.Exec(ctx, string(stmt)); err != nil {
			return fmt.Errorf("executing %s: %w", name, err)
		}
	}
	return tx.Commit(ctx)
}