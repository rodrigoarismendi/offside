merge into silver.seasons as t
using (
    select distinct on (league_id, year)
        (payload->'league'->>'id')::int      as league_id,
        (sns->>'year')                       as year,
        (sns->>'start')::date                       as start_date,
        (sns->>'end')::date                       as end_date,
        (sns->>'current')::boolean                       as current,
        (sns->'coverage'->>'odds')::boolean     as odds,
        (sns->'players'->>'odds')::boolean     as players,
        (sns->'coverage'->'fixtures'->>'events')::boolean     as events,
        (sns->'coverage'->'fixtures'->>'lineups')::boolean     as lineups,
        (sns->'coverage'->'fixtures'->>'statistics_players')::boolean     as statistics_players,
        (sns->'coverage'->'fixtures'->>'statistics_fixtures')::boolean     as statistics_fixtures,
        (sns->'coverage'->>'injuries')::boolean     as injuries,
        (sns->'coverage'->>'standings')::boolean     as standings,
        (sns->'coverage'->>'top_cards')::boolean     as top_cards,
        (sns->'coverage'->>'predictions')::boolean     as predictions,
        (sns->'coverage'->>'top_assists')::boolean     as top_assists,
        (sns->'coverage'->>'top_scorers')::boolean     as top_scorers,
        loaded_at
    from bronze.leagues,
        jsonb_array_elements(coalesce(payload->'seasons', '[]'::jsonb)) as sns
    order by league_id, year, loaded_at desc
) as s
on t.league_id = s.league_id
and t.year = s.year
when matched then
    update set start_date = s.start_date, end_date = s.end_date,
               current = s.current, odds = s.odds, players = s.players,
               events = s.events, lineups = s.lineups, statistics_players = s.statistics_players,
               statistics_fixtures = s.statistics_fixtures, injuries = s.injuries,
               standings = s.standings, top_cards = s.top_cards, predictions = s.predictions,
               top_assists = s.top_assists, top_scorers = s.top_scorers,
               loaded_at = s.loaded_at
when not matched then
    insert (league_id, year, start_date, end_date, current, odds, players,
            events, lineups, statistics_players, statistics_fixtures, injuries,
            standings, top_cards, predictions, top_assists, top_scorers, loaded_at)
    values (s.league_id, s.year, s.start_date, s.end_date, s.current, s.odds, s.players,
            s.events, s.lineups, s.statistics_players, s.statistics_fixtures, s.injuries,
            s.standings, s.top_cards, s.predictions, s.top_assists, s.top_scorers, s.loaded_at);