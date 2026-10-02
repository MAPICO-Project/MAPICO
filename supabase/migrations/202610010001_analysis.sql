-- G4: authenticated analysis lifecycle and service-only callback application.

-- Worker event IDs are globally unique even though ordinary HTTP idempotency keys are tenant-scoped.
create unique index idempotency_analysis_callback_event
 on public.idempotency_keys(scope,key) where scope='analysis_callback';

create function public.create_my_analysis_job(p_batch_id uuid,p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare owner_id uuid:=auth.uid(); b public.garment_batches; stored public.idempotency_keys;
 request_fingerprint text; j public.analysis_jobs; response jsonb;
begin
 if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 if p_batch_id is null then raise exception 'invalid_batch_id' using errcode='22023'; end if;
 if p_idempotency_key is null or length(p_idempotency_key) not between 8 and 128
 or p_idempotency_key !~ '^[A-Za-z0-9._:-]+$' then raise exception 'invalid_idempotency_key' using errcode='22023'; end if;
 request_fingerprint:=md5(p_batch_id::text);
 insert into public.idempotency_keys(user_id,scope,key,request_hash)
 values(owner_id,'analysis_job_create',p_idempotency_key,request_fingerprint) on conflict do nothing;
 select * into stored from public.idempotency_keys where user_id=owner_id and scope='analysis_job_create' and key=p_idempotency_key for update;
 if stored.expires_at<=now() then
  delete from public.idempotency_keys where user_id=owner_id and scope='analysis_job_create' and key=p_idempotency_key;
  insert into public.idempotency_keys(user_id,scope,key,request_hash)
  values(owner_id,'analysis_job_create',p_idempotency_key,request_fingerprint) returning * into stored;
 end if;
 if stored.request_hash<>request_fingerprint then raise exception 'idempotency_conflict' using errcode='P0001'; end if;
 if stored.response_body is not null then return stored.response_body; end if;
 select * into b from public.garment_batches where id=p_batch_id and user_id=owner_id for update;
 if not found then raise exception 'batch_not_found' using errcode='P0002'; end if;
 if b.status<>'uploaded' then raise exception 'batch_not_uploaded' using errcode='P0001'; end if;
 if not exists(select 1 from public.garment_assets where user_id=owner_id and batch_id=b.id and kind='source' and verified_at is not null and deleted_at is null)
 then raise exception 'source_asset_not_ready' using errcode='P0001'; end if;
 if exists(select 1 from public.analysis_jobs where batch_id=b.id) then raise exception 'analysis_job_exists' using errcode='P0001'; end if;
 insert into public.analysis_jobs(user_id,batch_id) values(owner_id,b.id) returning * into j;
 update public.garment_batches set status='processing' where id=b.id;
 response:=jsonb_build_object('id',j.id,'batch_id',j.batch_id,'status',j.status,'attempt',j.attempt,'max_attempts',j.max_attempts,
  'progress',j.progress,'stage',j.stage,'error_code',j.error_code,'created_at',j.created_at,'updated_at',j.updated_at,'completed_at',j.completed_at);
 update public.idempotency_keys set response_body=response,response_status=202
 where user_id=owner_id and scope='analysis_job_create' and key=p_idempotency_key;
 return response;
end $$;

create function public.retry_my_analysis_job(p_job_id uuid,p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare owner_id uuid:=auth.uid(); j public.analysis_jobs; b public.garment_batches; stored public.idempotency_keys;
 request_fingerprint text; response jsonb;
begin
 if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 if p_job_id is null then raise exception 'invalid_job_id' using errcode='22023'; end if;
 if p_idempotency_key is null or length(p_idempotency_key) not between 8 and 128
 or p_idempotency_key !~ '^[A-Za-z0-9._:-]+$' then raise exception 'invalid_idempotency_key' using errcode='22023'; end if;
 request_fingerprint:=md5(p_job_id::text);
 insert into public.idempotency_keys(user_id,scope,key,request_hash)
 values(owner_id,'analysis_job_retry',p_idempotency_key,request_fingerprint) on conflict do nothing;
 select * into stored from public.idempotency_keys where user_id=owner_id and scope='analysis_job_retry' and key=p_idempotency_key for update;
 if stored.expires_at<=now() then
  delete from public.idempotency_keys where user_id=owner_id and scope='analysis_job_retry' and key=p_idempotency_key;
  insert into public.idempotency_keys(user_id,scope,key,request_hash)
  values(owner_id,'analysis_job_retry',p_idempotency_key,request_fingerprint) returning * into stored;
 end if;
 if stored.request_hash<>request_fingerprint then raise exception 'idempotency_conflict' using errcode='P0001'; end if;
 if stored.response_body is not null then return stored.response_body; end if;
 select * into j from public.analysis_jobs where id=p_job_id and user_id=owner_id for update;
 if not found then raise exception 'job_not_found' using errcode='P0002'; end if;
 select * into b from public.garment_batches where id=j.batch_id and user_id=owner_id for update;
 if b.status='confirmed' then raise exception 'batch_already_confirmed' using errcode='P0001'; end if;
 if j.status<>'failed' then raise exception 'job_not_retryable' using errcode='P0001'; end if;
 if j.attempt>=j.max_attempts then raise exception 'attempts_exhausted' using errcode='P0001'; end if;
 if coalesce(j.error_code,'') not in ('WORKER_TIMEOUT','MODEL_UNAVAILABLE','STORAGE_UNAVAILABLE','INTERNAL_ERROR','CALLBACK_TIMEOUT')
 then raise exception 'job_not_retryable' using errcode='P0001'; end if;
 update public.analysis_jobs set status='queued',available_at=now(),lease_token=null,lease_expires_at=null,
  progress=0,stage=null,result=null,error_code=null,completed_at=null where id=j.id returning * into j;
 update public.garment_batches set status='processing' where id=b.id;
 response:=jsonb_build_object('id',j.id,'batch_id',j.batch_id,'status',j.status,'attempt',j.attempt,'max_attempts',j.max_attempts,
  'progress',j.progress,'stage',j.stage,'error_code',j.error_code,'created_at',j.created_at,'updated_at',j.updated_at,'completed_at',j.completed_at);
 update public.idempotency_keys set response_body=response,response_status=202
 where user_id=owner_id and scope='analysis_job_retry' and key=p_idempotency_key;
 return response;
end $$;

create function public.list_my_garment_drafts(p_batch_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare owner_id uuid:=auth.uid(); b public.garment_batches; response jsonb;
begin
 if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 if p_batch_id is null then raise exception 'invalid_batch_id' using errcode='22023'; end if;
 select * into b from public.garment_batches where id=p_batch_id and user_id=owner_id;
 if not found then raise exception 'batch_not_found' using errcode='P0002'; end if;
 select jsonb_build_object('items',coalesce(jsonb_agg(jsonb_build_object(
  'id',d.id,'batch_id',d.batch_id,'item_index',d.item_index,'asset_id',d.asset_id,'status',d.status,
  'predicted_attributes',jsonb_build_object('category',d.raw_prediction->>'category','subcategory',d.raw_prediction->'subcategory'),
  'current_attributes',jsonb_build_object(
   'category',coalesce(d.user_overrides->>'category',d.raw_prediction->>'category'),
   'subcategory',case when d.user_overrides?'subcategory' then d.user_overrides->'subcategory' else d.raw_prediction->'subcategory' end,
   'note',case when d.user_overrides?'note' then d.user_overrides->'note' else d.raw_prediction->'note' end),
  'prediction_confidence',d.raw_prediction->'confidence','version',d.version
 ) order by d.item_index),'[]'::jsonb)) into response
 from public.garment_drafts d where d.user_id=owner_id and d.batch_id=b.id;
 return response;
end $$;

create function public.update_my_garment_draft(
 p_draft_id uuid,p_expected_version integer,
 p_has_category boolean,p_category text,p_has_subcategory boolean,p_subcategory text,p_has_note boolean,p_note text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare owner_id uuid:=auth.uid(); d public.garment_drafts; overrides jsonb; effective jsonb;
begin
 if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 if p_draft_id is null or p_expected_version is null or p_expected_version<1
 or p_has_category is null or p_has_subcategory is null or p_has_note is null
 then raise exception 'invalid_draft_patch' using errcode='22023'; end if;
 if not (p_has_category or p_has_subcategory or p_has_note) then raise exception 'empty_draft_patch' using errcode='22023'; end if;
 if p_has_category and (p_category is null or p_category not in ('top','bottom','outerwear','dress','shoes','bag','accessory','other'))
 then raise exception 'invalid_category' using errcode='22023'; end if;
 if p_has_subcategory and p_subcategory is not null and length(p_subcategory)>80 then raise exception 'invalid_subcategory' using errcode='22023'; end if;
 if p_has_note and p_note is not null and length(p_note)>1000 then raise exception 'invalid_note' using errcode='22023'; end if;
 select * into d from public.garment_drafts where id=p_draft_id and user_id=owner_id for update;
 if not found then raise exception 'draft_not_found' using errcode='P0002'; end if;
 if d.version<>p_expected_version then raise exception 'version_conflict' using errcode='P0001'; end if;
 if d.status not in ('predicted','edited') or not exists(select 1 from public.garment_batches where id=d.batch_id and user_id=owner_id and status='review')
 then raise exception 'draft_not_editable' using errcode='P0001'; end if;
 overrides:=d.user_overrides;
 if p_has_category then overrides:=overrides||jsonb_build_object('category',p_category); end if;
 if p_has_subcategory then overrides:=overrides||jsonb_build_object('subcategory',p_subcategory); end if;
 if p_has_note then overrides:=overrides||jsonb_build_object('note',p_note); end if;
 update public.garment_drafts set user_overrides=overrides,status='edited',version=version+1 where id=d.id returning * into d;
 effective:=d.raw_prediction||d.user_overrides;
 return jsonb_build_object(
  'id',d.id,'batch_id',d.batch_id,'item_index',d.item_index,'asset_id',d.asset_id,'status',d.status,
  'predicted_attributes',jsonb_build_object('category',d.raw_prediction->>'category','subcategory',d.raw_prediction->'subcategory'),
  'current_attributes',jsonb_build_object('category',effective->>'category','subcategory',effective->'subcategory','note',effective->'note'),
  'prediction_confidence',d.raw_prediction->'confidence','version',d.version);
end $$;

create function public.confirm_my_garment_batch(p_batch_id uuid,p_draft_ids uuid[],p_versions jsonb,p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare owner_id uuid:=auth.uid(); b public.garment_batches; d public.garment_drafts; stored public.idempotency_keys;
 request_fingerprint text; effective jsonb; garment_ids jsonb:='[]'::jsonb; garment_id uuid; response jsonb; n integer;
begin
 if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 if p_batch_id is null or cardinality(p_draft_ids) is null or cardinality(p_draft_ids) not between 1 and 6
 or exists(select 1 from unnest(p_draft_ids) x where x is null)
 or (select count(distinct x) from unnest(p_draft_ids) x)<>cardinality(p_draft_ids)
 or jsonb_typeof(p_versions) is distinct from 'object'
 or (select count(*) from jsonb_object_keys(p_versions))<>cardinality(p_draft_ids)
 or exists(select 1 from jsonb_object_keys(p_versions) k where not(k=any(select x::text from unnest(p_draft_ids) x)))
 then raise exception 'invalid_draft_ids' using errcode='22023'; end if;
 if p_idempotency_key is null or length(p_idempotency_key) not between 8 and 128
 or p_idempotency_key !~ '^[A-Za-z0-9._:-]+$' then raise exception 'invalid_idempotency_key' using errcode='22023'; end if;
 request_fingerprint:=md5(p_batch_id::text||':'||(select string_agg(x::text||'='||(p_versions->>x::text),',' order by x) from unnest(p_draft_ids) x));
 insert into public.idempotency_keys(user_id,scope,key,request_hash)
 values(owner_id,'garment_batch_confirm',p_idempotency_key,request_fingerprint) on conflict do nothing;
 select * into stored from public.idempotency_keys where user_id=owner_id and scope='garment_batch_confirm' and key=p_idempotency_key for update;
 if stored.expires_at<=now() then
  delete from public.idempotency_keys where user_id=owner_id and scope='garment_batch_confirm' and key=p_idempotency_key;
  insert into public.idempotency_keys(user_id,scope,key,request_hash)
  values(owner_id,'garment_batch_confirm',p_idempotency_key,request_fingerprint) returning * into stored;
 end if;
 if stored.request_hash<>request_fingerprint then raise exception 'idempotency_conflict' using errcode='P0001'; end if;
 if stored.response_body is not null then return stored.response_body; end if;
 select * into b from public.garment_batches where id=p_batch_id and user_id=owner_id for update;
 if not found then raise exception 'batch_not_found' using errcode='P0002'; end if;
 if b.status<>'review' then raise exception 'batch_not_reviewable' using errcode='P0001'; end if;
 if not exists(select 1 from public.analysis_jobs where user_id=owner_id and batch_id=b.id and status in ('succeeded','partial_failed'))
 then raise exception 'analysis_not_reviewable' using errcode='P0001'; end if;
 select count(*) into n from public.garment_drafts where user_id=owner_id and batch_id=b.id and id=any(p_draft_ids);
 if n<>cardinality(p_draft_ids) then raise exception 'invalid_draft_ids' using errcode='22023'; end if;
 for d in select * from public.garment_drafts where user_id=owner_id and batch_id=b.id and id=any(p_draft_ids) order by id for update loop
  if d.status not in ('predicted','edited') then raise exception 'invalid_draft_state' using errcode='P0001'; end if;
  if (p_versions->>d.id::text) is null or (p_versions->>d.id::text)!~'^[1-9][0-9]*$'
  or (p_versions->>d.id::text)::integer<>d.version then raise exception 'version_conflict' using errcode='P0001'; end if;
  if not exists(select 1 from public.garment_assets where id=d.asset_id and user_id=owner_id and batch_id=b.id and kind='cutout' and verified_at is not null and deleted_at is null)
  then raise exception 'asset_not_ready' using errcode='P0001'; end if;
  effective:=d.raw_prediction||d.user_overrides;
  if coalesce(effective->>'category','') not in ('top','bottom','outerwear','dress','shoes','bag','accessory','other') then raise exception 'invalid_category'; end if;
  insert into public.garments(user_id,source_draft_id,asset_id,category,color_hex,pattern,formality,activity,attributes,memo)
  values(owner_id,d.id,d.asset_id,effective->>'category',effective->>'color_hex',effective->>'pattern',
   nullif(effective->>'formality','')::numeric,nullif(effective->>'activity','')::numeric,effective,effective->>'note')
  returning id into garment_id;
  garment_ids:=garment_ids||jsonb_build_array(garment_id);
 end loop;
 update public.garment_drafts set status=case when id=any(p_draft_ids) then 'confirmed' else 'rejected' end,version=version+1
 where user_id=owner_id and batch_id=b.id;
 update public.garment_batches set status='confirmed' where id=b.id;
 response:=jsonb_build_object('batch_id',b.id,'garment_ids',garment_ids);
 update public.idempotency_keys set response_body=response,response_status=201
 where user_id=owner_id and scope='garment_batch_confirm' and key=p_idempotency_key;
 return response;
end $$;

-- HMAC-verified callbacks use this before any mutable job or Storage inspection.
create function public.inspect_analysis_callback(p_event_id uuid,p_job_id uuid,p_attempt integer,p_payload_hash text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare stored public.idempotency_keys; j public.analysis_jobs; event_fingerprint text;
begin
 if p_event_id is null or p_job_id is null or p_attempt is null or p_attempt<1
 or p_payload_hash is null or length(p_payload_hash)<>64 or p_payload_hash!~'^[0-9a-f]{64}$'
 then raise exception 'invalid_callback' using errcode='22023'; end if;
 event_fingerprint:=p_job_id::text||':'||p_attempt::text||':'||p_payload_hash;
 select * into stored from public.idempotency_keys where scope='analysis_callback' and key=p_event_id::text;
 if found then
  if stored.request_hash<>event_fingerprint then raise exception 'callback_conflict' using errcode='P0001'; end if;
  if stored.response_body is null then raise exception 'callback_in_progress' using errcode='P0001'; end if;
  return jsonb_build_object('replayed',true,'response',stored.response_body);
 end if;
 select * into j from public.analysis_jobs where id=p_job_id;
 if not found then raise exception 'job_not_found' using errcode='P0002'; end if;
 return jsonb_build_object('replayed',false,'job',jsonb_build_object(
  'id',j.id,'user_id',j.user_id,'batch_id',j.batch_id,'status',j.status,'attempt',j.attempt,
  'lease_token',j.lease_token,'lease_expires_at',j.lease_expires_at));
end $$;

-- The BFF echoes this identity/version fence after verifying the object bytes.
create function public.get_analysis_cutout_fence(p_job_id uuid,p_object_key text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare j public.analysis_jobs; obj storage.objects; expected_prefix text;
begin
 if p_job_id is null or p_object_key is null or p_object_key='' then raise exception 'invalid_cutout_fence' using errcode='22023'; end if;
 select * into j from public.analysis_jobs where id=p_job_id;
 if not found then raise exception 'job_not_found' using errcode='P0002'; end if;
 expected_prefix:=j.user_id::text||'/'||j.batch_id::text||'/cutouts/';
 if p_object_key not like expected_prefix||'%' then raise exception 'invalid_cutout_path' using errcode='22023'; end if;
 select * into obj from storage.objects where bucket_id='closet-private' and name=p_object_key;
 if not found or obj.owner_id is distinct from j.user_id then raise exception 'cutout_asset_not_verified' using errcode='P0001'; end if;
 return jsonb_build_object('object_id',obj.id,'object_updated_at',obj.updated_at);
end $$;

create function public.apply_analysis_result(
 p_event_id uuid,p_job_id uuid,p_attempt integer,p_lease_token uuid,p_payload_hash text,
 p_status text,p_model_versions jsonb,p_items jsonb,p_errors jsonb
) returns jsonb language plpgsql security definer set search_path='' as $$
declare j public.analysis_jobs; stored public.idempotency_keys; item jsonb; obj storage.objects; asset_id uuid;
 item_count integer; error_count integer; idx integer; attrs jsonb; response jsonb; expected_prefix text;
 event_fingerprint text; expected_object_key text;
begin
 if p_event_id is null or p_job_id is null or p_attempt is null or p_attempt<1 or p_lease_token is null
 or p_payload_hash is null or length(p_payload_hash)<>64 or p_payload_hash!~'^[0-9a-f]{64}$'
 or p_status not in ('succeeded','partial_failed','failed')
 or jsonb_typeof(p_model_versions) is distinct from 'object' or not exists(select 1 from jsonb_object_keys(p_model_versions))
 or jsonb_typeof(p_items) is distinct from 'array' or jsonb_typeof(p_errors) is distinct from 'array'
 then raise exception 'invalid_callback' using errcode='22023'; end if;
 item_count:=jsonb_array_length(p_items); error_count:=jsonb_array_length(p_errors);
 if item_count>6 or (p_status='succeeded' and (item_count<1 or error_count<>0))
 or (p_status='partial_failed' and (item_count<1 or error_count<1))
 or (p_status='failed' and (item_count<>0 or error_count<1)) then raise exception 'invalid_result_count' using errcode='22023'; end if;
 event_fingerprint:=p_job_id::text||':'||p_attempt::text||':'||p_payload_hash;
 -- Resolve a durable replay before looking at mutable job/lease state.
 select * into stored from public.idempotency_keys where scope='analysis_callback' and key=p_event_id::text for update;
 if found then
  if stored.request_hash<>event_fingerprint then raise exception 'callback_conflict' using errcode='P0001'; end if;
  if stored.response_body is not null then return jsonb_build_object('job_id',p_job_id,'event_id',p_event_id,'applied',false); end if;
 end if;
 select * into j from public.analysis_jobs where id=p_job_id for update;
 if not found then raise exception 'job_not_found' using errcode='P0002'; end if;
 insert into public.idempotency_keys(user_id,scope,key,request_hash,expires_at)
 values(j.user_id,'analysis_callback',p_event_id::text,event_fingerprint,'infinity'::timestamptz) on conflict do nothing;
 select * into stored from public.idempotency_keys where scope='analysis_callback' and key=p_event_id::text for update;
 if stored.user_id<>j.user_id or stored.request_hash<>event_fingerprint then raise exception 'callback_conflict' using errcode='P0001'; end if;
 if stored.response_body is not null then return jsonb_build_object('job_id',p_job_id,'event_id',p_event_id,'applied',false); end if;
 if j.status<>'running' or j.attempt<>p_attempt or j.lease_token is distinct from p_lease_token or j.lease_expires_at<=now()
 then raise exception 'stale_lease' using errcode='P0001'; end if;
 expected_prefix:=j.user_id::text||'/'||j.batch_id::text||'/cutouts/';
 if item_count>0 and (select count(distinct (value->>'item_index')::integer) from jsonb_array_elements(p_items))<>item_count
 then raise exception 'duplicate_item_index' using errcode='22023'; end if;
 if item_count>0 and (select count(distinct value->>'client_item_key') from jsonb_array_elements(p_items))<>item_count
 then raise exception 'duplicate_client_item_key' using errcode='22023'; end if;
 for item in select value from jsonb_array_elements(p_items) loop
  if jsonb_typeof(item) is distinct from 'object' or coalesce(item->>'item_index','')!~'^[0-5]$'
  or coalesce(item->>'client_item_key','')='' or length(item->>'client_item_key')>80
  or coalesce(item->>'mask_object_key','') not like expected_prefix||'%'
  or item->>'content_type' not in ('image/jpeg','image/png','image/webp')
  or coalesce(item->>'byte_size','')!~'^[1-9][0-9]*$' or (item->>'byte_size')::bigint>20971520
  or jsonb_typeof(item->'attributes') is distinct from 'object'
  or coalesce(item->'attributes'->>'category','') not in ('top','bottom','outerwear','dress','shoes','bag','accessory','other')
  or jsonb_typeof(item->'bbox') is distinct from 'array' or jsonb_array_length(item->'bbox')<>4
  or jsonb_typeof(item->'bbox'->0) is distinct from 'number' or jsonb_typeof(item->'bbox'->1) is distinct from 'number'
  or jsonb_typeof(item->'bbox'->2) is distinct from 'number' or jsonb_typeof(item->'bbox'->3) is distinct from 'number'
  or (item->'bbox'->>0)::numeric not between 0 and 1 or (item->'bbox'->>1)::numeric not between 0 and 1
  or (item->'bbox'->>2)::numeric not between 0 and 1 or (item->'bbox'->>3)::numeric not between 0 and 1
  or (item->'bbox'->>0)::numeric >= (item->'bbox'->>2)::numeric or (item->'bbox'->>1)::numeric >= (item->'bbox'->>3)::numeric
  or (item?'confidence' and jsonb_typeof(item->'confidence') not in ('number','null'))
  or (jsonb_typeof(item->'confidence')='number' and (item->>'confidence')::numeric not between 0 and 1)
  or substring(item->>'mask_object_key' from length(expected_prefix)+1) !~ '^[A-Za-z0-9][A-Za-z0-9._-]*$'
  then raise exception 'invalid_result_item' using errcode='22023'; end if;
  idx:=(item->>'item_index')::integer;
  expected_object_key:=expected_prefix||'item-'||idx::text||case item->>'content_type'
   when 'image/jpeg' then '.jpg' when 'image/png' then '.png' when 'image/webp' then '.webp' end;
  if item->>'mask_object_key'<>expected_object_key then raise exception 'invalid_cutout_path' using errcode='22023'; end if;
  if coalesce(item->>'storage_object_id','')='' or coalesce(item->>'storage_updated_at','')=''
  then raise exception 'missing_storage_fence' using errcode='22023'; end if;
  select * into obj from storage.objects where bucket_id='closet-private' and name=item->>'mask_object_key' for update;
  if not found or obj.owner_id is distinct from j.user_id
  or obj.id::text<>item->>'storage_object_id' or obj.updated_at is distinct from (item->>'storage_updated_at')::timestamptz
  or coalesce(obj.metadata->>'mimetype','')<>item->>'content_type'
  or coalesce(obj.metadata->>'size','')!~'^[0-9]+$' or (obj.metadata->>'size')::bigint<>(item->>'byte_size')::bigint
  then raise exception 'cutout_asset_not_verified' using errcode='P0001'; end if;
  insert into public.garment_assets(user_id,batch_id,kind,object_key,content_type,byte_size,verified_at)
  values(j.user_id,j.batch_id,'cutout',item->>'mask_object_key',item->>'content_type',(item->>'byte_size')::bigint,now())
  returning id into asset_id;
  attrs:=(item->'attributes')||jsonb_build_object('client_item_key',item->>'client_item_key','bbox',item->'bbox','confidence',item->'confidence');
  insert into public.garment_drafts(user_id,batch_id,job_id,item_index,asset_id,raw_prediction,model_version)
  values(j.user_id,j.batch_id,j.id,idx,asset_id,attrs,coalesce(p_model_versions->>'attributes',p_model_versions->>'model','unknown'));
 end loop;
 update public.analysis_jobs set status=p_status,progress=100,stage=null,
  result=jsonb_build_object('status',p_status,'model_versions',p_model_versions,'errors',p_errors,'item_count',item_count),
  error_code=case when p_status='failed' then coalesce(p_errors->0->>'code','ANALYSIS_FAILED') else null end,
  lease_token=null,lease_expires_at=null,completed_at=now() where id=j.id;
 update public.garment_batches set status=case when p_status='failed' then 'failed' else 'review' end where id=j.batch_id;
 response:=jsonb_build_object('job_id',p_job_id,'event_id',p_event_id,'applied',true);
 update public.idempotency_keys set response_body=response,response_status=200
 where user_id=j.user_id and scope='analysis_callback' and key=p_event_id::text;
 return response;
end $$;

-- Raw model output and user overrides are never directly browser-readable.
revoke select on public.garment_drafts from authenticated;
revoke execute on function public.confirm_garment_batch(uuid,uuid[],jsonb) from authenticated;
revoke all on function public.create_my_analysis_job(uuid,text),public.retry_my_analysis_job(uuid,text),
 public.list_my_garment_drafts(uuid),
 public.update_my_garment_draft(uuid,integer,boolean,text,boolean,text,boolean,text),
 public.confirm_my_garment_batch(uuid,uuid[],jsonb,text),
 public.inspect_analysis_callback(uuid,uuid,integer,text),public.get_analysis_cutout_fence(uuid,text),
 public.apply_analysis_result(uuid,uuid,integer,uuid,text,text,jsonb,jsonb,jsonb) from public,anon,authenticated;
grant execute on function public.create_my_analysis_job(uuid,text),public.retry_my_analysis_job(uuid,text),
 public.list_my_garment_drafts(uuid),
 public.update_my_garment_draft(uuid,integer,boolean,text,boolean,text,boolean,text),
 public.confirm_my_garment_batch(uuid,uuid[],jsonb,text) to authenticated;
grant execute on function public.inspect_analysis_callback(uuid,uuid,integer,text),public.get_analysis_cutout_fence(uuid,text),
 public.apply_analysis_result(uuid,uuid,integer,uuid,text,text,jsonb,jsonb,jsonb) to service_role;
