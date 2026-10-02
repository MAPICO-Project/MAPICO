-- G5: server-owned weather/recommendation persistence and user-bound acceptance.

-- The core uniqueness rule made a refresh overwrite history. Drop that exact column-key
-- constraint by catalog identity so PostgreSQL identifier truncation cannot make this brittle.
do $$ declare constraint_name name; begin
 select c.conname into constraint_name from pg_constraint c
 where c.conrelid='public.weather_snapshots'::regclass and c.contype='u'
 and c.conkey=array[
  (select attnum from pg_attribute where attrelid=c.conrelid and attname='grid_x'),
  (select attnum from pg_attribute where attrelid=c.conrelid and attname='grid_y'),
  (select attnum from pg_attribute where attrelid=c.conrelid and attname='issued_at'),
  (select attnum from pg_attribute where attrelid=c.conrelid and attname='valid_at'),
  (select attnum from pg_attribute where attrelid=c.conrelid and attname='source')
 ]::smallint[];
 if constraint_name is null then raise exception 'weather_forecast_unique_constraint_not_found'; end if;
 execute format('alter table public.weather_snapshots drop constraint %I',constraint_name);
end $$;

create index weather_cache_lookup on public.weather_snapshots(grid_x,grid_y,valid_at,source,fetched_at desc,id desc);
alter table public.recommendation_requests add column weather_was_stale boolean not null default false;
alter table public.recommendation_requests add column weather_grid_x integer;
alter table public.recommendation_requests add column weather_grid_y integer;
alter table public.recommendation_requests add column weather_valid_at timestamptz;
alter table public.recommendation_requests add column result_hash text;
alter table public.recommendation_requests add column reservation_token uuid;
alter table public.recommendation_requests add column reservation_lease_expires_at timestamptz;

create function public.find_weather_snapshot(p_grid_x integer,p_grid_y integer,p_valid_at timestamptz,p_source text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare w public.weather_snapshots;
begin
 if p_grid_x is null or p_grid_y is null or p_valid_at is null or p_source is null or p_source=''
 then raise exception 'invalid_weather_lookup' using errcode='22023'; end if;
 select * into w from public.weather_snapshots where grid_x=p_grid_x and grid_y=p_grid_y
  and valid_at=p_valid_at and source=p_source order by fetched_at desc,id desc limit 1;
 if not found then return null; end if;
 return jsonb_build_object('id',w.id,'grid_x',w.grid_x,'grid_y',w.grid_y,'issued_at',w.issued_at,
  'valid_at',w.valid_at,'fetched_at',w.fetched_at,'source',w.source,'payload',w.payload);
end $$;

create function public.get_weather_snapshot(p_snapshot_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare w public.weather_snapshots;
begin
 if p_snapshot_id is null then raise exception 'invalid_weather_snapshot_id' using errcode='22023'; end if;
 select * into w from public.weather_snapshots where id=p_snapshot_id;
 if not found then raise exception 'weather_not_found' using errcode='P0002'; end if;
 return jsonb_build_object('id',w.id,'grid_x',w.grid_x,'grid_y',w.grid_y,'issued_at',w.issued_at,
  'valid_at',w.valid_at,'fetched_at',w.fetched_at,'source',w.source,'payload',w.payload);
end $$;

create function public.upsert_weather_snapshot(
 p_grid_x integer,p_grid_y integer,p_issued_at timestamptz,p_valid_at timestamptz,p_source text,p_payload jsonb
) returns jsonb language plpgsql security definer set search_path='' as $$
declare w public.weather_snapshots; precipitation text;
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
 insert into public.weather_snapshots(grid_x,grid_y,issued_at,valid_at,source,payload,fetched_at)
 values(p_grid_x,p_grid_y,p_issued_at,p_valid_at,p_source,p_payload,clock_timestamp())
 returning * into w;
 return jsonb_build_object('id',w.id,'grid_x',w.grid_x,'grid_y',w.grid_y,'issued_at',w.issued_at,
  'valid_at',w.valid_at,'fetched_at',w.fetched_at,'source',w.source,'payload',w.payload);
end $$;

create function public.begin_my_recommendation(
 p_grid_x integer,p_grid_y integer,p_valid_at timestamptz,p_requested_count integer,
 p_idempotency_key text,p_request_hash text,p_engine_version text,p_rules_version text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare owner_id uuid:=auth.uid(); profile public.profiles; stored public.idempotency_keys;
 request public.recommendation_requests; target date; response jsonb; lease_token uuid;
begin
 if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 if p_grid_x is null or p_grid_y is null or p_grid_x not between 0 and 10000 or p_grid_y not between 0 and 10000
 or p_valid_at is null or p_requested_count not between 1 and 3
 or p_idempotency_key is null or length(p_idempotency_key) not between 8 and 128 or p_idempotency_key!~'^[A-Za-z0-9._:-]+$'
 or p_request_hash is null or length(p_request_hash)<>64 or p_request_hash!~'^[0-9a-f]{64}$'
 or p_engine_version is null or length(p_engine_version) not between 1 and 100
 or p_rules_version is null or length(p_rules_version) not between 1 and 100
 then raise exception 'invalid_recommendation' using errcode='22023'; end if;
 select * into profile from public.profiles where id=owner_id;
 if not found then raise exception 'user_not_found' using errcode='P0002'; end if;
 target:=(now() at time zone profile.timezone)::date;
 if (p_valid_at at time zone profile.timezone)::date<>target then raise exception 'invalid_weather_slot' using errcode='22023'; end if;
 insert into public.idempotency_keys(user_id,scope,key,request_hash)
 values(owner_id,'recommendation_create',p_idempotency_key,p_request_hash) on conflict do nothing;
 select * into stored from public.idempotency_keys where user_id=owner_id and scope='recommendation_create' and key=p_idempotency_key for update;
 if stored.expires_at<=now() then
  delete from public.idempotency_keys where user_id=owner_id and scope='recommendation_create' and key=p_idempotency_key;
  insert into public.idempotency_keys(user_id,scope,key,request_hash)
  values(owner_id,'recommendation_create',p_idempotency_key,p_request_hash) returning * into stored;
 end if;
 if stored.request_hash<>p_request_hash then raise exception 'idempotency_conflict' using errcode='P0001'; end if;
 if stored.response_body is not null then
  select * into request from public.recommendation_requests where id=(stored.response_body->>'request_id')::uuid and user_id=owner_id for update;
  if not found then raise exception 'recommendation_reservation_missing' using errcode='P0001'; end if;
  if request.status='pending' and request.reservation_lease_expires_at<=now() then
   lease_token:=gen_random_uuid();
   update public.recommendation_requests set reservation_token=lease_token,reservation_lease_expires_at=now()+interval '2 minutes'
    where id=request.id;
   return jsonb_build_object('request_id',request.id,'status','pending','replayed',true,'in_progress',false,
    'resumed',true,'reservation_token',lease_token,'lease_expires_at',now()+interval '2 minutes');
  end if;
  return jsonb_build_object('request_id',request.id,'status',request.status,'replayed',true,
   'in_progress',request.status='pending','resumed',false);
 end if;
 lease_token:=gen_random_uuid();
 insert into public.recommendation_requests(user_id,weather_snapshot_id,tpo,target_date,requested_count,status,
  preference_snapshot,engine_version,rules_version,shortfall_reasons,weather_grid_x,weather_grid_y,weather_valid_at,
  reservation_token,reservation_lease_expires_at)
 values(owner_id,null,null,target,p_requested_count,'pending','[]',p_engine_version,p_rules_version,'[]',p_grid_x,p_grid_y,p_valid_at,
  lease_token,now()+interval '2 minutes')
 returning * into request;
 response:=jsonb_build_object('request_id',request.id);
 update public.idempotency_keys set response_body=response,response_status=202
 where user_id=owner_id and scope='recommendation_create' and key=p_idempotency_key;
 return jsonb_build_object('request_id',request.id,'status','pending','replayed',false,'in_progress',false,'resumed',false,
  'reservation_token',lease_token,'lease_expires_at',request.reservation_lease_expires_at);
end $$;

-- p_outfits: [{rank,scores,reason_facts,explanation,explanation_source,items:[{garment_id,slot}]}]
create function public.store_recommendation(
 p_user_id uuid,p_weather_snapshot_id uuid,p_target_date date,p_requested_count integer,
 p_engine_version text,p_rules_version text,p_shortfall_reasons jsonb,p_outfits jsonb,
 p_idempotency_key text,p_request_hash text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare profile public.profiles; weather public.weather_snapshots; stored public.idempotency_keys;
 request_id uuid; request_status text; outfit jsonb; item jsonb; outfit_id uuid; outfit_count integer;
 item_count integer; score jsonb; rank_value integer; response jsonb; preference_snapshot jsonb;
begin
 if p_user_id is null or p_weather_snapshot_id is null or p_target_date is null or p_requested_count not between 1 and 3
 or p_engine_version is null or length(p_engine_version) not between 1 and 100
 or p_rules_version is null or length(p_rules_version) not between 1 and 100
 or jsonb_typeof(p_shortfall_reasons) is distinct from 'array' or jsonb_typeof(p_outfits) is distinct from 'array'
 or p_idempotency_key is null or length(p_idempotency_key) not between 8 and 128 or p_idempotency_key!~'^[A-Za-z0-9._:-]+$'
 or p_request_hash is null or length(p_request_hash)<>64 or p_request_hash!~'^[0-9a-f]{64}$'
 then raise exception 'invalid_recommendation' using errcode='22023'; end if;
 select * into profile from public.profiles where id=p_user_id;
 if not found then raise exception 'user_not_found' using errcode='P0002'; end if;
 select * into weather from public.weather_snapshots where id=p_weather_snapshot_id;
 if not found then raise exception 'weather_not_found' using errcode='P0002'; end if;
 if (weather.valid_at at time zone profile.timezone)::date<>p_target_date
 or (now() at time zone profile.timezone)::date<>p_target_date then raise exception 'invalid_target_date' using errcode='22023'; end if;
 insert into public.idempotency_keys(user_id,scope,key,request_hash)
 values(p_user_id,'recommendation_create',p_idempotency_key,p_request_hash) on conflict do nothing;
 select * into stored from public.idempotency_keys where user_id=p_user_id and scope='recommendation_create' and key=p_idempotency_key for update;
 if stored.expires_at<=now() then
  delete from public.idempotency_keys where user_id=p_user_id and scope='recommendation_create' and key=p_idempotency_key;
  insert into public.idempotency_keys(user_id,scope,key,request_hash)
  values(p_user_id,'recommendation_create',p_idempotency_key,p_request_hash) returning * into stored;
 end if;
 if stored.request_hash<>p_request_hash then raise exception 'idempotency_conflict' using errcode='P0001'; end if;
 if stored.response_body is not null then return jsonb_build_object('recommendation_id',stored.response_body->>'recommendation_id','replayed',true); end if;
 outfit_count:=jsonb_array_length(p_outfits);
 if outfit_count>p_requested_count or outfit_count>3 then raise exception 'invalid_outfit_count' using errcode='22023'; end if;
 if outfit_count=0 then
  if jsonb_array_length(p_shortfall_reasons)<1 then raise exception 'shortfall_reason_required' using errcode='22023'; end if;
  request_status:='insufficient_wardrobe';
 else request_status:='ready'; end if;
 if exists(select 1 from jsonb_array_elements(p_shortfall_reasons) x where jsonb_typeof(x)<>'string' or length(x#>>'{}') not between 1 and 300)
 then raise exception 'invalid_shortfall_reason' using errcode='22023'; end if;
 if outfit_count>0 and (select count(distinct (value->>'rank')::integer) from jsonb_array_elements(p_outfits))<>outfit_count
 then raise exception 'duplicate_outfit_rank' using errcode='22023'; end if;
 select coalesce(jsonb_agg(jsonb_build_object('aesthetic_id',aesthetic_id,'weight',weight) order by aesthetic_id),'[]'::jsonb)
 into preference_snapshot from public.user_aesthetic_preferences where user_id=p_user_id;
 insert into public.recommendation_requests(user_id,weather_snapshot_id,tpo,target_date,requested_count,status,
  preference_snapshot,engine_version,rules_version,shortfall_reasons)
 values(p_user_id,p_weather_snapshot_id,null,p_target_date,p_requested_count,request_status,
  preference_snapshot,p_engine_version,p_rules_version,p_shortfall_reasons) returning id into request_id;
 for outfit in select value from jsonb_array_elements(p_outfits) order by (value->>'rank')::integer loop
  if jsonb_typeof(outfit) is distinct from 'object' or coalesce(outfit->>'rank','')!~'^[1-3]$'
  or (outfit->>'rank')::integer>outfit_count or jsonb_typeof(outfit->'scores') is distinct from 'object'
  or jsonb_typeof(outfit->'reason_facts') is distinct from 'array' or jsonb_typeof(outfit->'items') is distinct from 'array'
  or outfit->>'explanation_source' not in ('template','llm')
  or (outfit?'explanation' and jsonb_typeof(outfit->'explanation') not in ('string','null'))
  or length(coalesce(outfit->>'explanation',''))>1000 then raise exception 'invalid_outfit' using errcode='22023'; end if;
  rank_value:=(outfit->>'rank')::integer; score:=outfit->'scores';
  if score-array['weather','tpo','aesthetic','harmony']::text[]<>'{}'::jsonb
  or not(score?'weather' and score?'tpo' and score?'aesthetic' and score?'harmony')
  or jsonb_typeof(score->'weather')<>'number' or (score->>'weather')::numeric not between 0 and 1
  or jsonb_typeof(score->'aesthetic')<>'number' or (score->>'aesthetic')::numeric not between 0 and 1
  or jsonb_typeof(score->'harmony')<>'number' or (score->>'harmony')::numeric not between 0 and 1
  or jsonb_typeof(score->'tpo') is distinct from 'null'
  or exists(select 1 from jsonb_array_elements(outfit->'reason_facts') x where jsonb_typeof(x)<>'string' or length(x#>>'{}') not between 1 and 300)
  then raise exception 'invalid_outfit_scores' using errcode='22023'; end if;
  item_count:=jsonb_array_length(outfit->'items');
  if item_count not between 1 and 10
  or (select count(distinct value->>'garment_id') from jsonb_array_elements(outfit->'items'))<>item_count
  then raise exception 'invalid_outfit_items' using errcode='22023'; end if;
  for item in select value from jsonb_array_elements(outfit->'items') loop
   if coalesce(item->>'garment_id','')!~'^[0-9a-fA-F-]{36}$' or coalesce(item->>'slot','')='' or length(item->>'slot')>40
   or not exists(select 1 from public.garments g join public.garment_assets a on a.id=g.asset_id and a.user_id=g.user_id
     where g.id=(item->>'garment_id')::uuid and g.user_id=p_user_id and g.deleted_at is null and a.verified_at is not null and a.deleted_at is null)
   then raise exception 'garment_unavailable' using errcode='P0001'; end if;
  end loop;
  insert into public.outfit_recommendations(user_id,request_id,rank,scores,reason_facts,explanation,explanation_source)
  values(p_user_id,request_id,rank_value,score,outfit->'reason_facts',outfit->>'explanation',outfit->>'explanation_source') returning id into outfit_id;
  for item in select value from jsonb_array_elements(outfit->'items') loop
   insert into public.outfit_items(user_id,outfit_id,garment_id,slot)
   values(p_user_id,outfit_id,(item->>'garment_id')::uuid,item->>'slot');
  end loop;
 end loop;
 response:=jsonb_build_object('recommendation_id',request_id);
 update public.idempotency_keys set response_body=response,response_status=201
 where user_id=p_user_id and scope='recommendation_create' and key=p_idempotency_key;
 return jsonb_build_object('recommendation_id',request_id,'replayed',false);
end $$;

-- Finalizes only a reservation created by begin_my_recommendation; user/date/versions come from that row.
create function public.store_recommendation(
 p_request_id uuid,p_reservation_token uuid,p_weather_snapshot_id uuid,p_weather_was_stale boolean,p_shortfall_reasons jsonb,p_outfits jsonb
) returns jsonb language plpgsql security definer set search_path='' as $$
declare request public.recommendation_requests; weather public.weather_snapshots; outfit jsonb; item jsonb;
 outfit_id uuid; outfit_count integer; item_count integer; score jsonb; rank_value integer; pref_snapshot jsonb; result_fingerprint text;
 locked record; garment_set text; seen_sets text[]:='{}';
begin
 if p_request_id is null or p_reservation_token is null or p_weather_snapshot_id is null or p_weather_was_stale is null
 or jsonb_typeof(p_shortfall_reasons) is distinct from 'array' or jsonb_typeof(p_outfits) is distinct from 'array'
 then raise exception 'invalid_recommendation' using errcode='22023'; end if;
 result_fingerprint:=md5(p_weather_snapshot_id::text||':'||p_weather_was_stale::text||':'||p_shortfall_reasons::text||':'||p_outfits::text);
 select * into request from public.recommendation_requests where id=p_request_id for update;
 if not found then raise exception 'recommendation_not_found' using errcode='P0002'; end if;
 if request.status<>'pending' then
  if request.status in ('ready','insufficient_wardrobe') then
   if request.result_hash is distinct from result_fingerprint then raise exception 'recommendation_result_conflict' using errcode='P0001'; end if;
   return jsonb_build_object('recommendation_id',request.id,'status',request.status,'replayed',true);
  end if;
  raise exception 'recommendation_not_finalizable' using errcode='P0001';
 end if;
 if request.reservation_token is distinct from p_reservation_token or request.reservation_lease_expires_at<=now()
 then raise exception 'stale_recommendation_reservation' using errcode='P0001'; end if;
 select * into weather from public.weather_snapshots where id=p_weather_snapshot_id;
 if not found then raise exception 'weather_not_found' using errcode='P0002'; end if;
 if weather.grid_x is distinct from request.weather_grid_x or weather.grid_y is distinct from request.weather_grid_y
 or weather.valid_at is distinct from request.weather_valid_at or weather.source<>'kma_short_term'
 or weather.issued_at>now() or weather.fetched_at>now()+interval '1 minute' or weather.fetched_at<now()-interval '3 hours'
 or (p_weather_was_stale is distinct from (weather.fetched_at<now()-interval '10 minutes'))
 then raise exception 'weather_snapshot_not_eligible' using errcode='P0001'; end if;
 outfit_count:=jsonb_array_length(p_outfits);
 if outfit_count>request.requested_count or outfit_count>3 then raise exception 'invalid_outfit_count' using errcode='22023'; end if;
 if outfit_count=0 and jsonb_array_length(p_shortfall_reasons)<1 then raise exception 'shortfall_reason_required' using errcode='22023'; end if;
 if exists(select 1 from jsonb_array_elements(p_shortfall_reasons) x where jsonb_typeof(x)<>'string' or length(x#>>'{}') not between 1 and 300)
 then raise exception 'invalid_shortfall_reason' using errcode='22023'; end if;
 if outfit_count>0 and (select count(distinct (value->>'rank')::integer) from jsonb_array_elements(p_outfits))<>outfit_count
 then raise exception 'duplicate_outfit_rank' using errcode='22023'; end if;
 for outfit in select value from jsonb_array_elements(p_outfits) order by (value->>'rank')::integer loop
  if jsonb_typeof(outfit) is distinct from 'object' or coalesce(outfit->>'rank','')!~'^[1-3]$'
  or (outfit->>'rank')::integer>outfit_count or jsonb_typeof(outfit->'scores') is distinct from 'object'
  or jsonb_typeof(outfit->'reason_facts') is distinct from 'array' or jsonb_typeof(outfit->'items') is distinct from 'array'
  or outfit->>'explanation_source' not in ('template','llm')
  or (outfit?'explanation' and jsonb_typeof(outfit->'explanation') not in ('string','null'))
  or length(coalesce(outfit->>'explanation',''))>1000 then raise exception 'invalid_outfit' using errcode='22023'; end if;
  rank_value:=(outfit->>'rank')::integer; score:=outfit->'scores';
  if score-array['weather','tpo','aesthetic','harmony']::text[]<>'{}'::jsonb
  or not(score?'weather' and score?'tpo' and score?'aesthetic' and score?'harmony')
  or jsonb_typeof(score->'weather')<>'number' or (score->>'weather')::numeric not between 0 and 1
  or jsonb_typeof(score->'aesthetic')<>'number' or (score->>'aesthetic')::numeric not between 0 and 1
  or jsonb_typeof(score->'harmony')<>'number' or (score->>'harmony')::numeric not between 0 and 1
  or jsonb_typeof(score->'tpo') is distinct from 'null'
  or exists(select 1 from jsonb_array_elements(outfit->'reason_facts') x where jsonb_typeof(x)<>'string' or length(x#>>'{}') not between 1 and 300)
  then raise exception 'invalid_outfit_scores' using errcode='22023'; end if;
  item_count:=jsonb_array_length(outfit->'items');
  if item_count not between 1 and 10
  or (select count(distinct value->>'garment_id') from jsonb_array_elements(outfit->'items'))<>item_count
  then raise exception 'invalid_outfit_items' using errcode='22023'; end if;
  select string_agg(value->>'garment_id',',' order by value->>'garment_id') into garment_set
   from jsonb_array_elements(outfit->'items');
  if garment_set=any(seen_sets) then raise exception 'duplicate_outfit_garment_set' using errcode='22023'; end if;
  seen_sets:=array_append(seen_sets,garment_set);
  for item in select value from jsonb_array_elements(outfit->'items') order by value->>'garment_id' loop
   if coalesce(item->>'garment_id','')!~'^[0-9a-fA-F-]{36}$' or coalesce(item->>'slot','')='' or length(item->>'slot')>40
   then raise exception 'invalid_outfit_items' using errcode='22023'; end if;
   select g.deleted_at as garment_deleted_at,a.verified_at as asset_verified_at,a.deleted_at as asset_deleted_at into locked
    from public.garments g join public.garment_assets a on a.id=g.asset_id and a.user_id=g.user_id
    where g.id=(item->>'garment_id')::uuid and g.user_id=request.user_id order by g.id for update of g,a;
   if not found or locked.garment_deleted_at is not null or locked.asset_verified_at is null or locked.asset_deleted_at is not null
   then raise exception 'garment_unavailable' using errcode='P0001'; end if;
  end loop;
 end loop;
 select coalesce(jsonb_agg(jsonb_build_object('aesthetic_id',aesthetic_id,'weight',weight) order by aesthetic_id),'[]'::jsonb)
 into pref_snapshot from public.user_aesthetic_preferences where user_id=request.user_id;
 update public.recommendation_requests set weather_snapshot_id=weather.id,weather_was_stale=p_weather_was_stale,
  status=case when outfit_count=0 then 'insufficient_wardrobe' else 'ready' end,
  preference_snapshot=pref_snapshot,shortfall_reasons=p_shortfall_reasons,result_hash=result_fingerprint,
  reservation_token=null,reservation_lease_expires_at=null where id=request.id;
 for outfit in select value from jsonb_array_elements(p_outfits) order by (value->>'rank')::integer loop
  insert into public.outfit_recommendations(user_id,request_id,rank,scores,reason_facts,explanation,explanation_source)
  values(request.user_id,request.id,(outfit->>'rank')::integer,outfit->'scores',outfit->'reason_facts',outfit->>'explanation',outfit->>'explanation_source')
  returning id into outfit_id;
  for item in select value from jsonb_array_elements(outfit->'items') loop
   insert into public.outfit_items(user_id,outfit_id,garment_id,slot)
   values(request.user_id,outfit_id,(item->>'garment_id')::uuid,item->>'slot');
  end loop;
 end loop;
 return jsonb_build_object('recommendation_id',request.id,
  'status',case when outfit_count=0 then 'insufficient_wardrobe' else 'ready' end,'replayed',false);
end $$;

create function public.accept_my_recommendation(
 p_recommendation_id uuid,p_outfit_id uuid,p_worn_on date,p_idempotency_key text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare owner_id uuid:=auth.uid(); request public.recommendation_requests; outfit public.outfit_recommendations;
 stored public.idempotency_keys; request_fingerprint text; existing public.ootd_entries; result public.ootd_entries; response jsonb;
 locked record; locked_count integer:=0;
begin
 if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 if p_recommendation_id is null or p_outfit_id is null or p_worn_on is null then raise exception 'invalid_acceptance' using errcode='22023'; end if;
 if p_idempotency_key is null or length(p_idempotency_key) not between 8 and 128 or p_idempotency_key!~'^[A-Za-z0-9._:-]+$'
 then raise exception 'invalid_idempotency_key' using errcode='22023'; end if;
 request_fingerprint:=md5(p_recommendation_id::text||':'||p_outfit_id::text||':'||p_worn_on::text);
 insert into public.idempotency_keys(user_id,scope,key,request_hash)
 values(owner_id,'recommendation_accept',p_idempotency_key,request_fingerprint) on conflict do nothing;
 select * into stored from public.idempotency_keys where user_id=owner_id and scope='recommendation_accept' and key=p_idempotency_key for update;
 if stored.expires_at<=now() then
  delete from public.idempotency_keys where user_id=owner_id and scope='recommendation_accept' and key=p_idempotency_key;
  insert into public.idempotency_keys(user_id,scope,key,request_hash)
  values(owner_id,'recommendation_accept',p_idempotency_key,request_fingerprint) returning * into stored;
 end if;
 if stored.request_hash<>request_fingerprint then raise exception 'idempotency_conflict' using errcode='P0001'; end if;
 if stored.response_body is not null then return jsonb_build_object('ootd_id',stored.response_body->>'ootd_id','replayed',true); end if;
 perform pg_advisory_xact_lock(hashtextextended(owner_id::text||p_worn_on::text,0));
 select * into existing from public.ootd_entries where user_id=owner_id and worn_on=p_worn_on for update;
 if found then
  if existing.outfit_id is distinct from p_outfit_id then raise exception 'ootd_date_conflict' using errcode='P0001'; end if;
  if not exists(select 1 from public.outfit_recommendations where id=p_outfit_id and request_id=p_recommendation_id and user_id=owner_id)
  then raise exception 'outfit_not_found' using errcode='P0002'; end if;
  response:=jsonb_build_object('ootd_id',existing.id);
  update public.idempotency_keys set response_body=response,response_status=201
   where user_id=owner_id and scope='recommendation_accept' and key=p_idempotency_key;
  return jsonb_build_object('ootd_id',existing.id,'replayed',false);
 end if;
 select * into request from public.recommendation_requests where id=p_recommendation_id and user_id=owner_id for update;
 if not found then raise exception 'recommendation_not_found' using errcode='P0002'; end if;
 if request.target_date<>p_worn_on then raise exception 'recommendation_date_mismatch' using errcode='22023'; end if;
 if request.status<>'ready' or request.expires_at<=now() then raise exception 'recommendation_not_ready' using errcode='P0001'; end if;
 select * into outfit from public.outfit_recommendations where id=p_outfit_id and request_id=request.id and user_id=owner_id for update;
 if not found then raise exception 'outfit_not_found' using errcode='P0002'; end if;
 for locked in select g.deleted_at as garment_deleted_at,a.verified_at as asset_verified_at,a.deleted_at as asset_deleted_at
  from public.outfit_items i
  join public.garments g on g.id=i.garment_id and g.user_id=i.user_id
  join public.garment_assets a on a.id=g.asset_id and a.user_id=g.user_id
  where i.outfit_id=outfit.id and i.user_id=owner_id order by g.id for update of g,a loop
  locked_count:=locked_count+1;
  if locked.garment_deleted_at is not null or locked.asset_verified_at is null or locked.asset_deleted_at is not null
  then raise exception 'outfit_items_unavailable' using errcode='P0001'; end if;
 end loop;
 if locked_count=0 or locked_count<>(select count(*) from public.outfit_items where outfit_id=outfit.id and user_id=owner_id)
 then raise exception 'outfit_items_unavailable' using errcode='P0001'; end if;
 insert into public.ootd_entries(user_id,outfit_id,saved_outfit_id,worn_on,wear_status,visibility,item_snapshot,weather_snapshot_id)
 select owner_id,outfit.id,null,p_worn_on,'worn','private',
  jsonb_agg(jsonb_build_object('garment_id',g.id,'category',g.category,'unavailable',false) order by i.slot,g.id),request.weather_snapshot_id
 from public.outfit_items i join public.garments g on g.id=i.garment_id and g.user_id=i.user_id
 where i.outfit_id=outfit.id and i.user_id=owner_id returning * into result;
 response:=jsonb_build_object('ootd_id',result.id);
 update public.idempotency_keys set response_body=response,response_status=201
 where user_id=owner_id and scope='recommendation_accept' and key=p_idempotency_key;
 return jsonb_build_object('ootd_id',result.id,'replayed',false);
end $$;

-- Internal preference snapshot and reservation coordinates are not part of the browser projection.
revoke select on public.recommendation_requests from authenticated;
grant select(id,user_id,weather_snapshot_id,tpo,target_date,requested_count,status,engine_version,created_at,
 rules_version,expires_at,shortfall_reasons,weather_was_stale) on public.recommendation_requests to authenticated;
-- Remove the superseded pre-reservation overload defined earlier in this still-unapplied migration.
drop function public.store_recommendation(uuid,uuid,date,integer,text,text,jsonb,jsonb,text,text);
revoke insert,update,delete on public.weather_snapshots from service_role;
revoke execute on function public.accept_outfit(uuid,date) from public,anon,authenticated;
revoke all on function public.find_weather_snapshot(integer,integer,timestamptz,text),
 public.get_weather_snapshot(uuid),
 public.upsert_weather_snapshot(integer,integer,timestamptz,timestamptz,text,jsonb),
 public.store_recommendation(uuid,uuid,uuid,boolean,jsonb,jsonb),
 public.begin_my_recommendation(integer,integer,timestamptz,integer,text,text,text,text),
 public.accept_my_recommendation(uuid,uuid,date,text) from public,anon,authenticated;
grant execute on function public.find_weather_snapshot(integer,integer,timestamptz,text),
 public.get_weather_snapshot(uuid),
 public.upsert_weather_snapshot(integer,integer,timestamptz,timestamptz,text,jsonb),
 public.store_recommendation(uuid,uuid,uuid,boolean,jsonb,jsonb) to service_role;
grant execute on function public.begin_my_recommendation(integer,integer,timestamptz,integer,text,text,text,text),
 public.accept_my_recommendation(uuid,uuid,date,text) to authenticated;
