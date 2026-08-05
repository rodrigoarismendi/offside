create table if not exists gold.dim_league (
    league_key int generated always as identity primary key, -- surrogate key
    league_id int not null unique,
    name text not null,
    type text not null,
    country_name text not null,
    country_code text not null,
    logo_url text not null
);

insert into gold.dim_league (league_id, name, type, country_name, country_code, logo_url)
select
    league_id,
    league_name,
    type,
    country_name,
    country_code,
    logo
from silver.leagues;