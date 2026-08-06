truncate gold.agg_team_season;

insert into gold.agg_team_season
    (league_key, team_key, season, played, won, draw, lost,
     goals_for, goals_against, goal_diff, points, points_per_game, clean_sheets, final_rank)
with team_games as (   -- role-playing: unpivot home + away into one row per team-match
    select league_key, season, home_team_key as team_key,
           goals_home as gf, goals_away as ga, result as r
    from gold.fact_fixture where result is not null
    union all
    select league_key, season, away_team_key,
           goals_away, goals_home, -result
    from gold.fact_fixture where result is not null
),
agg as (
    select league_key, team_key, season,
        count(*)                                              as played,
        count(*) filter (where r = 1)                         as won,
        count(*) filter (where r = 0)                         as draw,
        count(*) filter (where r = -1)                        as lost,
        sum(gf)                                               as goals_for,
        sum(ga)                                               as goals_against,
        sum(gf) - sum(ga)                                     as goal_diff,
        sum(case when r=1 then 3 when r=0 then 1 else 0 end)  as points,
        count(*) filter (where ga = 0)                        as clean_sheets
    from team_games
    group by league_key, team_key, season
)
select a.*,
       round(a.points::numeric / nullif(a.played, 0), 2)      as points_per_game,
       fs.rank                                                as final_rank
from agg a
left join lateral (                          -- latest standings snapshot for this team-season
    select rank from gold.fact_standing s
    where s.league_key = a.league_key and s.team_key = a.team_key and s.season = a.season
    order by s.snapshot_date_key desc limit 1
) fs on true;