package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"offside/internal/config"
	"offside/internal/db"
)

const migrationsDir = "db/migrations"

func main() {
	ctx := context.Background()

	cfg, err := config.Load()
	if err != nil {
		log.Fatal(err)
	}

	pool, err := db.New(ctx, cfg.DatabaseURL)
	if err != nil {
		log.Fatal(err)
	}
	defer pool.Close()

	// A tracking table records which migrations have run, so we never re-apply one.
	if _, err := pool.Exec(ctx, `
		create table if not exists public.schema_migrations (
			filename   text primary key,
			applied_at timestamptz not null default now()
		)`); err != nil {
		log.Fatalf("creating schema_migrations: %v", err)
	}

	// Collect *.sql files, sorted — lexical order (0001, 0002, …) == apply order.
	entries, err := os.ReadDir(migrationsDir)
	if err != nil {
		log.Fatalf("reading %s: %v", migrationsDir, err)
	}
	var files []string
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".sql") {
			files = append(files, e.Name())
		}
	}
	sort.Strings(files)

	applied := 0
	for _, name := range files {
		var done bool
		if err := pool.QueryRow(ctx,
			`select exists(select 1 from public.schema_migrations where filename = $1)`, name,
		).Scan(&done); err != nil {
			log.Fatalf("checking %s: %v", name, err)
		}
		if done {
			continue // already applied — skip
		}

		sqlBytes, err := os.ReadFile(filepath.Join(migrationsDir, name))
		if err != nil {
			log.Fatalf("reading %s: %v", name, err)
		}

		// Apply the migration AND record it in one transaction — atomic.
		tx, err := pool.Begin(ctx)
		if err != nil {
			log.Fatal(err)
		}
		if _, err := tx.Exec(ctx, string(sqlBytes)); err != nil {
			tx.Rollback(ctx)
			log.Fatalf("applying %s: %v", name, err)
		}
		if _, err := tx.Exec(ctx,
			`insert into public.schema_migrations (filename) values ($1)`, name); err != nil {
			tx.Rollback(ctx)
			log.Fatalf("recording %s: %v", name, err)
		}
		if err := tx.Commit(ctx); err != nil {
			log.Fatalf("committing %s: %v", name, err)
		}

		fmt.Printf("applied %s\n", name)
		applied++
	}

	if applied == 0 {
		fmt.Println("no new migrations — database up to date ✔")
	} else {
		fmt.Printf("done — %d migration(s) applied ✔\n", applied)
	}
}