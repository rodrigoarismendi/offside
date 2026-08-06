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
  - [Gold — star schema](#gold--star-schema)
  - [Gold — KPI marts](#gold--kpi-marts)
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
        M --> GG["MergeGold<br/>(embedded gold/*.sql:<br/>SCD2 dims → facts → aggregates)"]
    end
    subgraph PG["PostgreSQL 17"]
        B[("bronze<br/>raw jsonb")]
        S[("silver<br/>typed tables")]
        G[("gold<br/>star schema + KPI marts")]
    end
    API --> C
    L --> B
    B -. reads .-> M
    M -- "MERGE" --> S
    S -. reads .-> GG
    GG -- "load" --> G
    G --> BI["SQL analytics / BI"]
```

Schema (tables) is created by a separate **`cmd/migrate`** runner; **`cmd/ingest`** then fills and transforms the data.

| Layer      | Schema   | Responsibility                                                          | Built by                     |
| ---------- | -------- | ---------------------------------------------------------------------- | ---------------------------- |
| **Bronze** | `bronze` | Land API responses **as-is** as `jsonb`, append-only (audit trail)      | Go (`InsertRaw`)             |
| **Silver** | `silver` | Parse `jsonb` → typed columns, dedup, one row per business entity        | SQL `MERGE`, run by Go       |
| **Gold**   | `gold`   | Kimball star schema (dims + facts) **+ KPI aggregate marts**             | SQL, run by Go (`MergeGold`) |

**Why ELT (transform in SQL, not Go):** the raw layer is immutable and replayable, so the model can be rebuilt at any time without re-calling the API (which matters under the free-tier quota). Go stays a thin extractor and only *orchestrates* the transforms.

**How Silver & Gold are transformed:** transform logic lives as `.sql` files, **embedded into the binary** via `//go:embed`. `db.MergeSilver` runs `internal/db/silver/*.sql` (upserts); `db.MergeGold` runs `internal/db/gold/*.sql` in filename order — **SCD2 dimension loads → fact loads → aggregate rebuilds** — each in a **single transaction**, so every layer updates atomically and idempotently. Static dimensions (`dim_date`, `dim_league`) are seeded once in their migrations; SCD2 dimensions (`dim_team`, `dim_venue`), the facts, and the aggregates are (re)built on every run by `MergeGold`.

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
│   ├── migrate/                   # schema runner: `go run ./cmd/migrate`
│   │   └── main.go                #   applies pending db/migrations/*.sql, tracks state
│   └── ingest/                    # pipeline: `go run ./cmd/ingest`
│       └── main.go                #   config → pool → bronze → MergeSilver → MergeGold
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
│       └── gold/                  # dims → facts → aggregates (numeric prefix = run order)
│           ├── 10_dim_team.sql        #   SCD2 expire-then-insert
│           ├── 11_dim_venue.sql       #   SCD2 expire-then-insert
│           ├── 20_fact_fixture.sql    #   upsert, surrogate-key lookups
│           ├── 21_fact_standing.sql   #   upsert, snapshot fact
│           ├── 30_agg_team_season.sql #   full-refresh aggregate
│           ├── 31_agg_league_month.sql
│           └── 32_agg_venue_home.sql
├── db/
│   └── migrations/                # DDL only; numbered, lexical order == apply order
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
│       ├── 0200_gold_dim_date.sql      # gold.dim_date    (generated seed)
│       ├── 0201_gold_dim_league.sql    # gold.dim_league  (Type 1 seed)
│       ├── 0202_gold_dim_team.sql      # gold.dim_team    (SCD2 table + index)
│       ├── 0203_gold_dim_venue.sql     # gold.dim_venue   (SCD2 table + index)
│       ├── 0300_gold_fact_fixture.sql  # gold.fact_fixture
│       ├── 0301_gold_fact_standing.sql # gold.fact_standing
│       ├── 0400_gold_agg_team_season.sql
│       ├── 0401_gold_agg_league_month.sql
│       └── 0402_gold_agg_venue_home.sql
├── docker-compose.yml             # PostgreSQL 17
├── .env.example                   # config template (no secrets)
├── go.mod / go.sum
└── README.md
```

> **DDL vs. transform:** `db/migrations/*.sql` create *structure* (tables) and seed static dimensions — applied by `cmd/migrate`, which tracks what's been run in a `schema_migrations` table. The `internal/db/silver/*.sql` and `internal/db/gold/*.sql` files are the *transforms* (Silver upserts; Gold SCD2 loads, fact loads, aggregate rebuilds), embedded and run by `cmd/ingest` on every pipeline run.

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

**Dimensions and facts are built and loading.** Four conformed dimensions plus two facts, all populated by `MergeGold` (dimensions seeded via migrations for the static ones).

| Dimension    | Source                        | SCD strategy         |
| ------------ | ----------------------------- | -------------------- |
| `dim_date`   | generated (`generate_series`) | static seed          |
| `dim_league` | `silver.leagues`              | Type 1 (overwrite)   |
| `dim_team`   | `silver.teams`                | **Type 2** (history) |
| `dim_venue`  | `silver.venues`               | **Type 2** (history) |

| Fact            | Grain (one row = …)                                        | Type              | Source            |
| --------------- | ---------------------------------------------------------- | ----------------- | ----------------- |
| `fact_fixture`  | one match                                                  | Transaction       | `silver.fixtures` |
| `fact_standing` | one team's table position, per league-season, per snapshot | Periodic snapshot | `silver.standings`|

**Key patterns used**
- **Surrogate keys** (`*_key`, `generated always as identity`) on every dimension; source ids kept as natural/business keys. Facts fetch surrogate keys via **lookup joins** on the natural key.
- **SCD Type 2** on `dim_team` and `dim_venue`: `valid_from` / `valid_to` / `is_current` columns, a **partial unique index** (`… where is_current`) enforcing one current version per business key, and an **expire-then-insert** load.
- **`dim_date`** is generated (not sourced from the API), keyed by a smart `yyyymmdd` integer.
- **Role-playing dimension:** `dim_team` is referenced twice by `fact_fixture` (`home_team_key`, `away_team_key`).
- **Degenerate dimension:** `fixture_id` / `status` sit directly on `fact_fixture`; `fact_standing` carries `season` as a degenerate.
- **Fact constellation:** both facts share the conformed dimensions (`dim_date`, `dim_league`, `dim_team`); they relate to each other only *through* those dimensions (drill-across), never by a fact-to-fact key.

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
        int      season             "degenerate"
        text     status_short       "degenerate dim"
        int      goals_home         "measure"
        int      goals_away         "measure"
        int      goals_total        "measure (derived)"
        smallint result             "measure: 1 home / 0 draw / -1 away"
    }
    fact_standing {
        int      standing_key       PK "surrogate"
        int      snapshot_date_key  FK
        int      league_key         FK
        int      team_key           FK
        int      season             "degenerate (grain)"
        int      rank                  "measure"
        int      points                "measure"
        int      played                "measure"
        smallint won                   "measure"
        smallint draw                  "measure"
        smallint lost                  "measure"
        int      goals_for             "measure"
        int      goals_against         "measure"
        int      goal_diff             "measure"
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

> Status: full star schema **built and loaded** (league 39 / season 2023) — dims `dim_date` (~5.8k days), `dim_league` (1), `dim_team` (20, SCD2), `dim_venue` (20, SCD2); facts `fact_fixture` (380) and `fact_standing` (20).

### Gold — KPI marts

Pre-computed **aggregate tables** built on top of the facts (rebuilt each run by `MergeGold`, *after* the facts). Each is a full-refresh (`truncate` + `insert`) summary at its own grain — the standard pattern for cheap, fully-derived rollups.

| Aggregate            | Grain           | KPIs                                                                   | Built from                        |
| -------------------- | --------------- | --------------------------------------------------------------------- | --------------------------------- |
| `agg_team_season`    | team × season   | played, W/D/L, GF, GA, GD, points, points/game, clean sheets, final rank | `fact_fixture` **+** `fact_standing` |
| `agg_league_month`   | league × month  | matches, total goals, goals/match, home-/draw-/away-win %             | `fact_fixture` + `dim_date`       |
| `agg_venue_home`     | venue × season  | home matches, home goals, home goals/match, home wins, home-win %     | `fact_fixture` + `dim_venue`      |

`agg_team_season` reconciles the two facts through their shared conformed dimensions (a **drill-across**): fixture-derived points vs. the official standings rank — a built-in data-quality check.

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

4. **Run migrations** — one command applies every `db/migrations/*.sql` (all Bronze, Silver, and Gold tables) and records what it ran:

   ```bash
   go mod tidy
   go run ./cmd/migrate
   ```

   Idempotent — re-run anytime; only unapplied migrations execute. See [Database migrations](#database-migrations) for how it works.

5. **Ingest + transform**

   ```bash
   go run ./cmd/ingest
   ```

   This loads Bronze from the API, runs `MergeSilver` (upsert Silver), then `MergeGold` (SCD2 dimensions → facts → aggregates). Expected tail: `gold merge complete ✔`.

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

Plain **DDL** files under `db/migrations/`, numbered so that lexical order equals apply order (`0001` schemas, `000x` bronze, `01xx` silver, `02xx` gold dims, `03xx` facts, `04xx` aggregates). They create *structure only* (a few also seed static dimensions); the **transform** logic lives separately in `internal/db/silver/*.sql` and `internal/db/gold/*.sql`, run by `cmd/ingest` (see [Ingestion](#ingestion)).

Apply them all with the runner:

```bash
go run ./cmd/migrate
```

**How it works:** `cmd/migrate` reads every `db/migrations/*.sql` in sorted order, and for each one not yet recorded in a `schema_migrations` tracking table, executes it **and** records it in a single transaction. So a migration is either fully applied *and* logged or neither — and re-running only applies new files (`no new migrations — database up to date ✔`). This is the same model as tools like goose / golang-migrate / Flyway.

> Migrations that seed data (`0200_gold_dim_date`, `0201_gold_dim_league`) use `on conflict … do nothing`, and DDL uses `create table if not exists`, so every migration is **idempotent** — required, since the runner may replay them.

Inspect:

```bash
docker exec -it offside_db psql -U offside -d offside -c "\dt bronze.*" -c "\dt silver.*" -c "\dt gold.*"
```

*(Run `cmd/migrate` from the project root — it reads `db/migrations` as a relative path.)*

---

## Ingestion

The `ingest` command runs the whole pipeline:

1. **Load config** and open a `pgxpool` connection.
2. **Extract + Load (Bronze):** for each endpoint, call the API, validate the `errors` array, split `response[]` into records, and insert each as one `jsonb` row into the matching `bronze.*` table (with `source_params`, `source`, `loaded_at`, and an `md5` `record_hash`).
3. **Transform (Silver):** `db.MergeSilver` runs every embedded `internal/db/silver/*.sql` `MERGE` in a single transaction, upserting Bronze `jsonb` into typed Silver tables.
4. **Model (Gold):** `db.MergeGold` runs every embedded `internal/db/gold/*.sql` (in filename order) in a single transaction: **SCD2 dimension loads** (`dim_team`, `dim_venue` — expire changed rows, insert new versions) → **fact loads** (`fact_fixture`, `fact_standing` — surrogate-key lookup + upsert) → **aggregate rebuilds** (`agg_*` — `truncate` + `insert`).

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
- [x] Gold facts: `fact_fixture` (transaction), `fact_standing` (snapshot)
- [x] Gold KPI marts: `agg_team_season`, `agg_league_month`, `agg_venue_home`
- [x] `cmd/migrate` runner with `schema_migrations` tracking
- [ ] Attendance source → `fact_fixture.attendance` (new Bronze source, key conforming)
- [ ] Widen scope: more leagues / seasons

---

## License

See [LICENSE](LICENSE).
