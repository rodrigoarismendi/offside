create table if not exists gold.agg_league_month (
    league_key      int not null references gold.dim_league(league_key),
    season          int not null,
    year            int not null,
    month           int not null,
    month_name      text,
    matches         int,
    total_goals     int,
    goals_per_match numeric(4,2),
    home_win_pct    numeric(5,2),
    draw_pct        numeric(5,2),
    away_win_pct    numeric(5,2),
    primary key (league_key, season, year, month)
);