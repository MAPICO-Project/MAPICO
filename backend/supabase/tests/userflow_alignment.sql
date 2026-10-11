-- Run only against a disposable migrated database. Every fixture rolls back.
-- 2026-10-09 user-flow alignment: aesthetic roles, feed 'wind', OOTD photo, profile avatar (media_uploads).
begin;

insert into auth.users(id) values
 ('79000000-0000-4000-8000-000000000001'),('79000000-0000-4000-8000-000000000002');
insert into public.aesthetics(id,code,label,definition,version,active) values
 ('79100000-0000-4000-8000-000000000001','fixture_g9_1','G9 1','Test only','fixture-g9',true),
 ('79100000-0000-4000-8000-000000000002','fixture_g9_2','G9 2','Test only','fixture-g9',true),
 ('79100000-0000-4000-8000-000000000003','fixture_g9_3','G9 3','Test only','fixture-g9',true),
 ('79100000-0000-4000-8000-000000000004','fixture_g9_4','G9 4','Test only','fixture-g9',true);
insert into public.garment_batches(id,user_id,status) values
 ('79200000-0000-4000-8000-000000000001','79000000-0000-4000-8000-000000000001','confirmed');
insert into public.garment_assets(id,user_id,batch_id,kind,object_key,content_type,byte_size,verified_at) values
 ('79300000-0000-4000-8000-000000000001','79000000-0000-4000-8000-000000000001','79200000-0000-4000-8000-000000000001','cutout','79000000-0000-4000-8000-000000000001/a.png','image/png',10,now());
insert into public.analysis_jobs(id,user_id,batch_id,status) values
 ('79400000-0000-4000-8000-000000000001','79000000-0000-4000-8000-000000000001','79200000-0000-4000-8000-000000000001','succeeded');
insert into public.garment_drafts(id,user_id,batch_id,job_id,item_index,asset_id,status,raw_prediction,model_version) values
 ('79500000-0000-4000-8000-000000000001','79000000-0000-4000-8000-000000000001','79200000-0000-4000-8000-000000000001','79400000-0000-4000-8000-000000000001',0,'79300000-0000-4000-8000-000000000001','confirmed','{"category":"top"}','v1');
insert into public.garments(id,user_id,source_draft_id,asset_id,category) values
 ('79600000-0000-4000-8000-000000000001','79000000-0000-4000-8000-000000000001','79500000-0000-4000-8000-000000000001','79300000-0000-4000-8000-000000000001','top');

-- 1. Aesthetic roles through the RPC.
set local role authenticated;
select set_config('request.jwt.claim.sub','79000000-0000-4000-8000-000000000001',true);
do $$ begin
 perform public.replace_my_aesthetic_preferences('[
  {"aesthetic_id":"79100000-0000-4000-8000-000000000001","role":"main"},
  {"aesthetic_id":"79100000-0000-4000-8000-000000000002","role":"sub"},
  {"aesthetic_id":"79100000-0000-4000-8000-000000000003","role":"sub"}]');
 if (select count(*) from public.user_aesthetic_preferences where user_id=auth.uid() and role='main')<>1
 or (select count(*) from public.user_aesthetic_preferences where user_id=auth.uid() and role='sub')<>2
 or abs((select sum(weight) from public.user_aesthetic_preferences where user_id=auth.uid())-1)>0.0001
 or (select count(distinct weight) from public.user_aesthetic_preferences where user_id=auth.uid())<>1
 then raise exception 'FAIL role replacement with derived equal weights'; end if;
 perform public.replace_my_aesthetic_preferences('[
  {"aesthetic_id":"79100000-0000-4000-8000-000000000002","role":"main","weight":0.5},
  {"aesthetic_id":"79100000-0000-4000-8000-000000000001","role":"sub","weight":0.5}]');
 if (select aesthetic_id from public.user_aesthetic_preferences where user_id=auth.uid() and role='main')
  <>'79100000-0000-4000-8000-000000000002' then raise exception 'FAIL tied weights resolved by role'; end if;
 perform public.replace_my_aesthetic_preferences('[{"aesthetic_id":"79100000-0000-4000-8000-000000000004","role":"main"}]');
 if (select weight from public.user_aesthetic_preferences where user_id=auth.uid())<>1
 then raise exception 'FAIL single main weight'; end if;

 begin perform public.replace_my_aesthetic_preferences('[
  {"aesthetic_id":"79100000-0000-4000-8000-000000000001","role":"main"},
  {"aesthetic_id":"79100000-0000-4000-8000-000000000002","role":"main"}]'); raise exception 'FAIL two mains';
 exception when invalid_parameter_value then if sqlerrm<>'invalid_aesthetic_roles' then raise; end if; end;
 begin perform public.replace_my_aesthetic_preferences('[
  {"aesthetic_id":"79100000-0000-4000-8000-000000000001","role":"sub"}]'); raise exception 'FAIL no main';
 exception when invalid_parameter_value then if sqlerrm<>'invalid_aesthetic_roles' then raise; end if; end;
 begin perform public.replace_my_aesthetic_preferences('[
  {"aesthetic_id":"79100000-0000-4000-8000-000000000001","role":"main"},
  {"aesthetic_id":"79100000-0000-4000-8000-000000000002","role":"sub"},
  {"aesthetic_id":"79100000-0000-4000-8000-000000000003","role":"sub"},
  {"aesthetic_id":"79100000-0000-4000-8000-000000000004","role":"sub"}]'); raise exception 'FAIL three subs';
 exception when invalid_parameter_value then if sqlerrm<>'invalid_preference_count' then raise; end if; end;
 begin perform public.replace_my_aesthetic_preferences('[{"aesthetic_id":"79100000-0000-4000-8000-000000000001","weight":1}]');
  raise exception 'FAIL missing role';
 exception when invalid_parameter_value then if sqlerrm<>'invalid_preferences' then raise; end if; end;
 begin perform public.replace_my_aesthetic_preferences('[{"aesthetic_id":"79100000-0000-4000-8000-000000000001","role":"primary"}]');
  raise exception 'FAIL unknown role';
 exception when invalid_parameter_value then if sqlerrm<>'invalid_preferences' then raise; end if; end;
 begin perform public.replace_my_aesthetic_preferences('[
  {"aesthetic_id":"79100000-0000-4000-8000-000000000001","role":"main","weight":1},
  {"aesthetic_id":"79100000-0000-4000-8000-000000000002","role":"sub"}]'); raise exception 'FAIL partial weights';
 exception when invalid_parameter_value then if sqlerrm<>'invalid_preferences' then raise; end if; end;
 begin perform public.replace_my_aesthetic_preferences('[
  {"aesthetic_id":"79100000-0000-4000-8000-000000000001","role":"main","weight":0.3},
  {"aesthetic_id":"79100000-0000-4000-8000-000000000002","role":"sub","weight":0.7}]'); raise exception 'FAIL sub outweighs main';
 exception when invalid_parameter_value then if sqlerrm<>'invalid_main_weight' then raise; end if; end;
 begin perform public.replace_my_aesthetic_preferences('[{"aesthetic_id":"79100000-0000-4000-8000-000000000001","role":"main","weight":"1"}]');
  raise exception 'FAIL string weight';
 exception when invalid_parameter_value then if sqlerrm<>'invalid_preferences' then raise; end if; end;
 if (select count(*) from public.user_aesthetic_preferences where user_id=auth.uid())<>1
 then raise exception 'FAIL invalid role replacement was not atomic'; end if;
end $$;
reset role;

-- 1b. DB-level role invariants hold even for privileged direct writes.
do $$ begin
 begin insert into public.user_aesthetic_preferences(user_id,aesthetic_id,weight,role)
  values('79000000-0000-4000-8000-000000000001','79100000-0000-4000-8000-000000000001',1,'main');
  raise exception 'FAIL second main row';
 exception when unique_violation then null; end;
 begin insert into public.user_aesthetic_preferences(user_id,aesthetic_id,weight)
  values('79000000-0000-4000-8000-000000000002','79100000-0000-4000-8000-000000000001',1);
  raise exception 'FAIL null role';
 exception when not_null_violation then null; end;
 begin insert into public.user_aesthetic_preferences(user_id,aesthetic_id,weight,role)
  values('79000000-0000-4000-8000-000000000002','79100000-0000-4000-8000-000000000001',1,'lead');
  raise exception 'FAIL unknown role check';
 exception when check_violation then null; end;
 begin
  insert into public.user_aesthetic_preferences(user_id,aesthetic_id,weight,role)
   values('79000000-0000-4000-8000-000000000002','79100000-0000-4000-8000-000000000001',1,'sub');
  set constraints public.aesthetic_roles_valid immediate;
  raise exception 'FAIL sub without main';
 exception when check_violation then if sqlerrm<>'invalid_aesthetic_roles' then raise; end if; end;
 begin
  insert into public.user_aesthetic_preferences(user_id,aesthetic_id,weight,role) values
   ('79000000-0000-4000-8000-000000000002','79100000-0000-4000-8000-000000000001',0.25,'main'),
   ('79000000-0000-4000-8000-000000000002','79100000-0000-4000-8000-000000000002',0.25,'sub'),
   ('79000000-0000-4000-8000-000000000002','79100000-0000-4000-8000-000000000003',0.25,'sub'),
   ('79000000-0000-4000-8000-000000000002','79100000-0000-4000-8000-000000000004',0.25,'sub');
  set constraints public.aesthetic_roles_valid immediate;
  raise exception 'FAIL three subs at DB level';
 exception when check_violation then if sqlerrm<>'invalid_aesthetic_roles' then raise; end if; end;
 begin
  insert into public.user_aesthetic_preferences(user_id,aesthetic_id,weight,role) values
   ('79000000-0000-4000-8000-000000000002','79100000-0000-4000-8000-000000000001',0.4,'main'),
   ('79000000-0000-4000-8000-000000000002','79100000-0000-4000-8000-000000000002',0.6,'sub');
  set constraints public.aesthetic_roles_valid immediate;
  raise exception 'FAIL sub outweighs main at DB level';
 exception when check_violation then if sqlerrm<>'invalid_main_weight' then raise; end if; end;
end $$;

-- 2. Feed weather 'wind'.
set local role authenticated;
select set_config('request.jwt.claim.sub','79000000-0000-4000-8000-000000000001',true);
do $$ declare created jsonb; begin
 created:=public.create_my_feed_post(null,'windy','79100000-0000-4000-8000-000000000001','wind',12,'g9-feed-wind',array['79600000-0000-4000-8000-000000000001'::uuid]);
 if not exists(select 1 from public.feed_posts where id=(created->>'post_id')::uuid and weather_code='wind')
 then raise exception 'FAIL wind feed post'; end if;
 begin perform public.create_my_feed_post(null,'storm','79100000-0000-4000-8000-000000000001','storm',12,'g9-feed-storm',array['79600000-0000-4000-8000-000000000001'::uuid]);
  raise exception 'FAIL unknown weather code';
 exception when invalid_parameter_value then if sqlerrm<>'invalid_feed_post' then raise; end if; end;
end $$;
reset role;
do $$ begin
 begin update public.feed_posts set weather_code='storm' where user_id='79000000-0000-4000-8000-000000000001';
  raise exception 'FAIL weather check constraint';
 exception when check_violation then null; end;
end $$;

-- 3+4. OOTD photo and avatar uploads.
set local role authenticated;
select set_config('request.jwt.claim.sub','79000000-0000-4000-8000-000000000001',true);
do $$ declare photo jsonb; photo2 jsonb; avatar jsonb; replay jsonb; done jsonb; created jsonb; updated jsonb;
 photo_key text; photo2_key text; avatar_key text; ootd uuid; i integer;
begin
 begin insert into public.media_uploads(user_id,purpose,bucket_id,object_key,content_type,byte_size)
  values(auth.uid(),'avatar','profile-media',auth.uid()::text||'/avatar/x.jpg','image/jpeg',3);
  raise exception 'FAIL direct media_uploads write'; exception when insufficient_privilege then null; end;
 begin update public.profiles set avatar_object_key=null; raise exception 'FAIL direct avatar write';
  exception when insufficient_privilege then null; end;
 begin perform public.create_my_media_upload('banner','image/jpeg',3,'g9-upload-bad');
  raise exception 'FAIL unknown purpose'; exception when invalid_parameter_value then if sqlerrm<>'invalid_media_upload' then raise; end if; end;
 begin perform public.create_my_media_upload('avatar','image/gif',3,'g9-upload-gif');
  raise exception 'FAIL gif'; exception when invalid_parameter_value then if sqlerrm<>'invalid_media_upload' then raise; end if; end;
 begin perform public.create_my_media_upload('avatar','image/jpeg',20971521,'g9-upload-big');
  raise exception 'FAIL oversize'; exception when invalid_parameter_value then if sqlerrm<>'invalid_media_upload' then raise; end if; end;

 photo:=public.create_my_media_upload('ootd_photo','image/jpeg',3,'g9-upload-photo');
 replay:=public.create_my_media_upload('ootd_photo','image/jpeg',3,'g9-upload-photo');
 if photo->>'replayed'<>'false' or replay->>'replayed'<>'true' or replay->>'upload_id'<>photo->>'upload_id'
 then raise exception 'FAIL upload create replay'; end if;
 begin perform public.create_my_media_upload('avatar','image/jpeg',3,'g9-upload-photo');
  raise exception 'FAIL upload idempotency conflict'; exception when raise_exception then if sqlerrm<>'idempotency_conflict' then raise; end if; end;
 select object_key into photo_key from public.media_uploads where id=(photo->>'upload_id')::uuid;
 if photo_key<>auth.uid()::text||'/ootd_photo/'||(photo->>'upload_id')||'.jpg'
 or not exists(select 1 from public.media_uploads where id=(photo->>'upload_id')::uuid and bucket_id='ootd-private')
 then raise exception 'FAIL photo object key/bucket'; end if;

 -- Storage writes only for the exact pending row.
 begin insert into storage.objects(bucket_id,name,owner_id,metadata)
  values('ootd-private',auth.uid()::text||'/ootd_photo/arbitrary.jpg',auth.uid(),'{"mimetype":"image/jpeg","size":3}');
  raise exception 'FAIL arbitrary ootd storage insert'; exception when insufficient_privilege then null; end;
 begin insert into storage.objects(bucket_id,name,owner_id,metadata)
  values('profile-media',photo_key,auth.uid(),'{"mimetype":"image/jpeg","size":3}');
  raise exception 'FAIL cross-bucket storage insert'; exception when insufficient_privilege then null; end;
 -- 2026-10-11 (N3): the policy ignores metadata (hosted checks it without metadata); mime/size are verified by
 -- complete_my_media_upload. Probe insert without metadata, rolled back by the sub-block.
 begin insert into storage.objects(bucket_id,name,owner_id,metadata) values('ootd-private',photo_key,auth.uid()::text,'{}');
  raise exception 'probe_rollback'; exception when raise_exception then if sqlerrm<>'probe_rollback' then raise; end if; end;

 begin perform public.complete_my_media_upload((photo->>'upload_id')::uuid,'valid');
  raise exception 'FAIL complete before upload'; exception when raise_exception then if sqlerrm<>'upload_not_found' then raise; end if; end;
 insert into storage.objects(bucket_id,name,owner_id,metadata)
 values('ootd-private',photo_key,auth.uid(),'{"mimetype":"image/jpeg","size":3}');
 if not exists(select 1 from storage.objects where bucket_id='ootd-private' and name=photo_key)
 then raise exception 'FAIL owner cannot read pending object for verification'; end if;

 -- Not verified yet: attaching must fail.
 begin perform public.create_my_ootd_with_photo(current_date-1,array['79600000-0000-4000-8000-000000000001'::uuid],null,null,'worn',
  null,4,null,'g9-ootd-early',(photo->>'upload_id')::uuid);
  raise exception 'FAIL attach unverified'; exception when raise_exception then if sqlerrm<>'media_upload_not_ready' then raise; end if; end;
 if exists(select 1 from public.ootd_entries where user_id=auth.uid()) then raise exception 'FAIL failed attach was not atomic'; end if;

 done:=public.complete_my_media_upload((photo->>'upload_id')::uuid,'valid');
 if done->>'invalid'<>'false' or public.complete_my_media_upload((photo->>'upload_id')::uuid,'valid')->>'invalid'<>'false'
 then raise exception 'FAIL photo verification/replay'; end if;

 avatar:=public.create_my_media_upload('avatar','image/png',4,'g9-upload-avatar');
 select object_key into avatar_key from public.media_uploads where id=(avatar->>'upload_id')::uuid;
 insert into storage.objects(bucket_id,name,owner_id,metadata)
 values('profile-media',avatar_key,auth.uid(),'{"mimetype":"image/png","size":4}');
 perform public.complete_my_media_upload((avatar->>'upload_id')::uuid,'valid');

 -- Purpose mismatch: avatar upload cannot become an OOTD photo.
 begin perform public.create_my_ootd_with_photo(current_date-1,array['79600000-0000-4000-8000-000000000001'::uuid],null,null,'worn',
  null,4,null,'g9-ootd-wrong',(avatar->>'upload_id')::uuid);
  raise exception 'FAIL purpose mismatch'; exception when raise_exception then if sqlerrm<>'media_upload_not_ready' then raise; end if; end;

 created:=public.create_my_ootd_with_photo(current_date-1,array['79600000-0000-4000-8000-000000000001'::uuid],null,null,'worn',
  '메모',4,null,'g9-ootd-create',(photo->>'upload_id')::uuid);
 ootd:=(created->>'ootd_id')::uuid;
 if (select photo_object_key from public.ootd_entries where id=ootd)<>photo_key
 or not exists(select 1 from public.media_uploads where id=(photo->>'upload_id')::uuid and attached_at is not null)
 then raise exception 'FAIL OOTD photo attach'; end if;
 if public.create_my_ootd_with_photo(current_date-1,array['79600000-0000-4000-8000-000000000001'::uuid],null,null,'worn',
  '메모',4,null,'g9-ootd-create',(photo->>'upload_id')::uuid)->>'replayed'<>'true' then raise exception 'FAIL OOTD create replay'; end if;
 -- Plain create keeps working without a photo.
 perform public.create_my_ootd_with_photo(current_date-3,array['79600000-0000-4000-8000-000000000001'::uuid],null,null,'worn',
  null,null,null,'g9-ootd-nophoto',null);
 -- One upload attaches once: it cannot also become another OOTD's photo.
 begin perform public.update_my_ootd_with_photo((select id from public.ootd_entries where user_id=auth.uid() and worn_on=current_date-3),1,
  false,null,false,null,false,null,false,null,false,null,false,null,false,null,false,null,true,(photo->>'upload_id')::uuid);
  raise exception 'FAIL reuse attached upload'; exception when raise_exception then if sqlerrm<>'media_upload_not_ready' then raise; end if; end;

 -- Photo-only patch: version guarded, same photo is a no-op, replacement and removal work.
 begin perform public.update_my_ootd_with_photo(ootd,9,false,null,false,null,false,null,false,null,false,null,false,null,false,null,false,null,true,null);
  raise exception 'FAIL photo patch version'; exception when raise_exception then if sqlerrm<>'version_conflict' then raise; end if; end;
 updated:=public.update_my_ootd_with_photo(ootd,1,false,null,false,null,false,null,false,null,false,null,false,null,false,null,false,null,true,(photo->>'upload_id')::uuid);
 if (updated->>'version')::integer<>2 or (select photo_object_key from public.ootd_entries where id=ootd)<>photo_key
 then raise exception 'FAIL same-photo patch'; end if;
 photo2:=public.create_my_media_upload('ootd_photo','image/webp',5,'g9-upload-photo2');
 select object_key into photo2_key from public.media_uploads where id=(photo2->>'upload_id')::uuid;
 insert into storage.objects(bucket_id,name,owner_id,metadata)
 values('ootd-private',photo2_key,auth.uid(),'{"mimetype":"image/webp","size":5}');
 perform public.complete_my_media_upload((photo2->>'upload_id')::uuid,'valid');
 updated:=public.update_my_ootd_with_photo(ootd,2,false,null,false,null,false,null,false,null,false,null,true,'새 메모',false,null,false,null,true,(photo2->>'upload_id')::uuid);
 if (updated->>'version')::integer<>3 or not exists(select 1 from public.ootd_entries where id=ootd and photo_object_key=photo2_key and note='새 메모')
 then raise exception 'FAIL combined patch with photo replacement'; end if;
 updated:=public.update_my_ootd_with_photo(ootd,3,false,null,false,null,false,null,false,null,false,null,false,null,false,null,false,null,true,null);
 if (updated->>'version')::integer<>4 or (select photo_object_key from public.ootd_entries where id=ootd) is not null
 then raise exception 'FAIL photo removal'; end if;
 begin perform public.update_my_ootd_with_photo(ootd,4,false,null,false,null,false,null,false,null,false,null,false,null,false,null,false,null,false,null);
  raise exception 'FAIL empty patch'; exception when invalid_parameter_value then if sqlerrm<>'invalid_ootd_patch' then raise; end if; end;

 -- Avatar via PATCH /me wrapper.
 perform public.update_my_profile_with_avatar(true,'아바타',false,null,true,(avatar->>'upload_id')::uuid);
 if not exists(select 1 from public.profiles where id=auth.uid() and display_name='아바타' and avatar_object_key=avatar_key)
 then raise exception 'FAIL avatar attach'; end if;
 perform public.update_my_profile_with_avatar(false,null,false,null,true,(avatar->>'upload_id')::uuid);
 begin perform public.update_my_profile_with_avatar(false,null,false,null,true,(photo2->>'upload_id')::uuid);
  raise exception 'FAIL ootd photo as avatar'; exception when raise_exception then if sqlerrm<>'media_upload_not_ready' then raise; end if; end;
 begin perform public.update_my_profile_with_avatar(false,null,false,null,false,null);
  raise exception 'FAIL empty avatar patch'; exception when invalid_parameter_value then if sqlerrm<>'empty_profile_patch' then raise; end if; end;
 perform public.update_my_profile_with_avatar(false,null,false,null,true,null);
 if (select avatar_object_key from public.profiles where id=auth.uid()) is not null then raise exception 'FAIL avatar removal'; end if;

 -- Invalid upload is retired and cannot be retried into success.
 replay:=public.create_my_media_upload('avatar','image/jpeg',3,'g9-upload-invalid');
 insert into storage.objects(bucket_id,name,owner_id,metadata)
 values('profile-media',(select object_key from public.media_uploads where id=(replay->>'upload_id')::uuid),auth.uid(),'{"mimetype":"image/jpeg","size":3}');
 if public.complete_my_media_upload((replay->>'upload_id')::uuid,'invalid')->>'invalid'<>'true'
 then raise exception 'FAIL invalid outcome'; end if;
 begin perform public.complete_my_media_upload((replay->>'upload_id')::uuid,'valid');
  raise exception 'FAIL retired upload completes'; exception when raise_exception then if sqlerrm<>'media_upload_not_ready' then raise; end if; end;

 -- Open upload limit.
 for i in 1..10 loop perform public.create_my_media_upload('avatar','image/jpeg',i,'g9-open-'||lpad(i::text,4,'0')); end loop;
 begin perform public.create_my_media_upload('avatar','image/jpeg',99,'g9-open-overflow');
  raise exception 'FAIL open upload limit'; exception when raise_exception then if sqlerrm<>'too_many_open_uploads' then raise; end if; end;

 perform set_config('test.g9_photo2',photo2->>'upload_id',true);
 perform set_config('test.g9_ootd',ootd::text,true);
end $$;

-- Tenant isolation: the other member cannot see, read or attach these uploads.
select set_config('request.jwt.claim.sub','79000000-0000-4000-8000-000000000002',true);
do $$ begin
 if exists(select 1 from public.media_uploads) then raise exception 'FAIL media_uploads tenant leak'; end if;
 if exists(select 1 from storage.objects where bucket_id in ('ootd-private','profile-media'))
 then raise exception 'FAIL cross-tenant storage read'; end if;
 begin perform public.update_my_profile_with_avatar(false,null,false,null,true,current_setting('test.g9_photo2')::uuid);
  raise exception 'FAIL cross-tenant attach'; exception when no_data_found then if sqlerrm<>'media_upload_not_found' then raise; end if; end;
 begin perform public.complete_my_media_upload(current_setting('test.g9_photo2')::uuid,'valid');
  raise exception 'FAIL cross-tenant complete'; exception when no_data_found then if sqlerrm<>'media_upload_not_found' then raise; end if; end;
end $$;
reset role;

-- Direct privileged writes still respect owner FK and purpose checks.
do $$ declare other_key text; avatar_key text; begin
 select object_key into avatar_key from public.media_uploads
  where user_id='79000000-0000-4000-8000-000000000001' and purpose='avatar' and verified_at is not null limit 1;
 begin update public.ootd_entries set photo_object_key=avatar_key where id=current_setting('test.g9_ootd')::uuid;
  raise exception 'FAIL avatar key as OOTD photo'; exception when check_violation then null; end;
 insert into public.media_uploads(id,user_id,purpose,bucket_id,object_key,content_type,byte_size,verified_at)
 values('79700000-0000-4000-8000-000000000001','79000000-0000-4000-8000-000000000002','ootd_photo','ootd-private',
  '79000000-0000-4000-8000-000000000002/ootd_photo/79700000-0000-4000-8000-000000000001.jpg','image/jpeg',3,now())
 returning object_key into other_key;
 begin update public.ootd_entries set photo_object_key=other_key where id=current_setting('test.g9_ootd')::uuid;
  raise exception 'FAIL cross-owner OOTD photo'; exception when foreign_key_violation then null; end;
 insert into public.media_uploads(id,user_id,purpose,bucket_id,object_key,content_type,byte_size,verified_at)
 values('79700000-0000-4000-8000-000000000002','79000000-0000-4000-8000-000000000002','avatar','profile-media',
  '79000000-0000-4000-8000-000000000002/avatar/79700000-0000-4000-8000-000000000002.jpg','image/jpeg',3,now())
 returning object_key into other_key;
 begin update public.profiles set avatar_object_key=other_key where id='79000000-0000-4000-8000-000000000001';
  raise exception 'FAIL cross-owner avatar'; exception when foreign_key_violation then null; end;
 begin insert into public.media_uploads(user_id,purpose,bucket_id,object_key,content_type,byte_size)
  values('79000000-0000-4000-8000-000000000002','avatar','ootd-private','79000000-0000-4000-8000-000000000002/avatar/x.jpg','image/jpeg',3);
  raise exception 'FAIL avatar in OOTD bucket'; exception when check_violation then null; end;
 begin insert into public.media_uploads(user_id,purpose,bucket_id,object_key,content_type,byte_size)
  values('79000000-0000-4000-8000-000000000002','avatar','profile-media','79000000-0000-4000-8000-000000000001/avatar/x.jpg','image/jpeg',3);
  raise exception 'FAIL foreign path prefix'; exception when check_violation then null; end;
 begin insert into public.media_uploads(user_id,purpose,bucket_id,object_key,content_type,byte_size,attached_at)
  values('79000000-0000-4000-8000-000000000002','avatar','profile-media','79000000-0000-4000-8000-000000000002/avatar/y.jpg','image/jpeg',3,now());
  raise exception 'FAIL attached before verified'; exception when check_violation then null; end;
 if (select count(*) from public.idempotency_keys where user_id='79000000-0000-4000-8000-000000000001' and scope='media_upload_create')<4
 then raise exception 'FAIL media upload idempotency rows'; end if;
 -- Account deletion cascades through the new FKs.
 update public.profiles set avatar_object_key=(select object_key from public.media_uploads
  where user_id='79000000-0000-4000-8000-000000000001' and purpose='avatar' and verified_at is not null and deleted_at is null limit 1)
 where id='79000000-0000-4000-8000-000000000001';
 delete from public.feed_posts where user_id='79000000-0000-4000-8000-000000000001';
 delete from auth.users where id='79000000-0000-4000-8000-000000000001';
 if exists(select 1 from public.media_uploads where user_id='79000000-0000-4000-8000-000000000001')
 then raise exception 'FAIL media cascade on account deletion'; end if;
end $$;

rollback;
