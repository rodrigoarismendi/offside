create table if not exists silver.leagues (
    league_id    bigint primary key, -- surrogate key for this raw row
    league_name  text,               -- one standings record, exactly as returned
    type         text,               -- the request params, e.g. {"league":39,"season":2023}
    country_name text,               -- which endpoint
    country_code text,               -- when we landed it
    logo         text,
    flag         text,
    loaded_at    timestamptz
);
