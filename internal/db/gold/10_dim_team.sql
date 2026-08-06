-- Step 1: expire changed current rows
update gold.dim_team d
set valid_to   = current_date - 1,
    is_current = false
from silver.teams s
where d.team_id = s.team_id
  and d.is_current
  and (d.name, d.code, d.country, d.founded, d.national, d.logo_url)
      is distinct from
      (s.name, s.code, s.country, s.founded, s.national, s.logo_url);

-- Step 2: insert new versions (brand-new + just-expired teams)
insert into gold.dim_team
    (team_id, name, code, country, founded, national, logo_url, valid_from, valid_to, is_current)
select
    s.team_id, s.name, s.code, s.country, s.founded, s.national, s.logo_url,
    current_date, date '9999-12-31', true
from silver.teams s
left join gold.dim_team d
    on d.team_id = s.team_id and d.is_current
where d.team_id is null;