merge into silver.teams as t
using (
    select distinct on (team_id)
        (payload->'team'->>'id')::int         as team_id,
         payload->'team'->>'name'             as name,
         payload->'team'->>'code'             as code,
         payload->'team'->>'country'          as country,
        (payload->'team'->>'founded')::int    as founded,
        (payload->'team'->>'national')::bool  as national,
         payload->'team'->>'logo'             as logo_url,
         loaded_at
    from bronze.teams
    order by team_id, loaded_at desc
) as s
on t.team_id = s.team_id
when matched then
    update set name = s.name, code = s.code, country = s.country,
               founded = s.founded, national = s.national,
               logo_url = s.logo_url, loaded_at = s.loaded_at
when not matched then
    insert (team_id, name, code, country, founded, national, logo_url, loaded_at)
    values (s.team_id, s.name, s.code, s.country, s.founded, s.national, s.logo_url, s.loaded_at);