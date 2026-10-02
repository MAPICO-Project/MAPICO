-- Run only against a disposable migrated database. Every fixture rolls back.
begin;
insert into auth.users(id) values
 ('72000000-0000-4000-8000-000000000001'),
 ('72000000-0000-4000-8000-000000000002');
insert into public.garment_batches(id,user_id,status) values
 ('72100000-0000-4000-8000-000000000001','72000000-0000-4000-8000-000000000001','review'),
 ('72100000-0000-4000-8000-000000000002','72000000-0000-4000-8000-000000000002','review');
insert into public.garment_assets(id,user_id,batch_id,kind,object_key,content_type,byte_size,verified_at) values
 ('72200000-0000-4000-8000-000000000001','72000000-0000-4000-8000-000000000001','72100000-0000-4000-8000-000000000001','source','72000000-0000-4000-8000-000000000001/source.jpg','image/jpeg',10,now()),
 ('72200000-0000-4000-8000-000000000002','72000000-0000-4000-8000-000000000001','72100000-0000-4000-8000-000000000001','cutout','72000000-0000-4000-8000-000000000001/cutout-1.png','image/png',10,now()),
 ('72200000-0000-4000-8000-000000000003','72000000-0000-4000-8000-000000000001','72100000-0000-4000-8000-000000000001','cutout','72000000-0000-4000-8000-000000000001/cutout-2.png','image/png',10,now()),
 ('72200000-0000-4000-8000-000000000004','72000000-0000-4000-8000-000000000002','72100000-0000-4000-8000-000000000002','cutout','72000000-0000-4000-8000-000000000002/cutout.png','image/png',10,now());
insert into public.analysis_jobs(id,user_id,batch_id,status) values
 ('72300000-0000-4000-8000-000000000001','72000000-0000-4000-8000-000000000001','72100000-0000-4000-8000-000000000001','succeeded'),
 ('72300000-0000-4000-8000-000000000002','72000000-0000-4000-8000-000000000002','72100000-0000-4000-8000-000000000002','succeeded');
insert into public.garment_drafts(id,user_id,batch_id,job_id,item_index,asset_id,status,raw_prediction,model_version) values
 ('72400000-0000-4000-8000-000000000001','72000000-0000-4000-8000-000000000001','72100000-0000-4000-8000-000000000001','72300000-0000-4000-8000-000000000001',0,'72200000-0000-4000-8000-000000000002','confirmed','{}','fixture'),
 ('72400000-0000-4000-8000-000000000002','72000000-0000-4000-8000-000000000001','72100000-0000-4000-8000-000000000001','72300000-0000-4000-8000-000000000001',1,'72200000-0000-4000-8000-000000000003','confirmed','{}','fixture'),
 ('72400000-0000-4000-8000-000000000003','72000000-0000-4000-8000-000000000002','72100000-0000-4000-8000-000000000002','72300000-0000-4000-8000-000000000002',0,'72200000-0000-4000-8000-000000000004','confirmed','{}','fixture');
insert into public.garments(id,user_id,source_draft_id,asset_id,category,attributes,memo) values
 ('72500000-0000-4000-8000-000000000001','72000000-0000-4000-8000-000000000001','72400000-0000-4000-8000-000000000001','72200000-0000-4000-8000-000000000002','top','{"category":"top"}','first'),
 ('72500000-0000-4000-8000-000000000002','72000000-0000-4000-8000-000000000001','72400000-0000-4000-8000-000000000002','72200000-0000-4000-8000-000000000003','bottom','{"category":"bottom"}','second'),
 ('72500000-0000-4000-8000-000000000003','72000000-0000-4000-8000-000000000002','72400000-0000-4000-8000-000000000003','72200000-0000-4000-8000-000000000004','top','{"category":"top"}','other');

set local role authenticated;
select set_config('request.jwt.claim.sub','72000000-0000-4000-8000-000000000001',true);
do $$ begin
 begin update public.garments set memo='direct'; raise exception 'FAIL direct garment write';
 exception when insufficient_privilege then null; end;
 begin perform public.update_my_garment('72500000-0000-4000-8000-000000000003',1,true,'bag',false,null,false,null);
  raise exception 'FAIL cross owner update'; exception when no_data_found then null; end;
 perform public.update_my_garment('72500000-0000-4000-8000-000000000001',1,true,'bag',true,'tote',true,null);
 if not exists(select 1 from public.garments where id='72500000-0000-4000-8000-000000000001'
   and category='bag' and attributes->>'category'='bag' and attributes->>'subcategory'='tote' and memo is null and version=2)
 then raise exception 'FAIL garment patch'; end if;
 begin perform public.update_my_garment('72500000-0000-4000-8000-000000000001',1,false,null,false,null,true,'stale');
  raise exception 'FAIL stale version'; exception when raise_exception then
  if sqlerrm<>'version_conflict' then raise; end if; end;

 perform public.delete_my_garment('72500000-0000-4000-8000-000000000001','delete-key-one');
 perform public.delete_my_garment('72500000-0000-4000-8000-000000000001','delete-key-one');
 if exists(select 1 from public.garments where id='72500000-0000-4000-8000-000000000001')
 then raise exception 'FAIL deleted garment still visible'; end if;
end $$;
reset role;
do $$ begin
 if not exists(select 1 from public.garments where id='72500000-0000-4000-8000-000000000001' and deleted_at is not null)
 then raise exception 'FAIL garment soft delete'; end if;
 if not exists(select 1 from public.garment_assets where id='72200000-0000-4000-8000-000000000002' and deleted_at is not null)
 then raise exception 'FAIL cutout cleanup marker'; end if;
 if exists(select 1 from public.garment_assets where id='72200000-0000-4000-8000-000000000001' and deleted_at is not null)
 then raise exception 'FAIL source deleted while batch garment active'; end if;
end $$;
set local role authenticated;
select set_config('request.jwt.claim.sub','72000000-0000-4000-8000-000000000001',true);
do $$ begin
 begin perform public.delete_my_garment('72500000-0000-4000-8000-000000000002','delete-key-one');
  raise exception 'FAIL idempotency conflict'; exception when raise_exception then
  if sqlerrm<>'idempotency_conflict' then raise; end if; end;
 perform public.delete_my_garment('72500000-0000-4000-8000-000000000002','delete-key-two');
end $$;
reset role;
do $$ begin
 if exists(select 1 from public.garment_assets where batch_id='72100000-0000-4000-8000-000000000001' and deleted_at is null)
 then raise exception 'FAIL orphan batch assets not marked'; end if;
 if (select response_status from public.idempotency_keys where scope='deleteGarment' and key='delete-key-two')<>202
 then raise exception 'FAIL delete replay not stored'; end if;
end $$;
rollback;
