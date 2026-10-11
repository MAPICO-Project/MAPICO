-- 2026-10-09 six garment categories. Run only against a disposable migrated database; rolls back.
begin;
insert into auth.users(id) values ('7b000000-0000-4000-8000-000000000001');
insert into public.garment_batches(id,user_id,status) values
 ('7b100000-0000-4000-8000-000000000001','7b000000-0000-4000-8000-000000000001','processing');
insert into public.garment_assets(id,user_id,batch_id,kind,object_key,content_type,byte_size,verified_at) values
 ('7b200000-0000-4000-8000-000000000001','7b000000-0000-4000-8000-000000000001','7b100000-0000-4000-8000-000000000001','source','7b000000-0000-4000-8000-000000000001/7b100000-0000-4000-8000-000000000001/source.jpg','image/jpeg',100,now());
insert into public.analysis_jobs(id,user_id,batch_id,status) values
 ('7b300000-0000-4000-8000-000000000001','7b000000-0000-4000-8000-000000000001','7b100000-0000-4000-8000-000000000001','queued');
insert into storage.objects(id,bucket_id,name,owner_id,metadata) values
 ('7b400000-0000-4000-8000-000000000001','closet-private','7b000000-0000-4000-8000-000000000001/7b100000-0000-4000-8000-000000000001/cutouts/item-0.png','7b000000-0000-4000-8000-000000000001','{"mimetype":"image/png","size":"321"}');

-- The table itself rejects the removed categories.
do $$ declare def text; begin
 select pg_get_constraintdef(oid) into def from pg_constraint where conname='garments_category_check' and conrelid='public.garments'::regclass;
 if def is null or def like '%dress%' or def like '%other%'
 or def not like '%outerwear%' or def not like '%top%' or def not like '%bottom%'
 or def not like '%shoes%' or def not like '%bag%' or def not like '%accessory%'
 then raise exception 'FAIL garments category check is not the six: %',def; end if;
end $$;

set local role service_role;
do $$ declare j public.analysis_jobs; fence jsonb; items jsonb; begin
 select * into j from public.claim_analysis_job(120);
 if j.id<>'7b300000-0000-4000-8000-000000000001' then raise exception 'FAIL unexpected claimed job'; end if;
 fence:=public.get_analysis_cutout_fence(j.id,'7b000000-0000-4000-8000-000000000001/7b100000-0000-4000-8000-000000000001/cutouts/item-0.png');
 items:=jsonb_build_array(jsonb_build_object(
  'item_index',0,'client_item_key','item-0','mask_object_key','7b000000-0000-4000-8000-000000000001/7b100000-0000-4000-8000-000000000001/cutouts/item-0.png',
  'content_type','image/png','byte_size',321,'storage_object_id',fence->>'object_id','storage_updated_at',fence->>'object_updated_at',
  'bbox',jsonb_build_array(0.1,0.1,0.9,0.9),'confidence',0.8,'attributes',jsonb_build_object('category','dress')));
 -- An out-of-six label must never reach the RPC as a category.
 begin perform public.apply_analysis_result('7b500000-0000-4000-8000-000000000001',j.id,j.attempt,j.lease_token,repeat('c',64),'succeeded','{"attributes":"v1"}',items,'[]');
  raise exception 'FAIL dress category accepted'; exception when invalid_parameter_value then if sqlerrm<>'invalid_result_item' then raise; end if; end;
 -- ai_category is only allowed next to a null category.
 begin perform public.apply_analysis_result('7b500000-0000-4000-8000-000000000001',j.id,j.attempt,j.lease_token,repeat('c',64),'succeeded','{"attributes":"v1"}',
  jsonb_set(items,'{0,attributes}','{"category":"top","ai_category":"dress"}'),'[]');
  raise exception 'FAIL ai_category with category accepted'; exception when invalid_parameter_value then if sqlerrm<>'invalid_result_item' then raise; end if; end;
 perform public.apply_analysis_result('7b500000-0000-4000-8000-000000000001',j.id,j.attempt,j.lease_token,repeat('c',64),'succeeded','{"attributes":"v1"}',
  jsonb_set(items,'{0,attributes}','{"category":null,"ai_category":"dress"}'),'[]');
end $$;
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub','7b000000-0000-4000-8000-000000000001',true);
do $$ declare listed jsonb; draft_id uuid; patched jsonb; confirmed jsonb; begin
 listed:=public.list_my_garment_drafts('7b100000-0000-4000-8000-000000000001');
 if jsonb_typeof(listed#>'{items,0,predicted_attributes,category}')<>'null'
 or jsonb_typeof(listed#>'{items,0,current_attributes,category}')<>'null'
 then raise exception 'FAIL unknown AI category should surface as null'; end if;
 draft_id:=(listed#>>'{items,0,id}')::uuid;
 -- Unreviewed category blocks saving with a validation error (not a generic failure).
 begin perform public.confirm_my_garment_batch('7b100000-0000-4000-8000-000000000001',array[draft_id],jsonb_build_object(draft_id::text,1),'six-confirm-early');
  raise exception 'FAIL null category confirmed'; exception when invalid_parameter_value then if sqlerrm<>'invalid_category' then raise; end if; end;
 foreach patched in array array['"dress"'::jsonb,'"other"'::jsonb] loop
  begin perform public.update_my_garment_draft(draft_id,1,true,patched#>>'{}',false,null,false,null);
   raise exception 'FAIL draft patch to %',patched; exception when invalid_parameter_value then if sqlerrm<>'invalid_category' then raise; end if; end;
 end loop;
 patched:=public.update_my_garment_draft(draft_id,1,true,'outerwear',false,null,false,null);
 if patched#>>'{current_attributes,category}'<>'outerwear' or jsonb_typeof(patched#>'{predicted_attributes,category}')<>'null'
 then raise exception 'FAIL user category choice'; end if;
 confirmed:=public.confirm_my_garment_batch('7b100000-0000-4000-8000-000000000001',array[draft_id],jsonb_build_object(draft_id::text,2),'six-confirm-ok');
 begin perform public.update_my_garment((confirmed#>>'{garment_ids,0}')::uuid,1,true,'dress',false,null,false,null);
  raise exception 'FAIL garment patch to dress'; exception when invalid_parameter_value then if sqlerrm<>'invalid_garment_category' then raise; end if; end;
end $$;
reset role;
do $$ begin
 if not exists(select 1 from public.garments where user_id='7b000000-0000-4000-8000-000000000001' and category='outerwear')
 then raise exception 'FAIL confirmed six-category garment'; end if;
end $$;
rollback;
