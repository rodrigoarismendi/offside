insert into gold.fact_standing
    (snapshot_date_key, league_key, team_key, season,
     rank, points, played, won, draw, lost, goals_for, goals_against, goal_diff)
select
    dd.date_key,
    dl.league_key,
    dt.team_key,
    s.season,
    s.rank,
    s.points,
    s.played,
    s.win,
    s.draw,
    s.lose,
    s.goals_for,
    s.goals_against,
    s.goals_diff
from silver.standings s
join gold.dim_date   dd on dd.full_date = s.updated_at::date
join gold.dim_league dl on dl.league_id = s.league_id
join gold.dim_team   dt on dt.team_id   = s.team_id and dt.is_current
on conflict (snapshot_date_key, league_key, season, team_key) do update set
    rank          = excluded.rank,
    points        = excluded.points,
    played        = excluded.played,
    won           = excluded.won,
    draw          = excluded.draw,
    lost          = excluded.lost,
    goals_for     = excluded.goals_for,
    goals_against = excluded.goals_against,
    goal_diff     = excluded.goal_diff;