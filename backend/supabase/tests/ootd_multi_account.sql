-- 2026-10-10 track B: several OOTD per day, AI notice gate, account purge. Every fixture rolls back.
begin;

insert into auth.users(id) values
 ('a1000000-0000-4000-8000-000000000001'),('a1000000-0000-4000-8000-000000000002');
-- U1 closet: g1 top, g2 bottom. U2 closet: g3 top.
insert into public.garment_batches(id,user_id,status) values
 ('a1100000-0000-4000-8000-000000000001','a1000000-0000-4000-8000-000000000001','confirmed'),
 ('a1100000-0000-4000-8000-000000000002','a1000000-0000-4000-8000-000000000002','confirmed'),
 ('a1100000-0000-4000-8000-000000000003','a1000000-0000-4000-8000-000000000001','uploaded'),
 ('a1100000-0000-4000-8000-000000000004','a1000000-0000-4000-8000-000000000001','failed');
insert into public.garment_assets(id,user_id,batch_id,kind,object_key,content_type,byte_size,verified_at) values
 ('a1200000-0000-4000-8000-000000000001','a1000000-0000-4000-8000-000000000001','a1100000-0000-4000-8000-000000000001','cutout','a1000000-0000-4000-8000-000000000001/b1/g1.png','image/png',10,now()),
 ('a1200000-0000-4000-8000-000000000002','a1000000-0000-4000-8000-000000000001','a1100000-0000-4000-8000-000000000001','cutout','a1000000-0000-4000-8000-000000000001/b1/g2.png','image/png',10,now()),
 ('a1200000-0000-4000-8000-000000000003','a1000000-0000-4000-8000-000000000002','a1100000-0000-4000-8000-000000000002','cutout','a1000000-0000-4000-8000-000000000002/b2/g3.png','image/png',10,now()),
 ('a1200000-0000-4000-8000-000000000004','a1000000-0000-4000-8000-000000000001','a1100000-0000-4000-8000-000000000003','source','a1000000-0000-4000-8000-000000000001/b3/source.jpg','image/jpeg',10,now());
insert into public.analysis_jobs(id,user_id,batch_id,status,attempt,max_attempts,error_code) values
 ('a1300000-0000-4000-8000-000000000001','a1000000-0000-4000-8000-000000000001','a1100000-0000-4000-8000-000000000001','succeeded',1,3,null),
 ('a1300000-0000-4000-8000-000000000002','a1000000-0000-4000-8000-000000000002','a1100000-0000-4000-8000-000000000002','succeeded',1,3,null),
 ('a1300000-0000-4000-8000-000000000004','a1000000-0000-4000-8000-000000000001','a1100000-0000-4000-8000-000000000004','failed',1,3,'WORKER_TIMEOUT');
insert into public.garment_drafts(id,user_id,batch_id,job_id,item_index,asset_id,status,raw_prediction,model_version) values
 ('a1400000-0000-4000-8000-000000000001','a1000000-0000-4000-8000-000000000001','a1100000-0000-4000-8000-000000000001','a1300000-0000-4000-8000-000000000001',0,'a1200000-0000-4000-8000-000000000001','confirmed','{"category":"top"}','v1'),
 ('a1400000-0000-4000-8000-000000000002','a1000000-0000-4000-8000-000000000001','a1100000-0000-4000-8000-000000000001','a1300000-0000-4000-8000-000000000001',1,'a1200000-0000-4000-8000-000000000002','confirmed','{"category":"bottom"}','v1'),
 ('a1400000-0000-4000-8000-000000000003','a1000000-0000-4000-8000-000000000002','a1100000-0000-4000-8000-000000000002','a1300000-0000-4000-8000-000000000002',0,'a1200000-0000-4000-8000-000000000003','confirmed','{"category":"top"}','v1');
insert into public.garments(id,user_id,source_draft_id,asset_id,category) values
 ('a1500000-0000-4000-8000-000000000001','a1000000-0000-4000-8000-000000000001','a1400000-0000-4000-8000-000000000001','a1200000-0000-4000-8000-000000000001','top'),
 ('a1500000-0000-4000-8000-000000000002','a1000000-0000-4000-8000-000000000001','a1400000-0000-4000-8000-000000000002','a1200000-0000-4000-8000-000000000002','bottom'),
 ('a1500000-0000-4000-8000-000000000003','a1000000-0000-4000-8000-000000000002','a1400000-0000-4000-8000-000000000003','a1200000-0000-4000-8000-000000000003','top');
insert into public.garment_aesthetic_scores(user_id,garment_id,aesthetic_id,score,model_version)
 select 'a1000000-0000-4000-8000-000000000001','a1500000-0000-4000-8000-000000000001',id,0.8,'v1' from public.aesthetics where code='casual';
insert into public.user_aesthetic_preferences(user_id,aesthetic_id,weight,role)
 select 'a1000000-0000-4000-8000-000000000001',id,1,'main' from public.aesthetics where code='casual';
-- One ready recommendation for today with two different outfits (g1 / g2).
insert into public.recommendation_requests(id,user_id,target_date,requested_count,status,preference_snapshot,engine_version,expires_at,rules_version)
 values('a1600000-0000-4000-8000-000000000001','a1000000-0000-4000-8000-000000000001',current_date,2,'ready','[]','v1',now()+interval '1 day','v1');
insert into public.outfit_recommendations(id,user_id,request_id,rank,scores,reason_facts,explanation_source) values
 ('a1700000-0000-4000-8000-000000000001','a1000000-0000-4000-8000-000000000001','a1600000-0000-4000-8000-000000000001',1,'{}','[]','template'),
 ('a1700000-0000-4000-8000-000000000002','a1000000-0000-4000-8000-000000000001','a1600000-0000-4000-8000-000000000001',2,'{}','[]','template');
insert into public.outfit_items(user_id,outfit_id,garment_id,slot) values
 ('a1000000-0000-4000-8000-000000000001','a1700000-0000-4000-8000-000000000001','a1500000-0000-4000-8000-000000000001','top'),
 ('a1000000-0000-4000-8000-000000000001','a1700000-0000-4000-8000-000000000002','a1500000-0000-4000-8000-000000000002','bottom');
-- Legacy planned row (pre-2026-10-10) with g2: must not count as wear.
insert into public.ootd_entries(id,user_id,worn_on,wear_status,item_snapshot) values
 ('a1800000-0000-4000-8000-000000000009','a1000000-0000-4000-8000-000000000001',current_date-10,'planned',
  '[{"garment_id":"a1500000-0000-4000-8000-000000000002","category":"bottom","unavailable":false}]');

-- ---------------------------------------------------------------- 1. multiple OOTD per day
set local role authenticated;
select set_config('request.jwt.claim.sub','a1000000-0000-4000-8000-000000000001',true);
do $$ declare o1 uuid; o2 uuid; o3 uuid; r jsonb; stats jsonb; cal jsonb; a1 jsonb; a2 jsonb; a3 jsonb; begin
 o1:=(public.create_my_ootd(current_date-1,array['a1500000-0000-4000-8000-000000000001'::uuid,'a1500000-0000-4000-8000-000000000002'::uuid],
  null,null,'worn',null,4,null,'multi-day-one')->>'ootd_id')::uuid;
 o2:=(public.create_my_ootd(current_date-1,array['a1500000-0000-4000-8000-000000000001'::uuid],
  null,null,null,'second look',null,null,'multi-day-two')->>'ootd_id')::uuid;
 if o1=o2 or (select count(*) from public.ootd_entries where user_id=auth.uid() and worn_on=current_date-1)<>2
 or exists(select 1 from public.ootd_entries where id in (o1,o2) and wear_status<>'worn')
 then raise exception 'FAIL two worn OOTD records on the same day'; end if;
 r:=public.create_my_ootd(current_date-1,array['a1500000-0000-4000-8000-000000000001'::uuid],null,null,null,'second look',null,null,'multi-day-two');
 if r->>'replayed'<>'true' or r->>'ootd_id'<>o2::text then raise exception 'FAIL same key replays instead of adding'; end if;
 begin perform public.create_my_ootd(current_date-1,array['a1500000-0000-4000-8000-000000000002'::uuid],null,null,'planned',null,null,null,'multi-planned');
  raise exception 'FAIL planned still creatable'; exception when invalid_parameter_value then if sqlerrm<>'invalid_ootd' then raise; end if; end;
 -- Moving a record onto a day that already has records is allowed.
 o3:=(public.create_my_ootd(current_date-2,array['a1500000-0000-4000-8000-000000000001'::uuid],null,null,'worn',null,null,null,'multi-day-three')->>'ootd_id')::uuid;
 r:=public.update_my_ootd(o3,1,true,current_date-1,false,null,false,null,false,null,false,null,false,null,false,null,false,null);
 if r->>'version'<>'2' or (select count(*) from public.ootd_entries where user_id=auth.uid() and worn_on=current_date-1)<>3
 then raise exception 'FAIL move onto occupied day'; end if;
 begin perform public.update_my_ootd(o3,2,false,null,false,null,false,null,false,null,true,'planned',false,null,false,null,false,null);
  raise exception 'FAIL patch to planned'; exception when invalid_parameter_value then if sqlerrm<>'invalid_ootd' then raise; end if; end;
 -- Legacy planned -> worn conversion stays possible.
 r:=public.update_my_ootd('a1800000-0000-4000-8000-000000000009',1,false,null,false,null,false,null,false,null,false,null,true,'legacy',false,null,false,null);
 if (select wear_status from public.ootd_entries where id='a1800000-0000-4000-8000-000000000009')<>'planned'
 then raise exception 'FAIL legacy planned note edit changed status'; end if;

 -- Statistics count per record: g1 is in three records on the same day, g2 in one (legacy planned excluded).
 stats:=public.get_my_closet_statistics();
 if (select (x->>'count')::integer from jsonb_array_elements(stats->'wear_counts') x where x->>'garment_id'='a1500000-0000-4000-8000-000000000001')<>3
 or (select (x->>'count')::integer from jsonb_array_elements(stats->'wear_counts') x where x->>'garment_id'='a1500000-0000-4000-8000-000000000002')<>1
 then raise exception 'FAIL per-record wear counts: %',stats; end if;

 -- Calendar: one entry per day, count, newest record as representative when none has a photo.
 cal:=public.get_my_ootd_calendar(current_date-3,current_date);
 if jsonb_array_length(cal)<>1 or (cal->0->>'count')::integer<>3 or cal->0->>'date'<>(current_date-1)::text
 or cal->0->>'representative_ootd_id'<>(select id::text from public.ootd_entries where user_id=auth.uid() and worn_on=current_date-1
   order by created_at desc,id desc limit 1)
 or cal->0->>'has_photo'<>'false' or cal->0 ? 'photo_object_key'
 then raise exception 'FAIL calendar summary %',cal; end if;
 begin perform public.get_my_ootd_calendar(current_date,current_date-1); raise exception 'FAIL reversed calendar range';
  exception when invalid_parameter_value then if sqlerrm<>'invalid_calendar_range' then raise; end if; end;
 begin perform public.get_my_ootd_calendar(current_date-62,current_date); raise exception 'FAIL calendar range limit';
  exception when invalid_parameter_value then if sqlerrm<>'invalid_calendar_range' then raise; end if; end;
 perform set_config('test.b_o1',o1::text,true);

 -- '오늘 입기': a different outfit the same day adds a record; the same outfit again returns the existing one.
 a1:=public.accept_my_recommendation('a1600000-0000-4000-8000-000000000001','a1700000-0000-4000-8000-000000000001',current_date,'accept-multi-1');
 a2:=public.accept_my_recommendation('a1600000-0000-4000-8000-000000000001','a1700000-0000-4000-8000-000000000002',current_date,'accept-multi-2');
 a3:=public.accept_my_recommendation('a1600000-0000-4000-8000-000000000001','a1700000-0000-4000-8000-000000000001',current_date,'accept-multi-3');
 if a1->>'ootd_id'=a2->>'ootd_id' or a3->>'ootd_id'<>a1->>'ootd_id'
 or (select count(*) from public.ootd_entries where user_id=auth.uid() and worn_on=current_date and wear_status='worn')<>2
 then raise exception 'FAIL accept adds per outfit: % % %',a1,a2,a3; end if;
end $$;
reset role;

-- A photo makes an older record the representative.
insert into public.media_uploads(id,user_id,purpose,bucket_id,object_key,content_type,byte_size,verified_at,attached_at) values
 ('a1900000-0000-4000-8000-000000000001','a1000000-0000-4000-8000-000000000001','ootd_photo','ootd-private',
  'a1000000-0000-4000-8000-000000000001/ootd_photo/a1900000-0000-4000-8000-000000000001.jpg','image/jpeg',10,now(),now()),
 ('a1900000-0000-4000-8000-000000000002','a1000000-0000-4000-8000-000000000001','avatar','profile-media',
  'a1000000-0000-4000-8000-000000000001/avatar/a1900000-0000-4000-8000-000000000002.jpg','image/jpeg',10,now(),now());
update public.ootd_entries set photo_object_key='a1000000-0000-4000-8000-000000000001/ootd_photo/a1900000-0000-4000-8000-000000000001.jpg'
 where id=current_setting('test.b_o1')::uuid;
update public.profiles set avatar_object_key='a1000000-0000-4000-8000-000000000001/avatar/a1900000-0000-4000-8000-000000000002.jpg'
 where id='a1000000-0000-4000-8000-000000000001';
set local role authenticated;
select set_config('request.jwt.claim.sub','a1000000-0000-4000-8000-000000000001',true);
do $$ declare cal jsonb; begin
 cal:=public.get_my_ootd_calendar(current_date-1,current_date-1);
 if cal->0->>'representative_ootd_id'<>current_setting('test.b_o1') or cal->0->>'has_photo'<>'true' or cal->0 ? 'photo_object_key'
 then raise exception 'FAIL photo representative %',cal; end if;
end $$;
reset role;

-- ---------------------------------------------------------------- 2. AI notice / training consent
set local role authenticated;
select set_config('request.jwt.claim.sub','a1000000-0000-4000-8000-000000000001',true);
do $$ declare first_at timestamptz; job jsonb; begin
 if (select training_consent or ai_notice_accepted_at is not null from public.profiles where id=auth.uid())
 then raise exception 'FAIL consent defaults'; end if;
 begin perform public.create_my_analysis_job('a1100000-0000-4000-8000-000000000003','notice-job-one');
  raise exception 'FAIL analysis without notice'; exception when raise_exception then if sqlerrm<>'ai_notice_required' then raise; end if; end;
 begin perform public.retry_my_analysis_job('a1300000-0000-4000-8000-000000000004','notice-retry-one');
  raise exception 'FAIL retry without notice'; exception when raise_exception then if sqlerrm<>'ai_notice_required' then raise; end if; end;
 if exists(select 1 from public.analysis_jobs where batch_id='a1100000-0000-4000-8000-000000000003')
 or (select status from public.analysis_jobs where id='a1300000-0000-4000-8000-000000000004')<>'failed'
 then raise exception 'FAIL refused analysis left state'; end if;
 begin perform public.update_my_profile_settings(false,null,false,null,false,null,false,false,null);
  raise exception 'FAIL empty settings patch'; exception when invalid_parameter_value then if sqlerrm<>'empty_profile_patch' then raise; end if; end;
 begin perform public.update_my_profile_settings(false,null,false,null,false,null,false,true,null);
  raise exception 'FAIL null training consent'; exception when invalid_parameter_value then if sqlerrm<>'invalid_consent' then raise; end if; end;
 perform public.update_my_profile_settings(true,'Track B',false,null,false,null,true,true,true);
 select ai_notice_accepted_at into first_at from public.profiles where id=auth.uid();
 if first_at is null or not(select training_consent and training_consent_updated_at is not null and display_name='Track B'
  from public.profiles where id=auth.uid()) then raise exception 'FAIL settings write'; end if;
 perform public.update_my_profile_settings(false,null,false,null,false,null,true,true,false);
 if (select ai_notice_accepted_at from public.profiles where id=auth.uid())<>first_at
 or (select training_consent from public.profiles where id=auth.uid()) then raise exception 'FAIL notice kept / consent withdrawn'; end if;
 job:=public.create_my_analysis_job('a1100000-0000-4000-8000-000000000003','notice-job-two');
 if job->>'status'<>'queued' then raise exception 'FAIL analysis after notice'; end if;
 begin perform public.purge_account_data(auth.uid()); raise exception 'FAIL purge exposed to user';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
select set_config('request.jwt.claim.sub','',true);

-- ---------------------------------------------------------------- 3. account purge
-- Social graph in both directions: U1 post liked/mimicked by U2, U1 likes/mimics U2's post.
insert into public.saved_outfits(id,user_id,title) values('a1a00000-0000-4000-8000-000000000001','a1000000-0000-4000-8000-000000000001','keep');
insert into public.saved_outfit_items(user_id,saved_outfit_id,garment_id,position)
 values('a1000000-0000-4000-8000-000000000001','a1a00000-0000-4000-8000-000000000001','a1500000-0000-4000-8000-000000000001',0);
insert into public.feed_posts(id,user_id,source_ootd_id,caption,visibility) values
 ('a1b00000-0000-4000-8000-000000000001','a1000000-0000-4000-8000-000000000001',current_setting('test.b_o1')::uuid,'mine','public'),
 ('a1b00000-0000-4000-8000-000000000002','a1000000-0000-4000-8000-000000000002',null,'theirs','public');
insert into public.feed_media(id,user_id,post_id,object_key,position,content_type,byte_size,verified_at) values
 ('a1c00000-0000-4000-8000-000000000001','a1000000-0000-4000-8000-000000000001','a1b00000-0000-4000-8000-000000000001',
  'a1000000-0000-4000-8000-000000000001/feed/p1.jpg',0,'image/jpeg',10,now()),
 ('a1c00000-0000-4000-8000-000000000002','a1000000-0000-4000-8000-000000000002','a1b00000-0000-4000-8000-000000000002',
  'a1000000-0000-4000-8000-000000000002/feed/p2.jpg',0,'image/jpeg',10,now());
insert into public.post_likes(user_id,post_id) values
 ('a1000000-0000-4000-8000-000000000002','a1b00000-0000-4000-8000-000000000001'),
 ('a1000000-0000-4000-8000-000000000001','a1b00000-0000-4000-8000-000000000002'),
 ('a1000000-0000-4000-8000-000000000002','a1b00000-0000-4000-8000-000000000002');
insert into public.mimic_requests(id,user_id,post_id,status) values
 ('a1d00000-0000-4000-8000-000000000001','a1000000-0000-4000-8000-000000000002','a1b00000-0000-4000-8000-000000000001','queued'),
 ('a1d00000-0000-4000-8000-000000000002','a1000000-0000-4000-8000-000000000001','a1b00000-0000-4000-8000-000000000002','queued');
insert into storage.objects(bucket_id,name,owner_id) values
 ('closet-private','a1000000-0000-4000-8000-000000000001/abandoned/x.jpg','a1000000-0000-4000-8000-000000000001'),
 ('closet-private','a1000000-0000-4000-8000-000000000002/b2/g3.png','a1000000-0000-4000-8000-000000000002');
do $$ begin
 if (select count(*) from public.ootd_entries where user_id='a1000000-0000-4000-8000-000000000001')<6
 or not exists(select 1 from public.idempotency_keys where user_id='a1000000-0000-4000-8000-000000000001')
 or not exists(select 1 from public.analysis_jobs where user_id='a1000000-0000-4000-8000-000000000001' and status='queued')
 then raise exception 'FAIL purge fixture incomplete'; end if;
end $$;

set local role service_role;
do $$ declare result jsonb; again jsonb; t record; n bigint; begin
 result:=public.purge_account_data('a1000000-0000-4000-8000-000000000001');
 if result->>'profile_deleted'<>'true' or (result->>'storage_objects_enqueued')::integer<>(select count(*) from public.storage_cleanup_queue)
 then raise exception 'FAIL purge result %',result; end if;
 -- Every user-owned table, discovered from the catalog so new tables are covered automatically.
 for t in select c.table_name from information_schema.columns c join information_schema.tables x
   on x.table_schema=c.table_schema and x.table_name=c.table_name and x.table_type='BASE TABLE'
   where c.table_schema='public' and c.column_name='user_id' order by c.table_name loop
  execute format('select count(*) from public.%I where user_id=$1',t.table_name) into n using 'a1000000-0000-4000-8000-000000000001'::uuid;
  if n<>0 then raise exception 'FAIL % keeps % rows after purge',t.table_name,n; end if;
 end loop;
 if exists(select 1 from public.profiles where id='a1000000-0000-4000-8000-000000000001')
 then raise exception 'FAIL profile kept'; end if;
 -- Other members' rows that pointed at the deleted user's content are gone too.
 if exists(select 1 from public.post_likes where post_id='a1b00000-0000-4000-8000-000000000001')
 or exists(select 1 from public.mimic_requests where post_id='a1b00000-0000-4000-8000-000000000001')
 or exists(select 1 from public.feed_posts where id='a1b00000-0000-4000-8000-000000000001')
 then raise exception 'FAIL cross-member references kept'; end if;
 -- The other member is untouched (minus the like/mimic on the deleted post).
 if (select count(*) from public.post_likes where user_id='a1000000-0000-4000-8000-000000000002')<>1
 or not exists(select 1 from public.feed_posts where id='a1b00000-0000-4000-8000-000000000002')
 or not exists(select 1 from public.garments where id='a1500000-0000-4000-8000-000000000003')
 or not exists(select 1 from public.profiles where id='a1000000-0000-4000-8000-000000000002')
 then raise exception 'FAIL other member damaged'; end if;
 -- Storage queue: every owned object path (closet, feed, profile, OOTD photo, abandoned) and nothing of U2.
 if exists(select 1 from public.storage_cleanup_queue where split_part(object_key,'/',1)<>'a1000000-0000-4000-8000-000000000001')
 or (select count(*) from public.storage_cleanup_queue where object_key in (
   'a1000000-0000-4000-8000-000000000001/b1/g1.png','a1000000-0000-4000-8000-000000000001/b1/g2.png',
   'a1000000-0000-4000-8000-000000000001/b3/source.jpg','a1000000-0000-4000-8000-000000000001/feed/p1.jpg',
   'a1000000-0000-4000-8000-000000000001/ootd_photo/a1900000-0000-4000-8000-000000000001.jpg',
   'a1000000-0000-4000-8000-000000000001/avatar/a1900000-0000-4000-8000-000000000002.jpg',
   'a1000000-0000-4000-8000-000000000001/abandoned/x.jpg'))<>7
 then raise exception 'FAIL storage cleanup queue'; end if;
 -- Retry after a partial failure (e.g. Admin API down) is a safe no-op.
 again:=public.purge_account_data('a1000000-0000-4000-8000-000000000001');
 if again->>'profile_deleted'<>'false' or (again->>'storage_objects_enqueued')::integer<>0
 then raise exception 'FAIL purge retry %',again; end if;
end $$;
reset role;
delete from auth.users where id='a1000000-0000-4000-8000-000000000001';

rollback;
