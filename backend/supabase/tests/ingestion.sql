-- Run only against a disposable migrated database. Every fixture rolls back.
begin;
insert into auth.users(id) values
 ('73000000-0000-4000-8000-000000000001'),
 ('73000000-0000-4000-8000-000000000002');

set local role authenticated;
select set_config('request.jwt.claim.sub','73000000-0000-4000-8000-000000000001',true);
do $$ declare first jsonb; replay jsonb; aid uuid; object_name text; begin
 first:=public.create_my_garment_batch('image/jpeg',3,'create-key-one');
 replay:=public.create_my_garment_batch('image/jpeg',3,'create-key-one');
 if first<>replay then raise exception 'FAIL create replay'; end if;
 object_name:=first->>'object_key';
 if object_name!~'^73000000-0000-4000-8000-000000000001/[0-9a-f-]+/source\.jpg$' then raise exception 'FAIL server path'; end if;
 select id into aid from public.garment_assets where object_key=object_name;
 if aid is null then raise exception 'FAIL source asset'; end if;
 begin perform public.create_my_garment_batch('image/png',3,'create-key-one'); raise exception 'FAIL create conflict';
 exception when raise_exception then if sqlerrm<>'idempotency_conflict' then raise; end if; end;

 insert into storage.objects(bucket_id,name,owner_id,metadata)
 values('closet-private',object_name,auth.uid(),'{"mimetype":"image/jpeg","size":3}');
 perform public.complete_my_garment_upload((first->'batch'->>'id')::uuid,'complete-key-one','valid');
 perform public.complete_my_garment_upload((first->'batch'->>'id')::uuid,'complete-key-one','valid');
 if not exists(select 1 from public.garment_assets where id=aid and verified_at is not null)
    or not exists(select 1 from public.garment_batches where id=(first->'batch'->>'id')::uuid and status='uploaded')
 then raise exception 'FAIL upload completion'; end if;
end $$;
reset role;
do $$ begin
 if not exists(select 1 from public.idempotency_keys where user_id='73000000-0000-4000-8000-000000000001'
   and scope in ('garment_batch_create','garment_upload_complete') and response_body is not null)
 then raise exception 'FAIL ingestion idempotency evidence'; end if;
end $$;

set local role authenticated;
select set_config('request.jwt.claim.sub','73000000-0000-4000-8000-000000000002',true);
do $$ begin
 begin insert into storage.objects(bucket_id,name,owner_id,metadata)
  values('closet-private','73000000-0000-4000-8000-000000000001/foreign/source.jpg',auth.uid(),'{}');
  raise exception 'FAIL arbitrary storage insert'; exception when insufficient_privilege then null; end;
 if exists(select 1 from public.garment_batches where user_id='73000000-0000-4000-8000-000000000001')
 then raise exception 'FAIL cross-owner batch read'; end if;
end $$;
reset role;
rollback;
