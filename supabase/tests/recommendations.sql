-- Run only against a disposable migrated database. Every fixture rolls back.
begin;
do $$ begin
 if not exists(select 1 from public.weather_snapshots where false) then null; end if;
 if not exists(select 1 from public.outfit_items where false) then null; end if;
end $$;
insert into auth.users(id) values
 ('74000000-0000-4000-8000-000000000001'),('74000000-0000-4000-8000-000000000002');
insert into public.garment_batches(id,user_id,status) values
 ('74100000-0000-4000-8000-000000000001','74000000-0000-4000-8000-000000000001','confirmed'),
 ('74100000-0000-4000-8000-000000000002','74000000-0000-4000-8000-000000000002','confirmed');
insert into public.garment_assets(id,user_id,batch_id,kind,object_key,content_type,byte_size,verified_at) values
 ('74200000-0000-4000-8000-000000000001','74000000-0000-4000-8000-000000000001','74100000-0000-4000-8000-000000000001','cutout','74000000-0000-4000-8000-000000000001/a.png','image/png',10,now()),
 ('74200000-0000-4000-8000-000000000002','74000000-0000-4000-8000-000000000001','74100000-0000-4000-8000-000000000001','cutout','74000000-0000-4000-8000-000000000001/b.png','image/png',10,now()),
 ('74200000-0000-4000-8000-000000000003','74000000-0000-4000-8000-000000000002','74100000-0000-4000-8000-000000000002','cutout','74000000-0000-4000-8000-000000000002/a.png','image/png',10,now());
insert into public.analysis_jobs(id,user_id,batch_id,status) values
 ('74300000-0000-4000-8000-000000000001','74000000-0000-4000-8000-000000000001','74100000-0000-4000-8000-000000000001','succeeded'),
 ('74300000-0000-4000-8000-000000000002','74000000-0000-4000-8000-000000000002','74100000-0000-4000-8000-000000000002','succeeded');
insert into public.garment_drafts(id,user_id,batch_id,job_id,item_index,asset_id,status,raw_prediction,model_version) values
 ('74400000-0000-4000-8000-000000000001','74000000-0000-4000-8000-000000000001','74100000-0000-4000-8000-000000000001','74300000-0000-4000-8000-000000000001',0,'74200000-0000-4000-8000-000000000001','confirmed','{"category":"top"}','v1'),
 ('74400000-0000-4000-8000-000000000002','74000000-0000-4000-8000-000000000001','74100000-0000-4000-8000-000000000001','74300000-0000-4000-8000-000000000001',1,'74200000-0000-4000-8000-000000000002','confirmed','{"category":"bottom"}','v1'),
 ('74400000-0000-4000-8000-000000000003','74000000-0000-4000-8000-000000000002','74100000-0000-4000-8000-000000000002','74300000-0000-4000-8000-000000000002',0,'74200000-0000-4000-8000-000000000003','confirmed','{"category":"top"}','v1');
insert into public.garments(id,user_id,source_draft_id,asset_id,category,attributes) values
 ('74500000-0000-4000-8000-000000000001','74000000-0000-4000-8000-000000000001','74400000-0000-4000-8000-000000000001','74200000-0000-4000-8000-000000000001','top','{"category":"top"}'),
 ('74500000-0000-4000-8000-000000000002','74000000-0000-4000-8000-000000000001','74400000-0000-4000-8000-000000000002','74200000-0000-4000-8000-000000000002','bottom','{"category":"bottom"}'),
 ('74500000-0000-4000-8000-000000000003','74000000-0000-4000-8000-000000000002','74400000-0000-4000-8000-000000000003','74200000-0000-4000-8000-000000000003','top','{"category":"top"}');
insert into public.weather_snapshots(id,grid_x,grid_y,issued_at,valid_at,fetched_at,source,payload) values
 ('74600000-0000-4000-8000-000000000001',60,127,date_trunc('hour',now())-interval '5 hours',date_trunc('hour',now()),now()-interval '4 hours','kma_short_term',
  '{"temperature_c":20,"feels_like_c":19,"precipitation_probability":0,"precipitation_type":"none","humidity":50,"air_quality":"good"}'),
 ('74600000-0000-4000-8000-000000000002',60,127,date_trunc('hour',now())-interval '5 hours',date_trunc('hour',now()),now()-interval '20 minutes','kma_short_term',
  '{"temperature_c":20,"feels_like_c":19,"precipitation_probability":0,"precipitation_type":"none","humidity":50,"air_quality":"good"}');

set local role authenticated;
select set_config('request.jwt.claim.sub','74000000-0000-4000-8000-000000000001',true);
do $$ declare r1 jsonb; r2 jsonb; r jsonb; begin
 begin perform public.upsert_weather_snapshot(60,127,now(),date_trunc('hour',now()),'kma_short_term','{"temperature_c":20,"precipitation_type":"none"}');
  raise exception 'FAIL weather upsert exposed'; exception when insufficient_privilege then null; end;
 begin perform public.get_weather_snapshot(gen_random_uuid()); raise exception 'FAIL weather getter exposed';
  exception when insufficient_privilege then null; end;
 begin insert into public.recommendation_requests(user_id,target_date,engine_version) values(auth.uid(),current_date,'forged');
  raise exception 'FAIL recommendation direct write'; exception when insufficient_privilege then null; end;
 begin perform preference_snapshot from public.recommendation_requests; raise exception 'FAIL preference snapshot exposed';
  exception when insufficient_privilege then null; end;
 begin perform public.accept_outfit(gen_random_uuid(),current_date); raise exception 'FAIL legacy accept exposed';
  exception when insufficient_privilege then null; end;
 r1:=public.begin_my_recommendation(60,127,date_trunc('hour',now()),1,'recommend-one',repeat('a',64),'engine-v1','rules-v1');
 r2:=public.begin_my_recommendation(60,127,date_trunc('hour',now()),1,'recommend-one',repeat('a',64),'engine-v1','rules-v1');
 if r1->>'replayed'<>'false' or r2->>'replayed'<>'true' or r2->>'in_progress'<>'true'
 or r2?'reservation_token' or r1->>'request_id'<>r2->>'request_id'
 then raise exception 'FAIL recommendation reservation replay'; end if;
 perform set_config('test.initial_token_one',r1->>'reservation_token',true);
 begin perform public.begin_my_recommendation(60,127,date_trunc('hour',now()),1,'recommend-one',repeat('b',64),'engine-v1','rules-v1');
  raise exception 'FAIL reservation idempotency conflict'; exception when raise_exception then if sqlerrm<>'idempotency_conflict' then raise; end if; end;
 r:=public.begin_my_recommendation(60,127,date_trunc('hour',now()),1,'recommend-two',repeat('c',64),'engine-v1','rules-v1');
 perform set_config('test.token_two',r->>'reservation_token',true);
 r:=public.begin_my_recommendation(60,127,date_trunc('hour',now()),1,'recommend-invalid',repeat('d',64),'engine-v1','rules-v1');
 perform set_config('test.token_bad',r->>'reservation_token',true);
 r:=public.begin_my_recommendation(60,127,date_trunc('hour',now()),2,'recommend-dupe',repeat('f',64),'engine-v1','rules-v1');
 perform set_config('test.token_dupe',r->>'reservation_token',true);
end $$;
select set_config('request.jwt.claim.sub','74000000-0000-4000-8000-000000000002',true);
do $$ declare r jsonb; begin
 r:=public.begin_my_recommendation(60,127,date_trunc('hour',now()),1,'recommend-other',repeat('e',64),'engine-v1','rules-v1');
 perform set_config('test.token_other',r->>'reservation_token',true);
end $$;
reset role;
update public.recommendation_requests set reservation_lease_expires_at=now()-interval '1 second'
 where id=(select (response_body->>'request_id')::uuid from public.idempotency_keys
  where user_id='74000000-0000-4000-8000-000000000001' and scope='recommendation_create' and key='recommend-one');
set local role authenticated;
select set_config('request.jwt.claim.sub','74000000-0000-4000-8000-000000000001',true);
do $$ declare resumed jsonb; begin
 resumed:=public.begin_my_recommendation(60,127,date_trunc('hour',now()),1,'recommend-one',repeat('a',64),'engine-v1','rules-v1');
 if resumed->>'resumed'<>'true' or resumed->>'in_progress'<>'false'
 or resumed->>'reservation_token'=current_setting('test.initial_token_one') then raise exception 'FAIL expired reservation resume'; end if;
 perform set_config('test.token_one',resumed->>'reservation_token',true);
end $$;
reset role;

set local role service_role;
do $$ declare weather jsonb; refreshed_weather jsonb; found_weather jsonb; outfit_a jsonb; outfit_b jsonb; duplicate_outfits jsonb;
 request_one uuid; request_two uuid; request_bad uuid; request_other uuid; request_dupe uuid; result jsonb; begin
 found_weather:=public.find_weather_snapshot(60,127,date_trunc('hour',now()),'kma_short_term');
 if found_weather->>'id'<>'74600000-0000-4000-8000-000000000002'
 or not exists(select 1 from public.weather_snapshots where id='74600000-0000-4000-8000-000000000001' and fetched_at<now()-interval '3 hours')
 then raise exception 'FAIL stale weather cache fixtures'; end if;
 weather:=public.upsert_weather_snapshot(60,127,date_trunc('hour',now())-interval '5 hours',date_trunc('hour',now()),'kma_short_term',
  '{"temperature_c":20,"feels_like_c":19,"precipitation_probability":0,"precipitation_type":"none","humidity":50,"air_quality":"good"}');
 found_weather:=public.find_weather_snapshot(60,127,date_trunc('hour',now()),'kma_short_term');
 if weather->>'id'<>found_weather->>'id' or public.get_weather_snapshot((weather->>'id')::uuid)->>'id'<>weather->>'id'
  then raise exception 'FAIL weather cache read'; end if;
 refreshed_weather:=public.upsert_weather_snapshot(60,127,date_trunc('hour',now())-interval '5 hours',date_trunc('hour',now()),'kma_short_term',
  '{"temperature_c":20,"feels_like_c":19,"precipitation_probability":0,"precipitation_type":"none","humidity":50,"air_quality":"good"}');
 if refreshed_weather->>'id'=weather->>'id' or public.find_weather_snapshot(60,127,date_trunc('hour',now()),'kma_short_term')->>'id'<>refreshed_weather->>'id'
 or (refreshed_weather->>'fetched_at')::timestamptz<(weather->>'fetched_at')::timestamptz
 or (select count(*) from public.weather_snapshots where grid_x=60 and grid_y=127 and valid_at=date_trunc('hour',now()) and source='kma_short_term')<>4
 then raise exception 'FAIL immutable weather refresh rows'; end if;
 if not exists(select 1 from public.weather_snapshots where id=(weather->>'id')::uuid and payload->>'temperature_c'='20')
 then raise exception 'FAIL prior weather row changed'; end if;
 begin update public.weather_snapshots set fetched_at=now(); raise exception 'FAIL direct weather mutation allowed';
  exception when insufficient_privilege then null; end;
 request_one:=(select response_body->>'request_id' from public.idempotency_keys where user_id='74000000-0000-4000-8000-000000000001' and scope='recommendation_create' and key='recommend-one')::uuid;
 request_two:=(select response_body->>'request_id' from public.idempotency_keys where user_id='74000000-0000-4000-8000-000000000001' and scope='recommendation_create' and key='recommend-two')::uuid;
 request_bad:=(select response_body->>'request_id' from public.idempotency_keys where user_id='74000000-0000-4000-8000-000000000001' and scope='recommendation_create' and key='recommend-invalid')::uuid;
 request_other:=(select response_body->>'request_id' from public.idempotency_keys where user_id='74000000-0000-4000-8000-000000000002' and scope='recommendation_create' and key='recommend-other')::uuid;
 request_dupe:=(select response_body->>'request_id' from public.idempotency_keys where user_id='74000000-0000-4000-8000-000000000001' and scope='recommendation_create' and key='recommend-dupe')::uuid;
 outfit_a:=jsonb_build_array(jsonb_build_object('rank',1,'scores',jsonb_build_object('weather',0.8,'tpo',null,'aesthetic',0.5,'harmony',0.7),
  'reason_facts',jsonb_build_array('mild weather'),'explanation','fixture','explanation_source','template',
  'items',jsonb_build_array(jsonb_build_object('garment_id','74500000-0000-4000-8000-000000000001','slot','top'))));
 outfit_b:=jsonb_build_array(jsonb_build_object('rank',1,'scores',jsonb_build_object('weather',0.8,'tpo',null,'aesthetic',0.5,'harmony',0.7),
  'reason_facts',jsonb_build_array('mild weather'),'explanation','fixture','explanation_source','template',
  'items',jsonb_build_array(jsonb_build_object('garment_id','74500000-0000-4000-8000-000000000003','slot','top'))));
 begin perform public.store_recommendation(request_one,current_setting('test.initial_token_one')::uuid,(weather->>'id')::uuid,false,'[]',outfit_a);
  raise exception 'FAIL stale reservation token accepted'; exception when raise_exception then if sqlerrm<>'stale_recommendation_reservation' then raise; end if; end;
 result:=public.store_recommendation(request_one,current_setting('test.token_one')::uuid,(weather->>'id')::uuid,false,'[]',outfit_a);
 if result->>'status'<>'ready' or public.store_recommendation(request_one,current_setting('test.token_one')::uuid,(weather->>'id')::uuid,false,'[]',outfit_a)->>'replayed'<>'true'
 then raise exception 'FAIL recommendation finalize replay'; end if;
 begin perform public.store_recommendation(request_one,current_setting('test.token_one')::uuid,(weather->>'id')::uuid,true,'[]',outfit_a);
  raise exception 'FAIL recommendation result conflict'; exception when raise_exception then
  if sqlerrm<>'recommendation_result_conflict' then raise; end if; end;
 perform public.store_recommendation(request_two,current_setting('test.token_two')::uuid,(weather->>'id')::uuid,false,'[]',outfit_a);
 perform public.store_recommendation(request_other,current_setting('test.token_other')::uuid,(weather->>'id')::uuid,false,'[]',outfit_b);
 perform set_config('test.other_recommendation',request_other::text,true);
 perform set_config('test.other_outfit',(select id::text from public.outfit_recommendations where request_id=request_other),true);
 update public.garments set deleted_at=now() where id='74500000-0000-4000-8000-000000000002';
 begin perform public.store_recommendation(request_bad,current_setting('test.token_bad')::uuid,(weather->>'id')::uuid,true,'[]',outfit_a);
  raise exception 'FAIL fresh weather marked stale'; exception when raise_exception then if sqlerrm<>'weather_snapshot_not_eligible' then raise; end if; end;
 begin perform public.store_recommendation(request_bad,current_setting('test.token_bad')::uuid,(weather->>'id')::uuid,false,'[]',
  jsonb_set(outfit_a,'{0,items,0,garment_id}','"74500000-0000-4000-8000-000000000002"'));
  raise exception 'FAIL deleted garment stored'; exception when raise_exception then if sqlerrm<>'garment_unavailable' then raise; end if; end;
 duplicate_outfits:=outfit_a||(jsonb_set(outfit_a->0,'{rank}','2'));
 begin perform public.store_recommendation(request_dupe,current_setting('test.token_dupe')::uuid,(weather->>'id')::uuid,false,'[]',duplicate_outfits);
  raise exception 'FAIL duplicate canonical outfit set'; exception when invalid_parameter_value then
  if sqlerrm<>'duplicate_outfit_garment_set' then raise; end if; end;
end $$;
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub','74000000-0000-4000-8000-000000000001',true);
do $$ declare recommendation_one uuid; recommendation_two uuid; recommendation_other uuid; outfit_one uuid; outfit_two uuid; accepted jsonb; begin
 recommendation_one:=(select id from public.recommendation_requests where user_id=auth.uid() and status='ready' order by created_at,id limit 1);
 recommendation_two:=(select id from public.recommendation_requests where user_id=auth.uid() and status='ready' and id<>recommendation_one limit 1);
 recommendation_other:=current_setting('test.other_recommendation')::uuid;
 outfit_one:=(select id from public.outfit_recommendations where request_id=recommendation_one);
 outfit_two:=(select id from public.outfit_recommendations where request_id=recommendation_two);
 begin perform public.accept_my_recommendation(recommendation_other,current_setting('test.other_outfit')::uuid,current_date,'accept-cross');
  raise exception 'FAIL cross owner accept'; exception when no_data_found then null; end;
 accepted:=public.accept_my_recommendation(recommendation_one,outfit_one,current_date,'accept-one');
 perform set_config('test.accepted_recommendation',recommendation_one::text,true);
 perform set_config('test.accepted_outfit',outfit_one::text,true);
 perform set_config('test.accepted_ootd',accepted->>'ootd_id',true);
 if accepted->>'replayed'<>'false' or public.accept_my_recommendation(recommendation_one,outfit_one,current_date,'accept-one')->>'replayed'<>'true'
 then raise exception 'FAIL accept replay'; end if;
 if public.accept_my_recommendation(recommendation_one,outfit_one,current_date,'accept-one-again')->>'ootd_id'<>accepted->>'ootd_id'
 then raise exception 'FAIL same outfit different key replay'; end if;
 begin perform public.accept_my_recommendation(recommendation_two,outfit_two,current_date,'accept-one');
  raise exception 'FAIL accept idempotency conflict'; exception when raise_exception then if sqlerrm<>'idempotency_conflict' then raise; end if; end;
 begin perform public.accept_my_recommendation(recommendation_two,outfit_two,current_date,'accept-two');
  raise exception 'FAIL OOTD date conflict'; exception when raise_exception then if sqlerrm<>'ootd_date_conflict' then raise; end if; end;
end $$;
reset role;
update public.recommendation_requests set expires_at=now()-interval '1 second'
 where id=current_setting('test.accepted_recommendation')::uuid;
update public.garments set deleted_at=now() where id='74500000-0000-4000-8000-000000000001';
set local role authenticated;
select set_config('request.jwt.claim.sub','74000000-0000-4000-8000-000000000001',true);
do $$ declare replay jsonb; begin
 replay:=public.accept_my_recommendation(current_setting('test.accepted_recommendation')::uuid,
  current_setting('test.accepted_outfit')::uuid,current_date,'accept-after-expiry');
 if replay->>'ootd_id'<>current_setting('test.accepted_ootd') then raise exception 'FAIL existing day replay ordering'; end if;
end $$;
reset role;
update public.garments set deleted_at=now() where id='74500000-0000-4000-8000-000000000003';
set local role authenticated;
select set_config('request.jwt.claim.sub','74000000-0000-4000-8000-000000000002',true);
do $$ begin
 begin perform public.accept_my_recommendation(current_setting('test.other_recommendation')::uuid,
  current_setting('test.other_outfit')::uuid,current_date,'accept-inactive');
  raise exception 'FAIL inactive garment accepted'; exception when raise_exception then
  if sqlerrm<>'outfit_items_unavailable' then raise; end if; end;
end $$;
reset role;
do $$ begin
 if not exists(select 1 from public.ootd_entries where user_id='74000000-0000-4000-8000-000000000001'
  and worn_on=current_date and wear_status='worn' and visibility='private' and saved_outfit_id is null
  and weather_snapshot_id is not null and item_snapshot->0->>'unavailable'='false')
 then raise exception 'FAIL accepted OOTD shape'; end if;
 if not exists(select 1 from public.recommendation_requests where weather_was_stale=false and preference_snapshot='[]')
 then raise exception 'FAIL recommendation finalized state'; end if;
end $$;
rollback;
