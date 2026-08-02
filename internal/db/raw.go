package db

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/jackc/pgx/v5/pgxpool"
)

// allowedTables whitelists valid targets, because the table name is
// interpolated into SQL (a table name cannot be a bind parameter).
var allowedTables = map[string]bool{
	"bronze.leagues":   true,
	"bronze.teams":     true,
	"bronze.fixtures":  true,
	"bronze.standings": true,
}

// InsertRaw lands one raw JSON record into a bronze table.
func InsertRaw(ctx context.Context, pool *pgxpool.Pool, table string, sourceParams any, blob json.RawMessage) error {
	if !allowedTables[table] {
		return fmt.Errorf("refusing to insert into unknown table %q", table)
	}

	params, err := json.Marshal(sourceParams)
	if err != nil {
		return fmt.Errorf("marshaling source params: %w", err)
	}

	sql := fmt.Sprintf(
		`insert into %s (payload, source_params, record_hash)
		 values ($1::jsonb, $2::jsonb, md5($1::text))`, table)

	if _, err := pool.Exec(ctx, sql, string(blob), string(params)); err != nil {
		return fmt.Errorf("inserting into %s: %w", table, err)
	}
	return nil
}