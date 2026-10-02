-- Regression hardening: serialize a cache key and make fetched_at strictly monotonic.
-- Some embedded/hosted clocks can return the same timestamp for consecutive refreshes;
-- find_weather_snapshot must still select the row created by the later refresh.
create or replace function public.upsert_weather_snapshot(
 p_grid_x integer,p_grid_y integer,p_issued_at timestamptz,p_valid_at timestamptz,p_source text,p_payload jsonb
) returns jsonb language plpgsql security definer set search_path='' as $$
declare w public.weather_snapshots; precipitation text; previous_fetched timestamptz; next_fetched timestamptz;
begin
 if p_grid_x is null or p_grid_y is null or p_grid_x not between 0 and 10000 or p_grid_y not between 0 and 10000
 or p_issued_at is null or p_valid_at is null or p_valid_at<p_issued_at
 or p_source is null or length(p_source) not between 1 and 80
 or jsonb_typeof(p_payload) is distinct from 'object'
 or not(p_payload?'temperature_c') or jsonb_typeof(p_payload->'temperature_c') is distinct from 'number'
 or (p_payload->>'temperature_c')::numeric not between -90 and 60
 or p_payload-array['temperature_c','feels_like_c','precipitation_probability','precipitation_type','humidity','air_quality']::text[]<>'{}'::jsonb
 then raise exception 'invalid_weather_snapshot' using errcode='22023'; end if;
 precipitation:=p_payload->>'precipitation_type';
 if precipitation is null or precipitation not in ('none','rain','snow','mixed','unknown')
 or (p_payload?'feels_like_c' and jsonb_typeof(p_payload->'feels_like_c') not in ('number','null'))
 or (jsonb_typeof(p_payload->'feels_like_c')='number' and (p_payload->>'feels_like_c')::numeric not between -120 and 80)
 or (p_payload?'precipitation_probability' and jsonb_typeof(p_payload->'precipitation_probability') not in ('number','null'))
 or (jsonb_typeof(p_payload->'precipitation_probability')='number' and (p_payload->>'precipitation_probability')::numeric not between 0 and 100)
 or (p_payload?'humidity' and jsonb_typeof(p_payload->'humidity') not in ('number','null'))
 or (jsonb_typeof(p_payload->'humidity')='number' and (p_payload->>'humidity')::numeric not between 0 and 100)
 or (p_payload?'air_quality' and jsonb_typeof(p_payload->'air_quality') not in ('string','null'))
 then raise exception 'invalid_weather_snapshot' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended(
  'weather:'||p_grid_x::text||':'||p_grid_y::text||':'||p_valid_at::text||':'||p_source,0));
 select max(fetched_at) into previous_fetched from public.weather_snapshots
  where grid_x=p_grid_x and grid_y=p_grid_y and valid_at=p_valid_at and source=p_source;
 next_fetched:=clock_timestamp();
 if previous_fetched is not null and next_fetched<=previous_fetched then
  next_fetched:=previous_fetched+interval '1 microsecond';
 end if;
 insert into public.weather_snapshots(grid_x,grid_y,issued_at,valid_at,source,payload,fetched_at)
 values(p_grid_x,p_grid_y,p_issued_at,p_valid_at,p_source,p_payload,next_fetched)
 returning * into w;
 return jsonb_build_object('id',w.id,'grid_x',w.grid_x,'grid_y',w.grid_y,'issued_at',w.issued_at,
  'valid_at',w.valid_at,'fetched_at',w.fetched_at,'source',w.source,'payload',w.payload);
end $$;

revoke all on function public.upsert_weather_snapshot(integer,integer,timestamptz,timestamptz,text,jsonb)
 from public,anon,authenticated;
grant execute on function public.upsert_weather_snapshot(integer,integer,timestamptz,timestamptz,text,jsonb) to service_role;
