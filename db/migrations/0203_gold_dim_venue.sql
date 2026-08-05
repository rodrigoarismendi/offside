create table if not exists gold.dim_venue (
    venue_key  int generated always as identity primary key,  -- surrogate key
    venue_id   int     not null,          -- natural key, NOT unique (repeats per version)
    name       text,
    city       text,
    address    text,
    surface    text,
    image      text,
    capacity   bigint,
    valid_from date    not null,
    valid_to   date    not null,
    is_current boolean not null
);

create unique index if not exists dim_venue_current_uq
    on gold.dim_venue (venue_id) where is_current;