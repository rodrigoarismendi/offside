create table if not exists gold.agg_venue_home (
    venue_key            int not null references gold.dim_venue(venue_key),
    season               int not null,
    home_matches         int,
    home_goals           int,
    home_goals_per_match numeric(4,2),
    home_wins            int,
    home_win_pct         numeric(5,2),
    primary key (venue_key, season)
);