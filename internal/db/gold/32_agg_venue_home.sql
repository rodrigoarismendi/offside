truncate gold.agg_venue_home;

insert into gold.agg_venue_home
    (venue_key, season, home_matches, home_goals, home_goals_per_match, home_wins, home_win_pct)
select
    ff.venue_key, ff.season,
    count(*)                                    as home_matches,
    sum(ff.goals_home)                          as home_goals,
    round(avg(ff.goals_home), 2)                as home_goals_per_match,
    count(*) filter (where ff.result = 1)       as home_wins,
    round(avg((ff.result = 1)::int) * 100, 2)   as home_win_pct
from gold.fact_fixture ff
where ff.venue_key is not null and ff.result is not null
group by ff.venue_key, ff.season;