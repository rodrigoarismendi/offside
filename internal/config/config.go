package config

import (
	"fmt"
	"os"

	"github.com/joho/godotenv"
)

type Config struct {
	APIKey      string // API_FOOTBALL_KEY
	APIHost     string // API_FOOTBALL_HOST
	DatabaseURL string // DATABASE_URL
}

func Load() (Config, error) {
	// Loads .env into the process env if present. Missing file is fine
	// (in prod you'd set real env vars), so we ignore that specific error.
	_ = godotenv.Load()

	c := Config{
		APIKey:      os.Getenv("API_FOOTBALL_KEY"),
		APIHost:     os.Getenv("API_FOOTBALL_HOST"),
		DatabaseURL: os.Getenv("DATABASE_URL"),
	}

	// Fail fast: a missing secret should stop the program with a clear message,
	// not surface later as a confusing 401 or connection error.
	if c.APIKey == "" {
		return Config{}, fmt.Errorf("API_FOOTBALL_KEY is not set")
	}
	if c.DatabaseURL == "" {
		return Config{}, fmt.Errorf("DATABASE_URL is not set")
	}
	if c.APIHost == "" {
		c.APIHost = "v3.football.api-sports.io" // sensible default
	}
	return c, nil
}

func (c Config) String() string {
	return fmt.Sprintf("Config{APIHost:%s, DatabaseURL:%s, APIKey:***}", c.APIHost, c.DatabaseURL)
}