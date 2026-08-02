merge into silver.venues as t
using (
    select distinct on (team_id, venue_id)
        (payload->'team'->>'id')::int as team_id,
        (payload->'venue'->>'id')::int as venue_id,
        (payload->'venue'->>'city') as city,
        (payload->'venue'->>'name') as venue_name,
        (payload->'venue'->>'image') as image,
        (payload->'venue'->>'address') as address,
        (payload->'venue'->>'surface') as surface,
        (payload->'venue'->>'capacity')::bigint as capacity,
        loaded_at
    from bronze.teams
    where (payload->'venue'->>'id') is not null
    order by team_id, venue_id, loaded_at desc
) as s
on t.team_id = s.team_id
and t.venue_id = s.venue_id
when matched then
    update
    set
        city = s.city,
        venue_name = s.venue_name,
        image = s.image,
        address = s.address,
        surface = s.surface,
        capacity = s.capacity,
        loaded_at = s.loaded_at
when not matched then
    insert (
        team_id,
        venue_id,
        city,
        venue_name,
        image,
        address,
        surface,
        capacity,
        loaded_at
    )
    values (
        s.team_id,
        s.venue_id,
        s.city,
        s.venue_name,
        s.image,
        s.address,
        s.surface,
        s.capacity,
        s.loaded_at
    );