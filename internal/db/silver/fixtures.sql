merge into silver.fixtures as t
using (
    select distinct on (fixture_id)
        (payload->'fixture'->>'id')::int                as fixture_id,
        (payload->'league'->>'id')::int                 as league_id,
        (payload->'league'->>'season')::int             as season,
         payload->'league'->>'round'                    as round,
        (payload->'fixture'->>'date')::timestamptz      as kickoff,
         payload->'fixture'->'status'->>'short'         as status_short,
         payload->'fixture'->'status'->>'long'          as status_long,
        (payload->'fixture'->'status'->>'elapsed')::int as status_elapsed,
         payload->'fixture'->>'referee'                 as referee,
        (payload->'fixture'->'venue'->>'id')::int       as venue_id,
         payload->'fixture'->'venue'->>'name'           as venue_name,
         payload->'fixture'->'venue'->>'city'           as venue_city,
        (payload->'teams'->'home'->>'id')::int          as home_team_id,
         payload->'teams'->'home'->>'name'              as home_team_name,
        (payload->'teams'->'away'->>'id')::int          as away_team_id,
         payload->'teams'->'away'->>'name'              as away_team_name,
        (payload->'teams'->'home'->>'winner')::boolean  as home_winner,
        (payload->'teams'->'away'->>'winner')::boolean  as away_winner,
        (payload->'goals'->>'home')::int                as goals_home,
        (payload->'goals'->>'away')::int                as goals_away,
        (payload->'score'->'halftime'->>'home')::int    as ht_home,
        (payload->'score'->'halftime'->>'away')::int    as ht_away,
        (payload->'score'->'fulltime'->>'home')::int    as ft_home,
        (payload->'score'->'fulltime'->>'away')::int    as ft_away,
        (payload->'score'->'extratime'->>'home')::int   as et_home,
        (payload->'score'->'extratime'->>'away')::int   as et_away,
        (payload->'score'->'penalty'->>'home')::int     as pen_home,
        (payload->'score'->'penalty'->>'away')::int     as pen_away,
         loaded_at
    from bronze.fixtures
    order by fixture_id, loaded_at desc
) as s
on t.fixture_id = s.fixture_id
when matched then update set
    league_id = s.league_id, season = s.season, round = s.round, kickoff = s.kickoff,
    status_short = s.status_short, status_long = s.status_long, status_elapsed = s.status_elapsed,
    referee = s.referee, venue_id = s.venue_id, venue_name = s.venue_name, venue_city = s.venue_city,
    home_team_id = s.home_team_id, home_team_name = s.home_team_name,
    away_team_id = s.away_team_id, away_team_name = s.away_team_name,
    home_winner = s.home_winner, away_winner = s.away_winner,
    goals_home = s.goals_home, goals_away = s.goals_away,
    ht_home = s.ht_home, ht_away = s.ht_away, ft_home = s.ft_home, ft_away = s.ft_away,
    et_home = s.et_home, et_away = s.et_away, pen_home = s.pen_home, pen_away = s.pen_away,
    loaded_at = s.loaded_at
when not matched then insert (
    fixture_id, league_id, season, round, kickoff,
    status_short, status_long, status_elapsed, referee,
    venue_id, venue_name, venue_city,
    home_team_id, home_team_name, away_team_id, away_team_name,
    home_winner, away_winner, goals_home, goals_away,
    ht_home, ht_away, ft_home, ft_away, et_home, et_away, pen_home, pen_away, loaded_at
) values (
    s.fixture_id, s.league_id, s.season, s.round, s.kickoff,
    s.status_short, s.status_long, s.status_elapsed, s.referee,
    s.venue_id, s.venue_name, s.venue_city,
    s.home_team_id, s.home_team_name, s.away_team_id, s.away_team_name,
    s.home_winner, s.away_winner, s.goals_home, s.goals_away,
    s.ht_home, s.ht_away, s.ft_home, s.ft_away, s.et_home, s.et_away, s.pen_home, s.pen_away, s.loaded_at
);