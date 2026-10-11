-- 2026-10-11 hosted fixes. Defects found only on hosted Supabase (demo-app session + hosted 1차 실측).
-- Earlier migrations are already applied remotely and stay untouched; everything here is create-or-replace / additive.
--  1) storage.objects.owner_id is TEXT on hosted (local stub was uuid): compare as text (#7, 42883 text = uuid).
--  2) Server-key (AI worker) cutout uploads have owner_id NULL (#2): the fence trusts the closet-private
--     `<user_id>/<batch_id>/cutouts/` path, which no browser role can write, and still rejects a non-matching owner.
--  3) Column grants for columns the API selects/filters with the user JWT (#5).
--  4) Storage insert policies no longer depend on metadata size/mimetype (N3); complete RPCs re-verify both.
--  5) Batch confirmation stores AI aesthetic scores into garment_aesthetic_scores (N4).
--  6) OOTD weather summary read for calendar / OOTD responses (#8).

-- ---------------------------------------------------------------------------
-- 1+2. Cutout fence / analysis result / mimic candidates
-- ---------------------------------------------------------------------------
-- Why NULL owner is accepted for cutouts:
--  * insert into storage.objects for `authenticated` in closet-private is only allowed by closet_source_upload,
--    which requires a pending kind='source' garment_assets row whose object_key equals the name. Source keys are
--    built server-side as `<uid>/<batch>/source.<ext>`, so no user JWT can create `<uid>/<batch>/cutouts/...`.
--    Only the secret key (BFF / AI worker) can write there, and those uploads carry no owner.
--  * The prefix is derived from the job row (user_id + batch_id), apply_analysis_result additionally requires the
--    HMAC-verified callback's live lease (attempt + lease_token) and the exact object id/updated_at/mime/size fence.
--  * If an owner IS recorded (e.g. a future signed upload), it must equal the job user.
create or replace function public.get_analysis_cutout_fence(p_job_id uuid,p_object_key text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare j public.analysis_jobs; obj storage.objects; expected_prefix text;
begin
 if p_job_id is null or p_object_key is null or p_object_key='' then raise exception 'invalid_cutout_fence' using errcode='22023'; end if;
 select * into j from public.analysis_jobs where id=p_job_id;
 if not found then raise exception 'job_not_found' using errcode='P0002'; end if;
 expected_prefix:=j.user_id::text||'/'||j.batch_id::text||'/cutouts/';
 if p_object_key not like expected_prefix||'%' then raise exception 'invalid_cutout_path' using errcode='22023'; end if;
 select * into obj from storage.objects where bucket_id='closet-private' and name=p_object_key;
 if not found or (obj.owner_id is not null and obj.owner_id<>j.user_id::text)
 then raise exception 'cutout_asset_not_verified' using errcode='P0001'; end if;
 return jsonb_build_object('object_id',obj.id,'object_updated_at',obj.updated_at);
end $$;

create or replace function public.apply_analysis_result(
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
  -- category is one of the six, or JSON null when the BFF moved an out-of-six AI label to ai_category.
  or (jsonb_typeof(item->'attributes'->'category') is distinct from 'null' and coalesce(item->'attributes'->>'category','') not in ('outerwear','top','bottom','shoes','bag','accessory'))
  or (item->'attributes'?'ai_category' and (jsonb_typeof(item->'attributes'->'category') is distinct from 'null'
   or jsonb_typeof(item->'attributes'->'ai_category') is distinct from 'string' or length(item->'attributes'->>'ai_category') not between 1 and 40))
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
  -- Hosted storage.objects.owner_id is text. Server-key (worker) uploads leave it NULL; a set owner must be the job user.
  if not found or (obj.owner_id is not null and obj.owner_id<>j.user_id::text)
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

-- Mimic candidates: the same cutout objects (owner NULL for worker uploads, else the garment owner as text).
create or replace function public.create_my_mimic_job(p_post_id uuid,p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_owner_id uuid:=auth.uid(); stored public.idempotency_keys; request_fingerprint text;
 current_post public.feed_posts; j public.mimic_requests; source_count integer; matched_count integer:=0;
 pair record; assigned jsonb:='{}'::jsonb; used uuid[]:='{}'; matches jsonb; used_vector boolean:=false;
 min_score constant numeric:=0.2;
begin
 if v_owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 if p_post_id is null or p_idempotency_key is null or length(p_idempotency_key) not between 8 and 128
 or p_idempotency_key!~'^[A-Za-z0-9._:-]+$'
 then raise exception 'invalid_mimic_request' using errcode='22023'; end if;
 perform pg_advisory_xact_lock(hashtextextended('mimic:'||v_owner_id::text,0));
 select * into current_post from public.feed_posts where id=p_post_id and visibility='public' and deleted_at is null for share;
 if not found then raise exception 'feed_post_not_found' using errcode='P0002'; end if;
 request_fingerprint:=md5(p_post_id::text);
 insert into public.idempotency_keys(user_id,scope,key,request_hash)
 values(v_owner_id,'mimic_create',p_idempotency_key,request_fingerprint) on conflict do nothing;
 select * into stored from public.idempotency_keys
  where user_id=v_owner_id and scope='mimic_create' and key=p_idempotency_key for update;
 if stored.expires_at<=now() then
  delete from public.idempotency_keys where user_id=v_owner_id and scope='mimic_create' and key=p_idempotency_key;
  insert into public.idempotency_keys(user_id,scope,key,request_hash)
  values(v_owner_id,'mimic_create',p_idempotency_key,request_fingerprint) returning * into stored;
 end if;
 if stored.request_hash<>request_fingerprint then raise exception 'idempotency_conflict' using errcode='P0001'; end if;
 if stored.response_body is not null then return public.get_my_mimic_job((stored.response_body->>'job_id')::uuid); end if;
 select count(*) into source_count from public.feed_post_items where post_id=current_post.id and user_id=current_post.user_id;
 -- Legacy link-less posts cannot be mimicked (the image path is retired).
 if source_count not between 1 and 10 then raise exception 'feed_media_unavailable' using errcode='P0001'; end if;
 insert into public.mimic_requests(user_id,post_id,status,absolute_deadline)
 values(v_owner_id,current_post.id,'running',now()+interval '2 hours') returning * into j;
 insert into public.mimic_source_items(job_id,position,source_item_key,post_item_id,category)
 select j.id,i.position,'item:'||i.id::text,i.id,i.category
 from public.feed_post_items i where i.post_id=current_post.id and i.user_id=current_post.user_id order by i.position;
 insert into public.mimic_candidate_items(job_id,garment_id,asset_id,garment_version,bucket_id,object_key,
  storage_object_id,storage_updated_at,asset_verified_at)
 select j.id,g.id,a.id,g.version,a.bucket_id,a.object_key,o.id,o.updated_at,a.verified_at
 from public.garments g join public.garment_assets a on a.id=g.asset_id and a.user_id=g.user_id and a.kind='cutout'
 join storage.objects o on o.bucket_id=a.bucket_id and o.name=a.object_key and (o.owner_id is null or o.owner_id=g.user_id::text)
 where g.user_id=v_owner_id and g.deleted_at is null and a.verified_at is not null and a.deleted_at is null
 order by g.id for share of g,a,o;
 for pair in
  select q.item_id,q.garment_id,q.vector_score,
   case when q.vector_score is null then q.rule_score else round(0.5*q.rule_score+0.5*greatest(q.vector_score,0),4) end as score
  from (
   select i.id as item_id,i.position,g.id as garment_id,
    public.g10_mimic_rule_score(i.color_hex,i.pattern,i.aesthetic_scores,g.color_hex,g.pattern,
     coalesce((select jsonb_object_agg(s.aesthetic_id::text,s.score) from public.garment_aesthetic_scores s
      where s.garment_id=g.id and s.user_id=v_owner_id),'{}'::jsonb)) as rule_score,
    (select public.g10_vector_similarity(se.embedding,ce.embedding) from public.garment_embeddings se
      join public.garment_embeddings ce on ce.garment_id=g.id and ce.model_version=se.model_version
      where se.garment_id=i.garment_id) as vector_score
   from public.feed_post_items i
   join public.mimic_candidate_items c on c.job_id=j.id
   join public.garments g on g.id=c.garment_id and g.user_id=v_owner_id and g.category=i.category
   where i.post_id=current_post.id and i.user_id=current_post.user_id
  ) q order by score desc,q.position,q.garment_id
 loop
  continue when pair.score<min_score or (assigned ? pair.item_id::text) or pair.garment_id=any(used);
  assigned:=assigned||jsonb_build_object(pair.item_id::text,jsonb_build_object('garment_id',pair.garment_id,'similarity',pair.score));
  used:=used||pair.garment_id; matched_count:=matched_count+1;
  used_vector:=used_vector or pair.vector_score is not null;
 end loop;
 select jsonb_agg(jsonb_build_object('source_item_key',s.source_item_key,
  'garment_id',coalesce(assigned->s.post_item_id::text->'garment_id','null'::jsonb),
  'similarity',coalesce(assigned->s.post_item_id::text->'similarity','null'::jsonb),
  'reason',case when assigned ? s.post_item_id::text then '같은 카테고리에서 색·패턴·추구미가 가장 가까운 옷입니다.'
   else '현재 옷장에서 같은 카테고리의 비슷한 옷을 찾지 못했습니다.' end) order by s.position)
 into matches from public.mimic_source_items s where s.job_id=j.id;
 update public.mimic_requests set status=case when matched_count>0 then 'succeeded' else 'no_match' end,
  result=jsonb_build_object('matches',matches,'coverage',matched_count::numeric/source_count),
  model_version=case when used_vector then 'rule-v1-vector' else 'rule-v1' end,
  completed_at=now(),retention_expires_at=now()+interval '7 days' where id=j.id;
 update public.idempotency_keys set response_body=jsonb_build_object('job_id',j.id),response_status=202
  where user_id=v_owner_id and scope='mimic_create' and key=p_idempotency_key;
 return public.get_my_mimic_job(j.id);
end $$;

-- ---------------------------------------------------------------------------
-- 3. Column grants used by user-JWT REST reads (checked by scripts/validate-schema.mjs)
-- ---------------------------------------------------------------------------
-- GET /analysis-jobs/{id}: retryable needs max_attempts. GET /feed, /me/posts filter deleted_at=is.null.
grant select(max_attempts) on public.analysis_jobs to authenticated;
grant select(deleted_at) on public.feed_posts to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Storage insert policies without metadata (N3)
-- ---------------------------------------------------------------------------
-- Hosted Storage evaluates the insert policy when it issues a signed upload URL and on direct uploads without
-- metadata->>'size'/'mimetype', so the old size/mime predicates rejected every profile/OOTD/feed upload.
-- Policies now bind path + pending row only; complete_my_media_upload / complete_my_feed_media still compare
-- the stored object's owner, mimetype and size before verifying. (closet_source_upload never used metadata.)
drop policy if exists user_media_upload on storage.objects;
drop policy if exists feed_media_upload on storage.objects;
create function public.g11_can_upload_media(p_bucket text,p_object_key text)
returns boolean language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and exists(
  select 1 from public.media_uploads u where u.bucket_id=p_bucket and u.object_key=p_object_key and u.user_id=auth.uid()
   and u.verified_at is null and u.deleted_at is null)
$$;
create policy user_media_upload on storage.objects for insert to authenticated with check(
 bucket_id in ('profile-media','ootd-private') and split_part(name,'/',1)=(select auth.uid())::text
 and public.g11_can_upload_media(bucket_id,name)
);
-- g7_can_verify_feed_media = pending media row of the caller's own private, live post (no metadata).
create policy feed_media_upload on storage.objects for insert to authenticated with check(
 bucket_id='feed-private' and split_part(name,'/',1)=(select auth.uid())::text
 and public.g7_can_verify_feed_media(name)
);
drop function public.g9_can_upload_media(text,text,text,text);
drop function public.g7_can_upload_feed_media(text,text,text);
revoke all on function public.g11_can_upload_media(text,text) from public,anon,authenticated;
grant execute on function public.g11_can_upload_media(text,text) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Aesthetic scores on confirmation (N4)
-- ---------------------------------------------------------------------------
create or replace function public.confirm_my_garment_batch(p_batch_id uuid,p_draft_ids uuid[],p_versions jsonb,p_idempotency_key text)
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
  -- A null/unknown category (AI label outside the six) must be chosen by the user before saving.
  if coalesce(effective->>'category','') not in ('outerwear','top','bottom','shoes','bag','accessory') then raise exception 'invalid_category' using errcode='22023'; end if;
  insert into public.garments(user_id,source_draft_id,asset_id,category,color_hex,pattern,formality,activity,attributes,memo)
  values(owner_id,d.id,d.asset_id,effective->>'category',effective->>'color_hex',effective->>'pattern',
   nullif(effective->>'formality','')::numeric,nullif(effective->>'activity','')::numeric,effective,effective->>'note')
  returning id into garment_id;
  -- N4: carry the AI per-garment aesthetic scores (raw_prediction.aesthetic_scores = [{aesthetic_id,score}]) into
  -- garment_aesthetic_scores. Malformed/unknown entries are skipped; no scores = no rows (neutral 0.5 downstream).
  insert into public.garment_aesthetic_scores(user_id,garment_id,aesthetic_id,score,model_version)
  select owner_id,garment_id,a.id,max(s.score),coalesce(d.model_version,'unknown')
  from (select case when jsonb_typeof(e)='object' and coalesce(e->>'aesthetic_id','')~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
          then (e->>'aesthetic_id')::uuid end as aesthetic_id,
         case when jsonb_typeof(e->'score')='number' and (e->>'score')::numeric between 0 and 1 then (e->>'score')::numeric end as score
        from jsonb_array_elements(case when jsonb_typeof(d.raw_prediction->'aesthetic_scores')='array'
          then d.raw_prediction->'aesthetic_scores' else '[]'::jsonb end) e) s
  join public.aesthetics a on a.id=s.aesthetic_id
  where s.score is not null
  group by a.id;
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

-- ---------------------------------------------------------------------------
-- 6. Weather summary for the caller's own OOTD records (#8)
-- ---------------------------------------------------------------------------
-- Returns only snapshots referenced by the caller's ootd_entries; grid coordinates are never returned.
create function public.get_my_ootd_weather(p_snapshot_ids uuid[])
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare owner_id uuid:=auth.uid(); result jsonb;
begin
 if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 if p_snapshot_ids is null or cardinality(p_snapshot_ids)>100 then raise exception 'invalid_weather_snapshot' using errcode='22023'; end if;
 select coalesce(jsonb_agg(jsonb_build_object('weather_snapshot_id',w.id,'valid_at',w.valid_at,
   'temperature_c',w.payload->'temperature_c','feels_like_c',w.payload->'feels_like_c',
   'precipitation_type',w.payload->'precipitation_type','precipitation_probability',w.payload->'precipitation_probability')
   order by w.id),'[]'::jsonb)
 into result from public.weather_snapshots w
 where w.id=any(p_snapshot_ids)
  and exists(select 1 from public.ootd_entries o where o.user_id=owner_id and o.weather_snapshot_id=w.id);
 return result;
end $$;
revoke all on function public.get_my_ootd_weather(uuid[]) from public,anon,authenticated;
grant execute on function public.get_my_ootd_weather(uuid[]) to authenticated;
