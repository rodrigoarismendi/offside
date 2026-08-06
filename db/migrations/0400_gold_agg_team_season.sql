create table if not exists gold.agg_team_season (
    league_key      int not null references gold.dim_league(league_key),
    team_key        int not null references gold.dim_team(team_key),
    season          int not null,
    played          int,
    won             int,
    draw            int,
    lost            int,
    goals_for       int,
    goals_against   int,
    goal_diff       int,
    points          int,
    points_per_game numeric(4,2),
    clean_sheets    int,
    final_rank      int,
    primary key (league_key, team_key, season)
);