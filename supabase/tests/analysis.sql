-- Run only against a disposable migrated database. Every fixture rolls back.
begin;
insert into auth.users(id) values
 ('73000000-0000-4000-8000-000000000001'),
 ('73000000-0000-4000-8000-000000000002');
insert into public.garment_batches(id,user_id,status) values
 ('73100000-0000-4000-8000-000000000001','73000000-0000-4000-8000-000000000001','uploaded'),
 ('73100000-0000-4000-8000-000000000002','73000000-0000-4000-8000-000000000002','uploaded'),
 ('73100000-0000-4000-8000-000000000003','73000000-0000-4000-8000-000000000001','failed');
insert into public.garment_assets(id,user_id,batch_id,kind,object_key,content_type,byte_size,verified_at) values
 ('73200000-0000-4000-8000-000000000001','73000000-0000-4000-8000-000000000001','73100000-0000-4000-8000-000000000001','source','73000000-0000-4000-8000-000000000001/73100000-0000-4000-8000-000000000001/source.jpg','image/jpeg',100,now()),
 ('73200000-0000-4000-8000-000000000002','73000000-0000-4000-8000-000000000002','73100000-0000-4000-8000-000000000002','source','73000000-0000-4000-8000-000000000002/73100000-0000-4000-8000-000000000002/source.jpg','image/jpeg',100,now());
insert into public.analysis_jobs(id,user_id,batch_id,status,attempt,max_attempts,error_code) values
 ('73300000-0000-4000-8000-000000000003','73000000-0000-4000-8000-000000000001','73100000-0000-4000-8000-000000000003','failed',1,3,'WORKER_TIMEOUT');
insert into storage.objects(id,bucket_id,name,owner_id,metadata) values
 ('73400000-0000-4000-8000-000000000001','closet-private','73000000-0000-4000-8000-000000000001/73100000-0000-4000-8000-000000000001/cutouts/item-0.png','73000000-0000-4000-8000-000000000001','{"mimetype":"image/png","size":"321"}');

set local role authenticated;
select set_config('request.jwt.claim.sub','73000000-0000-4000-8000-000000000001',true);
do $$ declare created jsonb; replay jsonb; retried jsonb; begin
 begin perform 1 from public.garment_drafts; raise exception 'FAIL raw draft table readable';
 exception when insufficient_privilege then null; end;
 begin perform public.apply_analysis_result(gen_random_uuid(),gen_random_uuid(),1,gen_random_uuid(),repeat('a',64),'failed','{"model":"v1"}','[]','[{"code":"X"}]');
  raise exception 'FAIL callback RPC exposed to user'; exception when insufficient_privilege then null; end;
 begin perform public.inspect_analysis_callback(gen_random_uuid(),gen_random_uuid(),1,repeat('a',64));
  raise exception 'FAIL callback preflight exposed to user'; exception when insufficient_privilege then null; end;
 begin perform public.get_analysis_cutout_fence(gen_random_uuid(),'not-owned');
  raise exception 'FAIL cutout fence exposed to user'; exception when insufficient_privilege then null; end;
 begin update storage.objects set metadata='{}'; raise exception 'FAIL storage update exposed';
  exception when insufficient_privilege then null; end;
 begin delete from storage.objects; raise exception 'FAIL storage delete exposed';
  exception when insufficient_privilege then null; end;
 created:=public.create_my_analysis_job('73100000-0000-4000-8000-000000000001','create-job-one');
 replay:=public.create_my_analysis_job('73100000-0000-4000-8000-000000000001','create-job-one');
 if created<>replay or created->>'status'<>'queued' then raise exception 'FAIL create replay'; end if;
 begin perform public.create_my_analysis_job('73100000-0000-4000-8000-000000000002','create-job-two');
  raise exception 'FAIL cross owner batch'; exception when no_data_found then null; end;
 retried:=public.retry_my_analysis_job('73300000-0000-4000-8000-000000000003','retry-job-one');
 if retried->>'status'<>'queued' or (retried->>'attempt')::integer<>1 then raise exception 'FAIL retry state'; end if;
 if public.retry_my_analysis_job('73300000-0000-4000-8000-000000000003','retry-job-one')<>retried then raise exception 'FAIL retry replay'; end if;
end $$;
reset role;
update public.analysis_jobs set available_at=now()+interval '1 day'
 where id='73300000-0000-4000-8000-000000000003';

set local role service_role;
do $$ declare j public.analysis_jobs; accepted jsonb; replay jsonb; items jsonb; preflight jsonb; fence jsonb; begin
 select * into j from public.claim_analysis_job(120);
 if j.batch_id<>'73100000-0000-4000-8000-000000000001' then raise exception 'FAIL unexpected claimed job'; end if;
 preflight:=public.inspect_analysis_callback('73500000-0000-4000-8000-000000000001',j.id,j.attempt,repeat('a',64));
 if preflight->>'replayed'<>'false' or preflight#>>'{job,batch_id}'<>j.batch_id::text then raise exception 'FAIL callback preflight'; end if;
 fence:=public.get_analysis_cutout_fence(j.id,'73000000-0000-4000-8000-000000000001/73100000-0000-4000-8000-000000000001/cutouts/item-0.png');
 items:=jsonb_build_array(jsonb_build_object(
  'item_index',0,'client_item_key','item-0','mask_object_key','73000000-0000-4000-8000-000000000001/73100000-0000-4000-8000-000000000001/cutouts/item-0.png',
  'content_type','image/png','byte_size',321,'storage_object_id',fence->>'object_id','storage_updated_at',fence->>'object_updated_at',
  'bbox',jsonb_build_array(0.1,0.1,0.9,0.9),'confidence',0.87,
  'attributes',jsonb_build_object('category','top','subcategory','shirt','note','model note','hidden_model_fact','must-not-leak')));
 begin perform public.apply_analysis_result('73500000-0000-4000-8000-000000000001',j.id,j.attempt,gen_random_uuid(),repeat('a',64),'succeeded','{"attributes":"v1"}',items,'[]');
  raise exception 'FAIL stale callback accepted'; exception when raise_exception then if sqlerrm<>'stale_lease' then raise; end if; end;
 begin perform public.apply_analysis_result('73500000-0000-4000-8000-000000000001',j.id,j.attempt,j.lease_token,repeat('a',64),'succeeded','{"attributes":"v1"}',
  jsonb_set(items,'{0,storage_object_id}','"73400000-0000-4000-8000-000000000099"'),'[]');
  raise exception 'FAIL changed storage object accepted'; exception when raise_exception then if sqlerrm<>'cutout_asset_not_verified' then raise; end if; end;
 accepted:=public.apply_analysis_result('73500000-0000-4000-8000-000000000001',j.id,j.attempt,j.lease_token,repeat('a',64),'succeeded','{"attributes":"v1"}',items,'[]');
 replay:=public.apply_analysis_result('73500000-0000-4000-8000-000000000001',j.id,j.attempt,j.lease_token,repeat('a',64),'succeeded','{"attributes":"v1"}',items,'[]');
 if accepted->>'applied'<>'true' or replay->>'applied'<>'false' then raise exception 'FAIL callback replay'; end if;
 if not exists(select 1 from public.idempotency_keys where scope='analysis_callback'
   and key='73500000-0000-4000-8000-000000000001' and response_status=200)
 then raise exception 'FAIL durable callback event'; end if;
 preflight:=public.inspect_analysis_callback('73500000-0000-4000-8000-000000000001',j.id,j.attempt,repeat('a',64));
 if preflight->>'replayed'<>'true' or preflight#>>'{response,applied}'<>'true' then raise exception 'FAIL durable preflight replay'; end if;
 begin perform public.inspect_analysis_callback('73500000-0000-4000-8000-000000000001',j.id,j.attempt,repeat('b',64));
  raise exception 'FAIL preflight payload conflict'; exception when raise_exception then if sqlerrm<>'callback_conflict' then raise; end if; end;
 begin perform public.apply_analysis_result('73500000-0000-4000-8000-000000000001',j.id,j.attempt,j.lease_token,repeat('b',64),'succeeded','{"attributes":"v1"}',items,'[]');
  raise exception 'FAIL callback payload conflict'; exception when raise_exception then if sqlerrm<>'callback_conflict' then raise; end if; end;
end $$;
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub','73000000-0000-4000-8000-000000000001',true);
do $$ declare listed jsonb; draft_id uuid; patched jsonb; versions jsonb; confirmed jsonb; begin
 listed:=public.list_my_garment_drafts('73100000-0000-4000-8000-000000000001');
 if jsonb_array_length(listed->'items')<>1 or listed::text like '%hidden_model_fact%' or listed::text like '%must-not-leak%'
 then raise exception 'FAIL safe draft projection'; end if;
 draft_id:=(listed->'items'->0->>'id')::uuid;
 patched:=public.update_my_garment_draft(draft_id,1,false,null,true,'tee',true,null);
 if patched->>'version'<>'2' or patched#>>'{current_attributes,subcategory}'<>'tee' or patched::text like '%hidden_model_fact%'
 then raise exception 'FAIL safe draft patch'; end if;
 begin perform public.update_my_garment_draft(draft_id,1,true,'bottom',false,null,false,null);
  raise exception 'FAIL stale draft version'; exception when raise_exception then if sqlerrm<>'version_conflict' then raise; end if; end;
 versions:=jsonb_build_object(draft_id::text,2);
 confirmed:=public.confirm_my_garment_batch('73100000-0000-4000-8000-000000000001',array[draft_id],versions,'confirm-one');
 if jsonb_array_length(confirmed->'garment_ids')<>1 then raise exception 'FAIL confirm result'; end if;
 if public.confirm_my_garment_batch('73100000-0000-4000-8000-000000000001',array[draft_id],versions,'confirm-one')<>confirmed
 then raise exception 'FAIL confirm replay'; end if;
 begin perform public.confirm_garment_batch('73100000-0000-4000-8000-000000000001',array[draft_id],versions);
  raise exception 'FAIL legacy raw confirm exposed'; exception when insufficient_privilege then null; end;
end $$;
reset role;
do $$ begin
 if not exists(select 1 from public.garments where user_id='73000000-0000-4000-8000-000000000001' and category='top'
  and attributes->>'subcategory'='tee' and memo is null) then raise exception 'FAIL confirmed garment mapping'; end if;
 if not exists(select 1 from public.garment_batches where id='73100000-0000-4000-8000-000000000001' and status='confirmed')
 then raise exception 'FAIL confirmed batch status'; end if;
end $$;
rollback;
