merge into silver.leagues as t
using (
    select distinct on (league_id)
        (payload->'league'->>'id')::int               as league_id,
        payload->'league'->>'name'                    as league_name,
        payload->'league'->>'type'                    as type,
        payload->'country'->>'name'                   as country_name,
        payload->'country'->>'code'                   as country_code,
        payload->'league'->>'logo'                    as logo,
        payload->'country'->>'flag'                   as flag,
        loaded_at
    from bronze.leagues
    order by league_id, loaded_at desc
) as s
on t.league_id = s.league_id
when matched then
    update set league_name = s.league_name, type = s.type,
               country_name = s.country_name, country_code = s.country_code,
               logo = s.logo, flag = s.flag, loaded_at = s.loaded_at
when not matched then
    insert (league_id, league_name, type, country_name, country_code, logo, flag, loaded_at)
    values (s.league_id, s.league_name, s.type, s.country_name, s.country_code, s.logo, s.flag, s.loaded_at);