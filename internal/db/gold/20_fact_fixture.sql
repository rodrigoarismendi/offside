insert into gold.fact_fixture
    (fixture_id, date_key, league_key, home_team_key, away_team_key,
     venue_key, season, status_short, goals_home, goals_away, goals_total, result)
select
    f.fixture_id,
    dd.date_key,
    dl.league_key,
    th.team_key,
    ta.team_key,
    dv.venue_key,
    f.season,
    f.status_short,
    f.goals_home,
    f.goals_away,
    coalesce(f.goals_home, 0) + coalesce(f.goals_away, 0),
    case
        when f.goals_home > f.goals_away then 1
        when f.goals_home < f.goals_away then -1
        when f.goals_home = f.goals_away then 0
    end
from silver.fixtures f
join      gold.dim_date   dd on dd.full_date = f.kickoff::date
join      gold.dim_league dl on dl.league_id = f.league_id
join      gold.dim_team   th on th.team_id   = f.home_team_id and th.is_current
join      gold.dim_team   ta on ta.team_id   = f.away_team_id and ta.is_current
left join gold.dim_venue  dv on dv.venue_id  = f.venue_id     and dv.is_current
on conflict (fixture_id) do update set
    date_key      = excluded.date_key,
    league_key    = excluded.league_key,
    home_team_key = excluded.home_team_key,
    away_team_key = excluded.away_team_key,
    venue_key     = excluded.venue_key,
    season        = excluded.season,
    status_short  = excluded.status_short,
    goals_home    = excluded.goals_home,
    goals_away    = excluded.goals_away,
    goals_total   = excluded.goals_total,
    result        = excluded.result;