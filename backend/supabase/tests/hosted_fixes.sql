-- 2026-10-11 hosted fixes (202610110001). Run only against a disposable migrated database; rolls back.
-- storage.objects.owner_id is TEXT here as on hosted; worker (secret-key) cutout uploads have owner_id NULL.
begin;
insert into auth.users(id) values ('7c000000-0000-4000-8000-000000000001'),('7c000000-0000-4000-8000-000000000002');
insert into public.garment_batches(id,user_id,status) values
 ('7c100000-0000-4000-8000-000000000001','7c000000-0000-4000-8000-000000000001','processing');
insert into public.garment_assets(id,user_id,batch_id,kind,object_key,content_type,byte_size,verified_at) values
 ('7c200000-0000-4000-8000-000000000001','7c000000-0000-4000-8000-000000000001','7c100000-0000-4000-8000-000000000001','source','7c000000-0000-4000-8000-000000000001/7c100000-0000-4000-8000-000000000001/source.jpg','image/jpeg',100,now());
insert into public.analysis_jobs(id,user_id,batch_id,status) values
 ('7c300000-0000-4000-8000-000000000001','7c000000-0000-4000-8000-000000000001','7c100000-0000-4000-8000-000000000001','queued');
insert into storage.objects(id,bucket_id,name,owner_id,metadata) values
 ('7c400000-0000-4000-8000-000000000001','closet-private','7c000000-0000-4000-8000-000000000001/7c100000-0000-4000-8000-000000000001/cutouts/item-0.png',null,'{"mimetype":"image/png","size":"321"}'),
 ('7c400000-0000-4000-8000-000000000002','closet-private','7c000000-0000-4000-8000-000000000001/7c100000-0000-4000-8000-000000000001/cutouts/item-1.png','7c000000-0000-4000-8000-000000000002','{"mimetype":"image/png","size":"321"}'),
 ('7c400000-0000-4000-8000-000000000003','closet-private','7c000000-0000-4000-8000-000000000001/7c100000-0000-4000-8000-000000000001/cutouts/item-2.png','7c000000-0000-4000-8000-000000000001','{"mimetype":"image/png","size":"321"}');

do $$ begin
 if (select data_type from information_schema.columns where table_schema='storage' and table_name='objects' and column_name='owner_id')<>'text'
 then raise exception 'FAIL stub storage.objects.owner_id must be text like hosted'; end if;
end $$;

set local role service_role;
do $$ declare j public.analysis_jobs; fence jsonb; items jsonb; aesthetic uuid; begin
 select * into j from public.claim_analysis_job(120);
 if j.id<>'7c300000-0000-4000-8000-000000000001' then raise exception 'FAIL unexpected claimed job'; end if;
 -- NULL owner (worker upload) under the job's cutouts/ prefix passes; the job user as owner passes; another owner fails.
 perform public.get_analysis_cutout_fence(j.id,'7c000000-0000-4000-8000-000000000001/7c100000-0000-4000-8000-000000000001/cutouts/item-2.png');
 begin perform public.get_analysis_cutout_fence(j.id,'7c000000-0000-4000-8000-000000000001/7c100000-0000-4000-8000-000000000001/cutouts/item-1.png');
  raise exception 'FAIL foreign owner cutout fenced'; exception when raise_exception then if sqlerrm<>'cutout_asset_not_verified' then raise; end if; end;
 begin perform public.get_analysis_cutout_fence(j.id,'7c000000-0000-4000-8000-000000000002/7c100000-0000-4000-8000-000000000001/cutouts/item-0.png');
  raise exception 'FAIL foreign prefix fenced'; exception when invalid_parameter_value then if sqlerrm<>'invalid_cutout_path' then raise; end if; end;
 fence:=public.get_analysis_cutout_fence(j.id,'7c000000-0000-4000-8000-000000000001/7c100000-0000-4000-8000-000000000001/cutouts/item-0.png');
 select id into aesthetic from public.aesthetics order by code limit 1;
 items:=jsonb_build_array(jsonb_build_object(
  'item_index',0,'client_item_key','item-0','mask_object_key','7c000000-0000-4000-8000-000000000001/7c100000-0000-4000-8000-000000000001/cutouts/item-0.png',
  'content_type','image/png','byte_size',321,'storage_object_id',fence->>'object_id','storage_updated_at',fence->>'object_updated_at',
  'bbox',jsonb_build_array(0.1,0.1,0.9,0.9),'confidence',0.8,
  'attributes',jsonb_build_object('category','top','aesthetic_scores',jsonb_build_array(
    jsonb_build_object('aesthetic_id',aesthetic,'score',0.8),
    jsonb_build_object('aesthetic_id','7cffffff-0000-4000-8000-000000000001','score',0.5)))));
 perform public.apply_analysis_result('7c500000-0000-4000-8000-000000000001',j.id,j.attempt,j.lease_token,repeat('d',64),'succeeded','{"attributes":"v1"}',items,'[]');
end $$;
reset role;

-- N3: storage insert policies ignore metadata (hosted checks them without it); path + pending row still required.
do $$ begin
 if exists(select 1 from pg_proc where proname in ('g9_can_upload_media','g7_can_upload_feed_media'))
 then raise exception 'FAIL metadata-based upload predicates still present'; end if;
 if not exists(select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='user_media_upload')
 or not exists(select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='feed_media_upload')
 then raise exception 'FAIL upload policies missing'; end if;
end $$;

set local role authenticated;
select set_config('request.jwt.claim.sub','7c000000-0000-4000-8000-000000000001',true);
do $$ declare listed jsonb; draft_id uuid; confirmed jsonb; begin
 -- #5: columns read by the API with the user JWT.
 perform max_attempts,updated_at from public.analysis_jobs;
 perform deleted_at from public.feed_posts;
 listed:=public.list_my_garment_drafts('7c100000-0000-4000-8000-000000000001');
 draft_id:=(listed#>>'{items,0,id}')::uuid;
 confirmed:=public.confirm_my_garment_batch('7c100000-0000-4000-8000-000000000001',array[draft_id],jsonb_build_object(draft_id::text,1),'hosted-confirm');
 -- N4: the known aesthetic score is stored; the unknown aesthetic id is skipped.
 if (select count(*) from public.garment_aesthetic_scores where garment_id=(confirmed#>>'{garment_ids,0}')::uuid)<>1
 or not exists(select 1 from public.garment_aesthetic_scores where garment_id=(confirmed#>>'{garment_ids,0}')::uuid and score=0.8 and model_version='v1')
 then raise exception 'FAIL aesthetic scores not carried to garment_aesthetic_scores'; end if;
end $$;
reset role;

-- #8: OOTD weather summary only for snapshots the caller's own OOTD references; no grid coordinates.
insert into public.weather_snapshots(id,grid_x,grid_y,issued_at,valid_at,source,payload) values
 ('7c600000-0000-4000-8000-000000000001',62,89,now()-interval '1 hour',date_trunc('hour',now()),'kma_short_term',
  '{"temperature_c":4.2,"feels_like_c":1.0,"precipitation_probability":60,"precipitation_type":"snow","humidity":70,"air_quality":null}'),
 ('7c600000-0000-4000-8000-000000000002',62,89,now()-interval '2 hour',date_trunc('hour',now())-interval '1 hour','kma_short_term',
  '{"temperature_c":9,"feels_like_c":null,"precipitation_probability":null,"precipitation_type":"none","humidity":null,"air_quality":null}');
insert into public.ootd_entries(id,user_id,worn_on,visibility,item_snapshot,wear_status,weather_snapshot_id) values
 ('7c700000-0000-4000-8000-000000000001','7c000000-0000-4000-8000-000000000001',current_date-1,'private',
  '[{"garment_id":"7c800000-0000-4000-8000-000000000001","category":"top","unavailable":false}]','worn','7c600000-0000-4000-8000-000000000001');
set local role authenticated;
select set_config('request.jwt.claim.sub','7c000000-0000-4000-8000-000000000001',true);
do $$ declare result jsonb; begin
 result:=public.get_my_ootd_weather(array['7c600000-0000-4000-8000-000000000001','7c600000-0000-4000-8000-000000000002']::uuid[]);
 if jsonb_array_length(result)<>1 or result#>>'{0,weather_snapshot_id}'<>'7c600000-0000-4000-8000-000000000001'
 or (result#>>'{0,temperature_c}')::numeric<>4.2 or result#>>'{0,precipitation_type}'<>'snow' or result->0?'grid_x'
 then raise exception 'FAIL ootd weather summary %',result; end if;
 begin perform id from public.weather_snapshots; raise exception 'FAIL raw weather snapshots exposed';
  exception when insufficient_privilege then null; end;
end $$;
select set_config('request.jwt.claim.sub','7c000000-0000-4000-8000-000000000002',true);
do $$ begin
 if jsonb_array_length(public.get_my_ootd_weather(array['7c600000-0000-4000-8000-000000000001']::uuid[]))<>0
 then raise exception 'FAIL other user read OOTD weather'; end if;
end $$;
reset role;
rollback;
