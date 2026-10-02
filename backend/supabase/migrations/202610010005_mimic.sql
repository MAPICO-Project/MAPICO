-- G8: durable mimic jobs with immutable feed/candidate snapshots and safe projections.

alter table public.mimic_requests add column attempt integer not null default 0 check(attempt>=0);
alter table public.mimic_requests add column max_attempts integer not null default 3 check(max_attempts between 1 and 10);
alter table public.mimic_requests add column available_at timestamptz not null default now();
alter table public.mimic_requests add column lease_token uuid;
alter table public.mimic_requests add column lease_expires_at timestamptz;
alter table public.mimic_requests add column error_code text;
alter table public.mimic_requests add column absolute_deadline timestamptz not null default now()+interval '2 hours';
alter table public.mimic_requests add column retention_expires_at timestamptz;
alter table public.mimic_requests add column updated_at timestamptz not null default now();
update public.mimic_requests set
 completed_at=coalesce(completed_at,created_at),
 retention_expires_at=coalesce(completed_at,created_at)+interval '7 days'
where status in ('succeeded','no_match','failed');
alter table public.mimic_requests add constraint mimic_terminal_retention check(
 (status in ('queued','running') and completed_at is null and retention_expires_at is null)
 or (status in ('succeeded','no_match','failed') and completed_at is not null and retention_expires_at is not null)
);
create trigger mimic_updated before update on public.mimic_requests
 for each row execute function public.touch_updated_at();
create unique index mimic_one_open_per_user_post on public.mimic_requests(user_id,post_id)
 where status in ('queued','running');
create index mimic_queue on public.mimic_requests(status,available_at,lease_expires_at,absolute_deadline);

create table public.mimic_source_items (
 job_id uuid not null references public.mimic_requests(id) on delete cascade,
 position integer not null check(position>=0),
 source_item_key text not null,
 feed_media_id uuid not null,
 bucket_id text not null check(bucket_id='feed-private'), object_key text not null,
 storage_object_id uuid not null, storage_updated_at timestamptz not null,
 content_type text not null check(content_type in ('image/jpeg','image/png','image/webp')),
 byte_size bigint not null check(byte_size between 1 and 20971520), verified_at timestamptz not null,
 primary key(job_id,source_item_key), unique(job_id,position), unique(job_id,feed_media_id),
 check(source_item_key='media:'||feed_media_id::text)
);
create table public.mimic_candidate_items (
 job_id uuid not null references public.mimic_requests(id) on delete cascade,
 garment_id uuid not null, asset_id uuid not null, garment_version integer not null check(garment_version>0),
 bucket_id text not null check(bucket_id='closet-private'), object_key text not null,
 storage_object_id uuid not null, storage_updated_at timestamptz not null,
 asset_verified_at timestamptz not null,
 primary key(job_id,garment_id), unique(job_id,asset_id)
);
alter table public.mimic_source_items enable row level security;
alter table public.mimic_candidate_items enable row level security;
revoke all on public.mimic_source_items,public.mimic_candidate_items from public,anon,authenticated;
grant all on public.mimic_source_items,public.mimic_candidate_items to service_role;

-- Worker event IDs are globally unique across users for this domain.
create unique index idempotency_mimic_callback_event
 on public.idempotency_keys(scope,key) where scope='mimic_callback';

create function public.get_my_mimic_job(p_job_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_owner_id uuid:=auth.uid(); j public.mimic_requests; safe_matches jsonb:='[]'::jsonb;
 safe_status text; safe_coverage numeric; safe_error jsonb; valid_count integer:=0; source_count integer:=0;
begin
 if v_owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 if p_job_id is null then raise exception 'invalid_job_id' using errcode='22023'; end if;
 update public.mimic_requests set status='failed',error_code='DEADLINE_EXCEEDED',completed_at=now(),
  retention_expires_at=now()+interval '7 days',lease_token=null,lease_expires_at=null
 where id=p_job_id and user_id=v_owner_id and status in ('queued','running') and absolute_deadline<=now();
 select * into j from public.mimic_requests where id=p_job_id and user_id=v_owner_id;
 if not found or (j.retention_expires_at is not null and j.retention_expires_at<=now())
 then raise exception 'mimic_job_not_found' using errcode='P0002'; end if;
 if not exists(select 1 from public.feed_posts p where p.id=j.post_id and p.visibility='public' and p.deleted_at is null)
 then raise exception 'mimic_job_not_found' using errcode='P0002'; end if;
 select count(*) into source_count from public.mimic_source_items where job_id=j.id;
 if j.status in ('succeeded','no_match') then
  select coalesce(jsonb_agg(jsonb_build_object(
   'source_item_key',x.value->>'source_item_key',
   'garment_id',case when available then x.value->'garment_id' else 'null'::jsonb end,
   'similarity',case when available then x.value->'similarity' else 'null'::jsonb end,
   'reason',case when (x.value->>'garment_id') is null then x.value->'reason'
    when available then x.value->'reason' else to_jsonb('현재 사용할 수 없는 옷입니다.'::text) end
  ) order by x.ord),'[]'::jsonb),count(*) filter(where available)
  into safe_matches,valid_count
  from jsonb_array_elements(coalesce(j.result->'matches','[]'::jsonb)) with ordinality x(value,ord)
  cross join lateral (
   select (x.value->>'garment_id') is not null and exists(
    select 1 from public.mimic_candidate_items c
    join public.garments g on g.id=c.garment_id and g.user_id=j.user_id and g.asset_id=c.asset_id and g.deleted_at is null
    join public.garment_assets a on a.id=c.asset_id and a.user_id=j.user_id and a.kind='cutout'
     and a.verified_at is not null and a.deleted_at is null and a.object_key=c.object_key
    join storage.objects o on o.bucket_id=c.bucket_id and o.name=c.object_key
     and o.id=c.storage_object_id and o.updated_at=c.storage_updated_at
    where c.job_id=j.id and c.garment_id=(x.value->>'garment_id')::uuid
   ) as available
  ) availability;
 end if;
 safe_status:=j.status;
 if j.status='succeeded' and valid_count=0 then safe_status:='no_match'; end if;
 if safe_status in ('succeeded','no_match') then
  safe_coverage:=case when source_count=0 then 0 else valid_count::numeric/source_count end;
 end if;
 if j.status='failed' then
  safe_error:=jsonb_build_object(
   'code',case when j.error_code in ('DEADLINE_EXCEEDED','ATTEMPTS_EXHAUSTED','SOURCE_UNAVAILABLE','CANDIDATE_SNAPSHOT_CHANGED','MODEL_UNAVAILABLE','WORKER_TIMEOUT') then j.error_code else 'MIMIC_FAILED' end,
   'message',case when j.error_code='DEADLINE_EXCEEDED' then '따라입기 요청 시간이 만료되었습니다.'
    when j.error_code='ATTEMPTS_EXHAUSTED' then '따라입기 처리를 완료하지 못했습니다.'
    when j.error_code='SOURCE_UNAVAILABLE' then '원본 게시물을 더 이상 사용할 수 없습니다.'
    else '따라입기 처리를 완료하지 못했습니다.' end,
   'retryable',j.error_code in ('MODEL_UNAVAILABLE','WORKER_TIMEOUT'));
 end if;
 return jsonb_build_object('id',j.id,'post_id',j.post_id,'status',safe_status,
  'matches',case when safe_status in ('succeeded','no_match') then safe_matches else '[]'::jsonb end,
  'model_version',case when safe_status in ('succeeded','no_match') then j.model_version else null end,
  'coverage',safe_coverage,'error',safe_error);
end $$;

create function public.create_my_mimic_job(p_post_id uuid,p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_owner_id uuid:=auth.uid(); stored public.idempotency_keys; request_fingerprint text;
 current_post public.feed_posts; existing_id uuid; j public.mimic_requests; source_count integer; open_count integer;
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
 update public.mimic_requests set status='failed',error_code='DEADLINE_EXCEEDED',completed_at=now(),
  retention_expires_at=now()+interval '7 days',lease_token=null,lease_expires_at=null
 where user_id=v_owner_id and status in ('queued','running') and absolute_deadline<=now();
 select id into existing_id from public.mimic_requests
  where user_id=v_owner_id and post_id=p_post_id and status in ('queued','running') for update;
 if found then
  update public.idempotency_keys set response_body=jsonb_build_object('job_id',existing_id),response_status=202
   where user_id=v_owner_id and scope='mimic_create' and key=p_idempotency_key;
  return public.get_my_mimic_job(existing_id);
 end if;
 select count(*) into open_count from public.mimic_requests where user_id=v_owner_id and status in ('queued','running');
 if open_count>=3 then raise exception 'mimic_open_limit' using errcode='P0001'; end if;
 select count(*) into source_count from public.feed_media m join storage.objects o
  on o.bucket_id=m.bucket_id and o.name=m.object_key and o.owner_id::text=m.user_id::text
  where m.post_id=current_post.id and m.user_id=current_post.user_id and m.verified_at is not null and m.deleted_at is null;
 if source_count not between 1 and 10 then raise exception 'feed_media_unavailable' using errcode='P0001'; end if;
 insert into public.mimic_requests(user_id,post_id,absolute_deadline)
 values(v_owner_id,current_post.id,now()+interval '2 hours') returning * into j;
 insert into public.mimic_source_items(job_id,position,source_item_key,feed_media_id,bucket_id,object_key,
  storage_object_id,storage_updated_at,content_type,byte_size,verified_at)
 select j.id,m.position,'media:'||m.id::text,m.id,m.bucket_id,m.object_key,o.id,o.updated_at,m.content_type,m.byte_size,m.verified_at
 from public.feed_media m join storage.objects o on o.bucket_id=m.bucket_id and o.name=m.object_key and o.owner_id::text=m.user_id::text
 where m.post_id=current_post.id and m.user_id=current_post.user_id and m.verified_at is not null and m.deleted_at is null
 order by m.position for share of m,o;
 if (select count(*) from public.mimic_source_items where job_id=j.id)<>source_count
 then raise exception 'feed_media_changed' using errcode='P0001'; end if;
 insert into public.mimic_candidate_items(job_id,garment_id,asset_id,garment_version,bucket_id,object_key,
  storage_object_id,storage_updated_at,asset_verified_at)
 select j.id,g.id,a.id,g.version,a.bucket_id,a.object_key,o.id,o.updated_at,a.verified_at
 from public.garments g join public.garment_assets a on a.id=g.asset_id and a.user_id=g.user_id and a.kind='cutout'
 join storage.objects o on o.bucket_id=a.bucket_id and o.name=a.object_key and o.owner_id::text=g.user_id::text
 where g.user_id=v_owner_id and g.deleted_at is null and a.verified_at is not null and a.deleted_at is null
 order by g.id for share of g,a,o;
 update public.idempotency_keys set response_body=jsonb_build_object('job_id',j.id),response_status=202
  where user_id=v_owner_id and scope='mimic_create' and key=p_idempotency_key;
 return public.get_my_mimic_job(j.id);
end $$;

create function public.claim_mimic_job(p_lease_seconds integer default 120)
returns jsonb language plpgsql security definer set search_path='' as $$
declare selected uuid; j public.mimic_requests; current_post public.feed_posts; locked_count integer; expected_count integer;
 source_items jsonb; candidates jsonb;
begin
 if p_lease_seconds is null or p_lease_seconds not between 30 and 900
 then raise exception 'invalid_lease' using errcode='22023'; end if;
 update public.mimic_requests set status='failed',error_code='DEADLINE_EXCEEDED',completed_at=now(),
  retention_expires_at=now()+interval '7 days',lease_token=null,lease_expires_at=null
 where status in ('queued','running') and absolute_deadline<=now();
 update public.mimic_requests set status='failed',error_code='ATTEMPTS_EXHAUSTED',completed_at=now(),
  retention_expires_at=now()+interval '7 days',lease_token=null,lease_expires_at=null
 where status='running' and lease_expires_at<=now() and attempt>=max_attempts;
 select id into selected from public.mimic_requests where attempt<max_attempts and absolute_deadline>now()
  and ((status='queued' and available_at<=now()) or (status='running' and lease_expires_at<=now()))
 order by available_at,id for update skip locked limit 1;
 if selected is null then return null; end if;
 select * into j from public.mimic_requests where id=selected for update;
 select * into current_post from public.feed_posts where id=j.post_id for share;
 if not found or current_post.visibility<>'public' or current_post.deleted_at is not null then
  update public.mimic_requests set status='failed',error_code='SOURCE_UNAVAILABLE',completed_at=now(),
   retention_expires_at=now()+interval '7 days',lease_token=null,lease_expires_at=null where id=j.id;
  return null;
 end if;
 select count(*) into expected_count from public.mimic_source_items where job_id=j.id;
 perform m.id from public.mimic_source_items s
 join public.feed_media m on m.id=s.feed_media_id and m.post_id=j.post_id
 join storage.objects o on o.bucket_id=s.bucket_id and o.name=s.object_key
 where s.job_id=j.id order by s.position for share of m,o;
 select count(*),coalesce(jsonb_agg(jsonb_build_object('source_item_key',s.source_item_key,'position',s.position,
  'bucket_id',s.bucket_id,'object_key',s.object_key,'storage_object_id',s.storage_object_id,
  'storage_updated_at',s.storage_updated_at,'content_type',s.content_type,'byte_size',s.byte_size) order by s.position),'[]'::jsonb)
 into locked_count,source_items
 from public.mimic_source_items s join public.feed_media m on m.id=s.feed_media_id and m.post_id=j.post_id
  and m.bucket_id=s.bucket_id and m.object_key=s.object_key and m.verified_at=s.verified_at and m.deleted_at is null
 join storage.objects o on o.bucket_id=s.bucket_id and o.name=s.object_key and o.id=s.storage_object_id and o.updated_at=s.storage_updated_at
 where s.job_id=j.id;
 if locked_count<>expected_count then
  update public.mimic_requests set status='failed',error_code='SOURCE_UNAVAILABLE',completed_at=now(),
   retention_expires_at=now()+interval '7 days',lease_token=null,lease_expires_at=null where id=j.id;
  return null;
 end if;
 select count(*) into expected_count from public.mimic_candidate_items where job_id=j.id;
 perform g.id from public.mimic_candidate_items c
 join public.garments g on g.id=c.garment_id and g.user_id=j.user_id
 join public.garment_assets a on a.id=c.asset_id and a.user_id=j.user_id
 join storage.objects o on o.bucket_id=c.bucket_id and o.name=c.object_key
 where c.job_id=j.id order by c.garment_id for share of g,a,o;
 select count(*),coalesce(jsonb_agg(jsonb_build_object('garment_id',c.garment_id,'asset_id',c.asset_id,
  'garment_version',c.garment_version,'bucket_id',c.bucket_id,'object_key',c.object_key,
  'storage_object_id',c.storage_object_id,'storage_updated_at',c.storage_updated_at) order by c.garment_id),'[]'::jsonb)
 into locked_count,candidates
 from public.mimic_candidate_items c join public.garments g on g.id=c.garment_id and g.user_id=j.user_id
  and g.asset_id=c.asset_id and g.version=c.garment_version and g.deleted_at is null
 join public.garment_assets a on a.id=c.asset_id and a.user_id=j.user_id and a.kind='cutout'
  and a.verified_at=c.asset_verified_at and a.deleted_at is null and a.object_key=c.object_key
 join storage.objects o on o.bucket_id=c.bucket_id and o.name=c.object_key and o.id=c.storage_object_id and o.updated_at=c.storage_updated_at
 where c.job_id=j.id;
 if locked_count<>expected_count then
  update public.mimic_requests set status='failed',error_code='CANDIDATE_SNAPSHOT_CHANGED',completed_at=now(),
   retention_expires_at=now()+interval '7 days',lease_token=null,lease_expires_at=null where id=j.id;
  return null;
 end if;
 update public.mimic_requests set status='running',attempt=attempt+1,lease_token=gen_random_uuid(),
  lease_expires_at=now()+make_interval(secs=>p_lease_seconds) where id=j.id returning * into j;
 return jsonb_build_object('id',j.id,'user_id',j.user_id,'post_id',j.post_id,'attempt',j.attempt,
  'lease_token',j.lease_token,'lease_expires_at',j.lease_expires_at,'absolute_deadline',j.absolute_deadline,
  'source_items',source_items,'candidates',candidates);
end $$;

create function public.inspect_mimic_callback(p_event_id uuid,p_job_id uuid,p_attempt integer,p_payload_hash text)
returns jsonb language plpgsql security definer set search_path='' as $$
declare stored public.idempotency_keys; j public.mimic_requests; event_fingerprint text;
begin
 if p_event_id is null or p_job_id is null or p_attempt is null or p_attempt<1
 or p_payload_hash is null or length(p_payload_hash)<>64 or p_payload_hash!~'^[0-9a-f]{64}$'
 then raise exception 'invalid_callback' using errcode='22023'; end if;
 event_fingerprint:=p_job_id::text||':'||p_attempt::text||':'||p_payload_hash;
 select * into stored from public.idempotency_keys where scope='mimic_callback' and key=p_event_id::text;
 if found then
  if stored.request_hash<>event_fingerprint then raise exception 'callback_conflict' using errcode='P0001'; end if;
  if stored.response_body is null then raise exception 'callback_in_progress' using errcode='P0001'; end if;
  return jsonb_build_object('replayed',true,'response',stored.response_body);
 end if;
 select * into j from public.mimic_requests where id=p_job_id;
 if not found then raise exception 'mimic_job_not_found' using errcode='P0002'; end if;
 return jsonb_build_object('replayed',false,'job',jsonb_build_object('id',j.id,'user_id',j.user_id,
  'post_id',j.post_id,'status',j.status,'attempt',j.attempt,'lease_token',j.lease_token,
  'lease_expires_at',j.lease_expires_at,'absolute_deadline',j.absolute_deadline));
end $$;

create function public.apply_mimic_result(
 p_event_id uuid,p_job_id uuid,p_attempt integer,p_lease_token uuid,p_payload_hash text,
 p_status text,p_model_version text,p_matches jsonb,p_coverage numeric,p_error_code text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare j public.mimic_requests; stored public.idempotency_keys; current_post public.feed_posts; item jsonb;
 event_fingerprint text; response jsonb; source_count integer; matched_count integer:=0; locked_count integer; expected_count integer;
 candidate public.mimic_candidate_items;
begin
 if p_event_id is null or p_job_id is null or p_attempt is null or p_attempt<1 or p_lease_token is null
 or p_payload_hash is null or length(p_payload_hash)<>64 or p_payload_hash!~'^[0-9a-f]{64}$'
 or p_status not in ('succeeded','no_match','failed') or jsonb_typeof(p_matches) is distinct from 'array'
 then raise exception 'invalid_callback' using errcode='22023'; end if;
 event_fingerprint:=p_job_id::text||':'||p_attempt::text||':'||p_payload_hash;
 -- Durable replay is resolved before mutable lease state.
 select * into stored from public.idempotency_keys where scope='mimic_callback' and key=p_event_id::text for update;
 if found then
  if stored.request_hash<>event_fingerprint then raise exception 'callback_conflict' using errcode='P0001'; end if;
  if stored.response_body is not null then return jsonb_build_object('job_id',p_job_id,'event_id',p_event_id,'applied',false); end if;
 end if;
 select * into j from public.mimic_requests where id=p_job_id for update;
 if not found then raise exception 'mimic_job_not_found' using errcode='P0002'; end if;
 insert into public.idempotency_keys(user_id,scope,key,request_hash,expires_at)
 values(j.user_id,'mimic_callback',p_event_id::text,event_fingerprint,'infinity'::timestamptz) on conflict do nothing;
 select * into stored from public.idempotency_keys where scope='mimic_callback' and key=p_event_id::text for update;
 if stored.user_id<>j.user_id or stored.request_hash<>event_fingerprint then raise exception 'callback_conflict' using errcode='P0001'; end if;
 if stored.response_body is not null then return jsonb_build_object('job_id',p_job_id,'event_id',p_event_id,'applied',false); end if;
 if j.status<>'running' or j.attempt<>p_attempt or j.lease_token is distinct from p_lease_token
 or j.lease_expires_at<=now() or j.absolute_deadline<=now()
 then raise exception 'stale_lease' using errcode='P0001'; end if;
 -- Stable lock order: source post, source media/object fences, candidate garment/asset/object fences.
 select * into current_post from public.feed_posts where id=j.post_id for share;
 if not found or current_post.visibility<>'public' or current_post.deleted_at is not null then
  update public.mimic_requests set status='failed',error_code='SOURCE_UNAVAILABLE',result=null,model_version=null,
   completed_at=now(),retention_expires_at=now()+interval '7 days',lease_token=null,lease_expires_at=null where id=j.id;
  response:=jsonb_build_object('job_id',j.id,'event_id',p_event_id,'applied',true);
  update public.idempotency_keys set response_body=response,response_status=200
   where user_id=j.user_id and scope='mimic_callback' and key=p_event_id::text;
  return response;
 end if;
 select count(*) into expected_count from public.mimic_source_items where job_id=j.id;
 perform m.id from public.mimic_source_items s
 join public.feed_media m on m.id=s.feed_media_id and m.post_id=j.post_id
 join storage.objects o on o.bucket_id=s.bucket_id and o.name=s.object_key
 where s.job_id=j.id order by s.position for share of m,o;
 select count(*) into locked_count from public.mimic_source_items s
 join public.feed_media m on m.id=s.feed_media_id and m.post_id=j.post_id and m.bucket_id=s.bucket_id
  and m.object_key=s.object_key and m.verified_at=s.verified_at and m.deleted_at is null
 join storage.objects o on o.bucket_id=s.bucket_id and o.name=s.object_key and o.id=s.storage_object_id and o.updated_at=s.storage_updated_at
 where s.job_id=j.id;
 if locked_count<>expected_count then
  update public.mimic_requests set status='failed',error_code='SOURCE_UNAVAILABLE',result=null,model_version=null,
   completed_at=now(),retention_expires_at=now()+interval '7 days',lease_token=null,lease_expires_at=null where id=j.id;
  response:=jsonb_build_object('job_id',j.id,'event_id',p_event_id,'applied',true);
  update public.idempotency_keys set response_body=response,response_status=200
   where user_id=j.user_id and scope='mimic_callback' and key=p_event_id::text;
  return response;
 end if;
 -- Lock every still-current candidate in deterministic order before validating matches.
 perform g.id from public.mimic_candidate_items c
 join public.garments g on g.id=c.garment_id and g.user_id=j.user_id
 join public.garment_assets a on a.id=c.asset_id and a.user_id=j.user_id
 join storage.objects o on o.bucket_id=c.bucket_id and o.name=c.object_key
 where c.job_id=j.id order by c.garment_id for share of g,a,o;
 select count(*) into source_count from public.mimic_source_items where job_id=j.id;
 if p_status in ('succeeded','no_match') then
  if p_model_version is null or p_model_version!~'^[A-Za-z0-9._:-]{1,100}$'
  or jsonb_array_length(p_matches)<>source_count
  or (select count(distinct value->>'source_item_key') from jsonb_array_elements(p_matches))<>source_count
  then raise exception 'invalid_mimic_result' using errcode='22023'; end if;
 else
  if jsonb_array_length(p_matches)<>0 or p_model_version is not null or p_coverage is not null
  or p_error_code not in ('MODEL_UNAVAILABLE','WORKER_TIMEOUT','INTERNAL_ERROR')
  then raise exception 'invalid_mimic_failure' using errcode='22023'; end if;
 end if;
 for item in select value from jsonb_array_elements(p_matches) loop
  if jsonb_typeof(item) is distinct from 'object' or (select count(*) from jsonb_object_keys(item))<>4
  or coalesce(item->>'source_item_key','')='' or length(item->>'source_item_key')>50
  or not exists(select 1 from public.mimic_source_items s where s.job_id=j.id and s.source_item_key=item->>'source_item_key')
  or jsonb_typeof(item->'reason') is distinct from 'string' or length(item->>'reason')>500
  then raise exception 'invalid_mimic_match' using errcode='22023'; end if;
  if item->>'garment_id' is null then
   if jsonb_typeof(item->'garment_id') is distinct from 'null' or jsonb_typeof(item->'similarity') is distinct from 'null'
   then raise exception 'invalid_mimic_match' using errcode='22023'; end if;
  else
   if (item->>'garment_id')!~'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
   or jsonb_typeof(item->'similarity') is distinct from 'number'
   or (item->>'similarity')::numeric not between -1 and 1
   then raise exception 'invalid_mimic_match' using errcode='22023'; end if;
   select * into candidate from public.mimic_candidate_items
    where job_id=j.id and garment_id=(item->>'garment_id')::uuid;
   if not found then raise exception 'invalid_candidate_snapshot' using errcode='22023'; end if;
   if not exists(select 1 from public.garments g join public.garment_assets a on a.id=g.asset_id and a.user_id=g.user_id
    join storage.objects o on o.bucket_id=a.bucket_id and o.name=a.object_key
    where g.id=candidate.garment_id and g.user_id=j.user_id and g.asset_id=candidate.asset_id
     and g.version=candidate.garment_version and g.deleted_at is null and a.kind='cutout'
     and a.verified_at=candidate.asset_verified_at and a.deleted_at is null and a.object_key=candidate.object_key
     and o.id=candidate.storage_object_id and o.updated_at=candidate.storage_updated_at)
   then raise exception 'candidate_fence_changed' using errcode='P0001'; end if;
   matched_count:=matched_count+1;
  end if;
 end loop;
 if p_status in ('succeeded','no_match') and ((p_status='succeeded' and matched_count=0)
 or (p_status='no_match' and matched_count<>0)
 or p_coverage is null or p_coverage<>matched_count::numeric/source_count)
 then raise exception 'invalid_mimic_coverage' using errcode='22023'; end if;
 update public.mimic_requests set status=p_status,result=jsonb_build_object('matches',p_matches,'coverage',p_coverage),
  model_version=p_model_version,error_code=case when p_status='failed' then p_error_code else null end,
  completed_at=now(),retention_expires_at=now()+interval '7 days',lease_token=null,lease_expires_at=null where id=j.id;
 response:=jsonb_build_object('job_id',j.id,'event_id',p_event_id,'applied',true);
 update public.idempotency_keys set response_body=response,response_status=200
  where user_id=j.user_id and scope='mimic_callback' and key=p_event_id::text;
 return response;
end $$;

drop policy if exists owner_read on public.mimic_requests;
revoke select on public.mimic_requests from authenticated;
revoke select(id,user_id,post_id,status,created_at,completed_at) on public.mimic_requests from authenticated;
revoke insert,update,delete on public.mimic_requests from authenticated;
revoke all on function public.create_my_mimic_job(uuid,text),public.get_my_mimic_job(uuid),
 public.claim_mimic_job(integer),public.inspect_mimic_callback(uuid,uuid,integer,text),
 public.apply_mimic_result(uuid,uuid,integer,uuid,text,text,text,jsonb,numeric,text)
 from public,anon,authenticated;
grant execute on function public.create_my_mimic_job(uuid,text),public.get_my_mimic_job(uuid) to authenticated;
grant execute on function public.claim_mimic_job(integer),public.inspect_mimic_callback(uuid,uuid,integer,text),
 public.apply_mimic_result(uuid,uuid,integer,uuid,text,text,text,jsonb,numeric,text) to service_role;
