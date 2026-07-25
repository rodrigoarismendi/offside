package main

import (
	"fmt"
	"log"

	"offside/internal/config"
)

func main() {
	cfg, err := config.Load()
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println("loaded:", cfg)
	fmt.Println("key length:", len(cfg.APIKey)) // proves the key loaded, without printing it
}