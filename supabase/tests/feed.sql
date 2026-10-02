-- Run only against a disposable migrated database. Every fixture rolls back.
-- Projection/idempotency evidence also exercises profiles and idempotency_keys through narrow RPCs.
begin;

insert into auth.users(id) values
 ('77000000-0000-4000-8000-000000000001'),
 ('77000000-0000-4000-8000-000000000002');
select set_config('test.feed_aesthetic',(select id::text from public.aesthetics where active order by id limit 1),true);
insert into public.ootd_entries(id,user_id,worn_on,visibility,item_snapshot,wear_status) values
 ('77100000-0000-4000-8000-000000000001','77000000-0000-4000-8000-000000000001',current_date-1,'private',
  '[{"garment_id":"77200000-0000-4000-8000-000000000001","category":"top","unavailable":false}]','worn');

set local role authenticated;
select set_config('request.jwt.claim.sub','77000000-0000-4000-8000-000000000001',true);
do $$ declare created jsonb; replay jsonb; completed jsonb; v_post_id uuid; media_id uuid;
 limit_post uuid; invalid_post uuid; invalid_media uuid; object_name text; storage_id uuid; storage_updated timestamptz; i integer;
begin
 begin insert into public.feed_posts(user_id,caption,visibility) values(auth.uid(),'forged','private');
  raise exception 'FAIL direct feed post write'; exception when insufficient_privilege then null; end;
 begin insert into public.post_likes(user_id,post_id) values(auth.uid(),gen_random_uuid());
  raise exception 'FAIL direct like write'; exception when insufficient_privilege then null; end;
 begin perform id from public.feed_media; raise exception 'FAIL raw feed media exposed';
  exception when insufficient_privilege then null; end;
 begin perform public.project_feed_posts(auth.uid(),array[gen_random_uuid()]); raise exception 'FAIL service projection exposed';
  exception when insufficient_privilege then null; end;

 created:=public.create_my_feed_post('77100000-0000-4000-8000-000000000001','hello',current_setting('test.feed_aesthetic')::uuid,
  null,20,'feed-post-one');
 replay:=public.create_my_feed_post('77100000-0000-4000-8000-000000000001','hello',current_setting('test.feed_aesthetic')::uuid,
  'unknown',20,'feed-post-one');
 v_post_id:=(created->>'post_id')::uuid;
 if created->>'replayed'<>'false' or replay->>'replayed'<>'true' or replay->>'post_id'<>v_post_id::text
 or created?'object_key' then raise exception 'FAIL post create replay/projection'; end if;
 begin perform public.create_my_feed_post(null,'changed',current_setting('test.feed_aesthetic')::uuid,'clear',null,'feed-post-one');
  raise exception 'FAIL post idempotency conflict'; exception when raise_exception then if sqlerrm<>'idempotency_conflict' then raise; end if; end;
 if not exists(select 1 from public.feed_posts where id=v_post_id and visibility='private' and weather_code='unknown')
 then raise exception 'FAIL private draft/default weather'; end if;
 begin perform source_ootd_id from public.feed_posts where id=v_post_id; raise exception 'FAIL source OOTD column exposed';
  exception when insufficient_privilege then null; end;

 begin perform public.update_my_feed_post(v_post_id,false,null,false,null,true,'public');
  raise exception 'FAIL public without media'; exception when raise_exception then if sqlerrm<>'feed_media_required' then raise; end if; end;
 created:=public.create_my_feed_media(v_post_id,'image/jpeg',3,'feed-media-one');
 replay:=public.create_my_feed_media(v_post_id,'image/jpeg',3,'feed-media-one');
 media_id:=(created->>'media_id')::uuid;
 if replay->>'replayed'<>'true' or replay->>'media_id'<>media_id::text or created?'object_key'
 then raise exception 'FAIL media replay/raw key'; end if;
 object_name:=auth.uid()::text||'/'||v_post_id::text||'/'||media_id::text||'.jpg';
 begin insert into storage.objects(bucket_id,name,owner_id,metadata)
  values('feed-private',auth.uid()::text||'/arbitrary.jpg',auth.uid(),'{"mimetype":"image/jpeg","size":3}');
  raise exception 'FAIL arbitrary feed storage insert'; exception when insufficient_privilege then null; end;
 begin insert into storage.objects(bucket_id,name,owner_id,metadata)
  values('feed-private',object_name,auth.uid(),'{"mimetype":"image/jpeg","size":"not-a-number"}');
  raise exception 'FAIL malformed storage metadata'; exception when insufficient_privilege then null; end;
 insert into storage.objects(bucket_id,name,owner_id,metadata)
 values('feed-private',object_name,auth.uid(),'{"mimetype":"image/jpeg","size":3}');
 select id,updated_at into storage_id,storage_updated from storage.objects where bucket_id='feed-private' and name=object_name;
 completed:=public.complete_my_feed_media(v_post_id,media_id,'feed-complete-one','valid',storage_id,storage_updated);
 if completed->>'invalid'<>'false' or completed->>'replayed'<>'false'
 or public.complete_my_feed_media(v_post_id,media_id,'feed-complete-one','valid',storage_id,storage_updated)->>'replayed'<>'true'
 then raise exception 'FAIL media complete replay'; end if;
 perform public.update_my_feed_post(v_post_id,false,null,false,null,true,'public');
 if not exists(select 1 from public.feed_posts where id=v_post_id and visibility='public') then raise exception 'FAIL publish'; end if;
 perform public.like_my_feed_post(v_post_id); perform public.like_my_feed_post(v_post_id);
 if (select count(*) from public.post_likes pl where pl.user_id=auth.uid() and pl.post_id=v_post_id)<>1
 then raise exception 'FAIL duplicate own like'; end if;

 created:=public.create_my_feed_post(null,'limit',current_setting('test.feed_aesthetic')::uuid,'clear',null,'feed-limit-post');
 limit_post:=(created->>'post_id')::uuid;
 for i in 1..10 loop
  perform public.create_my_feed_media(limit_post,'image/png',8,'feed-limit-'||lpad(i::text,2,'0'));
 end loop;
 begin perform public.create_my_feed_media(limit_post,'image/png',8,'feed-limit-11');
  raise exception 'FAIL feed media max ten'; exception when raise_exception then if sqlerrm<>'feed_media_limit' then raise; end if; end;

 created:=public.create_my_feed_post(null,'invalid',current_setting('test.feed_aesthetic')::uuid,'rain',12,'feed-invalid-post');
 invalid_post:=(created->>'post_id')::uuid;
 created:=public.create_my_feed_media(invalid_post,'image/png',8,'feed-invalid-media');
 invalid_media:=(created->>'media_id')::uuid;
 object_name:=auth.uid()::text||'/'||invalid_post::text||'/'||invalid_media::text||'.png';
 insert into storage.objects(bucket_id,name,owner_id,metadata)
 values('feed-private',object_name,auth.uid(),'{"mimetype":"image/png","size":8}');
 select id,updated_at into storage_id,storage_updated from storage.objects where bucket_id='feed-private' and name=object_name;
 completed:=public.complete_my_feed_media(invalid_post,invalid_media,'feed-invalid-done','invalid',storage_id,storage_updated);
 if completed->>'invalid'<>'true' or not exists(select 1 from public.feed_posts where id=invalid_post and visibility='private')
 then raise exception 'FAIL invalid media terminal state'; end if;

 perform set_config('test.feed_post',v_post_id::text,true);
 perform set_config('test.feed_media',media_id::text,true);
 perform set_config('test.feed_object',(auth.uid()::text||'/'||v_post_id::text||'/'||media_id::text||'.jpg'),true);
end $$;
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub','77000000-0000-4000-8000-000000000002',true);
do $$ begin
 begin perform public.create_my_feed_post('77100000-0000-4000-8000-000000000001','cross',current_setting('test.feed_aesthetic')::uuid,
  'clear',null,'feed-cross-post'); raise exception 'FAIL cross owner OOTD source';
  exception when no_data_found then null; end;
 if not exists(select 1 from public.feed_posts where id=current_setting('test.feed_post')::uuid)
 then raise exception 'FAIL public feed not visible'; end if;
 perform public.like_my_feed_post(current_setting('test.feed_post')::uuid);
 perform public.like_my_feed_post(current_setting('test.feed_post')::uuid);
 if (select count(*) from public.post_likes where user_id=auth.uid() and post_id=current_setting('test.feed_post')::uuid)<>1
 then raise exception 'FAIL duplicate public like'; end if;
 begin insert into storage.objects(bucket_id,name,owner_id,metadata)
  values('feed-private',current_setting('test.feed_object'),auth.uid(),'{"mimetype":"image/jpeg","size":3}');
  raise exception 'FAIL cross owner media upload'; exception when insufficient_privilege then null; end;
end $$;
reset role;

set local role service_role;
do $$ declare projected jsonb; begin
 projected:=public.project_feed_posts('77000000-0000-4000-8000-000000000002',array[current_setting('test.feed_post')::uuid]);
 if jsonb_array_length(projected)<>1 or projected->0?'source_ootd_id' or projected->0?'garment_ids'
 or projected->0->>'liked_by_me'<>'true' or (projected->0->>'like_count')::integer<>2
 or projected->0->'media'->0->>'object_key'<>current_setting('test.feed_object')
 then raise exception 'FAIL service-only safe projection'; end if;
end $$;
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub','77000000-0000-4000-8000-000000000001',true);
select public.update_my_feed_post(current_setting('test.feed_post')::uuid,false,null,false,null,true,'private');
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub','77000000-0000-4000-8000-000000000002',true);
do $$ begin
 if exists(select 1 from public.feed_posts where id=current_setting('test.feed_post')::uuid)
 or exists(select 1 from public.post_likes where post_id=current_setting('test.feed_post')::uuid)
 then raise exception 'FAIL private post/archive visible'; end if;
 perform public.unlike_my_feed_post(current_setting('test.feed_post')::uuid);
 perform public.unlike_my_feed_post(current_setting('test.feed_post')::uuid);
 if exists(select 1 from public.post_likes where user_id=auth.uid() and post_id=current_setting('test.feed_post')::uuid)
 then raise exception 'FAIL hidden post unlike'; end if;
 begin perform public.like_my_feed_post(current_setting('test.feed_post')::uuid);
  raise exception 'FAIL hidden post like'; exception when no_data_found then null; end;
end $$;
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub','77000000-0000-4000-8000-000000000001',true);
select public.update_my_feed_post(current_setting('test.feed_post')::uuid,false,null,false,null,true,'public');
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub','77000000-0000-4000-8000-000000000002',true);
select public.unlike_my_feed_post(current_setting('test.feed_post')::uuid);
select public.unlike_my_feed_post(current_setting('test.feed_post')::uuid);
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub','77000000-0000-4000-8000-000000000001',true);
do $$ declare deleted jsonb; begin
 deleted:=public.delete_my_feed_post(current_setting('test.feed_post')::uuid);
 if deleted->>'status'<>'deletion_pending'
 or public.delete_my_feed_post(current_setting('test.feed_post')::uuid)->>'status'<>'deletion_pending'
 then raise exception 'FAIL delete replay'; end if;
end $$;
reset role;

do $$ begin
 if not exists(select 1 from public.feed_posts where id=current_setting('test.feed_post')::uuid
  and deleted_at is not null and visibility='private' and source_ootd_id is null)
 or not exists(select 1 from public.feed_media where id=current_setting('test.feed_media')::uuid and deleted_at is not null)
 then raise exception 'FAIL feed withdrawal markers/detach'; end if;
end $$;

set local role authenticated;
select set_config('request.jwt.claim.sub','77000000-0000-4000-8000-000000000001',true);
select public.delete_my_ootd('77100000-0000-4000-8000-000000000001','feed-ootd-delete');
reset role;

set local role service_role;
do $$ begin
 if jsonb_array_length(public.project_feed_posts('77000000-0000-4000-8000-000000000002',array[current_setting('test.feed_post')::uuid]))<>0
 then raise exception 'FAIL deleted post projection'; end if;
end $$;
reset role;

rollback;
