-- Step 1: expire changed current rows
update gold.dim_venue d
set valid_to   = current_date - 1,
    is_current = false
from (
    select distinct on (venue_id)
        venue_id, venue_name, city, address, surface, image, capacity
    from silver.venues
    order by venue_id, loaded_at desc
) s
where d.venue_id = s.venue_id
  and d.is_current
  and (d.name, d.city, d.address, d.surface, d.image, d.capacity)
      is distinct from
      (s.venue_name, s.city, s.address, s.surface, s.image, s.capacity);

-- Step 2: insert new versions (brand-new + just-expired venues)
insert into gold.dim_venue
    (venue_id, name, city, address, surface, image, capacity, valid_from, valid_to, is_current)
select
    s.venue_id, s.venue_name, s.city, s.address, s.surface, s.image, s.capacity,
    current_date, date '9999-12-31', true
from (
    select distinct on (venue_id)
        venue_id, venue_name, city, address, surface, image, capacity
    from silver.venues
    order by venue_id, loaded_at desc
) s
left join gold.dim_venue d
    on d.venue_id = s.venue_id and d.is_current
where d.venue_id is null;