create table if not exists gold.dim_team (
    team_key   int generated always as identity primary key,
    team_id    int     not null,
    name       text    not null,
    code       text,
    country    text,
    founded    int,
    national   boolean not null,
    logo_url   text,
    valid_from date    not null,
    valid_to   date    not null,
    is_current boolean not null
);

create unique index if not exists dim_team_current_uq
    on gold.dim_team (team_id) where is_current;