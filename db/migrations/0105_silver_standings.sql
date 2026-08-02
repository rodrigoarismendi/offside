create table if not exists silver.standings (
    league_id      int,
    season         int,
    team_id        int,
    team_name      text,
    rank           int,
    points         int,
    goals_diff     int,
    group_name     text,
    form           text,
    played         int,
    win            int,
    draw           int,
    lose           int,
    goals_for      int,
    goals_against  int,
    loaded_at      timestamptz,
    primary key (league_id, season, team_id)
);