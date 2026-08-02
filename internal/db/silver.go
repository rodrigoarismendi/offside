package db

import (
	"context"
	"embed"
	"fmt"
	"io/fs"
	"sort"

	"github.com/jackc/pgx/v5/pgxpool"
)

//go:embed silver/*.sql
var silverSQL embed.FS

// MergeSilver runs every embedded silver/*.sql transform in one transaction.
func MergeSilver(ctx context.Context, pool *pgxpool.Pool) error {
	files, err := fs.Glob(silverSQL, "silver/*.sql")
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
		stmt, err := silverSQL.ReadFile(name)
		if err != nil {
			return fmt.Errorf("reading %s: %w", name, err)
		}
		if _, err := tx.Exec(ctx, string(stmt)); err != nil {
			return fmt.Errorf("executing %s: %w", name, err)
		}
	}
	return tx.Commit(ctx)
}