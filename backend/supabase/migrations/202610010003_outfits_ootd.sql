-- G6: owner-bound saved outfits, manual OOTD and snapshot-based closet statistics.

create index saved_outfits_owner_page on public.saved_outfits(user_id,created_at desc,id desc);
create index ootd_owner_page on public.ootd_entries(user_id,worn_on desc,id desc);

create function public.g6_build_snapshot(p_owner uuid,p_garment_ids uuid[])
returns jsonb language plpgsql security definer set search_path='' as $$
declare locked record; locked_count integer:=0; result jsonb;
begin
 if p_owner is null or p_garment_ids is null or cardinality(p_garment_ids) not between 1 and 10
 or cardinality(p_garment_ids)<>(select count(distinct x) from unnest(p_garment_ids) x)
 then raise exception 'invalid_garment_ids' using errcode='22023'; end if;
 for locked in
  select g.id,g.deleted_at,a.verified_at,a.deleted_at as asset_deleted_at
  from public.garments g join public.garment_assets a on a.id=g.asset_id and a.user_id=g.user_id
  where g.user_id=p_owner and g.id=any(p_garment_ids) order by g.id for update of g,a
 loop
  locked_count:=locked_count+1;
  if locked.deleted_at is not null or locked.verified_at is null or locked.asset_deleted_at is not null
  then raise exception 'garment_unavailable' using errcode='P0001'; end if;
 end loop;
 if locked_count<>cardinality(p_garment_ids) then raise exception 'garment_not_found' using errcode='P0002'; end if;
 select jsonb_agg(jsonb_build_object('garment_id',g.id,'category',g.category,'unavailable',false) order by u.ord)
 into result from unnest(p_garment_ids) with ordinality u(id,ord)
 join public.garments g on g.id=u.id and g.user_id=p_owner;
 return result;
end $$;

create function public.g6_assert_source(
 p_owner uuid,p_saved_outfit_id uuid,p_outfit_id uuid,p_garment_ids uuid[]
) returns void language plpgsql security definer set search_path='' as $$
declare expected_count integer; matched_count integer;
begin
 if num_nonnulls(p_saved_outfit_id,p_outfit_id)>1 then raise exception 'multiple_ootd_sources' using errcode='22023'; end if;
 if p_saved_outfit_id is not null then
  if not exists(select 1 from public.saved_outfits where id=p_saved_outfit_id and user_id=p_owner)
  then raise exception 'saved_outfit_not_found' using errcode='P0002'; end if;
  select count(*),count(*) filter(where i.garment_id=any(p_garment_ids)) into expected_count,matched_count
  from public.saved_outfit_items i where i.saved_outfit_id=p_saved_outfit_id and i.user_id=p_owner;
 elsif p_outfit_id is not null then
  if not exists(select 1 from public.outfit_recommendations where id=p_outfit_id and user_id=p_owner)
  then raise exception 'outfit_not_found' using errcode='P0002'; end if;
  select count(*),count(*) filter(where i.garment_id=any(p_garment_ids)) into expected_count,matched_count
  from public.outfit_items i where i.outfit_id=p_outfit_id and i.user_id=p_owner;
 else return;
 end if;
 if expected_count<>cardinality(p_garment_ids) or matched_count<>expected_count
 then raise exception 'source_composition_mismatch' using errcode='P0001'; end if;
end $$;

create function public.g6_validate_weather(
 p_owner uuid,p_weather_snapshot_id uuid,p_worn_on date,p_outfit_id uuid
) returns void language plpgsql security definer set search_path='' as $$
declare tz text; weather public.weather_snapshots; expected uuid;
begin
 if p_weather_snapshot_id is null then
  if p_outfit_id is not null then
   select r.weather_snapshot_id into expected from public.outfit_recommendations o
    join public.recommendation_requests r on r.id=o.request_id and r.user_id=o.user_id
    where o.id=p_outfit_id and o.user_id=p_owner;
   if expected is not null then raise exception 'recommendation_weather_mismatch' using errcode='22023'; end if;
  end if;
  return;
 end if;
 select timezone into tz from public.profiles where id=p_owner;
 select * into weather from public.weather_snapshots where id=p_weather_snapshot_id;
 if not found then raise exception 'weather_not_found' using errcode='P0002'; end if;
 if weather.source<>'kma_short_term' or (weather.valid_at at time zone tz)::date<>p_worn_on
 then raise exception 'invalid_weather_snapshot' using errcode='22023'; end if;
 if p_outfit_id is not null then
  select r.weather_snapshot_id into expected from public.outfit_recommendations o
   join public.recommendation_requests r on r.id=o.request_id and r.user_id=o.user_id
   where o.id=p_outfit_id and o.user_id=p_owner;
  if expected is distinct from p_weather_snapshot_id then raise exception 'recommendation_weather_mismatch' using errcode='22023'; end if;
 end if;
end $$;

create function public.create_my_saved_outfit(
 p_title text,p_note text,p_garment_ids uuid[],p_source_recommendation_id uuid,p_idempotency_key text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare owner_id uuid:=auth.uid(); stored public.idempotency_keys; result public.saved_outfits;
 request_fingerprint text; response jsonb; gid uuid; pos integer;
begin
 if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 if p_title is null or length(btrim(p_title)) not between 1 and 100 or length(p_note)>1000
 or p_idempotency_key is null or length(p_idempotency_key) not between 8 and 128 or p_idempotency_key!~'^[A-Za-z0-9._:-]+$'
 then raise exception 'invalid_saved_outfit' using errcode='22023'; end if;
 perform public.g6_build_snapshot(owner_id,p_garment_ids);
 perform public.g6_assert_source(owner_id,null,p_source_recommendation_id,p_garment_ids);
 request_fingerprint:=md5(p_title||':'||coalesce(p_note,'<null>')||':'||array_to_string(p_garment_ids,',')||':'||coalesce(p_source_recommendation_id::text,'<null>'));
 insert into public.idempotency_keys(user_id,scope,key,request_hash) values(owner_id,'saved_outfit_create',p_idempotency_key,request_fingerprint) on conflict do nothing;
 select * into stored from public.idempotency_keys where user_id=owner_id and scope='saved_outfit_create' and key=p_idempotency_key for update;
 if stored.expires_at<=now() then
  delete from public.idempotency_keys where user_id=owner_id and scope='saved_outfit_create' and key=p_idempotency_key;
  insert into public.idempotency_keys(user_id,scope,key,request_hash) values(owner_id,'saved_outfit_create',p_idempotency_key,request_fingerprint) returning * into stored;
 end if;
 if stored.request_hash<>request_fingerprint then raise exception 'idempotency_conflict' using errcode='P0001'; end if;
 if stored.response_body is not null then return jsonb_build_object('saved_outfit_id',stored.response_body->>'saved_outfit_id','replayed',true); end if;
 insert into public.saved_outfits(user_id,title,note,source_recommendation_id)
 values(owner_id,p_title,p_note,p_source_recommendation_id) returning * into result;
 pos:=0; foreach gid in array p_garment_ids loop
  insert into public.saved_outfit_items(user_id,saved_outfit_id,garment_id,position) values(owner_id,result.id,gid,pos); pos:=pos+1;
 end loop;
 response:=jsonb_build_object('saved_outfit_id',result.id);
 update public.idempotency_keys set response_body=response,response_status=201 where user_id=owner_id and scope='saved_outfit_create' and key=p_idempotency_key;
 return response||jsonb_build_object('replayed',false);
end $$;

create function public.update_my_saved_outfit(
 p_saved_outfit_id uuid,p_expected_version integer,
 p_has_title boolean,p_title text,p_has_note boolean,p_note text,
 p_has_garment_ids boolean,p_garment_ids uuid[],p_has_source_recommendation_id boolean,p_source_recommendation_id uuid
) returns jsonb language plpgsql security definer set search_path='' as $$
declare owner_id uuid:=auth.uid(); current_row public.saved_outfits; final_ids uuid[]; final_source uuid; gid uuid; pos integer:=0;
begin
 if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 if p_saved_outfit_id is null or p_expected_version is null or p_expected_version<1
 or not coalesce(p_has_title,false) and not coalesce(p_has_note,false) and not coalesce(p_has_garment_ids,false) and not coalesce(p_has_source_recommendation_id,false)
 or p_has_title is null or p_has_note is null or p_has_garment_ids is null or p_has_source_recommendation_id is null
 then raise exception 'invalid_saved_outfit_patch' using errcode='22023'; end if;
 if p_has_title and (p_title is null or length(btrim(p_title)) not between 1 and 100) then raise exception 'invalid_title' using errcode='22023'; end if;
 if p_has_note and length(p_note)>1000 then raise exception 'invalid_note' using errcode='22023'; end if;
 select * into current_row from public.saved_outfits where id=p_saved_outfit_id and user_id=owner_id for update;
 if not found then raise exception 'saved_outfit_not_found' using errcode='P0002'; end if;
 if current_row.version<>p_expected_version then raise exception 'version_conflict' using errcode='P0001'; end if;
 if p_has_garment_ids then
  perform public.g6_build_snapshot(owner_id,p_garment_ids); final_ids:=p_garment_ids;
 else
  select array_agg(garment_id order by position) into final_ids from public.saved_outfit_items where saved_outfit_id=current_row.id and user_id=owner_id;
 end if;
 final_source:=case when p_has_source_recommendation_id then p_source_recommendation_id else current_row.source_recommendation_id end;
 perform public.g6_assert_source(owner_id,null,final_source,final_ids);
 update public.saved_outfits set title=case when p_has_title then p_title else title end,
  note=case when p_has_note then p_note else note end,source_recommendation_id=final_source,version=version+1 where id=current_row.id;
 if p_has_garment_ids then
  delete from public.saved_outfit_items where saved_outfit_id=current_row.id;
  foreach gid in array final_ids loop insert into public.saved_outfit_items(user_id,saved_outfit_id,garment_id,position) values(owner_id,current_row.id,gid,pos); pos:=pos+1; end loop;
 end if;
 return jsonb_build_object('saved_outfit_id',current_row.id,'version',current_row.version+1);
end $$;

create function public.delete_my_saved_outfit(p_saved_outfit_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare owner_id uuid:=auth.uid(); locked_id uuid;
begin
 if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 select id into locked_id from public.saved_outfits where id=p_saved_outfit_id and user_id=owner_id for update;
 if not found then raise exception 'saved_outfit_not_found' using errcode='P0002'; end if;
 update public.ootd_entries set saved_outfit_id=null where user_id=owner_id and saved_outfit_id=locked_id;
 delete from public.saved_outfits where id=locked_id and user_id=owner_id;
 delete from public.idempotency_keys where user_id=owner_id and scope='saved_outfit_create'
  and response_body->>'saved_outfit_id'=locked_id::text;
end $$;

create function public.create_my_ootd(
 p_worn_on date,p_garment_ids uuid[],p_saved_outfit_id uuid,p_outfit_id uuid,p_wear_status text,
 p_note text,p_rating integer,p_weather_snapshot_id uuid,p_idempotency_key text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare owner_id uuid:=auth.uid(); tz text; snapshot jsonb; stored public.idempotency_keys; request_fingerprint text;
 result public.ootd_entries; response jsonb;
begin
 if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 if p_worn_on is null or p_wear_status not in ('planned','worn') or length(p_note)>1000
 or (p_rating is not null and p_rating not between 1 and 5) or (p_wear_status='planned' and p_rating is not null)
 or num_nonnulls(p_saved_outfit_id,p_outfit_id)>1
 or p_idempotency_key is null or length(p_idempotency_key) not between 8 and 128 or p_idempotency_key!~'^[A-Za-z0-9._:-]+$'
 then raise exception 'invalid_ootd' using errcode='22023'; end if;
 select timezone into tz from public.profiles where id=owner_id;
 if p_wear_status='worn' and p_worn_on>(now() at time zone tz)::date then raise exception 'future_worn_not_allowed' using errcode='22023'; end if;
 snapshot:=public.g6_build_snapshot(owner_id,p_garment_ids);
 perform public.g6_assert_source(owner_id,p_saved_outfit_id,p_outfit_id,p_garment_ids);
 perform public.g6_validate_weather(owner_id,p_weather_snapshot_id,p_worn_on,p_outfit_id);
 request_fingerprint:=md5(p_worn_on::text||':'||array_to_string(p_garment_ids,',')||':'||coalesce(p_saved_outfit_id::text,'<null>')||':'||coalesce(p_outfit_id::text,'<null>')||':'||p_wear_status||':'||coalesce(p_note,'<null>')||':'||coalesce(p_rating::text,'<null>')||':'||coalesce(p_weather_snapshot_id::text,'<null>'));
 insert into public.idempotency_keys(user_id,scope,key,request_hash) values(owner_id,'ootd_create',p_idempotency_key,request_fingerprint) on conflict do nothing;
 select * into stored from public.idempotency_keys where user_id=owner_id and scope='ootd_create' and key=p_idempotency_key for update;
 if stored.expires_at<=now() then delete from public.idempotency_keys where user_id=owner_id and scope='ootd_create' and key=p_idempotency_key;
  insert into public.idempotency_keys(user_id,scope,key,request_hash) values(owner_id,'ootd_create',p_idempotency_key,request_fingerprint) returning * into stored; end if;
 if stored.request_hash<>request_fingerprint then raise exception 'idempotency_conflict' using errcode='P0001'; end if;
 if stored.response_body is not null then return jsonb_build_object('ootd_id',stored.response_body->>'ootd_id','replayed',true); end if;
 perform pg_advisory_xact_lock(hashtextextended(owner_id::text||p_worn_on::text,0));
 if exists(select 1 from public.ootd_entries where user_id=owner_id and worn_on=p_worn_on)
 then raise exception 'ootd_date_conflict' using errcode='P0001'; end if;
 insert into public.ootd_entries(user_id,outfit_id,saved_outfit_id,worn_on,wear_status,visibility,item_snapshot,weather_snapshot_id,note,rating,version)
 values(owner_id,p_outfit_id,p_saved_outfit_id,p_worn_on,p_wear_status,'private',snapshot,p_weather_snapshot_id,p_note,p_rating,1) returning * into result;
 response:=jsonb_build_object('ootd_id',result.id);
 update public.idempotency_keys set response_body=response,response_status=201 where user_id=owner_id and scope='ootd_create' and key=p_idempotency_key;
 return response||jsonb_build_object('replayed',false);
end $$;

create function public.update_my_ootd(
 p_ootd_id uuid,p_expected_version integer,p_has_worn_on boolean,p_worn_on date,
 p_has_garment_ids boolean,p_garment_ids uuid[],p_has_saved_outfit_id boolean,p_saved_outfit_id uuid,
 p_has_outfit_id boolean,p_outfit_id uuid,p_has_wear_status boolean,p_wear_status text,
 p_has_note boolean,p_note text,p_has_rating boolean,p_rating integer,
 p_has_weather_snapshot_id boolean,p_weather_snapshot_id uuid
) returns jsonb language plpgsql security definer set search_path='' as $$
declare owner_id uuid:=auth.uid(); current_row public.ootd_entries; prelocked_row public.ootd_entries; final_date date; final_saved uuid; final_outfit uuid;
 final_status text; final_note text; final_rating integer; final_weather uuid; final_snapshot jsonb; final_ids uuid[]; tz text; d date;
begin
 if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 if p_ootd_id is null or p_expected_version is null or p_expected_version<1
 or p_has_worn_on is null or p_has_garment_ids is null or p_has_saved_outfit_id is null or p_has_outfit_id is null
 or p_has_wear_status is null or p_has_note is null or p_has_rating is null or p_has_weather_snapshot_id is null
 or not(p_has_worn_on or p_has_garment_ids or p_has_saved_outfit_id or p_has_outfit_id or p_has_wear_status or p_has_note or p_has_rating or p_has_weather_snapshot_id)
 then raise exception 'invalid_ootd_patch' using errcode='22023'; end if;
 -- Read the old date without a row lock, acquire date locks in stable order, then lock
 -- and recheck the row. This prevents two opposite date moves from deadlocking.
 select * into prelocked_row from public.ootd_entries where id=p_ootd_id and user_id=owner_id;
 if not found then raise exception 'ootd_not_found' using errcode='P0002'; end if;
 final_date:=case when p_has_worn_on then p_worn_on else prelocked_row.worn_on end;
 if final_date is null then raise exception 'invalid_ootd' using errcode='22023'; end if;
 for d in select distinct x from unnest(array[prelocked_row.worn_on,final_date]) x order by x loop
  perform pg_advisory_xact_lock(hashtextextended(owner_id::text||d::text,0));
 end loop;
 select * into current_row from public.ootd_entries where id=p_ootd_id and user_id=owner_id for update;
 if not found then raise exception 'ootd_not_found' using errcode='P0002'; end if;
 if current_row.worn_on is distinct from prelocked_row.worn_on then raise exception 'version_conflict' using errcode='P0001'; end if;
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
 if final_date is null or (p_has_wear_status and p_wear_status not in ('planned','worn')) or length(final_note)>1000
 or (final_rating is not null and final_rating not between 1 and 5) or (final_status='planned' and final_rating is not null)
 or num_nonnulls(final_saved,final_outfit)>1 then raise exception 'invalid_ootd' using errcode='22023'; end if;
 select timezone into tz from public.profiles where id=owner_id;
 if final_status='worn' and final_date>(now() at time zone tz)::date then raise exception 'future_worn_not_allowed' using errcode='22023'; end if;
 if final_date<>current_row.worn_on and exists(select 1 from public.ootd_entries where user_id=owner_id and worn_on=final_date and id<>current_row.id)
 then raise exception 'ootd_date_conflict' using errcode='P0001'; end if;
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

create function public.delete_my_ootd(p_ootd_id uuid,p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare owner_id uuid:=auth.uid(); stored public.idempotency_keys; request_fingerprint text; locked_id uuid; response jsonb;
begin
 if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 if p_ootd_id is null or p_idempotency_key is null or length(p_idempotency_key) not between 8 and 128 or p_idempotency_key!~'^[A-Za-z0-9._:-]+$'
 then raise exception 'invalid_ootd_delete' using errcode='22023'; end if;
 request_fingerprint:=md5(p_ootd_id::text);
 insert into public.idempotency_keys(user_id,scope,key,request_hash) values(owner_id,'ootd_delete',p_idempotency_key,request_fingerprint) on conflict do nothing;
 select * into stored from public.idempotency_keys where user_id=owner_id and scope='ootd_delete' and key=p_idempotency_key for update;
 if stored.expires_at<=now() then delete from public.idempotency_keys where user_id=owner_id and scope='ootd_delete' and key=p_idempotency_key;
  insert into public.idempotency_keys(user_id,scope,key,request_hash) values(owner_id,'ootd_delete',p_idempotency_key,request_fingerprint) returning * into stored; end if;
 if stored.request_hash<>request_fingerprint then raise exception 'idempotency_conflict' using errcode='P0001'; end if;
 if stored.response_body is not null then return jsonb_build_object('ootd_id',stored.response_body->>'ootd_id','replayed',true); end if;
 select id into locked_id from public.ootd_entries where id=p_ootd_id and user_id=owner_id for update;
 if not found then raise exception 'ootd_not_found' using errcode='P0002'; end if;
 -- G5 acceptance replays return this durable ID. Do not let another endpoint turn it
 -- into a dangling successful replay.
 if exists(select 1 from public.idempotency_keys where user_id=owner_id and scope='recommendation_accept'
  and response_body->>'ootd_id'=locked_id::text)
 then raise exception 'accepted_ootd_immutable' using errcode='P0001'; end if;
 if exists(select 1 from public.feed_posts where source_ootd_id=locked_id and user_id=owner_id)
 then raise exception 'ootd_in_use' using errcode='P0001'; end if;
 begin
  delete from public.ootd_entries where id=locked_id and user_id=owner_id;
 exception when foreign_key_violation then
  -- A feed row may race the explicit check while waiting on this OOTD lock.
  raise exception 'ootd_in_use' using errcode='P0001';
 end;
 delete from public.idempotency_keys where user_id=owner_id and scope='ootd_create'
  and response_body->>'ootd_id'=locked_id::text;
 response:=jsonb_build_object('ootd_id',locked_id);
 update public.idempotency_keys set response_body=response,response_status=204 where user_id=owner_id and scope='ootd_delete' and key=p_idempotency_key;
 return response||jsonb_build_object('replayed',false);
end $$;

create function public.get_my_ootd_snapshot(p_ootd_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare owner_id uuid:=auth.uid(); stored jsonb; result jsonb;
begin
 if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 select item_snapshot into stored from public.ootd_entries where id=p_ootd_id and user_id=owner_id;
 if not found then raise exception 'ootd_not_found' using errcode='P0002'; end if;
 if jsonb_typeof(stored) is distinct from 'array' then raise exception 'invalid_ootd_snapshot' using errcode='P0001'; end if;
 select coalesce(jsonb_agg(jsonb_build_object(
  'garment_id',x->>'garment_id','category',x->>'category',
  'unavailable',not exists(select 1 from public.garments g join public.garment_assets a on a.id=g.asset_id and a.user_id=g.user_id
   where g.id=case when coalesce(x->>'garment_id','')~'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' then (x->>'garment_id')::uuid end
   and g.user_id=owner_id and g.deleted_at is null and a.verified_at is not null and a.deleted_at is null)
 ) order by ord),'[]'::jsonb) into result from jsonb_array_elements(stored) with ordinality a(x,ord);
 return result;
end $$;

create function public.get_my_closet_statistics()
returns jsonb language plpgsql security definer set search_path='' as $$
declare owner_id uuid:=auth.uid(); tz text; as_of date; counts jsonb; unworn jsonb;
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
 return jsonb_build_object('as_of',as_of,'wear_counts',counts,'unworn_30_days',unworn);
end $$;

revoke insert,update,delete on public.saved_outfits,public.saved_outfit_items,public.ootd_entries from authenticated;
revoke all on function public.g6_build_snapshot(uuid,uuid[]),public.g6_assert_source(uuid,uuid,uuid,uuid[]),
 public.g6_validate_weather(uuid,uuid,date,uuid),
 public.create_my_saved_outfit(text,text,uuid[],uuid,text),
 public.update_my_saved_outfit(uuid,integer,boolean,text,boolean,text,boolean,uuid[],boolean,uuid),
 public.delete_my_saved_outfit(uuid),
 public.create_my_ootd(date,uuid[],uuid,uuid,text,text,integer,uuid,text),
 public.update_my_ootd(uuid,integer,boolean,date,boolean,uuid[],boolean,uuid,boolean,uuid,boolean,text,boolean,text,boolean,integer,boolean,uuid),
 public.delete_my_ootd(uuid,text),public.get_my_ootd_snapshot(uuid),public.get_my_closet_statistics() from public,anon,authenticated;
grant execute on function public.create_my_saved_outfit(text,text,uuid[],uuid,text),
 public.update_my_saved_outfit(uuid,integer,boolean,text,boolean,text,boolean,uuid[],boolean,uuid),
 public.delete_my_saved_outfit(uuid),
 public.create_my_ootd(date,uuid[],uuid,uuid,text,text,integer,uuid,text),
 public.update_my_ootd(uuid,integer,boolean,date,boolean,uuid[],boolean,uuid,boolean,uuid,boolean,text,boolean,text,boolean,integer,boolean,uuid),
 public.delete_my_ootd(uuid,text),public.get_my_ootd_snapshot(uuid),public.get_my_closet_statistics() to authenticated;
