-- G3: user-bound batch creation and upload completion.

create function public.create_my_garment_batch(
  p_content_type text,
  p_file_size bigint,
  p_idempotency_key text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  owner_id uuid:=auth.uid();
  request_fingerprint text;
  stored public.idempotency_keys;
  batch_id uuid;
  asset_id uuid;
  object_key text;
  extension text;
  created timestamptz;
  response jsonb;
begin
  if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
  if p_content_type not in ('image/jpeg','image/png','image/webp') or p_content_type is null
     or p_file_size is null or p_file_size not between 1 and 20971520 then
    raise exception 'invalid_batch_create' using errcode='22023';
  end if;
  if p_idempotency_key is null or length(p_idempotency_key) not between 8 and 128
     or p_idempotency_key !~ '^[A-Za-z0-9._:-]+$' then
    raise exception 'invalid_idempotency_key' using errcode='22023';
  end if;
  request_fingerprint:=md5(p_content_type||':'||p_file_size::text);

  insert into public.idempotency_keys(user_id,scope,key,request_hash)
  values(owner_id,'garment_batch_create',p_idempotency_key,request_fingerprint)
  on conflict do nothing;
  select * into stored from public.idempotency_keys
   where user_id=owner_id and scope='garment_batch_create' and key=p_idempotency_key for update;
  if stored.expires_at<=now() then
    delete from public.idempotency_keys where user_id=owner_id and scope='garment_batch_create' and key=p_idempotency_key;
    insert into public.idempotency_keys(user_id,scope,key,request_hash)
    values(owner_id,'garment_batch_create',p_idempotency_key,request_fingerprint)
    returning * into stored;
  end if;
  if stored.request_hash<>request_fingerprint then raise exception 'idempotency_conflict' using errcode='P0001'; end if;
  if stored.response_body is not null then return stored.response_body; end if;
  if (select count(*) from public.garment_batches where user_id=owner_id and status='awaiting_upload')>=20 then
    raise exception 'too_many_open_batches' using errcode='P0001';
  end if;

  batch_id:=gen_random_uuid(); asset_id:=gen_random_uuid(); created:=now();
  extension:=case p_content_type when 'image/jpeg' then 'jpg' when 'image/png' then 'png' else 'webp' end;
  object_key:=owner_id::text||'/'||batch_id::text||'/source.'||extension;
  insert into public.garment_batches(id,user_id,status,created_at)
   values(batch_id,owner_id,'awaiting_upload',created);
  insert into public.garment_assets(id,user_id,batch_id,kind,object_key,content_type,byte_size)
   values(asset_id,owner_id,batch_id,'source',object_key,p_content_type,p_file_size);
  response:=jsonb_build_object('batch',jsonb_build_object('id',batch_id,'status','awaiting_upload','created_at',created),'object_key',object_key);
  update public.idempotency_keys set response_body=response,response_status=201
   where user_id=owner_id and scope='garment_batch_create' and key=p_idempotency_key;
  return response;
end $$;

create function public.complete_my_garment_upload(
  p_batch_id uuid,
  p_idempotency_key text,
  p_outcome text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  owner_id uuid:=auth.uid();
  request_fingerprint text;
  stored public.idempotency_keys;
  b public.garment_batches;
  a public.garment_assets;
  object_record storage.objects;
  response jsonb;
begin
  if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
  if p_batch_id is null then raise exception 'invalid_batch_id' using errcode='22023'; end if;
  if p_idempotency_key is null or length(p_idempotency_key) not between 8 and 128
     or p_idempotency_key !~ '^[A-Za-z0-9._:-]+$' then
    raise exception 'invalid_idempotency_key' using errcode='22023';
  end if;
  if p_outcome not in ('valid','invalid') or p_outcome is null then
    raise exception 'invalid_upload_outcome' using errcode='22023';
  end if;
  request_fingerprint:=md5(p_batch_id::text);

  insert into public.idempotency_keys(user_id,scope,key,request_hash)
  values(owner_id,'garment_upload_complete',p_idempotency_key,request_fingerprint)
  on conflict do nothing;
  select * into stored from public.idempotency_keys
   where user_id=owner_id and scope='garment_upload_complete' and key=p_idempotency_key for update;
  if stored.expires_at<=now() then
    delete from public.idempotency_keys where user_id=owner_id and scope='garment_upload_complete' and key=p_idempotency_key;
    insert into public.idempotency_keys(user_id,scope,key,request_hash)
    values(owner_id,'garment_upload_complete',p_idempotency_key,request_fingerprint)
    returning * into stored;
  end if;
  if stored.request_hash<>request_fingerprint then raise exception 'idempotency_conflict' using errcode='P0001'; end if;
  if stored.response_body is not null then return stored.response_body; end if;

  select * into b from public.garment_batches where id=p_batch_id and user_id=owner_id for update;
  if not found then raise exception 'batch_not_found' using errcode='P0002'; end if;
  if b.status='failed' then raise exception 'invalid_batch_state' using errcode='P0001'; end if;
  if b.status<>'awaiting_upload' then
    response:=jsonb_build_object('batch',jsonb_build_object('id',b.id,'status',b.status,'created_at',b.created_at),'invalid',false);
    update public.idempotency_keys set response_body=response,response_status=200
     where user_id=owner_id and scope='garment_upload_complete' and key=p_idempotency_key;
    return response;
  end if;
  select * into a from public.garment_assets where user_id=owner_id and batch_id=p_batch_id and kind='source' for update;
  if not found then raise exception 'asset_not_found' using errcode='P0002'; end if;
  select * into object_record from storage.objects where bucket_id=a.bucket_id and name=a.object_key;
  if not found then raise exception 'upload_not_found' using errcode='P0001'; end if;

  if p_outcome='invalid' or object_record.owner_id::text<>owner_id::text
     or coalesce(object_record.metadata->>'mimetype','')<>a.content_type
     or coalesce(object_record.metadata->>'size','')!~'^[0-9]+$'
     or (object_record.metadata->>'size')::bigint<>a.byte_size then
    update public.garment_batches set status='failed' where id=b.id;
    response:=jsonb_build_object('batch',jsonb_build_object('id',b.id,'status','failed','created_at',b.created_at),'invalid',true);
    update public.idempotency_keys set response_body=response,response_status=422
     where user_id=owner_id and scope='garment_upload_complete' and key=p_idempotency_key;
    return response;
  end if;

  update public.garment_assets set verified_at=now() where id=a.id and verified_at is null;
  update public.garment_batches set status='uploaded' where id=b.id;
  response:=jsonb_build_object('batch',jsonb_build_object('id',b.id,'status','uploaded','created_at',b.created_at),'invalid',false);
  update public.idempotency_keys set response_body=response,response_status=200
   where user_id=owner_id and scope='garment_upload_complete' and key=p_idempotency_key;
  return response;
end $$;

create policy closet_source_upload on storage.objects for insert to authenticated with check(
  bucket_id='closet-private' and split_part(name,'/',1)=(select auth.uid())::text
  and exists(
    select 1 from public.garment_assets a join public.garment_batches b
      on b.user_id=a.user_id and b.id=a.batch_id
    where a.object_key=name and a.user_id=(select auth.uid()) and a.kind='source'
      and a.verified_at is null and a.deleted_at is null and b.status='awaiting_upload'
  )
);
create policy closet_source_verify on storage.objects for select to authenticated using(
  bucket_id='closet-private' and exists(
    select 1 from public.garment_assets a join public.garment_batches b
      on b.user_id=a.user_id and b.id=a.batch_id
    where a.object_key=name and a.user_id=(select auth.uid()) and a.kind='source'
      and a.verified_at is null and a.deleted_at is null and b.status='awaiting_upload'
  )
);
grant insert,select on storage.objects to authenticated;
revoke all on function public.create_my_garment_batch(text,bigint,text),public.complete_my_garment_upload(uuid,text,text) from public,anon,authenticated;
grant execute on function public.create_my_garment_batch(text,bigint,text),public.complete_my_garment_upload(uuid,text,text) to authenticated;
