-- 2026-10-09 user-flow alignment (PM-independent items only): aesthetic main/sub roles,
-- feed weather 'wind', one selected OOTD photo and a profile image. Existing migrations remain immutable.

-- 1. Aesthetic roles. role is canonical; weight keeps its old meaning (0<w<=1, sum 1) and
-- may never rank a sub above the main.
alter table public.user_aesthetic_preferences add column role text check(role in ('main','sub'));
update public.user_aesthetic_preferences p set role=case when p.aesthetic_id=(
 select q.aesthetic_id from public.user_aesthetic_preferences q where q.user_id=p.user_id
 order by q.weight desc,q.aesthetic_id limit 1) then 'main' else 'sub' end;
alter table public.user_aesthetic_preferences alter column role set not null;
create unique index one_main_aesthetic_per_user on public.user_aesthetic_preferences(user_id) where role='main';

-- Deferred so replace-all writes (delete + insert) are judged on the final state.
create function public.g9_check_aesthetic_roles() returns trigger
language plpgsql security definer set search_path='' as $$
declare target uuid; mains integer; subs integer;
begin
 foreach target in array array_remove(array[
  case when tg_op<>'INSERT' then old.user_id end,
  case when tg_op<>'DELETE' then new.user_id end],null) loop
  select count(*) filter(where role='main'),count(*) filter(where role='sub') into mains,subs
   from public.user_aesthetic_preferences where user_id=target;
  if mains+subs>0 and (mains<>1 or subs>2) then
   raise exception 'invalid_aesthetic_roles' using errcode='23514';
  end if;
  if exists(select 1 from public.user_aesthetic_preferences s join public.user_aesthetic_preferences m
   on m.user_id=s.user_id and m.role='main' where s.user_id=target and s.role='sub' and s.weight>m.weight)
  then raise exception 'invalid_main_weight' using errcode='23514'; end if;
 end loop;
 return null;
end $$;
create constraint trigger aesthetic_roles_valid after insert or update or delete on public.user_aesthetic_preferences
 deferrable initially deferred for each row execute function public.g9_check_aesthetic_roles();

-- Items: {aesthetic_id, role, weight?}. Exactly one main, 0..2 sub. Weights are all-or-none;
-- when omitted every item gets 1/n (role, not weight, carries priority).
create or replace function public.replace_my_aesthetic_preferences(p_preferences jsonb)
returns void language plpgsql security definer set search_path='' as $$
declare owner_id uuid:=auth.uid(); item_count integer; weighted integer;
begin
 if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 if p_preferences is null or jsonb_typeof(p_preferences) is distinct from 'array'
 then raise exception 'invalid_preferences' using errcode='22023'; end if;
 item_count:=jsonb_array_length(p_preferences);
 if item_count not between 1 and 3 then raise exception 'invalid_preference_count' using errcode='22023'; end if;
 if exists(
  select 1 from jsonb_array_elements(p_preferences) value
  where jsonb_typeof(value) is distinct from 'object'
     or case when jsonb_typeof(value)='object' then
      not (value ? 'aesthetic_id' and value ? 'role')
      or exists(select 1 from jsonb_object_keys(value) k where k not in ('aesthetic_id','role','weight'))
      or jsonb_typeof(value->'aesthetic_id') is distinct from 'string'
      or (value->>'aesthetic_id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      or jsonb_typeof(value->'role') is distinct from 'string'
      or (value->>'role') not in ('main','sub')
      or (value ? 'weight' and case when jsonb_typeof(value->'weight')='number'
       then (value->>'weight')::numeric<=0 or (value->>'weight')::numeric>1 else true end)
     else true end
 ) then raise exception 'invalid_preferences' using errcode='22023'; end if;
 if (select count(distinct lower(value->>'aesthetic_id')) from jsonb_array_elements(p_preferences) value)<>item_count
 then raise exception 'duplicate_aesthetic' using errcode='22023'; end if;
 if (select count(*) from jsonb_array_elements(p_preferences) value where value->>'role'='main')<>1
 then raise exception 'invalid_aesthetic_roles' using errcode='22023'; end if;
 select count(*) into weighted from jsonb_array_elements(p_preferences) value where value ? 'weight';
 if weighted not in (0,item_count) then raise exception 'invalid_preferences' using errcode='22023'; end if;
 if weighted>0 then
  if abs((select sum((value->>'weight')::numeric) from jsonb_array_elements(p_preferences) value)-1)>0.0001
  then raise exception 'invalid_preference_weight_sum' using errcode='22023'; end if;
  if (select max((value->>'weight')::numeric) from jsonb_array_elements(p_preferences) value where value->>'role'='sub')
   >(select (value->>'weight')::numeric from jsonb_array_elements(p_preferences) value where value->>'role'='main')
  then raise exception 'invalid_main_weight' using errcode='22023'; end if;
 end if;

 -- The profile row is a per-user mutex for concurrent account writes and replacements.
 perform id from public.profiles where id=owner_id for update;
 if not found then raise exception 'profile_not_found' using errcode='P0002'; end if;
 if (
  select count(*) from public.aesthetics
  where active and id=any(array(
   select (value->>'aesthetic_id')::uuid from jsonb_array_elements(p_preferences) value
  ))
 )<>item_count then raise exception 'inactive_or_unknown_aesthetic' using errcode='22023'; end if;

 delete from public.user_aesthetic_preferences where user_id=owner_id;
 insert into public.user_aesthetic_preferences(user_id,aesthetic_id,weight,role)
 select owner_id,(value->>'aesthetic_id')::uuid,
  case when weighted=0 then 1.0/item_count else (value->>'weight')::numeric end,value->>'role'
 from jsonb_array_elements(p_preferences) value;
 set constraints public.aesthetic_roles_valid immediate;
end $$;

-- 2. Feed weather 'wind' (user flow filter: 맑음·흐림·비·눈·바람).
alter table public.feed_posts drop constraint feed_posts_weather_code_check;
alter table public.feed_posts add constraint feed_posts_weather_code_check
 check(weather_code in ('clear','cloudy','rain','snow','wind','unknown'));

create or replace function public.create_my_feed_post(
 p_source_ootd_id uuid,p_caption text,p_aesthetic_id uuid,p_weather_code text,
 p_temperature_c numeric,p_idempotency_key text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare owner_id uuid:=auth.uid(); stored public.idempotency_keys; result public.feed_posts;
 request_fingerprint text; response jsonb; normalized_weather text:=coalesce(p_weather_code,'unknown');
begin
 if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 if p_caption is null or length(p_caption)>2000 or p_aesthetic_id is null
 or normalized_weather not in ('clear','cloudy','rain','snow','wind','unknown')
 or (p_temperature_c is not null and p_temperature_c not between -90 and 60)
 or p_idempotency_key is null or length(p_idempotency_key) not between 8 and 128
 or p_idempotency_key!~'^[A-Za-z0-9._:-]+$'
 then raise exception 'invalid_feed_post' using errcode='22023'; end if;
 if not exists(select 1 from public.aesthetics where id=p_aesthetic_id and active)
 then raise exception 'aesthetic_not_found' using errcode='P0002'; end if;
 if p_source_ootd_id is not null and not exists(
  select 1 from public.ootd_entries where id=p_source_ootd_id and user_id=owner_id
 ) then raise exception 'ootd_not_found' using errcode='P0002'; end if;
 request_fingerprint:=md5(coalesce(p_source_ootd_id::text,'<null>')||':'||p_caption||':'||p_aesthetic_id::text||':'||normalized_weather||':'||coalesce(p_temperature_c::text,'<null>'));
 insert into public.idempotency_keys(user_id,scope,key,request_hash)
 values(owner_id,'feed_post_create',p_idempotency_key,request_fingerprint) on conflict do nothing;
 select * into stored from public.idempotency_keys
  where user_id=owner_id and scope='feed_post_create' and key=p_idempotency_key for update;
 if stored.expires_at<=now() then
  delete from public.idempotency_keys where user_id=owner_id and scope='feed_post_create' and key=p_idempotency_key;
  insert into public.idempotency_keys(user_id,scope,key,request_hash)
  values(owner_id,'feed_post_create',p_idempotency_key,request_fingerprint) returning * into stored;
 end if;
 if stored.request_hash<>request_fingerprint then raise exception 'idempotency_conflict' using errcode='P0001'; end if;
 if stored.response_body is not null then
  return jsonb_build_object('post_id',stored.response_body->>'post_id','replayed',true);
 end if;
 insert into public.feed_posts(user_id,source_ootd_id,caption,aesthetic_id,weather_code,temperature_c,visibility)
 values(owner_id,p_source_ootd_id,p_caption,p_aesthetic_id,normalized_weather,p_temperature_c,'private') returning * into result;
 response:=jsonb_build_object('post_id',result.id);
 update public.idempotency_keys set response_body=response,response_status=201
  where user_id=owner_id and scope='feed_post_create' and key=p_idempotency_key;
 return response||jsonb_build_object('replayed',false);
end $$;

-- 3+4. Owner-only uploads for the OOTD photo and the profile image. Same two-step pattern as
-- garment sources: server row -> signed upload -> server verification -> attach once.
-- Separate private buckets keep OOTD photos away from closet originals and public feed copies.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values
 ('profile-media','profile-media',false,20971520,array['image/jpeg','image/png','image/webp']),
 ('ootd-private','ootd-private',false,20971520,array['image/jpeg','image/png','image/webp']);

create table public.media_uploads (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references public.profiles(id) on delete cascade,
 purpose text not null check(purpose in ('avatar','ootd_photo')),
 bucket_id text not null check(bucket_id in ('profile-media','ootd-private')),
 object_key text unique not null, content_type text not null check(content_type in ('image/jpeg','image/png','image/webp')),
 byte_size bigint not null check(byte_size between 1 and 20971520),
 verified_at timestamptz, attached_at timestamptz, deleted_at timestamptz, created_at timestamptz not null default now(),
 unique(user_id,id), unique(user_id,object_key),
 check((purpose='avatar' and bucket_id='profile-media') or (purpose='ootd_photo' and bucket_id='ootd-private')),
 check(split_part(object_key,'/',1)=user_id::text and split_part(object_key,'/',2)=purpose),
 check(attached_at is null or verified_at is not null)
);
create index media_upload_open on public.media_uploads(user_id,created_at) where verified_at is null and deleted_at is null;
alter table public.media_uploads enable row level security;
revoke all on public.media_uploads from public,anon,authenticated;
grant all on public.media_uploads to service_role;
create policy owner_read on public.media_uploads for select to authenticated using((select auth.uid())=user_id);
grant select on public.media_uploads to authenticated;

-- Storage path columns. Composite FKs pin the object to the same owner; the path segment pins the purpose.
alter table public.profiles add column avatar_object_key text unique;
alter table public.profiles add constraint profile_avatar_owner foreign key(id,avatar_object_key)
 references public.media_uploads(user_id,object_key);
alter table public.profiles add constraint profile_avatar_purpose
 check(avatar_object_key is null or split_part(avatar_object_key,'/',2)='avatar');
alter table public.ootd_entries add column photo_object_key text unique;
alter table public.ootd_entries add constraint ootd_photo_owner foreign key(user_id,photo_object_key)
 references public.media_uploads(user_id,object_key);
alter table public.ootd_entries add constraint ootd_photo_purpose
 check(photo_object_key is null or split_part(photo_object_key,'/',2)='ootd_photo');

create function public.create_my_media_upload(
 p_purpose text,p_content_type text,p_file_size bigint,p_idempotency_key text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare owner_id uuid:=auth.uid(); stored public.idempotency_keys; request_fingerprint text;
 upload_id uuid; extension text; response jsonb;
begin
 if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 if p_purpose is null or p_purpose not in ('avatar','ootd_photo')
 or p_content_type is null or p_content_type not in ('image/jpeg','image/png','image/webp')
 or p_file_size is null or p_file_size not between 1 and 20971520
 or p_idempotency_key is null or length(p_idempotency_key) not between 8 and 128
 or p_idempotency_key!~'^[A-Za-z0-9._:-]+$'
 then raise exception 'invalid_media_upload' using errcode='22023'; end if;
 perform id from public.profiles where id=owner_id for update;
 if not found then raise exception 'profile_not_found' using errcode='P0002'; end if;
 request_fingerprint:=md5(p_purpose||':'||p_content_type||':'||p_file_size::text);
 insert into public.idempotency_keys(user_id,scope,key,request_hash)
 values(owner_id,'media_upload_create',p_idempotency_key,request_fingerprint) on conflict do nothing;
 select * into stored from public.idempotency_keys
  where user_id=owner_id and scope='media_upload_create' and key=p_idempotency_key for update;
 if stored.expires_at<=now() then
  delete from public.idempotency_keys where user_id=owner_id and scope='media_upload_create' and key=p_idempotency_key;
  insert into public.idempotency_keys(user_id,scope,key,request_hash)
  values(owner_id,'media_upload_create',p_idempotency_key,request_fingerprint) returning * into stored;
 end if;
 if stored.request_hash<>request_fingerprint then raise exception 'idempotency_conflict' using errcode='P0001'; end if;
 if stored.response_body is not null then
  return jsonb_build_object('upload_id',stored.response_body->>'upload_id','replayed',true);
 end if;
 if (select count(*) from public.media_uploads where user_id=owner_id and verified_at is null and deleted_at is null
  and created_at>now()-interval '24 hours')>=10
 then raise exception 'too_many_open_uploads' using errcode='P0001'; end if;
 upload_id:=gen_random_uuid();
 extension:=case p_content_type when 'image/jpeg' then 'jpg' when 'image/png' then 'png' else 'webp' end;
 insert into public.media_uploads(id,user_id,purpose,bucket_id,object_key,content_type,byte_size)
 values(upload_id,owner_id,p_purpose,case p_purpose when 'avatar' then 'profile-media' else 'ootd-private' end,
  owner_id::text||'/'||p_purpose||'/'||upload_id::text||'.'||extension,p_content_type,p_file_size);
 response:=jsonb_build_object('upload_id',upload_id);
 update public.idempotency_keys set response_body=response,response_status=201
  where user_id=owner_id and scope='media_upload_create' and key=p_idempotency_key;
 return response||jsonb_build_object('replayed',false);
end $$;

-- Naturally idempotent: a verified upload completes again with the same result.
create function public.complete_my_media_upload(p_upload_id uuid,p_outcome text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare owner_id uuid:=auth.uid(); u public.media_uploads; object_record storage.objects;
begin
 if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 if p_upload_id is null or p_outcome is null or p_outcome not in ('valid','invalid')
 then raise exception 'invalid_media_upload_completion' using errcode='22023'; end if;
 select * into u from public.media_uploads where id=p_upload_id and user_id=owner_id for update;
 if not found then raise exception 'media_upload_not_found' using errcode='P0002'; end if;
 if u.deleted_at is not null then raise exception 'media_upload_not_ready' using errcode='P0001'; end if;
 if u.verified_at is not null then
  return jsonb_build_object('upload_id',u.id,'purpose',u.purpose,'invalid',false);
 end if;
 select * into object_record from storage.objects where bucket_id=u.bucket_id and name=u.object_key;
 if not found then raise exception 'upload_not_found' using errcode='P0001'; end if;
 if p_outcome='invalid' or object_record.owner_id::text<>owner_id::text
 or coalesce(object_record.metadata->>'mimetype','')<>u.content_type
 or coalesce(object_record.metadata->>'size','')!~'^[0-9]+$'
 or (object_record.metadata->>'size')::bigint<>u.byte_size then
  update public.media_uploads set deleted_at=now() where id=u.id;
  return jsonb_build_object('upload_id',u.id,'purpose',u.purpose,'invalid',true);
 end if;
 update public.media_uploads set verified_at=now() where id=u.id;
 return jsonb_build_object('upload_id',u.id,'purpose',u.purpose,'invalid',false);
end $$;

-- Internal: consume a verified, unattached upload of the expected purpose. Re-sending the
-- currently attached upload is a no-op so client retries stay safe.
create function public.g9_take_media_upload(p_owner uuid,p_upload_id uuid,p_purpose text,p_current_key text)
returns text language plpgsql security definer set search_path='' as $$
declare u public.media_uploads;
begin
 select * into u from public.media_uploads where id=p_upload_id and user_id=p_owner for update;
 if not found then raise exception 'media_upload_not_found' using errcode='P0002'; end if;
 if u.object_key is not distinct from p_current_key then return u.object_key; end if;
 if u.purpose<>p_purpose or u.deleted_at is not null or u.verified_at is null or u.attached_at is not null
 then raise exception 'media_upload_not_ready' using errcode='P0001'; end if;
 update public.media_uploads set attached_at=now() where id=u.id;
 return u.object_key;
end $$;

-- PATCH /me: avatar_upload_id joins the existing presence-flag profile write atomically.
create function public.update_my_profile_with_avatar(
 p_set_display_name boolean,p_display_name text,p_set_timezone boolean,p_timezone text,
 p_set_avatar boolean,p_avatar_upload_id uuid
) returns void language plpgsql security definer set search_path='' as $$
declare owner_id uuid:=auth.uid(); current_key text;
begin
 if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 if p_set_avatar is null or p_set_display_name is null or p_set_timezone is null
 or not (p_set_display_name or p_set_timezone or p_set_avatar)
 then raise exception 'empty_profile_patch' using errcode='22023'; end if;
 if p_set_display_name or p_set_timezone then
  perform public.update_my_profile(p_set_display_name,p_display_name,p_set_timezone,p_timezone);
 end if;
 if p_set_avatar then
  select avatar_object_key into current_key from public.profiles where id=owner_id for update;
  if not found then raise exception 'profile_not_found' using errcode='P0002'; end if;
  update public.profiles set avatar_object_key=case when p_avatar_upload_id is null then null
   else public.g9_take_media_upload(owner_id,p_avatar_upload_id,'avatar',current_key) end
  where id=owner_id;
 end if;
end $$;

-- POST /ootd: photo attach runs in the same transaction as the existing create RPC.
-- The photo is not part of the create fingerprint; a replay returns the original record.
create function public.create_my_ootd_with_photo(
 p_worn_on date,p_garment_ids uuid[],p_saved_outfit_id uuid,p_outfit_id uuid,p_wear_status text,
 p_note text,p_rating integer,p_weather_snapshot_id uuid,p_idempotency_key text,p_photo_upload_id uuid
) returns jsonb language plpgsql security definer set search_path='' as $$
declare owner_id uuid:=auth.uid(); result jsonb;
begin
 if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 result:=public.create_my_ootd(p_worn_on,p_garment_ids,p_saved_outfit_id,p_outfit_id,p_wear_status,
  p_note,p_rating,p_weather_snapshot_id,p_idempotency_key);
 if p_photo_upload_id is not null and (result->>'replayed')::boolean is false then
  update public.ootd_entries set photo_object_key=public.g9_take_media_upload(owner_id,p_photo_upload_id,'ootd_photo',null)
  where id=(result->>'ootd_id')::uuid and user_id=owner_id;
 end if;
 return result;
end $$;

-- PATCH /ootd/{id}: other fields keep update_my_ootd semantics; a photo-only patch applies the
-- same ownership/version/accepted-record guards and bumps version once.
create function public.update_my_ootd_with_photo(
 p_ootd_id uuid,p_expected_version integer,p_has_worn_on boolean,p_worn_on date,
 p_has_garment_ids boolean,p_garment_ids uuid[],p_has_saved_outfit_id boolean,p_saved_outfit_id uuid,
 p_has_outfit_id boolean,p_outfit_id uuid,p_has_wear_status boolean,p_wear_status text,
 p_has_note boolean,p_note text,p_has_rating boolean,p_rating integer,
 p_has_weather_snapshot_id boolean,p_weather_snapshot_id uuid,
 p_has_photo_upload_id boolean,p_photo_upload_id uuid
) returns jsonb language plpgsql security definer set search_path='' as $$
declare owner_id uuid:=auth.uid(); result jsonb; current_row public.ootd_entries;
begin
 if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 if p_has_photo_upload_id is null then raise exception 'invalid_ootd_patch' using errcode='22023'; end if;
 if not p_has_photo_upload_id or coalesce(p_has_worn_on or p_has_garment_ids or p_has_saved_outfit_id or p_has_outfit_id
  or p_has_wear_status or p_has_note or p_has_rating or p_has_weather_snapshot_id,true) then
  result:=public.update_my_ootd(p_ootd_id,p_expected_version,p_has_worn_on,p_worn_on,p_has_garment_ids,p_garment_ids,
   p_has_saved_outfit_id,p_saved_outfit_id,p_has_outfit_id,p_outfit_id,p_has_wear_status,p_wear_status,
   p_has_note,p_note,p_has_rating,p_rating,p_has_weather_snapshot_id,p_weather_snapshot_id);
 else
  if p_ootd_id is null or p_expected_version is null or p_expected_version<1
  then raise exception 'invalid_ootd_patch' using errcode='22023'; end if;
  select * into current_row from public.ootd_entries where id=p_ootd_id and user_id=owner_id for update;
  if not found then raise exception 'ootd_not_found' using errcode='P0002'; end if;
  if current_row.version<>p_expected_version then raise exception 'version_conflict' using errcode='P0001'; end if;
  if exists(select 1 from public.idempotency_keys where user_id=owner_id and scope='recommendation_accept'
   and response_body->>'ootd_id'=current_row.id::text)
  then raise exception 'accepted_ootd_immutable' using errcode='P0001'; end if;
  update public.ootd_entries set version=version+1 where id=current_row.id;
  result:=jsonb_build_object('ootd_id',current_row.id,'version',current_row.version+1);
 end if;
 if p_has_photo_upload_id then
  select * into current_row from public.ootd_entries where id=p_ootd_id and user_id=owner_id for update;
  update public.ootd_entries set photo_object_key=case when p_photo_upload_id is null then null
   else public.g9_take_media_upload(owner_id,p_photo_upload_id,'ootd_photo',current_row.photo_object_key) end
  where id=current_row.id;
 end if;
 return result;
end $$;

-- Storage: insert only for the exact pending row; read only the owner's live uploads.
create function public.g9_can_upload_media(p_bucket text,p_object_key text,p_content_type text,p_byte_size text)
returns boolean language plpgsql stable security definer set search_path='' as $$
begin
 if p_byte_size is null or p_byte_size!~'^[0-9]+$' then return false; end if;
 return auth.uid() is not null and exists(
  select 1 from public.media_uploads u where u.bucket_id=p_bucket and u.object_key=p_object_key and u.user_id=auth.uid()
   and u.verified_at is null and u.deleted_at is null and u.content_type=p_content_type and u.byte_size=p_byte_size::bigint
 );
end $$;
create function public.g9_can_read_media(p_bucket text,p_object_key text)
returns boolean language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and exists(
  select 1 from public.media_uploads u where u.bucket_id=p_bucket and u.object_key=p_object_key
   and u.user_id=auth.uid() and u.deleted_at is null)
$$;
create policy user_media_upload on storage.objects for insert to authenticated with check(
 bucket_id in ('profile-media','ootd-private') and split_part(name,'/',1)=(select auth.uid())::text
 and public.g9_can_upload_media(bucket_id,name,metadata->>'mimetype',metadata->>'size')
);
create policy user_media_read on storage.objects for select to authenticated using(
 bucket_id in ('profile-media','ootd-private') and public.g9_can_read_media(bucket_id,name)
);
grant insert,select on storage.objects to authenticated;

revoke all on function public.g9_check_aesthetic_roles(),
 public.create_my_media_upload(text,text,bigint,text),public.complete_my_media_upload(uuid,text),
 public.g9_take_media_upload(uuid,uuid,text,text),
 public.update_my_profile_with_avatar(boolean,text,boolean,text,boolean,uuid),
 public.create_my_ootd_with_photo(date,uuid[],uuid,uuid,text,text,integer,uuid,text,uuid),
 public.update_my_ootd_with_photo(uuid,integer,boolean,date,boolean,uuid[],boolean,uuid,boolean,uuid,boolean,text,boolean,text,boolean,integer,boolean,uuid,boolean,uuid),
 public.g9_can_upload_media(text,text,text,text),public.g9_can_read_media(text,text)
 from public,anon,authenticated;
grant execute on function public.create_my_media_upload(text,text,bigint,text),public.complete_my_media_upload(uuid,text),
 public.update_my_profile_with_avatar(boolean,text,boolean,text,boolean,uuid),
 public.create_my_ootd_with_photo(date,uuid[],uuid,uuid,text,text,integer,uuid,text,uuid),
 public.update_my_ootd_with_photo(uuid,integer,boolean,date,boolean,uuid[],boolean,uuid,boolean,uuid,boolean,text,boolean,text,boolean,integer,boolean,uuid,boolean,uuid),
 public.g9_can_upload_media(text,text,text,text),public.g9_can_read_media(text,text) to authenticated;
