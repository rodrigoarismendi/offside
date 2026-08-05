create table if not exists gold.dim_date (
    date_key     int     primary key,      -- yyyymmdd, e.g. 20230811
    full_date    date    not null unique,
    year         int     not null,
    quarter      int     not null,
    month        int     not null,
    month_name   text    not null,
    day          int     not null,
    day_of_week  int     not null,         -- ISO: 1=Mon .. 7=Sun
    day_name     text    not null,
    week         int     not null,         -- ISO week number
    is_weekend   boolean not null,
    season_year  int     not null          -- football season start year (Aug boundary)
);

insert into gold.dim_date
select
    to_char(d, 'YYYYMMDD')::int          as date_key,
    d                                    as full_date,
    extract(year    from d)::int         as year,
    extract(quarter from d)::int         as quarter,
    extract(month   from d)::int         as month,
    trim(to_char(d, 'Month'))            as month_name,
    extract(day     from d)::int         as day,
    extract(isodow  from d)::int         as day_of_week,
    trim(to_char(d, 'Day'))              as day_name,
    extract(week    from d)::int         as week,
    extract(isodow  from d) in (6, 7)    as is_weekend,
    case when extract(month from d) >= 8
         then extract(year from d)::int
         else extract(year from d)::int - 1
    end                                  as season_year
from generate_series('2010-01-01'::date, '2026-12-31'::date, interval '1 day') as g(d)
on conflict (date_key) do nothing;