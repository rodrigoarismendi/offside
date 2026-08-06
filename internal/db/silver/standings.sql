merge into silver.standings as t
using (
    select distinct on (league_id, season, team_id)
        (payload->'league'->>'id')::int              as league_id,
        (payload->'league'->>'season')::int          as season,
        (row_obj->'team'->>'id')::int                as team_id,
        row_obj->'team'->>'name'                     as team_name,
        (row_obj->>'rank')::int                      as rank,
        (row_obj->>'points')::int                    as points,
        (row_obj->>'goalsDiff')::int                 as goals_diff,
        row_obj->>'group'                            as group_name,
        row_obj->>'form'                             as form,
        (row_obj->'all'->>'played')::int             as played,
        (row_obj->'all'->>'win')::int                as win,
        (row_obj->'all'->>'draw')::int               as draw,
        (row_obj->'all'->>'lose')::int               as lose,
        (row_obj->'all'->'goals'->>'for')::int       as goals_for,
        (row_obj->'all'->'goals'->>'against')::int   as goals_against,
        (row_obj->>'update')::timestamptz            as updated_at,
        loaded_at
    from bronze.standings,
        jsonb_array_elements(payload->'league'->'standings') as grp,      -- explode groups
        jsonb_array_elements(grp)                            as row_obj   -- explode teams in a group
    order by league_id, season, team_id, loaded_at desc
) as s
on t.team_id = s.team_id
    and t.league_id = s.league_id
    and t.season = s.season
when matched then
    update set rank = s.rank, points = s.points, goals_diff = s.goals_diff,
               group_name = s.group_name, form = s.form,
               played = s.played, win = s.win, draw = s.draw, lose = s.lose,
               goals_for = s.goals_for, goals_against = s.goals_against,
               updated_at = s.updated_at, loaded_at = s.loaded_at
when not matched then
    insert (league_id, season, team_id, team_name, rank, points, goals_diff,
        group_name, form, played, win, draw, lose, goals_for, goals_against, updated_at, loaded_at)
    values (s.league_id, s.season, s.team_id, s.team_name, s.rank, s.points, s.goals_diff,
        s.group_name, s.form, s.played, s.win, s.draw, s.lose, s.goals_for, s.goals_against, s.updated_at, s.loaded_at);