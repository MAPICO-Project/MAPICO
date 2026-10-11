-- 2026-10-10 decisions, track B (OOTD·account). Existing migrations remain immutable.
-- 1) Several OOTD records per day; new records are always 'worn'.
-- 2) External-AI notice (required before analysis) and photo-training consent (optional, default false).
-- 3) Account deletion: every user row is removed; Storage objects go to a cleanup queue.

-- ---------------------------------------------------------------------------
-- 1. Multiple OOTD per day
-- ---------------------------------------------------------------------------
-- Drop by catalog identity (column set), not by the generated name.
do $$ declare constraint_name name; begin
 select c.conname into constraint_name from pg_constraint c
 where c.conrelid='public.ootd_entries'::regclass and c.contype='u'
 and (select array_agg(a.attname::text order by a.attname) from unnest(c.conkey) k
      join pg_attribute a on a.attrelid=c.conrelid and a.attnum=k)=array['user_id','worn_on'];
 if constraint_name is null then raise exception 'ootd_day_unique_constraint_not_found'; end if;
 execute format('alter table public.ootd_entries drop constraint %I',constraint_name);
end $$;
-- Calendar/list order: day DESC, then newest record first. id breaks created_at ties.
drop index if exists public.ootd_owner_page;
create index ootd_owner_day_page on public.ootd_entries(user_id,worn_on desc,created_at desc,id desc);
comment on column public.ootd_entries.wear_status is
 '2026-10-10: new records are worn only. unconfirmed/planned remain for legacy rows and are not counted as wear.';

-- Manual record: always adds one row (Idempotency-Key still dedupes retries). planned is no longer accepted.
create or replace function public.create_my_ootd(
 p_worn_on date,p_garment_ids uuid[],p_saved_outfit_id uuid,p_outfit_id uuid,p_wear_status text,
 p_note text,p_rating integer,p_weather_snapshot_id uuid,p_idempotency_key text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare owner_id uuid:=auth.uid(); tz text; snapshot jsonb; stored public.idempotency_keys; request_fingerprint text;
 result public.ootd_entries; response jsonb; status text:=coalesce(p_wear_status,'worn');
begin
 if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 if p_worn_on is null or status<>'worn' or length(p_note)>1000
 or (p_rating is not null and p_rating not between 1 and 5)
 or num_nonnulls(p_saved_outfit_id,p_outfit_id)>1
 or p_idempotency_key is null or length(p_idempotency_key) not between 8 and 128 or p_idempotency_key!~'^[A-Za-z0-9._:-]+$'
 then raise exception 'invalid_ootd' using errcode='22023'; end if;
 select timezone into tz from public.profiles where id=owner_id;
 if p_worn_on>(now() at time zone tz)::date then raise exception 'future_worn_not_allowed' using errcode='22023'; end if;
 snapshot:=public.g6_build_snapshot(owner_id,p_garment_ids);
 perform public.g6_assert_source(owner_id,p_saved_outfit_id,p_outfit_id,p_garment_ids);
 perform public.g6_validate_weather(owner_id,p_weather_snapshot_id,p_worn_on,p_outfit_id);
 request_fingerprint:=md5(p_worn_on::text||':'||array_to_string(p_garment_ids,',')||':'||coalesce(p_saved_outfit_id::text,'<null>')||':'||coalesce(p_outfit_id::text,'<null>')||':'||status||':'||coalesce(p_note,'<null>')||':'||coalesce(p_rating::text,'<null>')||':'||coalesce(p_weather_snapshot_id::text,'<null>'));
 insert into public.idempotency_keys(user_id,scope,key,request_hash) values(owner_id,'ootd_create',p_idempotency_key,request_fingerprint) on conflict do nothing;
 select * into stored from public.idempotency_keys where user_id=owner_id and scope='ootd_create' and key=p_idempotency_key for update;
 if stored.expires_at<=now() then delete from public.idempotency_keys where user_id=owner_id and scope='ootd_create' and key=p_idempotency_key;
  insert into public.idempotency_keys(user_id,scope,key,request_hash) values(owner_id,'ootd_create',p_idempotency_key,request_fingerprint) returning * into stored; end if;
 if stored.request_hash<>request_fingerprint then raise exception 'idempotency_conflict' using errcode='P0001'; end if;
 if stored.response_body is not null then return jsonb_build_object('ootd_id',stored.response_body->>'ootd_id','replayed',true); end if;
 insert into public.ootd_entries(user_id,outfit_id,saved_outfit_id,worn_on,wear_status,visibility,item_snapshot,weather_snapshot_id,note,rating,version)
 values(owner_id,p_outfit_id,p_saved_outfit_id,p_worn_on,'worn','private',snapshot,p_weather_snapshot_id,p_note,p_rating,1) returning * into result;
 response:=jsonb_build_object('ootd_id',result.id);
 update public.idempotency_keys set response_body=response,response_status=201 where user_id=owner_id and scope='ootd_create' and key=p_idempotency_key;
 return response||jsonb_build_object('replayed',false);
end $$;

-- Update: moving to a day that already has records is allowed. wear_status may only be set to worn
-- (legacy planned -> worn); it can never be set back to planned.
create or replace function public.update_my_ootd(
 p_ootd_id uuid,p_expected_version integer,p_has_worn_on boolean,p_worn_on date,
 p_has_garment_ids boolean,p_garment_ids uuid[],p_has_saved_outfit_id boolean,p_saved_outfit_id uuid,
 p_has_outfit_id boolean,p_outfit_id uuid,p_has_wear_status boolean,p_wear_status text,
 p_has_note boolean,p_note text,p_has_rating boolean,p_rating integer,
 p_has_weather_snapshot_id boolean,p_weather_snapshot_id uuid
) returns jsonb language plpgsql security definer set search_path='' as $$
declare owner_id uuid:=auth.uid(); current_row public.ootd_entries; final_date date; final_saved uuid; final_outfit uuid;
 final_status text; final_note text; final_rating integer; final_weather uuid; final_snapshot jsonb; final_ids uuid[]; tz text;
begin
 if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 if p_ootd_id is null or p_expected_version is null or p_expected_version<1
 or p_has_worn_on is null or p_has_garment_ids is null or p_has_saved_outfit_id is null or p_has_outfit_id is null
 or p_has_wear_status is null or p_has_note is null or p_has_rating is null or p_has_weather_snapshot_id is null
 or not(p_has_worn_on or p_has_garment_ids or p_has_saved_outfit_id or p_has_outfit_id or p_has_wear_status or p_has_note or p_has_rating or p_has_weather_snapshot_id)
 then raise exception 'invalid_ootd_patch' using errcode='22023'; end if;
 select * into current_row from public.ootd_entries where id=p_ootd_id and user_id=owner_id for update;
 if not found then raise exception 'ootd_not_found' using errcode='P0002'; end if;
 if current_row.version<>p_expected_version then raise exception 'version_conflict' using errcode='P0001'; end if;
 if exists(select 1 from public.idempotency_keys where user_id=owner_id and scope='recommendation_accept'
  and response_body->>'ootd_id'=current_row.id::text)
 then raise exception 'accepted_ootd_immutable' using errcode='P0001'; end if;
 final_date:=case when p_has_worn_on then p_worn_on else current_row.worn_on end;
 final_saved:=case when p_has_saved_outfit_id then p_saved_outfit_id else current_row.saved_outfit_id end;
 final_outfit:=case when p_has_outfit_id then p_outfit_id else current_row.outfit_id end;
 final_status:=case when p_has_wear_status then p_wear_status else current_row.wear_status end;
 final_note:=case when p_has_note then p_note else current_row.note end;
 final_rating:=case when p_has_rating then p_rating else current_row.rating end;
 final_weather:=case when p_has_weather_snapshot_id then p_weather_snapshot_id else current_row.weather_snapshot_id end;
 if final_date is null or (p_has_wear_status and p_wear_status is distinct from 'worn') or length(final_note)>1000
 or (final_rating is not null and final_rating not between 1 and 5) or (final_status='planned' and final_rating is not null)
 or num_nonnulls(final_saved,final_outfit)>1 then raise exception 'invalid_ootd' using errcode='22023'; end if;
 select timezone into tz from public.profiles where id=owner_id;
 if final_status='worn' and final_date>(now() at time zone tz)::date then raise exception 'future_worn_not_allowed' using errcode='22023'; end if;
 if p_has_garment_ids then final_snapshot:=public.g6_build_snapshot(owner_id,p_garment_ids); final_ids:=p_garment_ids;
 else final_snapshot:=current_row.item_snapshot;
  select array_agg((x->>'garment_id')::uuid order by ord) into final_ids from jsonb_array_elements(current_row.item_snapshot) with ordinality a(x,ord);
 end if;
 perform public.g6_assert_source(owner_id,final_saved,final_outfit,final_ids);
 perform public.g6_validate_weather(owner_id,final_weather,final_date,final_outfit);
 update public.ootd_entries set worn_on=final_date,saved_outfit_id=final_saved,outfit_id=final_outfit,
  wear_status=final_status,note=final_note,rating=final_rating,weather_snapshot_id=final_weather,
  item_snapshot=final_snapshot,version=version+1 where id=current_row.id;
 return jsonb_build_object('ootd_id',current_row.id,'version',current_row.version+1);
end $$;

-- '오늘 입기': a different outfit on the same day adds one more record. Accepting the SAME outfit
-- for the same day again (new key, double tap) returns the existing record instead of a duplicate.
create or replace function public.accept_my_recommendation(
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
 -- Serialises concurrent acceptances of the same outfit for the same day.
 perform pg_advisory_xact_lock(hashtextextended(owner_id::text||p_worn_on::text||p_outfit_id::text,0));
 select * into existing from public.ootd_entries where user_id=owner_id and worn_on=p_worn_on and outfit_id=p_outfit_id
  order by created_at,id limit 1 for update;
 if found then
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

-- Calendar summary: one row per day with the record count and a representative record.
-- Representative = newest record that has a photo; if none has a photo, the newest record
-- (created_at DESC, id DESC — the same order GET /ootd uses within a day). The Storage key is not
-- returned (has_photo only); the BFF reads the representative's key and returns a signed URL.
create function public.get_my_ootd_calendar(p_from date,p_to date)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare owner_id uuid:=auth.uid(); result jsonb;
begin
 if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 if p_from is null or p_to is null or p_from>p_to or p_to-p_from>61 then raise exception 'invalid_calendar_range' using errcode='22023'; end if;
 with ranked as (
  select o.worn_on,o.id,o.photo_object_key,o.weather_snapshot_id,
   count(*) over(partition by o.worn_on) as n,
   row_number() over(partition by o.worn_on order by (o.photo_object_key is not null) desc,o.created_at desc,o.id desc) as rn
  from public.ootd_entries o where o.user_id=owner_id and o.worn_on between p_from and p_to
 )
 select coalesce(jsonb_agg(jsonb_build_object('date',worn_on,'count',n,'representative_ootd_id',id,
  'has_photo',photo_object_key is not null,'weather_snapshot_id',weather_snapshot_id) order by worn_on desc),'[]'::jsonb)
 into result from ranked where rn=1;
 return result;
end $$;

-- ---------------------------------------------------------------------------
-- 2. External-AI notice and training consent
-- ---------------------------------------------------------------------------
-- training_consent (core migration, default false) is reused as the optional photo-training consent.
alter table public.profiles add column ai_notice_accepted_at timestamptz;
alter table public.profiles add column training_consent_updated_at timestamptz;
comment on column public.profiles.ai_notice_accepted_at is
 'Required notice: photos are sent to an external AI service for analysis. NULL = analysis jobs are refused.';
comment on column public.profiles.training_consent is
 'Optional consent to use photos for model training. Default false. Stored only; no training pipeline reads it yet.';

-- PATCH /me: profile fields, notice acceptance and training consent in one transaction.
-- The notice timestamp is set once (first acceptance) and cannot be withdrawn through the API.
create function public.update_my_profile_settings(
 p_set_display_name boolean,p_display_name text,p_set_timezone boolean,p_timezone text,
 p_set_avatar boolean,p_avatar_upload_id uuid,p_accept_ai_notice boolean,
 p_set_training_consent boolean,p_training_consent boolean
) returns void language plpgsql security definer set search_path='' as $$
declare owner_id uuid:=auth.uid();
begin
 if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 if p_set_display_name is null or p_set_timezone is null or p_set_avatar is null
 or p_accept_ai_notice is null or p_set_training_consent is null
 or not(p_set_display_name or p_set_timezone or p_set_avatar or p_accept_ai_notice or p_set_training_consent)
 then raise exception 'empty_profile_patch' using errcode='22023'; end if;
 if p_set_training_consent and p_training_consent is null then raise exception 'invalid_consent' using errcode='22023'; end if;
 perform id from public.profiles where id=owner_id for update;
 if not found then raise exception 'profile_not_found' using errcode='P0002'; end if;
 if p_set_display_name or p_set_timezone or p_set_avatar then
  perform public.update_my_profile_with_avatar(p_set_display_name,p_display_name,p_set_timezone,p_timezone,p_set_avatar,p_avatar_upload_id);
 end if;
 if p_accept_ai_notice then
  update public.profiles set ai_notice_accepted_at=coalesce(ai_notice_accepted_at,now()) where id=owner_id;
 end if;
 if p_set_training_consent then
  update public.profiles set training_consent=p_training_consent,
   training_consent_updated_at=case when training_consent is distinct from p_training_consent then now() else training_consent_updated_at end
  where id=owner_id;
 end if;
end $$;

create function public.g10b_require_ai_notice(p_owner uuid) returns void
language plpgsql stable security definer set search_path='' as $$
begin
 if not exists(select 1 from public.profiles where id=p_owner and ai_notice_accepted_at is not null)
 then raise exception 'ai_notice_required' using errcode='P0001'; end if;
end $$;

-- Analysis create/retry send the photo to the external worker: refuse without the notice.
create or replace function public.create_my_analysis_job(p_batch_id uuid,p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare owner_id uuid:=auth.uid(); b public.garment_batches; stored public.idempotency_keys;
 request_fingerprint text; j public.analysis_jobs; response jsonb;
begin
 if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 if p_batch_id is null then raise exception 'invalid_batch_id' using errcode='22023'; end if;
 if p_idempotency_key is null or length(p_idempotency_key) not between 8 and 128
 or p_idempotency_key !~ '^[A-Za-z0-9._:-]+$' then raise exception 'invalid_idempotency_key' using errcode='22023'; end if;
 perform public.g10b_require_ai_notice(owner_id);
 request_fingerprint:=md5(p_batch_id::text);
 insert into public.idempotency_keys(user_id,scope,key,request_hash)
 values(owner_id,'analysis_job_create',p_idempotency_key,request_fingerprint) on conflict do nothing;
 select * into stored from public.idempotency_keys where user_id=owner_id and scope='analysis_job_create' and key=p_idempotency_key for update;
 if stored.expires_at<=now() then
  delete from public.idempotency_keys where user_id=owner_id and scope='analysis_job_create' and key=p_idempotency_key;
  insert into public.idempotency_keys(user_id,scope,key,request_hash)
  values(owner_id,'analysis_job_create',p_idempotency_key,request_fingerprint) returning * into stored;
 end if;
 if stored.request_hash<>request_fingerprint then raise exception 'idempotency_conflict' using errcode='P0001'; end if;
 if stored.response_body is not null then return stored.response_body; end if;
 select * into b from public.garment_batches where id=p_batch_id and user_id=owner_id for update;
 if not found then raise exception 'batch_not_found' using errcode='P0002'; end if;
 if b.status<>'uploaded' then raise exception 'batch_not_uploaded' using errcode='P0001'; end if;
 if not exists(select 1 from public.garment_assets where user_id=owner_id and batch_id=b.id and kind='source' and verified_at is not null and deleted_at is null)
 then raise exception 'source_asset_not_ready' using errcode='P0001'; end if;
 if exists(select 1 from public.analysis_jobs where batch_id=b.id) then raise exception 'analysis_job_exists' using errcode='P0001'; end if;
 insert into public.analysis_jobs(user_id,batch_id) values(owner_id,b.id) returning * into j;
 update public.garment_batches set status='processing' where id=b.id;
 response:=jsonb_build_object('id',j.id,'batch_id',j.batch_id,'status',j.status,'attempt',j.attempt,'max_attempts',j.max_attempts,
  'progress',j.progress,'stage',j.stage,'error_code',j.error_code,'created_at',j.created_at,'updated_at',j.updated_at,'completed_at',j.completed_at);
 update public.idempotency_keys set response_body=response,response_status=202
 where user_id=owner_id and scope='analysis_job_create' and key=p_idempotency_key;
 return response;
end $$;

create or replace function public.retry_my_analysis_job(p_job_id uuid,p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare owner_id uuid:=auth.uid(); j public.analysis_jobs; b public.garment_batches; stored public.idempotency_keys;
 request_fingerprint text; response jsonb;
begin
 if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 if p_job_id is null then raise exception 'invalid_job_id' using errcode='22023'; end if;
 if p_idempotency_key is null or length(p_idempotency_key) not between 8 and 128
 or p_idempotency_key !~ '^[A-Za-z0-9._:-]+$' then raise exception 'invalid_idempotency_key' using errcode='22023'; end if;
 perform public.g10b_require_ai_notice(owner_id);
 request_fingerprint:=md5(p_job_id::text);
 insert into public.idempotency_keys(user_id,scope,key,request_hash)
 values(owner_id,'analysis_job_retry',p_idempotency_key,request_fingerprint) on conflict do nothing;
 select * into stored from public.idempotency_keys where user_id=owner_id and scope='analysis_job_retry' and key=p_idempotency_key for update;
 if stored.expires_at<=now() then
  delete from public.idempotency_keys where user_id=owner_id and scope='analysis_job_retry' and key=p_idempotency_key;
  insert into public.idempotency_keys(user_id,scope,key,request_hash)
  values(owner_id,'analysis_job_retry',p_idempotency_key,request_fingerprint) returning * into stored;
 end if;
 if stored.request_hash<>request_fingerprint then raise exception 'idempotency_conflict' using errcode='P0001'; end if;
 if stored.response_body is not null then return stored.response_body; end if;
 select * into j from public.analysis_jobs where id=p_job_id and user_id=owner_id for update;
 if not found then raise exception 'job_not_found' using errcode='P0002'; end if;
 select * into b from public.garment_batches where id=j.batch_id and user_id=owner_id for update;
 if b.status='confirmed' then raise exception 'batch_already_confirmed' using errcode='P0001'; end if;
 if j.status<>'failed' then raise exception 'job_not_retryable' using errcode='P0001'; end if;
 if j.attempt>=j.max_attempts then raise exception 'attempts_exhausted' using errcode='P0001'; end if;
 if coalesce(j.error_code,'') not in ('WORKER_TIMEOUT','MODEL_UNAVAILABLE','STORAGE_UNAVAILABLE','INTERNAL_ERROR','CALLBACK_TIMEOUT')
 then raise exception 'job_not_retryable' using errcode='P0001'; end if;
 update public.analysis_jobs set status='queued',available_at=now(),lease_token=null,lease_expires_at=null,
  progress=0,stage=null,result=null,error_code=null,completed_at=null where id=j.id returning * into j;
 update public.garment_batches set status='processing' where id=b.id;
 response:=jsonb_build_object('id',j.id,'batch_id',j.batch_id,'status',j.status,'attempt',j.attempt,'max_attempts',j.max_attempts,
  'progress',j.progress,'stage',j.stage,'error_code',j.error_code,'created_at',j.created_at,'updated_at',j.updated_at,'completed_at',j.completed_at);
 update public.idempotency_keys set response_body=response,response_status=202
 where user_id=owner_id and scope='analysis_job_retry' and key=p_idempotency_key;
 return response;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Account deletion
-- ---------------------------------------------------------------------------
-- Storage objects cannot be removed from SQL; a server-side worker deletes the object and then
-- this row. No user_id/FK so the queue outlives the account. (Worker not implemented yet.)
create table public.storage_cleanup_queue (
 id uuid primary key default gen_random_uuid(),
 bucket_id text not null check(bucket_id in ('closet-private','feed-private','profile-media','ootd-private')),
 object_key text not null check(length(object_key) between 1 and 1024),
 reason text not null check(reason in ('account_deletion')),
 enqueued_at timestamptz not null default now(),
 attempts integer not null default 0 check(attempts>=0),
 unique(bucket_id,object_key)
);
alter table public.storage_cleanup_queue enable row level security;
revoke all on public.storage_cleanup_queue from public,anon,authenticated;
grant all on public.storage_cleanup_queue to service_role;

-- Service-only. Called by DELETE /me after the user JWT was verified; the BFF then deletes the
-- auth user with the Admin API. Idempotent: a retry after a partial failure finds no profile,
-- re-enqueues any leftover objects (no-op on conflict) and returns profile_deleted=false.
-- Removes every user-owned row, including other members' likes and mimic jobs on this user's
-- posts (post_likes/mimic_requests cascade from feed_posts).
create function public.purge_account_data(p_user_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare existed boolean; enqueued integer;
begin
 if p_user_id is null then raise exception 'invalid_user_id' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended('account_purge:'||p_user_id::text,0));
 perform id from public.profiles where id=p_user_id for update;
 existed:=found;
 insert into public.storage_cleanup_queue(bucket_id,object_key,reason)
 select s.bucket_id,s.object_key,'account_deletion' from (
  select a.bucket_id,a.object_key from public.garment_assets a where a.user_id=p_user_id
  union select m.bucket_id,m.object_key from public.feed_media m where m.user_id=p_user_id
  union select u.bucket_id,u.object_key from public.media_uploads u where u.user_id=p_user_id
  -- Objects uploaded without a surviving DB row (abandoned uploads) share the owner prefix.
  union select o.bucket_id,o.name from storage.objects o
   where o.bucket_id in ('closet-private','feed-private','profile-media','ootd-private')
   and split_part(o.name,'/',1)=p_user_id::text
 ) s on conflict(bucket_id,object_key) do nothing;
 get diagnostics enqueued=row_count;
 -- Explicit child-first order: ON DELETE NO ACTION references (e.g. outfit_items -> garments,
 -- feed_posts -> ootd_entries) are checked per cascaded statement, so one profile delete is not enough.
 update public.profiles set avatar_object_key=null where id=p_user_id;
 delete from public.feed_posts where user_id=p_user_id;   -- media, links, others' likes/mimic jobs cascade
 delete from public.post_likes where user_id=p_user_id;
 delete from public.mimic_requests where user_id=p_user_id;
 delete from public.ootd_entries where user_id=p_user_id;
 delete from public.saved_outfits where user_id=p_user_id;
 delete from public.recommendation_requests where user_id=p_user_id;
 delete from public.garments where user_id=p_user_id;     -- aesthetic scores, embeddings cascade
 delete from public.garment_drafts where user_id=p_user_id;
 delete from public.analysis_jobs where user_id=p_user_id;
 delete from public.garment_assets where user_id=p_user_id;
 delete from public.garment_batches where user_id=p_user_id;
 delete from public.media_uploads where user_id=p_user_id;
 delete from public.profiles where id=p_user_id;           -- preferences, idempotency keys and the rest cascade
 return jsonb_build_object('user_id',p_user_id,'profile_deleted',existed,'storage_objects_enqueued',enqueued);
end $$;

revoke all on function public.get_my_ootd_calendar(date,date),
 public.update_my_profile_settings(boolean,text,boolean,text,boolean,uuid,boolean,boolean,boolean),
 public.g10b_require_ai_notice(uuid),public.purge_account_data(uuid) from public,anon,authenticated;
grant execute on function public.get_my_ootd_calendar(date,date),
 public.update_my_profile_settings(boolean,text,boolean,text,boolean,uuid,boolean,boolean,boolean) to authenticated;
grant execute on function public.purge_account_data(uuid) to service_role;
