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
    subgraph GO["Go — Extract + Load (thin)"]
        C["apifootball client"] --> L["db insert helpers"]
    end
    subgraph PG["PostgreSQL 17"]
        B[("bronze<br/>raw jsonb")]
        S[("silver<br/>typed & clean")]
        G[("gold<br/>star schema")]
    end
    API --> C
    L --> B
    B -- "SQL" --> S
    S -- "SQL" --> G
    G --> BI["SQL analytics / BI"]
```

| Layer      | Schema   | Responsibility                                                        | Built by |
| ---------- | -------- | --------------------------------------------------------------------- | -------- |
| **Bronze** | `bronze` | Land API responses **as-is** as `jsonb`, append-only (audit trail)    | Go       |
| **Silver** | `silver` | Parse `jsonb` → typed columns, dedup, one row per business entity      | SQL      |
| **Gold**   | `gold`   | Kimball star schema: conformed dimensions + fact tables               | SQL      |

**Why ELT (transform in SQL, not Go):** the raw layer is immutable and replayable, so the model can be rebuilt at any time without re-calling the API (which matters under the free-tier quota). Go stays a thin, robust extractor.

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
│   └── ingest/            # main entry point: `go run ./cmd/ingest`
│       └── main.go
├── internal/
│   ├── apifootball/       # HTTP client + envelope decoding → []json.RawMessage
│   ├── config/            # .env → typed Config (fail-fast on missing secrets)
│   └── db/                # pgxpool setup + raw-insert helpers
├── db/
│   └── migrations/        # numbered SQL; sort order == pipeline order
│       ├── 0001_schemas.sql        # bronze / silver / gold
│       ├── 0002_bronze_leagues.sql    # bronze.leagues
│       └── 0003_bronze_teams.sql      # bronze.teams
├── docker-compose.yml     # PostgreSQL 17
├── .env.example           # config template (no secrets)
├── go.mod / go.sum
└── README.md
```

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

> Status: `bronze.leagues` and `bronze.teams` exist; `bronze.fixtures` and `bronze.standings` are planned.

### Silver — cleaned & typed

One row per business entity, keyed by the **source (natural) key**, produced by SQL over the Bronze `jsonb`. Note that some entities are extracted from **nested** structures of a single Bronze table (e.g. `venues` and `countries` fall out of `bronze.teams` / `bronze.leagues`).

```mermaid
erDiagram
    silver_leagues {
        int  league_id    PK
        text name
        text type
        text country_name
        text country_code
        text logo_url
    }
    silver_seasons {
        int     league_id  PK,FK
        int     season     PK
        date    start_date
        date    end_date
        boolean is_current
    }
    silver_teams {
        int     team_id   PK
        text    name
        text    code
        text    country
        int     founded
        boolean national
        text    logo_url
    }
    silver_venues {
        int  venue_id  PK
        text name
        text city
        int  capacity
        text surface
    }
    silver_fixtures {
        int         fixture_id     PK
        int         league_id      FK
        int         season
        timestamptz kickoff_utc
        text        status
        int         home_team_id   FK
        int         away_team_id   FK
        int         venue_id       FK
        int         goals_home
        int         goals_away
    }
    silver_standings {
        int         league_id      PK,FK
        int         season         PK
        int         team_id        PK,FK
        timestamptz snapshot_at    PK
        int         rank
        int         points
        int         played
        int         win
        int         draw
        int         lose
        int         goals_for
        int         goals_against
    }

    silver_leagues   ||--o{ silver_seasons   : "has"
    silver_leagues   ||--o{ silver_fixtures  : "hosts"
    silver_teams     ||--o{ silver_fixtures  : "home"
    silver_teams     ||--o{ silver_fixtures  : "away"
    silver_venues    ||--o{ silver_fixtures  : "at"
    silver_leagues   ||--o{ silver_standings : "ranks in"
    silver_teams     ||--o{ silver_standings : "positioned"
```

### Gold — star schema (proposed target)

> **This is a design blueprint, not implemented DDL.** Implementing and refining it (exact measures, SCD types, edge cases) is the modeling exercise. Adjust freely.

**Facts**

| Fact            | Grain (one row = …)                               | Type               |
| --------------- | ------------------------------------------------- | ------------------ |
| `fact_fixture`  | one match                                         | Transaction        |
| `fact_standing` | one team's table position, per league-season, per snapshot | Periodic snapshot  |

**Key patterns used**
- **Surrogate keys** (`*_key`) on every dimension; source ids kept as natural/business keys.
- **Role-playing dimension:** `dim_team` referenced twice by `fact_fixture` (`home_team_key`, `away_team_key`).
- **Degenerate dimension:** `fixture_id` and `status` stored directly on `fact_fixture`.
- **`dim_date`** is generated (not sourced from the API).
- **SCD** applied to `dim_team` (e.g. Type 2 for transfers / attribute changes).

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
        int     day_of_week
        text    day_name
        boolean is_weekend
        text    season_label
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
        int  venue_key   PK "surrogate"
        int  venue_id       "natural key"
        text name
        text city
        int  capacity
        text surface
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

4. **Run migrations** (see [Database migrations](#database-migrations) for details)

   ```bash
   docker exec -i offside_db psql -U offside -d offside < db/migrations/0001_schemas.sql
   docker exec -i offside_db psql -U offside -d offside < db/migrations/0002_bronze_leagues.sql
   docker exec -i offside_db psql -U offside -d offside < db/migrations/0003_bronze_teams.sql
   ```

5. **Ingest**

   ```bash
   go mod tidy
   go run ./cmd/ingest
   ```

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

Plain SQL files under `db/migrations/`, numbered so that lexical order equals pipeline order (`00xx` bronze, then silver, then gold). Apply against the running container:

```bash
docker exec -i offside_db psql -U offside -d offside < db/migrations/0001_schemas.sql
docker exec -i offside_db psql -U offside -d offside < db/migrations/0002_bronze_leagues.sql
docker exec -i offside_db psql -U offside -d offside < db/migrations/0003_bronze_teams.sql
```

Inspect:

```bash
docker exec -it offside_db psql -U offside -d offside -c "\dn" -c "\dt bronze.*"
```

---

## Ingestion

The `ingest` command loads config, opens a `pgxpool` connection, calls the configured API-Football endpoints, validates the `errors` array, splits `response[]` into individual records, and inserts each as one `jsonb` row into the matching `bronze.*` table (with `source_params`, `source`, `loaded_at`, and an `md5` `record_hash`).

```bash
go run ./cmd/ingest
```

---

## Roadmap & status

- [x] Docker PostgreSQL + Go module + config loader
- [x] `pgxpool` connectivity
- [x] Medallion schemas (`bronze` / `silver` / `gold`)
- [x] Bronze tables: `leagues`, `teams`
- [ ] Bronze tables: `fixtures`, `standings`
- [ ] `apifootball` client + `db` insert helpers (fill Bronze)
- [ ] Silver: JSON → typed, deduped tables
- [ ] Gold: `dim_date`, dimensions, `fact_fixture`, `fact_standing`
- [ ] Widen scope: more leagues / seasons

---

## License

See [LICENSE](LICENSE).
