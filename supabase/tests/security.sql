-- Run only against a disposable migrated database. Every fixture rolls back.
begin;
insert into auth.users(id) values('00000000-0000-0000-0000-000000000001'),('00000000-0000-0000-0000-000000000002');
insert into public.garment_batches(id,user_id,status) values
 ('10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','processing'),
 ('10000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000002','uploaded');
insert into public.garment_assets(id,user_id,batch_id,kind,object_key,content_type,byte_size,verified_at) values
 ('20000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','cutout','00000000-0000-0000-0000-000000000001/test.png','image/png',100,now());
insert into public.analysis_jobs(id,user_id,batch_id) values
 ('30000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001');

do $$ declare j public.analysis_jobs; payload jsonb; begin
 begin
  insert into public.analysis_jobs(user_id,batch_id) values('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000002');
  raise exception 'FAIL cross-owner FK permitted';
 exception when foreign_key_violation then null; end;
 begin perform public.claim_analysis_job(null); raise exception 'FAIL null lease accepted';
 exception when raise_exception then if sqlerrm<>'invalid_lease' then raise; end if; end;
 select * into j from public.claim_analysis_job(120);
 if j.attempt<>1 or j.lease_token is null then raise exception 'FAIL claim'; end if;
 payload:=jsonb_build_array(jsonb_build_object('item_index',0,'asset_id','20000000-0000-0000-0000-000000000001','raw_prediction',jsonb_build_object('category','top','color_hex','#112233'),'model_version','test-v1'));
 begin perform public.finish_analysis_job(j.id,null,j.lease_token,'succeeded',payload); raise exception 'FAIL null attempt accepted';
 exception when raise_exception then if sqlerrm<>'invalid_lease' then raise; end if; end;
 begin perform public.finish_analysis_job(j.id,j.attempt,gen_random_uuid(),'succeeded',payload); raise exception 'FAIL wrong fence accepted';
 exception when raise_exception then if sqlerrm<>'stale_lease' then raise; end if; end;
 perform public.finish_analysis_job(j.id,j.attempt,j.lease_token,'succeeded',payload);
 perform public.finish_analysis_job(j.id,j.attempt,j.lease_token,'succeeded',payload);
 if (select count(*) from public.garment_drafts)<>1 then raise exception 'FAIL duplicate callback'; end if;
end $$;

set local role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000002',true);
do $$ begin
 if (select count(*) from public.garment_drafts)<>0 then raise exception 'FAIL tenant read leak'; end if;
 begin update public.analysis_jobs set status='succeeded'; raise exception 'FAIL client job write';
 exception when insufficient_privilege then null; end;
 begin perform lease_token from public.analysis_jobs; raise exception 'FAIL lease read leak';
 exception when insufficient_privilege then null; end;
end $$;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-000000000001',true);
do $$ declare d public.garment_drafts; n integer; begin
 select * into d from public.garment_drafts limit 1;
 begin perform public.confirm_garment_batch(d.batch_id,array[d.id],jsonb_build_object(d.id::text,99)); raise exception 'FAIL stale version accepted';
 exception when raise_exception then if sqlerrm<>'version_conflict' then raise; end if; end;
 select count(*) into n from public.confirm_garment_batch(d.batch_id,array[d.id],jsonb_build_object(d.id::text,d.version));
 if n<>1 then raise exception 'FAIL confirm'; end if;
 perform public.confirm_garment_batch(d.batch_id,array[d.id],jsonb_build_object(d.id::text,d.version));
 if (select count(*) from public.garments)<>1 then raise exception 'FAIL duplicate garment'; end if;
end $$;
reset role;
insert into public.recommendation_requests(id,user_id,target_date,status,engine_version) values
 ('40000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001',current_date,'ready','test-v1');
insert into public.outfit_recommendations(id,user_id,request_id,rank,scores) values
 ('50000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001',1,'{}');
insert into public.outfit_items(user_id,outfit_id,garment_id,slot)
 select user_id,'50000000-0000-0000-0000-000000000001',id,'top' from public.garments;
set local role authenticated;
do $$ declare o public.ootd_entries; begin
 o:=public.accept_outfit('50000000-0000-0000-0000-000000000001',current_date);
 perform public.accept_outfit('50000000-0000-0000-0000-000000000001',current_date);
 if (select count(*) from public.ootd_entries)<>1 or jsonb_array_length(o.item_snapshot)<>1 then raise exception 'FAIL accept atomic snapshot'; end if;
end $$;
reset role;
rollback;
