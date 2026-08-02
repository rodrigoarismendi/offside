package main

import (
	"context"
	"log"
	"net/url"

	"offside/internal/apifootball"
	"offside/internal/config"
	"offside/internal/db"

	"github.com/jackc/pgx/v5/pgxpool"
)

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

	client := apifootball.New(cfg)

	const league, season = "39", "2023"

	jobs := []struct {
		name, table, path string
		params            url.Values
	}{
		{"leagues", "bronze.leagues", "/leagues", url.Values{"id": {league}}},
		{"teams", "bronze.teams", "/teams", url.Values{"league": {league}, "season": {season}}},
		{"fixtures", "bronze.fixtures", "/fixtures", url.Values{"league": {league}, "season": {season}}},
		{"standings", "bronze.standings", "/standings", url.Values{"league": {league}, "season": {season}}},
	}

	for _, j := range jobs {
		if err := ingest(ctx, client, pool, j.table, j.path, j.params); err != nil {
			log.Fatalf("ingesting %s: %v", j.name, err)
		}
	}

	// Bronze fully loaded → transform into Silver.
	if err := db.MergeSilver(ctx, pool); err != nil {
		log.Fatalf("merging silver: %v", err)
	}

	log.Println("ingestion + silver merge complete ✔")
}

func ingest(ctx context.Context, client *apifootball.Client, pool *pgxpool.Pool, table, path string, params url.Values) error {
	records, err := client.Get(ctx, path, params)
	if err != nil {
		return err
	}

	// Capture what request produced these rows, for the source_params column.
	sp := map[string]string{}
	for k := range params {
		sp[k] = params.Get(k)
	}

	for _, blob := range records {
		if err := db.InsertRaw(ctx, pool, table, sp, blob); err != nil {
			return err
		}
	}

	log.Printf("%-9s → %3d records landed in %s", path, len(records), table)
	return nil
}