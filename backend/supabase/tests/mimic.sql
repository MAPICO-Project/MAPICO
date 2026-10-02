-- Run only against a disposable migrated database. Every fixture rolls back.
-- Coverage evidence: mimic_candidate_items and idempotency_keys are exercised through the narrow service RPCs below.
begin;

insert into auth.users(id) values
 ('78000000-0000-4000-8000-000000000001'),
 ('78000000-0000-4000-8000-000000000002'),
 ('78000000-0000-4000-8000-000000000003');
insert into public.garment_batches(id,user_id,status) values
 ('78010000-0000-4000-8000-000000000001','78000000-0000-4000-8000-000000000001','confirmed'),
 ('78010000-0000-4000-8000-000000000003','78000000-0000-4000-8000-000000000003','confirmed');
insert into public.garment_assets(id,user_id,batch_id,kind,object_key,content_type,byte_size,verified_at) values
 ('78020000-0000-4000-8000-000000000001','78000000-0000-4000-8000-000000000001','78010000-0000-4000-8000-000000000001','cutout','78000000-0000-4000-8000-000000000001/mimic/top.png','image/png',12,now()),
 ('78020000-0000-4000-8000-000000000003','78000000-0000-4000-8000-000000000003','78010000-0000-4000-8000-000000000003','cutout','78000000-0000-4000-8000-000000000003/mimic/other.png','image/png',12,now());
insert into public.analysis_jobs(id,user_id,batch_id,status,completed_at) values
 ('78030000-0000-4000-8000-000000000001','78000000-0000-4000-8000-000000000001','78010000-0000-4000-8000-000000000001','succeeded',now()),
 ('78030000-0000-4000-8000-000000000003','78000000-0000-4000-8000-000000000003','78010000-0000-4000-8000-000000000003','succeeded',now());
insert into public.garment_drafts(id,user_id,batch_id,job_id,item_index,asset_id,status,raw_prediction,model_version) values
 ('78040000-0000-4000-8000-000000000001','78000000-0000-4000-8000-000000000001','78010000-0000-4000-8000-000000000001','78030000-0000-4000-8000-000000000001',0,'78020000-0000-4000-8000-000000000001','confirmed','{"category":"top"}','v1'),
 ('78040000-0000-4000-8000-000000000003','78000000-0000-4000-8000-000000000003','78010000-0000-4000-8000-000000000003','78030000-0000-4000-8000-000000000003',0,'78020000-0000-4000-8000-000000000003','confirmed','{"category":"top"}','v1');
insert into public.garments(id,user_id,source_draft_id,asset_id,category,attributes) values
 ('78050000-0000-4000-8000-000000000001','78000000-0000-4000-8000-000000000001','78040000-0000-4000-8000-000000000001','78020000-0000-4000-8000-000000000001','top','{"category":"top"}'),
 ('78050000-0000-4000-8000-000000000003','78000000-0000-4000-8000-000000000003','78040000-0000-4000-8000-000000000003','78020000-0000-4000-8000-000000000003','top','{"category":"top"}');
insert into storage.objects(id,bucket_id,name,owner_id,metadata,updated_at) values
 ('78060000-0000-4000-8000-000000000001','closet-private','78000000-0000-4000-8000-000000000001/mimic/top.png','78000000-0000-4000-8000-000000000001','{"mimetype":"image/png","size":12}',now()),
 ('78060000-0000-4000-8000-000000000003','closet-private','78000000-0000-4000-8000-000000000003/mimic/other.png','78000000-0000-4000-8000-000000000003','{"mimetype":"image/png","size":12}',now());

insert into public.feed_posts(id,user_id,caption,visibility) values
 ('78100000-0000-4000-8000-000000000001','78000000-0000-4000-8000-000000000002','one','public'),
 ('78100000-0000-4000-8000-000000000002','78000000-0000-4000-8000-000000000002','two','public'),
 ('78100000-0000-4000-8000-000000000003','78000000-0000-4000-8000-000000000002','three','public'),
 ('78100000-0000-4000-8000-000000000004','78000000-0000-4000-8000-000000000002','four','public'),
 ('78100000-0000-4000-8000-000000000005','78000000-0000-4000-8000-000000000002','five','public'),
 ('78100000-0000-4000-8000-000000000006','78000000-0000-4000-8000-000000000002','private','private');
insert into public.feed_media(id,user_id,post_id,object_key,position,verified_at,content_type,byte_size) values
 ('78200000-0000-4000-8000-000000000001','78000000-0000-4000-8000-000000000002','78100000-0000-4000-8000-000000000001','78000000-0000-4000-8000-000000000002/78100000-0000-4000-8000-000000000001/1.jpg',0,now(),'image/jpeg',10),
 ('78200000-0000-4000-8000-000000000002','78000000-0000-4000-8000-000000000002','78100000-0000-4000-8000-000000000002','78000000-0000-4000-8000-000000000002/78100000-0000-4000-8000-000000000002/2.jpg',0,now(),'image/jpeg',10),
 ('78200000-0000-4000-8000-000000000003','78000000-0000-4000-8000-000000000002','78100000-0000-4000-8000-000000000003','78000000-0000-4000-8000-000000000002/78100000-0000-4000-8000-000000000003/3.jpg',0,now(),'image/jpeg',10),
 ('78200000-0000-4000-8000-000000000004','78000000-0000-4000-8000-000000000002','78100000-0000-4000-8000-000000000004','78000000-0000-4000-8000-000000000002/78100000-0000-4000-8000-000000000004/4.jpg',0,now(),'image/jpeg',10),
 ('78200000-0000-4000-8000-000000000005','78000000-0000-4000-8000-000000000002','78100000-0000-4000-8000-000000000005','78000000-0000-4000-8000-000000000002/78100000-0000-4000-8000-000000000005/5.jpg',0,now(),'image/jpeg',10),
 ('78200000-0000-4000-8000-000000000006','78000000-0000-4000-8000-000000000002','78100000-0000-4000-8000-000000000006','78000000-0000-4000-8000-000000000002/78100000-0000-4000-8000-000000000006/6.jpg',0,now(),'image/jpeg',10);
insert into storage.objects(id,bucket_id,name,owner_id,metadata,updated_at) values
 ('78300000-0000-4000-8000-000000000001','feed-private','78000000-0000-4000-8000-000000000002/78100000-0000-4000-8000-000000000001/1.jpg','78000000-0000-4000-8000-000000000002','{"mimetype":"image/jpeg","size":10}',now()),
 ('78300000-0000-4000-8000-000000000002','feed-private','78000000-0000-4000-8000-000000000002/78100000-0000-4000-8000-000000000002/2.jpg','78000000-0000-4000-8000-000000000002','{"mimetype":"image/jpeg","size":10}',now()),
 ('78300000-0000-4000-8000-000000000003','feed-private','78000000-0000-4000-8000-000000000002/78100000-0000-4000-8000-000000000003/3.jpg','78000000-0000-4000-8000-000000000002','{"mimetype":"image/jpeg","size":10}',now()),
 ('78300000-0000-4000-8000-000000000004','feed-private','78000000-0000-4000-8000-000000000002/78100000-0000-4000-8000-000000000004/4.jpg','78000000-0000-4000-8000-000000000002','{"mimetype":"image/jpeg","size":10}',now()),
 ('78300000-0000-4000-8000-000000000005','feed-private','78000000-0000-4000-8000-000000000002/78100000-0000-4000-8000-000000000005/5.jpg','78000000-0000-4000-8000-000000000002','{"mimetype":"image/jpeg","size":10}',now()),
 ('78300000-0000-4000-8000-000000000006','feed-private','78000000-0000-4000-8000-000000000002/78100000-0000-4000-8000-000000000006/6.jpg','78000000-0000-4000-8000-000000000002','{"mimetype":"image/jpeg","size":10}',now());

set local role authenticated;
select set_config('request.jwt.claim.sub','78000000-0000-4000-8000-000000000001',true);
do $$ declare created jsonb; replay jsonb; begin
 begin perform id from public.mimic_requests; raise exception 'FAIL raw mimic table exposed';
  exception when insufficient_privilege then null; end;
 begin perform job_id from public.mimic_source_items; raise exception 'FAIL source snapshot exposed';
  exception when insufficient_privilege then null; end;
 begin perform public.claim_mimic_job(120); raise exception 'FAIL claim exposed';
  exception when insufficient_privilege then null; end;
 begin perform public.inspect_mimic_callback(gen_random_uuid(),gen_random_uuid(),1,repeat('a',64));
  raise exception 'FAIL callback inspect exposed'; exception when insufficient_privilege then null; end;
 begin perform public.create_my_mimic_job('78100000-0000-4000-8000-000000000006','mimic-private-one');
  raise exception 'FAIL private source accepted'; exception when no_data_found then null; end;
 created:=public.create_my_mimic_job('78100000-0000-4000-8000-000000000001','mimic-create-one');
 replay:=public.create_my_mimic_job('78100000-0000-4000-8000-000000000001','mimic-create-two');
 if created->>'status'<>'queued' or jsonb_array_length(created->'matches')<>0
 or created->>'id'<>replay->>'id' or created->'coverage'<>'null'::jsonb
 then raise exception 'FAIL queued projection/open job reuse'; end if;
 begin perform public.create_my_mimic_job('78100000-0000-4000-8000-000000000002','mimic-create-one');
  raise exception 'FAIL create key conflict'; exception when raise_exception then if sqlerrm<>'idempotency_conflict' then raise; end if; end;
 perform set_config('test.mimic_job_one',created->>'id',true);
end $$;
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub','78000000-0000-4000-8000-000000000003',true);
do $$ begin
 begin perform public.get_my_mimic_job(current_setting('test.mimic_job_one')::uuid);
  raise exception 'FAIL cross owner job exposed'; exception when no_data_found then null; end;
end $$;
reset role;

set local role service_role;
do $$ declare claimed jsonb; inspected jsonb; matches jsonb; applied jsonb; begin
 claimed:=public.claim_mimic_job(120);
 if claimed->>'id'<>current_setting('test.mimic_job_one')
 or claimed->'source_items'->0->>'source_item_key'<>'media:78200000-0000-4000-8000-000000000001'
 or jsonb_array_length(claimed->'source_items')<>1 or jsonb_array_length(claimed->'candidates')<>1
 or claimed->'candidates'->0->>'garment_id'<>'78050000-0000-4000-8000-000000000001'
 then raise exception 'FAIL immutable source/candidate claim snapshot'; end if;
 perform set_config('test.mimic_attempt',claimed->>'attempt',true);
 perform set_config('test.mimic_lease',claimed->>'lease_token',true);
 inspected:=public.inspect_mimic_callback('78500000-0000-4000-8000-000000000001',
  current_setting('test.mimic_job_one')::uuid,(claimed->>'attempt')::integer,repeat('a',64));
 if inspected->>'replayed'<>'false' or inspected#>>'{job,status}'<>'running' then raise exception 'FAIL callback inspect'; end if;
 matches:=jsonb_build_array(jsonb_build_object('source_item_key','media:78200000-0000-4000-8000-000000000001',
  'garment_id','78050000-0000-4000-8000-000000000003','similarity',0.7,'reason','cross'));
 begin perform public.apply_mimic_result('78500000-0000-4000-8000-000000000002',current_setting('test.mimic_job_one')::uuid,
  current_setting('test.mimic_attempt')::integer,current_setting('test.mimic_lease')::uuid,repeat('b',64),
  'succeeded','mimic-v1',matches,1,null);
  raise exception 'FAIL cross owner candidate accepted'; exception when invalid_parameter_value then if sqlerrm<>'invalid_candidate_snapshot' then raise; end if; end;
 update public.garments set version=version+1 where id='78050000-0000-4000-8000-000000000001';
 matches:=jsonb_build_array(jsonb_build_object('source_item_key','media:78200000-0000-4000-8000-000000000001',
  'garment_id','78050000-0000-4000-8000-000000000001','similarity',0.8,'reason','비슷한 상의'));
 begin perform public.apply_mimic_result('78500000-0000-4000-8000-000000000003',current_setting('test.mimic_job_one')::uuid,
  current_setting('test.mimic_attempt')::integer,current_setting('test.mimic_lease')::uuid,repeat('c',64),
  'succeeded','mimic-v1',matches,1,null);
  raise exception 'FAIL changed candidate fence accepted'; exception when raise_exception then if sqlerrm<>'candidate_fence_changed' then raise; end if; end;
 update public.garments set version=version-1 where id='78050000-0000-4000-8000-000000000001';
 applied:=public.apply_mimic_result('78500000-0000-4000-8000-000000000004',current_setting('test.mimic_job_one')::uuid,
  current_setting('test.mimic_attempt')::integer,current_setting('test.mimic_lease')::uuid,repeat('d',64),
  'succeeded','mimic-v1',matches,1,null);
 if applied->>'applied'<>'true' then raise exception 'FAIL valid callback'; end if;
 if public.apply_mimic_result('78500000-0000-4000-8000-000000000004',current_setting('test.mimic_job_one')::uuid,
  current_setting('test.mimic_attempt')::integer,current_setting('test.mimic_lease')::uuid,repeat('d',64),
  'succeeded','mimic-v1',matches,1,null)->>'applied'<>'false' then raise exception 'FAIL callback replay'; end if;
 begin perform public.apply_mimic_result('78500000-0000-4000-8000-000000000004',current_setting('test.mimic_job_one')::uuid,
  current_setting('test.mimic_attempt')::integer,current_setting('test.mimic_lease')::uuid,repeat('e',64),
  'succeeded','mimic-v1',matches,1,null);
  raise exception 'FAIL callback payload conflict'; exception when raise_exception then if sqlerrm<>'callback_conflict' then raise; end if; end;
end $$;
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub','78000000-0000-4000-8000-000000000001',true);
do $$ declare projected jsonb; begin
 projected:=public.get_my_mimic_job(current_setting('test.mimic_job_one')::uuid);
 if projected->>'status'<>'succeeded' or projected->>'model_version'<>'mimic-v1'
 or projected#>>'{matches,0,garment_id}'<>'78050000-0000-4000-8000-000000000001'
 or (projected->>'coverage')::numeric<>1 or projected::text like '%object_key%'
 then raise exception 'FAIL succeeded safe projection'; end if;
end $$;
reset role;
update public.garments set deleted_at=now() where id='78050000-0000-4000-8000-000000000001';
set local role authenticated;
select set_config('request.jwt.claim.sub','78000000-0000-4000-8000-000000000001',true);
do $$ declare projected jsonb; begin
 projected:=public.get_my_mimic_job(current_setting('test.mimic_job_one')::uuid);
 if projected->>'status'<>'no_match' or (projected->>'coverage')::numeric<>0 or projected->'matches'->0->'garment_id'<>'null'::jsonb
 then raise exception 'FAIL unavailable terminal garment projection'; end if;
end $$;
reset role;
update public.garments set deleted_at=null where id='78050000-0000-4000-8000-000000000001';
update public.feed_posts set visibility='private' where id='78100000-0000-4000-8000-000000000001';
set local role authenticated;
select set_config('request.jwt.claim.sub','78000000-0000-4000-8000-000000000001',true);
do $$ begin
 begin perform public.get_my_mimic_job(current_setting('test.mimic_job_one')::uuid);
  raise exception 'FAIL private source result exposed'; exception when no_data_found then null; end;
end $$;
reset role;
update public.feed_posts set visibility='public' where id='78100000-0000-4000-8000-000000000001';

-- A complete no-match result retains one source entry with a null candidate.
set local role authenticated;
select set_config('request.jwt.claim.sub','78000000-0000-4000-8000-000000000001',true);
select set_config('test.mimic_job_two',(public.create_my_mimic_job('78100000-0000-4000-8000-000000000002','mimic-create-three')->>'id'),true);
reset role;
set local role service_role;
do $$ declare claimed jsonb; matches jsonb; begin
 claimed:=public.claim_mimic_job(120);
 matches:=jsonb_build_array(jsonb_build_object('source_item_key','media:78200000-0000-4000-8000-000000000002',
  'garment_id',null,'similarity',null,'reason','맞는 후보 없음'));
 perform public.apply_mimic_result('78500000-0000-4000-8000-000000000005',(claimed->>'id')::uuid,
  (claimed->>'attempt')::integer,(claimed->>'lease_token')::uuid,repeat('f',64),'no_match','mimic-v1',matches,0,null);
end $$;
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub','78000000-0000-4000-8000-000000000001',true);
do $$ declare projected jsonb:=public.get_my_mimic_job(current_setting('test.mimic_job_two')::uuid); begin
 if projected->>'status'<>'no_match' or (projected->>'coverage')::numeric<>0
 or projected->'matches'->0->'garment_id'<>'null'::jsonb then raise exception 'FAIL no-match projection'; end if;
end $$;
reset role;

-- GET and claim both sweep the independent two-hour execution deadline; retention is seven days after terminal.
set local role authenticated;
select set_config('request.jwt.claim.sub','78000000-0000-4000-8000-000000000001',true);
select set_config('test.mimic_job_three',(public.create_my_mimic_job('78100000-0000-4000-8000-000000000003','mimic-deadline-get')->>'id'),true);
reset role;
update public.mimic_requests set absolute_deadline=now()-interval '1 second' where id=current_setting('test.mimic_job_three')::uuid;
set local role authenticated;
select set_config('request.jwt.claim.sub','78000000-0000-4000-8000-000000000001',true);
do $$ declare projected jsonb:=public.get_my_mimic_job(current_setting('test.mimic_job_three')::uuid); begin
 if projected->>'status'<>'failed' or projected#>>'{error,code}'<>'DEADLINE_EXCEEDED' then raise exception 'FAIL get deadline sweep'; end if;
end $$;
reset role;
do $$ begin
 if not exists(select 1 from public.mimic_requests where id=current_setting('test.mimic_job_three')::uuid
  and retention_expires_at between now()+interval '6 days 23 hours' and now()+interval '7 days 1 hour')
 then raise exception 'FAIL terminal seven-day retention'; end if;
end $$;
update public.mimic_requests set retention_expires_at=now()-interval '1 second' where id=current_setting('test.mimic_job_three')::uuid;
set local role authenticated;
select set_config('request.jwt.claim.sub','78000000-0000-4000-8000-000000000001',true);
do $$ begin
 begin perform public.get_my_mimic_job(current_setting('test.mimic_job_three')::uuid);
  raise exception 'FAIL expired terminal result visible'; exception when no_data_found then null; end;
end $$;
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub','78000000-0000-4000-8000-000000000001',true);
select set_config('test.mimic_claim_deadline',(public.create_my_mimic_job('78100000-0000-4000-8000-000000000005','mimic-deadline-claim')->>'id'),true);
reset role;
update public.mimic_requests set absolute_deadline=now()-interval '1 second'
 where id=current_setting('test.mimic_claim_deadline')::uuid;
set local role service_role;
select public.claim_mimic_job(120);
reset role;
do $$ begin
 if not exists(select 1 from public.mimic_requests where id=current_setting('test.mimic_claim_deadline')::uuid
  and status='failed' and error_code='DEADLINE_EXCEEDED' and retention_expires_at is not null)
 then raise exception 'FAIL claim deadline sweep'; end if;
end $$;

set local role authenticated;
select set_config('request.jwt.claim.sub','78000000-0000-4000-8000-000000000001',true);
select set_config('test.mimic_job_four',(public.create_my_mimic_job('78100000-0000-4000-8000-000000000004','mimic-source-change')->>'id'),true);
reset role;
update public.feed_media set deleted_at=now() where id='78200000-0000-4000-8000-000000000004';
set local role service_role;
select public.claim_mimic_job(120);
reset role;
do $$ begin
 if not exists(select 1 from public.mimic_requests where id=current_setting('test.mimic_job_four')::uuid
  and status='failed' and error_code='SOURCE_UNAVAILABLE') then raise exception 'FAIL claim source fence'; end if;
end $$;
update public.feed_media set deleted_at=null where id='78200000-0000-4000-8000-000000000004';

-- User advisory serialization plus partial unique index make the per-user cap deterministic.
set local role authenticated;
select set_config('request.jwt.claim.sub','78000000-0000-4000-8000-000000000001',true);
do $$ declare a jsonb; b jsonb; c jsonb; begin
 a:=public.create_my_mimic_job('78100000-0000-4000-8000-000000000003','mimic-cap-one');
 b:=public.create_my_mimic_job('78100000-0000-4000-8000-000000000004','mimic-cap-two');
 c:=public.create_my_mimic_job('78100000-0000-4000-8000-000000000005','mimic-cap-three');
 if a->>'id'=b->>'id' or b->>'id'=c->>'id' then raise exception 'FAIL cap setup'; end if;
 begin perform public.create_my_mimic_job('78100000-0000-4000-8000-000000000001','mimic-cap-four');
  raise exception 'FAIL open cap bypassed'; exception when raise_exception then if sqlerrm<>'mimic_open_limit' then raise; end if; end;
end $$;
reset role;

do $$ declare before_count integer; begin
 select count(*) into before_count from public.mimic_requests where post_id in(
  select id from public.feed_posts where user_id='78000000-0000-4000-8000-000000000002');
 if before_count=0 then raise exception 'FAIL cascade fixture'; end if;
 delete from auth.users where id='78000000-0000-4000-8000-000000000002';
 if exists(select 1 from public.mimic_requests where post_id in(
  '78100000-0000-4000-8000-000000000001','78100000-0000-4000-8000-000000000002','78100000-0000-4000-8000-000000000003',
  '78100000-0000-4000-8000-000000000004','78100000-0000-4000-8000-000000000005','78100000-0000-4000-8000-000000000006'))
 then raise exception 'FAIL author/post mimic cascade'; end if;
end $$;

rollback;
