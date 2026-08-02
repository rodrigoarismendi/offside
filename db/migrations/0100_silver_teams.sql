create table if not exists silver.teams (
    team_id   int primary key,
    name      text,
    code      text,
    country   text,
    founded   int,
    national  boolean,
    logo_url  text,
    loaded_at timestamptz
);