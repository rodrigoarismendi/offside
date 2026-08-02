create table if not exists silver.venues (
    team_id    int,
    venue_id   int,
    venue_name text,
    city       text,
    address    text,
    surface    text,
    image      text,
    capacity   bigint,
    loaded_at  timestamptz,
    primary key (team_id, venue_id)
);