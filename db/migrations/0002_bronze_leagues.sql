create table if not exists bronze.leagues (
    id            bigint generated always as identity primary key,  -- surrogate key for THIS raw row
    payload       jsonb        not null,                            -- one league record, exactly as returned
    source_params jsonb,                                            -- the request params (e.g. {"id": 39}) for context
    source        text         not null default 'leagues',         -- which endpoint this came from
    loaded_at     timestamptz  not null default now(),             -- when we landed it  ← DV "load date" preview
    record_hash   text                                             -- md5 of payload, for dedup  ← DV "hashdiff" preview
);