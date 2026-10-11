-- 2026-10-10 track C: home aesthetic chip on recommendations, and "most-worn aesthetic" statistics.
-- Region (시·도) selection needs no schema change: the API maps a region code to a representative
-- coordinate and then to the same weather grid. Wardrobe-sufficiency rules live in lib/recommendations.js
-- and are stored through the existing shortfall_reasons array.

-- 1. The chip the user selected on Home (main by default, or one of their subs). Null for users with no
--    aesthetic preferences (and rows created before this migration).
alter table public.recommendation_requests add column selected_aesthetic_id uuid references public.aesthetics(id);
grant select(selected_aesthetic_id) on public.recommendation_requests to authenticated;

-- The 9-argument reservation replaces the 8-argument one (dropped; remote DB has never been pushed, so no
-- legacy caller exists and a single signature avoids PostgREST overload ambiguity). Body = 202610010002
-- version plus the chip check (after the idempotent replay branch) and column write. The selected aesthetic must be one of the caller's own
-- preferences; it may be null only when the caller has none.
drop function public.begin_my_recommendation(integer,integer,timestamptz,integer,text,text,text,text);
create function public.begin_my_recommendation(
 p_grid_x integer,p_grid_y integer,p_valid_at timestamptz,p_requested_count integer,
 p_idempotency_key text,p_request_hash text,p_engine_version text,p_rules_version text,p_selected_aesthetic_id uuid
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
 -- Chip check only for a new reservation: a same-key retry replays the earlier result even if
 -- preferences changed since (the request hash already pins the selection).
 if p_selected_aesthetic_id is null then
  if exists(select 1 from public.user_aesthetic_preferences where user_id=owner_id)
  then raise exception 'invalid_recommendation' using errcode='22023'; end if;
 elsif not exists(select 1 from public.user_aesthetic_preferences where user_id=owner_id and aesthetic_id=p_selected_aesthetic_id)
 then raise exception 'invalid_recommendation' using errcode='22023'; end if;
 lease_token:=gen_random_uuid();
 insert into public.recommendation_requests(user_id,weather_snapshot_id,tpo,target_date,requested_count,status,
  preference_snapshot,engine_version,rules_version,shortfall_reasons,weather_grid_x,weather_grid_y,weather_valid_at,
  reservation_token,reservation_lease_expires_at,selected_aesthetic_id)
 values(owner_id,null,null,target,p_requested_count,'pending','[]',p_engine_version,p_rules_version,'[]',p_grid_x,p_grid_y,p_valid_at,
  lease_token,now()+interval '2 minutes',p_selected_aesthetic_id)
 returning * into request;
 response:=jsonb_build_object('request_id',request.id);
 update public.idempotency_keys set response_body=response,response_status=202
 where user_id=owner_id and scope='recommendation_create' and key=p_idempotency_key;
 return jsonb_build_object('request_id',request.id,'status','pending','replayed',false,'in_progress',false,'resumed',false,
  'reservation_token',lease_token,'lease_expires_at',request.reservation_lease_expires_at);
end $$;
revoke all on function public.begin_my_recommendation(integer,integer,timestamptz,integer,text,text,text,text,uuid) from public,anon,authenticated;
grant execute on function public.begin_my_recommendation(integer,integer,timestamptz,integer,text,text,text,text,uuid) to authenticated;

-- 2. Statistics: same signature and grants as 202610010003, plus aesthetic totals.
-- Most-worn aesthetic = per worn OOTD entry (each entry counts, so several entries on one day add up),
-- per distinct garment in that entry's snapshot, sum garment_aesthetic_scores.score by aesthetic.
-- Ties break by aesthetic code. No scores at all -> top_aesthetic null, aesthetic_totals [].
create or replace function public.get_my_closet_statistics()
returns jsonb language plpgsql security definer set search_path='' as $$
declare owner_id uuid:=auth.uid(); tz text; as_of date; counts jsonb; unworn jsonb; totals jsonb;
begin
 if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 select timezone into tz from public.profiles where id=owner_id;
 as_of:=(now() at time zone tz)::date;
 with parsed as (
  select o.id,case when jsonb_typeof(x)='object' and coalesce(x->>'garment_id','')~'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
   then (x->>'garment_id')::uuid end garment_id
  from public.ootd_entries o cross join lateral jsonb_array_elements(
   case when jsonb_typeof(o.item_snapshot)='array' then o.item_snapshot else '[]'::jsonb end) a(x)
  where o.user_id=owner_id and o.wear_status='worn' and o.worn_on<=as_of
 ), worn as (
  select distinct id,garment_id from parsed where garment_id is not null
 ), active as (select id from public.garments where user_id=owner_id and deleted_at is null)
 select coalesce(jsonb_agg(jsonb_build_object('garment_id',a.id,'count',coalesce(c.n,0)) order by a.id),'[]'::jsonb)
 into counts from active a left join (select garment_id,count(*) n from worn group by garment_id) c on c.garment_id=a.id;
 with parsed as (
  select case when jsonb_typeof(x)='object' and coalesce(x->>'garment_id','')~'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
   then (x->>'garment_id')::uuid end garment_id from public.ootd_entries o
  cross join lateral jsonb_array_elements(case when jsonb_typeof(o.item_snapshot)='array' then o.item_snapshot else '[]'::jsonb end) a(x)
  where o.user_id=owner_id and o.wear_status='worn' and o.worn_on between as_of-29 and as_of
 ), recent as (
  select distinct garment_id from parsed where garment_id is not null
 )
 select coalesce(jsonb_agg(g.id order by g.id),'[]'::jsonb) into unworn from public.garments g
 where g.user_id=owner_id and g.deleted_at is null and not exists(select 1 from recent r where r.garment_id=g.id);
 with parsed as (
  select o.id,case when jsonb_typeof(x)='object' and coalesce(x->>'garment_id','')~'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
   then (x->>'garment_id')::uuid end garment_id
  from public.ootd_entries o cross join lateral jsonb_array_elements(
   case when jsonb_typeof(o.item_snapshot)='array' then o.item_snapshot else '[]'::jsonb end) a(x)
  where o.user_id=owner_id and o.wear_status='worn' and o.worn_on<=as_of
 ), worn as (
  select distinct id,garment_id from parsed where garment_id is not null
 ), summed as (
  select s.aesthetic_id,sum(s.score) total from worn w
  join public.garment_aesthetic_scores s on s.garment_id=w.garment_id and s.user_id=owner_id
  group by s.aesthetic_id
 )
 select coalesce(jsonb_agg(jsonb_build_object('aesthetic_id',a.id,'code',a.code,'label',a.label,'score_total',round(m.total,3))
  order by m.total desc,a.code),'[]'::jsonb)
 into totals from summed m join public.aesthetics a on a.id=m.aesthetic_id where m.total>0;
 return jsonb_build_object('as_of',as_of,'wear_counts',counts,'unworn_30_days',unworn,
  'aesthetic_totals',totals,'top_aesthetic',case when jsonb_array_length(totals)>0 then totals->0 else 'null'::jsonb end);
end $$;
