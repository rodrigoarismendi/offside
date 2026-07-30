create table if not exists bronze.standings (
    id            bigint generated always as identity primary key,  -- surrogate key for this raw row
    payload       jsonb        not null,                            -- one standings record, exactly as returned
    source_params jsonb,                                            -- the request params, e.g. {"league":39,"season":2023}
    source        text         not null default 'standings',       -- which endpoint
    loaded_at     timestamptz  not null default now(),             -- when we landed it
    record_hash   text                                             -- md5 of payload, for dedup
);