create table if not exists gold.fact_standing (
    standing_key       int generated always as identity primary key,   -- surrogate
    snapshot_date_key  int not null references gold.dim_date(date_key),
    league_key         int not null references gold.dim_league(league_key),
    team_key           int not null references gold.dim_team(team_key),
    season             int not null,                                   -- degenerate (part of grain)
    rank               int,
    points             int,
    played             int,
    won                smallint,
    draw               smallint,
    lost               smallint,
    goals_for          int,
    goals_against      int,
    goal_diff          int,
    unique (snapshot_date_key, league_key, season, team_key)           -- enforce grain + upsert target
);