create table if not exists gold.fact_fixture (
    fixture_id    int  primary key,                                   -- degenerate key / grain
    date_key      int  not null references gold.dim_date(date_key),
    league_key    int  not null references gold.dim_league(league_key),
    home_team_key int  not null references gold.dim_team(team_key),   -- role-playing
    away_team_key int  not null references gold.dim_team(team_key),   -- role-playing
    venue_key     int  references gold.dim_venue(venue_key),          -- nullable (some fixtures lack a venue)
    season        int,
    status_short  text,                                               -- degenerate
    goals_home    int,
    goals_away    int,
    goals_total   int,
    result        smallint                                            -- 1 home win / 0 draw / -1 away
);