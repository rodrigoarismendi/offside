package main

import (
	"context"
	"fmt"
	"log"

	"offside/internal/config"
	"offside/internal/db"
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

	fmt.Println("connected to Postgres ✔")
}