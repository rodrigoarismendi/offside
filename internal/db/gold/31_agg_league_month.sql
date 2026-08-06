truncate gold.agg_league_month;

insert into gold.agg_league_month
    (league_key, season, year, month, month_name, matches, total_goals,
     goals_per_match, home_win_pct, draw_pct, away_win_pct)
select
    ff.league_key, ff.season, dd.year, dd.month, dd.month_name,
    count(*)                                    as matches,
    sum(ff.goals_total)                         as total_goals,
    round(avg(ff.goals_total), 2)               as goals_per_match,
    round(avg((ff.result =  1)::int) * 100, 2)  as home_win_pct,
    round(avg((ff.result =  0)::int) * 100, 2)  as draw_pct,
    round(avg((ff.result = -1)::int) * 100, 2)  as away_win_pct
from gold.fact_fixture ff
join gold.dim_date dd on dd.date_key = ff.date_key
where ff.result is not null
group by ff.league_key, ff.season, dd.year, dd.month, dd.month_name;