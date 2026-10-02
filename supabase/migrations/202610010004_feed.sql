-- G7: private feed drafts, isolated shared media and privacy-safe likes.

alter table public.feed_media add column content_type text;
alter table public.feed_media add column byte_size bigint;
alter table public.feed_media add constraint feed_media_upload_metadata check(
 (content_type is null and byte_size is null)
 or (content_type in ('image/jpeg','image/png','image/webp') and byte_size between 1 and 20971520)
);

create index feed_owner_page on public.feed_posts(user_id,created_at desc,id desc) where deleted_at is null;
create index liked_posts_page on public.post_likes(user_id,created_at desc,post_id desc);

create function public.create_my_feed_post(
 p_source_ootd_id uuid,p_caption text,p_aesthetic_id uuid,p_weather_code text,
 p_temperature_c numeric,p_idempotency_key text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare owner_id uuid:=auth.uid(); stored public.idempotency_keys; result public.feed_posts;
 request_fingerprint text; response jsonb; normalized_weather text:=coalesce(p_weather_code,'unknown');
begin
 if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 if p_caption is null or length(p_caption)>2000 or p_aesthetic_id is null
 or normalized_weather not in ('clear','cloudy','rain','snow','unknown')
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

create function public.update_my_feed_post(
 p_post_id uuid,p_has_caption boolean,p_caption text,p_has_aesthetic_id boolean,p_aesthetic_id uuid,
 p_has_visibility boolean,p_visibility text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare owner_id uuid:=auth.uid(); current_row public.feed_posts; final_visibility text;
begin
 if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 if p_post_id is null or p_has_caption is null or p_has_aesthetic_id is null or p_has_visibility is null
 or not(p_has_caption or p_has_aesthetic_id or p_has_visibility)
 then raise exception 'invalid_feed_patch' using errcode='22023'; end if;
 if p_has_caption and (p_caption is null or length(p_caption)>2000)
 then raise exception 'invalid_caption' using errcode='22023'; end if;
 if p_has_aesthetic_id and (p_aesthetic_id is null or not exists(
  select 1 from public.aesthetics where id=p_aesthetic_id and active
 )) then raise exception 'aesthetic_not_found' using errcode='P0002'; end if;
 if p_has_visibility and p_visibility not in ('private','public')
 then raise exception 'invalid_visibility' using errcode='22023'; end if;
 select * into current_row from public.feed_posts
  where id=p_post_id and user_id=owner_id and deleted_at is null for update;
 if not found then raise exception 'feed_post_not_found' using errcode='P0002'; end if;
 final_visibility:=case when p_has_visibility then p_visibility else current_row.visibility end;
 if final_visibility='public' and (
  not exists(select 1 from public.feed_media where post_id=current_row.id and user_id=owner_id and verified_at is not null and deleted_at is null)
  or exists(select 1 from public.feed_media where post_id=current_row.id and user_id=owner_id and verified_at is null and deleted_at is null)
 ) then raise exception 'feed_media_required' using errcode='P0001'; end if;
 update public.feed_posts set
  caption=case when p_has_caption then p_caption else caption end,
  aesthetic_id=case when p_has_aesthetic_id then p_aesthetic_id else aesthetic_id end,
  visibility=final_visibility
 where id=current_row.id;
 return jsonb_build_object('post_id',current_row.id,'visibility',final_visibility);
end $$;

create function public.delete_my_feed_post(p_post_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare owner_id uuid:=auth.uid(); current_row public.feed_posts;
begin
 if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 if p_post_id is null then raise exception 'invalid_post_id' using errcode='22023'; end if;
 select * into current_row from public.feed_posts where id=p_post_id and user_id=owner_id for update;
 if not found then raise exception 'feed_post_not_found' using errcode='P0002'; end if;
 if current_row.deleted_at is null then
  update public.feed_posts set visibility='private',source_ootd_id=null,deleted_at=now() where id=current_row.id;
  update public.feed_media set deleted_at=coalesce(deleted_at,now()) where post_id=current_row.id and user_id=owner_id;
  delete from public.idempotency_keys where user_id=owner_id and scope='feed_post_create'
   and response_body->>'post_id'=current_row.id::text;
 end if;
 return jsonb_build_object('id',current_row.id,'status','deletion_pending');
end $$;

create function public.create_my_feed_media(
 p_post_id uuid,p_content_type text,p_file_size bigint,p_idempotency_key text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare owner_id uuid:=auth.uid(); current_post public.feed_posts; stored public.idempotency_keys;
 request_fingerprint text; media_id uuid; extension text; object_key text; next_position integer; response jsonb;
begin
 if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 if p_post_id is null or p_content_type not in ('image/jpeg','image/png','image/webp')
 or p_file_size is null or p_file_size not between 1 and 20971520
 or p_idempotency_key is null or length(p_idempotency_key) not between 8 and 128
 or p_idempotency_key!~'^[A-Za-z0-9._:-]+$'
 then raise exception 'invalid_feed_media' using errcode='22023'; end if;
 request_fingerprint:=md5(p_post_id::text||':'||p_content_type||':'||p_file_size::text);
 insert into public.idempotency_keys(user_id,scope,key,request_hash)
 values(owner_id,'feed_media_create',p_idempotency_key,request_fingerprint) on conflict do nothing;
 select * into stored from public.idempotency_keys
  where user_id=owner_id and scope='feed_media_create' and key=p_idempotency_key for update;
 if stored.expires_at<=now() then
  delete from public.idempotency_keys where user_id=owner_id and scope='feed_media_create' and key=p_idempotency_key;
  insert into public.idempotency_keys(user_id,scope,key,request_hash)
  values(owner_id,'feed_media_create',p_idempotency_key,request_fingerprint) returning * into stored;
 end if;
 if stored.request_hash<>request_fingerprint then raise exception 'idempotency_conflict' using errcode='P0001'; end if;
 if stored.response_body is not null then
  return jsonb_build_object('media_id',stored.response_body->>'media_id','replayed',true);
 end if;
 select * into current_post from public.feed_posts
  where id=p_post_id and user_id=owner_id and deleted_at is null for update;
 if not found then raise exception 'feed_post_not_found' using errcode='P0002'; end if;
 if current_post.visibility<>'private' then raise exception 'invalid_feed_state' using errcode='P0001'; end if;
 if (select count(*) from public.feed_media where post_id=current_post.id and user_id=owner_id and deleted_at is null)>=10
 then raise exception 'feed_media_limit' using errcode='P0001'; end if;
 select coalesce(max(position),-1)+1 into next_position from public.feed_media where post_id=current_post.id;
 media_id:=gen_random_uuid();
 extension:=case p_content_type when 'image/jpeg' then 'jpg' when 'image/png' then 'png' else 'webp' end;
 object_key:=owner_id::text||'/'||current_post.id::text||'/'||media_id::text||'.'||extension;
 insert into public.feed_media(id,user_id,post_id,object_key,position,content_type,byte_size)
 values(media_id,owner_id,current_post.id,object_key,next_position,p_content_type,p_file_size);
 response:=jsonb_build_object('media_id',media_id);
 update public.idempotency_keys set response_body=response,response_status=201
  where user_id=owner_id and scope='feed_media_create' and key=p_idempotency_key;
 return response||jsonb_build_object('replayed',false);
end $$;

create function public.complete_my_feed_media(
 p_post_id uuid,p_media_id uuid,p_idempotency_key text,p_outcome text,
 p_storage_id uuid,p_storage_updated_at timestamptz
) returns jsonb language plpgsql security definer set search_path='' as $$
declare owner_id uuid:=auth.uid(); stored public.idempotency_keys; current_post public.feed_posts;
 media public.feed_media; object_record storage.objects; request_fingerprint text; response jsonb;
begin
 if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 if p_post_id is null or p_media_id is null or p_outcome not in ('valid','invalid')
 or p_storage_id is null or p_storage_updated_at is null
 or p_idempotency_key is null or length(p_idempotency_key) not between 8 and 128
 or p_idempotency_key!~'^[A-Za-z0-9._:-]+$'
 then raise exception 'invalid_feed_media_completion' using errcode='22023'; end if;
 request_fingerprint:=md5(p_post_id::text||':'||p_media_id::text);
 insert into public.idempotency_keys(user_id,scope,key,request_hash)
 values(owner_id,'feed_media_complete',p_idempotency_key,request_fingerprint) on conflict do nothing;
 select * into stored from public.idempotency_keys
  where user_id=owner_id and scope='feed_media_complete' and key=p_idempotency_key for update;
 if stored.expires_at<=now() then
  delete from public.idempotency_keys where user_id=owner_id and scope='feed_media_complete' and key=p_idempotency_key;
  insert into public.idempotency_keys(user_id,scope,key,request_hash)
  values(owner_id,'feed_media_complete',p_idempotency_key,request_fingerprint) returning * into stored;
 end if;
 if stored.request_hash<>request_fingerprint then raise exception 'idempotency_conflict' using errcode='P0001'; end if;
 if stored.response_body is not null then return stored.response_body||jsonb_build_object('replayed',true); end if;
 select * into current_post from public.feed_posts
  where id=p_post_id and user_id=owner_id and deleted_at is null for update;
 if not found then raise exception 'feed_post_not_found' using errcode='P0002'; end if;
 if current_post.visibility<>'private' then raise exception 'invalid_feed_state' using errcode='P0001'; end if;
 select * into media from public.feed_media
  where id=p_media_id and post_id=current_post.id and user_id=owner_id for update;
 if not found then raise exception 'feed_media_not_found' using errcode='P0002'; end if;
 if media.verified_at is not null and media.deleted_at is null then
  response:=jsonb_build_object('post_id',current_post.id,'media_id',media.id,'invalid',false);
  update public.idempotency_keys set response_body=response,response_status=200
   where user_id=owner_id and scope='feed_media_complete' and key=p_idempotency_key;
  return response||jsonb_build_object('replayed',false);
 end if;
 if media.deleted_at is not null then raise exception 'invalid_feed_media_state' using errcode='P0001'; end if;
 select * into object_record from storage.objects where id=p_storage_id and bucket_id=media.bucket_id
  and name=media.object_key and updated_at=p_storage_updated_at for update;
 if not found then raise exception 'upload_not_found' using errcode='P0001'; end if;
 if p_outcome='invalid' or object_record.owner_id::text<>owner_id::text
 or coalesce(object_record.metadata->>'mimetype','')<>media.content_type
 or coalesce(object_record.metadata->>'size','')!~'^[0-9]+$'
 or (object_record.metadata->>'size')::bigint<>media.byte_size then
  update public.feed_media set deleted_at=now() where id=media.id;
  response:=jsonb_build_object('post_id',current_post.id,'media_id',media.id,'invalid',true);
  update public.idempotency_keys set response_body=response,response_status=422
   where user_id=owner_id and scope='feed_media_complete' and key=p_idempotency_key;
  return response||jsonb_build_object('replayed',false);
 end if;
 update public.feed_media set verified_at=now() where id=media.id;
 response:=jsonb_build_object('post_id',current_post.id,'media_id',media.id,'invalid',false);
 update public.idempotency_keys set response_body=response,response_status=200
  where user_id=owner_id and scope='feed_media_complete' and key=p_idempotency_key;
 return response||jsonb_build_object('replayed',false);
end $$;

create function public.like_my_feed_post(p_post_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare owner_id uuid:=auth.uid(); visible_id uuid;
begin
 if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 if p_post_id is null then raise exception 'invalid_post_id' using errcode='22023'; end if;
 select id into visible_id from public.feed_posts where id=p_post_id and deleted_at is null
  and (visibility='public' or user_id=owner_id) for share;
 if not found then raise exception 'feed_post_not_found' using errcode='P0002'; end if;
 insert into public.post_likes(user_id,post_id) values(owner_id,visible_id) on conflict do nothing;
end $$;

create function public.unlike_my_feed_post(p_post_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare owner_id uuid:=auth.uid();
begin
 if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 if p_post_id is null then raise exception 'invalid_post_id' using errcode='22023'; end if;
 -- Privacy-safe and idempotent: only the actor's archive row is touched. The
 -- post may now be private/deleted/missing, which must not become an oracle.
 delete from public.post_likes where user_id=owner_id and post_id=p_post_id;
end $$;

-- Service-only internal projection. Raw object keys never cross an authenticated RPC boundary.
create function public.project_feed_posts(p_actor_id uuid,p_post_ids uuid[])
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 if p_actor_id is null or not exists(select 1 from public.profiles where id=p_actor_id)
 or p_post_ids is null or cardinality(p_post_ids) not between 1 and 100
 or cardinality(p_post_ids)<>(select count(distinct x) from unnest(p_post_ids) x)
 then raise exception 'invalid_feed_projection' using errcode='22023'; end if;
 select coalesce(jsonb_agg(jsonb_build_object(
  'id',p.id,'author',jsonb_build_object('id',p.user_id,'display_name',pr.display_name),
  'caption',p.caption,'aesthetic_id',p.aesthetic_id,'weather_code',p.weather_code,
  'temperature_c',p.temperature_c,'visibility',p.visibility,'created_at',p.created_at,
  'liked_by_me',exists(select 1 from public.post_likes mine where mine.post_id=p.id and mine.user_id=p_actor_id),
  'like_count',(select count(*) from public.post_likes likes where likes.post_id=p.id),
  'media',coalesce((select jsonb_agg(jsonb_build_object('bucket_id',m.bucket_id,'object_key',m.object_key,'position',m.position) order by m.position)
   from public.feed_media m where m.post_id=p.id and m.user_id=p.user_id and m.verified_at is not null and m.deleted_at is null),'[]'::jsonb)
 ) order by u.ord),'[]'::jsonb) into result
 from unnest(p_post_ids) with ordinality u(id,ord)
 join public.feed_posts p on p.id=u.id and p.deleted_at is null and (p.visibility='public' or p.user_id=p_actor_id)
 join public.profiles pr on pr.id=p.user_id;
 return result;
end $$;

create function public.get_feed_media_fence(p_actor_id uuid,p_post_id uuid,p_media_id uuid)
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object(
  'post',jsonb_build_object('id',p.id,'user_id',p.user_id,'visibility',p.visibility,'deleted_at',p.deleted_at,'updated_at',p.updated_at),
  'media',jsonb_build_object('id',m.id,'user_id',m.user_id,'post_id',m.post_id,'bucket_id',m.bucket_id,
   'object_key',m.object_key,'content_type',m.content_type,'byte_size',m.byte_size,'verified_at',m.verified_at,
   'deleted_at',m.deleted_at,'position',m.position),
  'storage',case when o.id is null then null else jsonb_build_object('id',o.id,'bucket_id',o.bucket_id,'name',o.name,
   'owner_id',o.owner_id,'metadata',o.metadata,'updated_at',o.updated_at) end)
 from public.feed_posts p join public.feed_media m on m.post_id=p.id and m.user_id=p.user_id
 left join storage.objects o on o.bucket_id=m.bucket_id and o.name=m.object_key
 where p.id=p_post_id and p.user_id=p_actor_id and m.id=p_media_id
$$;

-- Service-only visibility-first page for the liked archive. Filtering before
-- limit/cursor prevents hidden posts from producing empty pages or ID oracles.
create function public.project_my_visible_likes(
 p_actor_id uuid,p_cursor_at timestamptz,p_cursor_post_id uuid,p_limit integer
) returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 if p_actor_id is null or not exists(select 1 from public.profiles where id=p_actor_id)
 or p_limit not between 2 and 101 or num_nonnulls(p_cursor_at,p_cursor_post_id)=1
 then raise exception 'invalid_liked_page' using errcode='22023'; end if;
 select coalesce(jsonb_agg(jsonb_build_object('post_id',q.post_id,'created_at',q.created_at)
  order by q.created_at desc,q.post_id desc),'[]'::jsonb) into result
 from (select l.post_id,l.created_at from public.post_likes l
  join public.feed_posts p on p.id=l.post_id and p.deleted_at is null
   and (p.visibility='public' or p.user_id=p_actor_id)
  where l.user_id=p_actor_id and (p_cursor_at is null or (l.created_at,l.post_id)<(p_cursor_at,p_cursor_post_id))
  order by l.created_at desc,l.post_id desc limit p_limit) q;
 return result;
end $$;

create function public.g7_can_upload_feed_media(p_object_key text,p_content_type text,p_byte_size text)
returns boolean language plpgsql stable security definer set search_path='' as $$
begin
 if p_byte_size is null or p_byte_size!~'^[0-9]+$' then return false; end if;
 return auth.uid() is not null and exists(
  select 1 from public.feed_media m join public.feed_posts p on p.id=m.post_id and p.user_id=m.user_id
  where m.object_key=p_object_key and m.user_id=auth.uid() and m.verified_at is null and m.deleted_at is null
   and m.content_type=p_content_type and m.byte_size=p_byte_size::bigint and p.visibility='private' and p.deleted_at is null
 );
end
$$;
create function public.g7_can_verify_feed_media(p_object_key text)
returns boolean language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and exists(
  select 1 from public.feed_media m join public.feed_posts p on p.id=m.post_id and p.user_id=m.user_id
  where m.object_key=p_object_key and m.user_id=auth.uid() and m.verified_at is null and m.deleted_at is null
   and p.visibility='private' and p.deleted_at is null
 )
$$;
create policy feed_media_upload on storage.objects for insert to authenticated with check(
 bucket_id='feed-private' and split_part(name,'/',1)=(select auth.uid())::text
 and public.g7_can_upload_feed_media(name,metadata->>'mimetype',metadata->>'size')
);
create policy feed_media_verify on storage.objects for select to authenticated using(
 bucket_id='feed-private' and public.g7_can_verify_feed_media(name)
);
grant insert,select on storage.objects to authenticated;

revoke insert,update,delete on public.feed_posts,public.feed_media,public.post_likes from authenticated;
revoke all on function public.create_my_feed_post(uuid,text,uuid,text,numeric,text),
 public.update_my_feed_post(uuid,boolean,text,boolean,uuid,boolean,text),public.delete_my_feed_post(uuid),
 public.create_my_feed_media(uuid,text,bigint,text),public.complete_my_feed_media(uuid,uuid,text,text,uuid,timestamptz),
 public.like_my_feed_post(uuid),public.unlike_my_feed_post(uuid),public.project_feed_posts(uuid,uuid[]),
 public.get_feed_media_fence(uuid,uuid,uuid),
 public.project_my_visible_likes(uuid,timestamptz,uuid,integer),
 public.g7_can_upload_feed_media(text,text,text),public.g7_can_verify_feed_media(text)
 from public,anon,authenticated;
grant execute on function public.create_my_feed_post(uuid,text,uuid,text,numeric,text),
 public.update_my_feed_post(uuid,boolean,text,boolean,uuid,boolean,text),public.delete_my_feed_post(uuid),
 public.create_my_feed_media(uuid,text,bigint,text),public.complete_my_feed_media(uuid,uuid,text,text,uuid,timestamptz),
 public.like_my_feed_post(uuid),public.unlike_my_feed_post(uuid),
 public.g7_can_upload_feed_media(text,text,text),public.g7_can_verify_feed_media(text) to authenticated;
grant execute on function public.project_feed_posts(uuid,uuid[]) to service_role;
grant execute on function public.get_feed_media_fence(uuid,uuid,uuid) to service_role;
grant execute on function public.project_my_visible_likes(uuid,timestamptz,uuid,integer) to service_role;
