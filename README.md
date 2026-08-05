# offside

> A local data-engineering project that ingests football data from **API-Football (v3)** into **PostgreSQL** using a thin **Go** loader, then models it into a **Kimball star schema** following a **medallion (Bronze / Silver / Gold)** architecture.

The project is a hands-on study of **dimensional modeling**. Extraction and loading are automated in Go; **all transformation and modeling is done in SQL (ELT)**.

---

## Table of contents

- [Objectives](#objectives)
- [Tech stack](#tech-stack)
- [Architecture](#architecture)
- [Data source — API-Football](#data-source--api-football)
- [Repository layout](#repository-layout)
- [Data model](#data-model)
  - [Bronze — raw landing](#bronze--raw-landing)
  - [Silver — cleaned & typed](#silver--cleaned--typed)
  - [Gold — star schema (proposed target)](#gold--star-schema-proposed-target)
- [Getting started](#getting-started)
- [Configuration](#configuration)
- [Database migrations](#database-migrations)
- [Ingestion](#ingestion)
- [Roadmap & status](#roadmap--status)
- [License](#license)

---

## Objectives

- Practice **Kimball-style dimensional modeling**: grain definition, surrogate keys, conformed dimensions, role-playing dimensions, transaction vs. periodic-snapshot facts, and slowly changing dimensions (SCD).
- Build a realistic **ELT pipeline**: land immutable raw data, then transform in the database.
- Keep the extractor (**Go**) decoupled from the model (**SQL**) so that model changes never require re-ingestion.

> **Scope:** Kimball star schema only. Data Vault 2.0 is intentionally out of scope for this project.

---

## Tech stack

| Concern        | Choice                                             |
| -------------- | -------------------------------------------------- |
| Language       | Go 1.26.x                                          |
| Database       | PostgreSQL 17 (Docker)                             |
| DB driver/pool | `github.com/jackc/pgx/v5` + `pgxpool`              |
| Config         | `github.com/joho/godotenv` (`.env`)                |
| Source API     | API-Football v3 (`v3.football.api-sports.io`)      |
| Transform      | SQL (in-database, ELT)                             |

---

## Architecture

Data flows left→right; each layer has a single responsibility. **Go only ever writes to Bronze**; every layer after that is pure SQL.

```mermaid
flowchart LR
    API["API-Football v3<br/>(REST / JSON)"]
    subgraph GO["Go (cmd/ingest)"]
        C["apifootball client"] --> L["bronze insert"]
        L --> M["MergeSilver<br/>(embedded silver/*.sql)"]
        M --> GG["MergeGold<br/>(embedded gold/*.sql, SCD2)"]
    end
    subgraph PG["PostgreSQL 17"]
        B[("bronze<br/>raw jsonb")]
        S[("silver<br/>typed tables")]
        G[("gold<br/>star schema")]
    end
    API --> C
    L --> B
    B -. reads .-> M
    M -- "MERGE" --> S
    S -. reads .-> GG
    GG -- "SCD2 load" --> G
    G --> BI["SQL analytics / BI"]
```

| Layer      | Schema   | Responsibility                                                        | Built by                |
| ---------- | -------- | --------------------------------------------------------------------- | ----------------------- |
| **Bronze** | `bronze` | Land API responses **as-is** as `jsonb`, append-only (audit trail)    | Go (`InsertRaw`)        |
| **Silver** | `silver` | Parse `jsonb` → typed columns, dedup, one row per business entity      | SQL `MERGE`, run by Go  |
| **Gold**   | `gold`   | Kimball star schema: conformed dimensions (+ facts, planned)          | SQL, run by Go (`MergeGold`) |

**Why ELT (transform in SQL, not Go):** the raw layer is immutable and replayable, so the model can be rebuilt at any time without re-calling the API (which matters under the free-tier quota). Go stays a thin extractor and only *orchestrates* the transforms.

**How Silver & Gold are transformed:** transform logic lives as `.sql` files, **embedded into the binary** via `//go:embed`. `db.MergeSilver` runs `internal/db/silver/*.sql` (upserts) and `db.MergeGold` runs `internal/db/gold/*.sql` (SCD2 dimension loads) — each in a **single transaction**, so every layer updates atomically and idempotently. Static dimensions (`dim_date`, `dim_league`) are seeded once in their migrations; the SCD2 dimensions (`dim_team`, `dim_venue`) are re-loaded on every run by `MergeGold`.

---

## Data source — API-Football

Direct host `v3.football.api-sports.io`, authenticated with the `x-apisports-key` header.

### Envelope

Every endpoint returns the same wrapper; the payload is always in the `response` **array**:

```jsonc
{
  "get": "teams",
  "parameters": { "league": "39", "season": "2023" },
  "errors": [],            // non-empty means failure — even on HTTP 200
  "results": 20,
  "paging": { "current": 1, "total": 1 },
  "response": [ /* one object per entity */ ]
}
```

> ⚠️ `errors` can be non-empty **with HTTP 200**, so the loader validates it explicitly.

### Endpoints ingested

| Endpoint     | Bronze table       | Feeds (Gold)                                    | Req. per league-season |
| ------------ | ------------------ | ----------------------------------------------- | ---------------------- |
| `/leagues`   | `bronze.leagues`   | `dim_league`, `dim_date` context, `dim_country` | 1                      |
| `/teams`     | `bronze.teams`     | `dim_team`, `dim_venue`                          | 1                      |
| `/fixtures`  | `bronze.fixtures`  | **`fact_fixture`**                              | 1 (~380 rows)          |
| `/standings` | `bronze.standings` | `fact_standing`                                 | 1                      |

**Free-tier limits:** 100 requests/day; historical coverage limited to seasons **≤ 2023**. Querying newer seasons returns an empty `response`. Initial scope: **league `39` (Premier League), season `2023`** — 4 requests total.

---

## Repository layout

```
offside/
├── cmd/
│   └── ingest/                    # main entry point: `go run ./cmd/ingest`
│       └── main.go                #   config → pool → load bronze → MergeSilver
├── internal/
│   ├── apifootball/
│   │   └── client.go              # HTTP client + envelope decode → []json.RawMessage
│   ├── config/
│   │   └── config.go              # .env → typed Config (fail-fast on missing secrets)
│   └── db/
│       ├── db.go                  # pgxpool setup + Ping
│       ├── raw.go                 # InsertRaw → bronze.* (whitelisted tables)
│       ├── silver.go              # //go:embed silver/*.sql + MergeSilver (one tx)
│       ├── silver/                # one MERGE (upsert) per entity, embedded in binary
│       │   ├── teams.sql
│       │   ├── venues.sql
│       │   ├── leagues.sql
│       │   ├── seasons.sql
│       │   ├── fixtures.sql
│       │   └── standings.sql
│       ├── gold.go                # //go:embed gold/*.sql + MergeGold (one tx)
│       └── gold/                  # SCD2 dimension loads, embedded in binary
│           ├── dim_team.sql       #   expire-then-insert (Type 2)
│           └── dim_venue.sql      #   expire-then-insert (Type 2)
├── db/
│   └── migrations/                # DDL only; numbered, lexical order == pipeline order
│       ├── 0001_schemas.sql            # bronze / silver / gold schemas
│       ├── 0002_bronze_leagues.sql     # bronze.leagues
│       ├── 0003_bronze_teams.sql       # bronze.teams
│       ├── 0004_bronze_fixtures.sql    # bronze.fixtures
│       ├── 0005_bronze_standings.sql   # bronze.standings
│       ├── 0100_silver_teams.sql       # silver.teams
│       ├── 0101_silver_venues.sql      # silver.venues
│       ├── 0102_silver_leagues.sql     # silver.leagues
│       ├── 0103_silver_seasons.sql     # silver.seasons
│       ├── 0104_silver_fixtures.sql    # silver.fixtures
│       ├── 0105_silver_standings.sql   # silver.standings
│       ├── 0200_gold_dim_date.sql      # gold.dim_date   (generated seed)
│       ├── 0201_gold_dim_league.sql    # gold.dim_league (Type 1)
│       ├── 0202_gold_dim_team.sql      # gold.dim_team   (SCD2 table + index)
│       └── 0203_gold_dim_venue.sql     # gold.dim_venue  (SCD2 table + index)
├── docker-compose.yml             # PostgreSQL 17
├── .env.example                   # config template (no secrets)
├── go.mod / go.sum
└── README.md
```

> **DDL vs. transform:** `db/migrations/*.sql` create *structure* (tables) and seed static dimensions, applied once via `psql`. The `internal/db/silver/*.sql` and `internal/db/gold/*.sql` files are the *transforms* (Silver upserts, Gold SCD2 loads), embedded and run by Go on every pipeline run.

---

## Data model

Legend for the diagrams below: **PK** = primary key, **FK** = foreign key. Mermaid entity names use `_` where the physical name uses a schema-qualified dot (e.g. `bronze_leagues` ⇒ `bronze.leagues`).

### Bronze — raw landing

Every Bronze table is **structurally identical** — the raw layer models nothing, it only captures. Differences between entities appear later, in Silver.

```mermaid
erDiagram
    bronze_leagues {
        bigint      id            PK "identity surrogate for this raw row"
        jsonb       payload          "one entity record, exactly as returned"
        jsonb       source_params    "request params, e.g. {league:39,season:2023}"
        text        source           "originating endpoint"
        timestamptz loaded_at        "load timestamp (default now())"
        text        record_hash      "md5(payload::text) — dedup handle"
    }
    bronze_teams {
        bigint      id            PK
        jsonb       payload
        jsonb       source_params
        text        source
        timestamptz loaded_at
        text        record_hash
    }
    bronze_fixtures {
        bigint      id            PK
        jsonb       payload
        jsonb       source_params
        text        source
        timestamptz loaded_at
        text        record_hash
    }
    bronze_standings {
        bigint      id            PK
        jsonb       payload
        jsonb       source_params
        text        source
        timestamptz loaded_at
        text        record_hash
    }
```

> Status: all four Bronze tables (`bronze.leagues`, `bronze.teams`, `bronze.fixtures`, `bronze.standings`) exist.

### Silver — cleaned & typed

Persisted **tables**, one row per business entity, keyed by the **source (natural) key** and kept in sync by an idempotent `MERGE` over the Bronze `jsonb`. Some entities are extracted from **nested** structures of a single Bronze table (e.g. `venues` from `bronze.teams`; `seasons` explode out of the nested `seasons[]` array in `bronze.leagues`; `standings` explode from a nested array-of-arrays in `bronze.standings`).

```mermaid
erDiagram
    silver_leagues {
        int  league_id    PK
        text league_name
        text type
        text country_name
        text country_code
        text logo
        text flag
        timestamptz loaded_at
    }
    silver_seasons {
        int     league_id   PK,FK
        int     year        PK
        date    start_date
        date    end_date
        boolean current
        boolean odds
        boolean players
        boolean standings
        boolean predictions
        timestamptz loaded_at
    }
    silver_teams {
        int     team_id   PK
        text    name
        text    code
        text    country
        int     founded
        boolean national
        text    logo_url
        timestamptz loaded_at
    }
    silver_venues {
        int  team_id    PK,FK
        int  venue_id   PK
        text venue_name
        text city
        text address
        text surface
        text image
        bigint capacity
        timestamptz loaded_at
    }
    silver_fixtures {
        int         fixture_id     PK
        int         league_id      FK
        int         season
        text        round
        timestamptz kickoff
        text        status_short
        int         status_elapsed
        text        referee
        int         venue_id       FK
        int         home_team_id   FK
        int         away_team_id   FK
        boolean     home_winner
        boolean     away_winner
        int         goals_home
        int         goals_away
        int         ht_home
        int         ht_away
        timestamptz loaded_at
    }
    silver_standings {
        int  league_id      PK,FK
        int  season         PK
        int  team_id        PK,FK
        text team_name
        int  rank
        int  points
        int  goals_diff
        text form
        int  played
        int  win
        int  draw
        int  lose
        int  goals_for
        int  goals_against
        timestamptz loaded_at
    }

    silver_leagues   ||--o{ silver_seasons   : "has"
    silver_leagues   ||--o{ silver_fixtures  : "hosts"
    silver_teams     ||--o{ silver_fixtures  : "home"
    silver_teams     ||--o{ silver_fixtures  : "away"
    silver_teams     ||--o{ silver_venues    : "plays at"
    silver_leagues   ||--o{ silver_standings : "ranks in"
    silver_teams     ||--o{ silver_standings : "positioned"
```

> Status: all six Silver tables built and populated (league 39 / season 2023): teams 20 · venues 20 · leagues 1 · seasons 17 · fixtures 380 · standings 20. Diagrams show representative columns — `silver.fixtures` also carries full-/extra-time and penalty score breakdowns, and `silver.seasons` carries the complete API `coverage` flag set.

### Gold — star schema

**Dimensions are built; facts are the next step.** The four conformed dimensions below exist and load automatically — `dim_date` / `dim_league` are seeded in their migrations, while `dim_team` / `dim_venue` are **SCD2** and re-loaded on every run by `MergeGold`. `fact_fixture` and `fact_standing` are shown as the design target (not yet implemented).

| Dimension    | Source                        | SCD strategy         |
| ------------ | ----------------------------- | -------------------- |
| `dim_date`   | generated (`generate_series`) | static seed          |
| `dim_league` | `silver.leagues`              | Type 1 (overwrite)   |
| `dim_team`   | `silver.teams`                | **Type 2** (history) |
| `dim_venue`  | `silver.venues`               | **Type 2** (history) |

| Fact (planned)  | Grain (one row = …)                                        | Type              |
| --------------- | ---------------------------------------------------------- | ----------------- |
| `fact_fixture`  | one match                                                  | Transaction       |
| `fact_standing` | one team's table position, per league-season, per snapshot | Periodic snapshot |

**Key patterns used**
- **Surrogate keys** (`*_key`, `generated always as identity`) on every dimension; source ids kept as natural/business keys.
- **SCD Type 2** on `dim_team` and `dim_venue`: `valid_from` / `valid_to` / `is_current` columns, a **partial unique index** (`… where is_current`) enforcing one current version per business key, and an **expire-then-insert** load.
- **`dim_date`** is generated (not sourced from the API), keyed by a smart `yyyymmdd` integer.
- **Role-playing dimension:** `dim_team` will be referenced twice by `fact_fixture` (`home_team_key`, `away_team_key`).
- **Degenerate dimension:** `fixture_id` / `status` planned to sit directly on `fact_fixture`.

```mermaid
erDiagram
    dim_date {
        int     date_key     PK "yyyymmdd"
        date    full_date
        int     year
        int     quarter
        int     month
        text    month_name
        int     day
        int     day_of_week "ISO 1=Mon..7=Sun"
        text    day_name
        int     week
        boolean is_weekend
        int     season_year "football season start year"
    }
    dim_league {
        int  league_key   PK "surrogate"
        int  league_id       "natural key"
        text name
        text type
        text country_name
        text country_code
        text logo_url
    }
    dim_team {
        int     team_key    PK "surrogate"
        int     team_id        "natural key"
        text    name
        text    code
        text    country
        int     founded
        boolean national
        text    logo_url
        date    valid_from     "SCD2"
        date    valid_to       "SCD2"
        boolean is_current     "SCD2"
    }
    dim_venue {
        int     venue_key   PK "surrogate"
        int     venue_id       "natural key (repeats per version)"
        text    name
        text    city
        text    address
        text    surface
        text    image
        bigint  capacity
        date    valid_from     "SCD2"
        date    valid_to       "SCD2"
        boolean is_current     "SCD2"
    }
    fact_fixture {
        int      fixture_id      PK "degenerate natural key"
        int      date_key        FK
        int      league_key      FK
        int      home_team_key   FK "role-playing"
        int      away_team_key   FK "role-playing"
        int      venue_key       FK
        text     status             "degenerate dim"
        int      goals_home         "measure"
        int      goals_away         "measure"
        int      goals_total        "measure (derived)"
        smallint result             "measure: 1 home / 0 draw / -1 away"
    }
    fact_standing {
        int standing_key       PK "surrogate"
        int snapshot_date_key  FK
        int league_key         FK
        int team_key           FK
        int rank                  "measure"
        int points                "measure"
        int played                "measure"
        int won                   "measure"
        int drawn                 "measure"
        int lost                  "measure"
        int goals_for             "measure"
        int goals_against         "measure"
        int goal_diff             "measure"
    }

    dim_date   ||--o{ fact_fixture  : "date_key"
    dim_league ||--o{ fact_fixture  : "league_key"
    dim_team   ||--o{ fact_fixture  : "home_team_key"
    dim_team   ||--o{ fact_fixture  : "away_team_key"
    dim_venue  ||--o{ fact_fixture  : "venue_key"
    dim_date   ||--o{ fact_standing : "snapshot_date_key"
    dim_league ||--o{ fact_standing : "league_key"
    dim_team   ||--o{ fact_standing : "team_key"
```

> Status: all four **dimensions built and loaded** — `dim_date` (~5.8k days), `dim_league` (1), `dim_team` (20, SCD2), `dim_venue` (20, SCD2). `fact_fixture` and `fact_standing` are the next milestone.

---

## Getting started

### Prerequisites

- Docker + Docker Compose
- Go 1.26+
- An API-Football key (free tier is sufficient)

### Steps

1. **Clone the repository**

   ```bash
   git clone https://github.com/rodrigoarismendi/offside.git
   cd offside
   ```

2. **Configure**

   ```bash
   cp .env.example .env
   # edit .env and paste your real API-Football key
   ```

3. **Start PostgreSQL**

   ```bash
   docker compose up -d
   docker compose ps          # expect: offside_db ... Up
   ```

4. **Run migrations** — creates all Bronze and Silver tables (see [Database migrations](#database-migrations) for details)

   ```bash
   for f in db/migrations/*.sql; do
     docker exec -i offside_db psql -U offside -d offside < "$f"
   done
   ```

   > On Windows CMD (no `for`-glob), apply each `db/migrations/*.sql` file in order — see the [Database migrations](#database-migrations) section for the explicit list.

5. **Ingest + transform**

   ```bash
   go mod tidy
   go run ./cmd/ingest
   ```

   This loads Bronze from the API, runs `MergeSilver` (upsert Silver), then `MergeGold` (SCD2 dimension loads). Expected tail: `gold merge complete ✔`.

---

## Configuration

Environment variables (loaded from `.env`, which is git-ignored):

| Variable            | Example                                                          | Description                     |
| ------------------- | ---------------------------------------------------------------- | ------------------------------- |
| `API_FOOTBALL_KEY`  | `••••••••`                                                        | API-Football key (**secret**)   |
| `API_FOOTBALL_HOST` | `v3.football.api-sports.io`                                      | API host                        |
| `DATABASE_URL`      | `postgres://offside:offside@localhost:5432/offside?sslmode=disable` | PostgreSQL connection string |

> **Never commit `.env`.** Only `.env.example` (no real values) is tracked.

---

## Database migrations

Plain **DDL** files under `db/migrations/`, numbered so that lexical order equals pipeline order (`0001` schemas, `000x` bronze, `01xx` silver). These create *structure only*; the Silver **transform** logic lives separately in `internal/db/silver/*.sql` and is run by Go (see [Ingestion](#ingestion)). Apply against the running container:

```bash
docker exec -i offside_db psql -U offside -d offside < db/migrations/0001_schemas.sql
docker exec -i offside_db psql -U offside -d offside < db/migrations/0002_bronze_leagues.sql
docker exec -i offside_db psql -U offside -d offside < db/migrations/0003_bronze_teams.sql
docker exec -i offside_db psql -U offside -d offside < db/migrations/0004_bronze_fixtures.sql
docker exec -i offside_db psql -U offside -d offside < db/migrations/0005_bronze_standings.sql
docker exec -i offside_db psql -U offside -d offside < db/migrations/0100_silver_teams.sql
docker exec -i offside_db psql -U offside -d offside < db/migrations/0101_silver_venues.sql
docker exec -i offside_db psql -U offside -d offside < db/migrations/0102_silver_leagues.sql
docker exec -i offside_db psql -U offside -d offside < db/migrations/0103_silver_seasons.sql
docker exec -i offside_db psql -U offside -d offside < db/migrations/0104_silver_fixtures.sql
docker exec -i offside_db psql -U offside -d offside < db/migrations/0105_silver_standings.sql
docker exec -i offside_db psql -U offside -d offside < db/migrations/0200_gold_dim_date.sql
docker exec -i offside_db psql -U offside -d offside < db/migrations/0201_gold_dim_league.sql
docker exec -i offside_db psql -U offside -d offside < db/migrations/0202_gold_dim_team.sql
docker exec -i offside_db psql -U offside -d offside < db/migrations/0203_gold_dim_venue.sql
```

> `0200_gold_dim_date.sql` and `0201_gold_dim_league.sql` also **seed** their tables (generated calendar / league row); the SCD2 dimensions (`dim_team`, `dim_venue`) are created empty here and populated by `MergeGold` during ingestion.

Inspect:

```bash
docker exec -it offside_db psql -U offside -d offside -c "\dn" -c "\dt bronze.*" -c "\dt silver.*" -c "\dt gold.*"
```

---

## Ingestion

The `ingest` command runs the whole pipeline:

1. **Load config** and open a `pgxpool` connection.
2. **Extract + Load (Bronze):** for each endpoint, call the API, validate the `errors` array, split `response[]` into records, and insert each as one `jsonb` row into the matching `bronze.*` table (with `source_params`, `source`, `loaded_at`, and an `md5` `record_hash`).
3. **Transform (Silver):** `db.MergeSilver` runs every embedded `internal/db/silver/*.sql` `MERGE` in a single transaction, upserting Bronze `jsonb` into typed Silver tables.
4. **Model (Gold):** `db.MergeGold` runs every embedded `internal/db/gold/*.sql` in a single transaction — the **SCD2 loads** (`dim_team`, `dim_venue`): expire changed current rows, then insert new versions.

```bash
go run ./cmd/ingest
```

Expected tail: `gold merge complete ✔`. Because Bronze is append-only, Silver is a keyed `MERGE`, and the Gold SCD2 loads only create a new version when an attribute actually changes, the command is **idempotent** — re-running grows Bronze (audit history) but leaves Silver and Gold row counts unchanged unless source values drift. Scope (league, season) is set by constants in `cmd/ingest/main.go`.

---

## Roadmap & status

- [x] Docker PostgreSQL + Go module + config loader
- [x] `pgxpool` connectivity
- [x] Medallion schemas (`bronze` / `silver` / `gold`)
- [x] Bronze tables: `leagues`, `teams`, `fixtures`, `standings`
- [x] `apifootball` client + `InsertRaw` (fill Bronze)
- [x] Silver: JSON → typed, deduped tables via Go-orchestrated `MERGE` (all 6 entities)
- [x] Gold dimensions: `dim_date` (seed), `dim_league` (Type 1), `dim_team` + `dim_venue` (SCD2), via `MergeGold`
- [ ] Gold facts: `fact_fixture`, `fact_standing`
- [ ] Widen scope: more leagues / seasons

---

## License

See [LICENSE](LICENSE).
