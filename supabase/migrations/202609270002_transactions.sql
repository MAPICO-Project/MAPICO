alter table public.garment_drafts add column version integer not null default 1;
alter table public.garments add column version integer not null default 1;
alter table public.ootd_entries add column version integer not null default 1;
alter table public.ootd_entries add column note text check(length(note)<=1000);
alter table public.ootd_entries add column rating integer check(rating between 1 and 5);
alter table public.recommendation_requests add column rules_version text not null default 'draft-v0';
alter table public.recommendation_requests add column expires_at timestamptz not null default now()+interval '24 hours';
alter table public.recommendation_requests add column shortfall_reasons jsonb not null default '[]';
alter table public.outfit_recommendations add column explanation_source text not null default 'template' check(explanation_source in ('template','llm'));
alter table public.garments add column updated_at timestamptz not null default now();
alter table public.analysis_jobs add column updated_at timestamptz not null default now();
grant select(updated_at) on public.analysis_jobs to authenticated;
create function public.touch_updated_at() returns trigger language plpgsql set search_path='' as $$
begin new.updated_at:=now(); return new; end $$;
create trigger garment_updated before update on public.garments for each row execute function public.touch_updated_at();
create trigger job_updated before update on public.analysis_jobs for each row execute function public.touch_updated_at();
revoke all on function public.touch_updated_at() from public,anon,authenticated;
-- A job and its draft must belong to the same batch, even for service-role writes.
alter table public.analysis_jobs add constraint jobs_batch_identity unique(user_id,batch_id,id);
alter table public.garment_drafts add constraint draft_job_batch foreign key(user_id,batch_id,job_id)
 references public.analysis_jobs(user_id,batch_id,id);

create function public.confirm_garment_batch(p_batch_id uuid,p_draft_ids uuid[],p_versions jsonb)
returns setof public.garments language plpgsql security definer set search_path='' as $$
declare owner_id uuid:=auth.uid(); b public.garment_batches; d public.garment_drafts; attrs jsonb; n integer;
begin
 if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 if cardinality(p_draft_ids) is null or cardinality(p_draft_ids) not between 1 and 6
 or exists(select 1 from unnest(p_draft_ids) x where x is null)
 or (select count(distinct x) from unnest(p_draft_ids) x)<>cardinality(p_draft_ids)
 then raise exception 'invalid_draft_ids'; end if;
 select * into b from public.garment_batches where id=p_batch_id and user_id=owner_id for update;
 if not found then raise exception 'batch_not_found' using errcode='P0002'; end if;
 select count(*) into n from public.garment_drafts where user_id=owner_id and batch_id=p_batch_id and id=any(p_draft_ids);
 if n<>cardinality(p_draft_ids) then raise exception 'invalid_draft_ids'; end if;
 if b.status='confirmed' then
   if exists(select 1 from public.garment_drafts where batch_id=p_batch_id and ((status='confirmed')<>(id=any(p_draft_ids)))) then
    raise exception 'confirmation_conflict'; end if;
   return query select * from public.garments where user_id=owner_id and source_draft_id=any(p_draft_ids); return;
 end if;
 if b.status<>'review' then raise exception 'batch_not_reviewable'; end if;
 for d in select * from public.garment_drafts where user_id=owner_id and batch_id=p_batch_id and id=any(p_draft_ids) order by id for update loop
  if d.status not in ('predicted','edited') then raise exception 'invalid_draft_state'; end if;
  if p_versions is null or (p_versions->>d.id::text)::integer is distinct from d.version then raise exception 'version_conflict'; end if;
  if not exists(select 1 from public.garment_assets where id=d.asset_id and user_id=owner_id and verified_at is not null and deleted_at is null) then raise exception 'asset_not_ready'; end if;
  attrs:=d.raw_prediction||d.user_overrides;
  insert into public.garments(user_id,source_draft_id,asset_id,category,color_hex,pattern,formality,activity,attributes)
  values(owner_id,d.id,d.asset_id,attrs->>'category',attrs->>'color_hex',attrs->>'pattern',
   (attrs->>'formality')::numeric,(attrs->>'activity')::numeric,attrs);
 end loop;
 update public.garment_drafts set status=case when id=any(p_draft_ids) then 'confirmed' else 'rejected' end,version=version+1
 where batch_id=p_batch_id and user_id=owner_id;
 update public.garment_batches set status='confirmed' where id=p_batch_id;
 return query select * from public.garments where user_id=owner_id and source_draft_id=any(p_draft_ids);
end $$;

create function public.accept_outfit(p_outfit_id uuid,p_worn_on date) returns public.ootd_entries
language plpgsql security definer set search_path='' as $$
declare owner_id uuid:=auth.uid(); result public.ootd_entries;
begin
 if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 if p_worn_on is null then raise exception 'date_required'; end if;
 -- Serialize day-level acceptance, including when no OOTD row exists yet.
 perform pg_advisory_xact_lock(hashtextextended(owner_id::text||p_worn_on::text,0));
 select * into result from public.ootd_entries where user_id=owner_id and worn_on=p_worn_on;
 if found then
  if result.outfit_id<>p_outfit_id then raise exception 'ootd_date_conflict'; end if;
  return result;
 end if;
 if not exists(select 1 from public.outfit_recommendations o join public.recommendation_requests r on r.id=o.request_id
 where o.id=p_outfit_id and o.user_id=owner_id and r.status='ready' and r.target_date=p_worn_on and r.expires_at>now())
 then raise exception 'outfit_not_ready'; end if;
 if not exists(select 1 from public.outfit_items where outfit_id=p_outfit_id)
 or exists(select 1 from public.outfit_items i join public.garments g on g.id=i.garment_id where i.outfit_id=p_outfit_id and g.deleted_at is not null)
 then raise exception 'outfit_items_unavailable'; end if;
 insert into public.ootd_entries(user_id,outfit_id,worn_on,item_snapshot)
 select owner_id,p_outfit_id,p_worn_on,jsonb_agg(jsonb_build_object('garment_id',g.id,'category',g.category,'color_hex',g.color_hex,'pattern',g.pattern,'slot',i.slot))
 from public.outfit_items i join public.garments g on g.id=i.garment_id where i.outfit_id=p_outfit_id returning * into result;
 return result;
end $$;

-- Durable PostgreSQL queue. Trusted BFF/dispatcher only, never give external GPU workers a DB key.
create function public.claim_analysis_job(p_lease_seconds integer default 120) returns setof public.analysis_jobs
language plpgsql security definer set search_path='' as $$
declare selected uuid;
begin
 if p_lease_seconds is null or p_lease_seconds not between 30 and 900 then raise exception 'invalid_lease'; end if;
 update public.analysis_jobs set status='failed',error_code='ATTEMPTS_EXHAUSTED',completed_at=now(),lease_token=null,lease_expires_at=null
 where status='running' and lease_expires_at<now() and attempt>=max_attempts;
 update public.garment_batches b set status='failed' where b.status='processing'
 and exists(select 1 from public.analysis_jobs j where j.batch_id=b.id and j.status='failed');
 select id into selected from public.analysis_jobs where attempt<max_attempts and
 ((status='queued' and available_at<=now()) or (status='running' and lease_expires_at<now()))
 order by available_at,id for update skip locked limit 1;
 if selected is null then return; end if;
 return query update public.analysis_jobs set status='running',attempt=attempt+1,lease_token=gen_random_uuid(),
 lease_expires_at=now()+make_interval(secs=>p_lease_seconds),progress=0 where id=selected returning *;
end $$;

-- Completion is atomic with draft creation. Assets must first be uploaded and verified by BFF.
create function public.finish_analysis_job(p_job_id uuid,p_attempt integer,p_lease_token uuid,p_status text,p_items jsonb)
returns void language plpgsql security definer set search_path='' as $$
declare j public.analysis_jobs; item jsonb;
begin
 if p_attempt is null or p_lease_token is null then raise exception 'invalid_lease'; end if;
 select * into j from public.analysis_jobs where id=p_job_id for update;
 if not found then raise exception 'job_not_found'; end if;
 if j.status in ('succeeded','partial_failed','failed') and j.attempt=p_attempt and j.lease_token=p_lease_token then
  if j.result=jsonb_build_object('status',p_status,'items',p_items) then return; end if;
  raise exception 'callback_conflict';
 end if;
 if j.status<>'running' or j.attempt<>p_attempt or j.lease_token is distinct from p_lease_token or j.lease_expires_at<=now()
 then raise exception 'stale_lease'; end if;
 if p_status not in ('succeeded','partial_failed','failed') or p_status is null
 or jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items)>6 then raise exception 'invalid_result'; end if;
 if (p_status='failed' and jsonb_array_length(p_items)<>0) or (p_status in ('succeeded','partial_failed') and jsonb_array_length(p_items)=0)
 then raise exception 'invalid_result_count'; end if;
 for item in select value from jsonb_array_elements(p_items) loop
  if not exists(select 1 from public.garment_assets where id=(item->>'asset_id')::uuid and user_id=j.user_id and batch_id=j.batch_id
   and kind='cutout' and verified_at is not null and deleted_at is null) then raise exception 'invalid_asset'; end if;
  insert into public.garment_drafts(user_id,batch_id,job_id,item_index,asset_id,raw_prediction,model_version)
  values(j.user_id,j.batch_id,j.id,(item->>'item_index')::integer,(item->>'asset_id')::uuid,item->'raw_prediction',item->>'model_version');
 end loop;
 update public.analysis_jobs set status=p_status,progress=100,result=jsonb_build_object('status',p_status,'items',p_items),completed_at=now()
 where id=j.id;
 update public.garment_batches set status=case when p_status='failed' then 'failed' else 'review' end where id=j.batch_id;
end $$;
revoke all on function public.confirm_garment_batch(uuid,uuid[],jsonb),public.accept_outfit(uuid,date),public.claim_analysis_job(integer),public.finish_analysis_job(uuid,integer,uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.confirm_garment_batch(uuid,uuid[],jsonb),public.accept_outfit(uuid,date) to authenticated;
grant execute on function public.claim_analysis_job(integer),public.finish_analysis_job(uuid,integer,uuid,text,jsonb) to service_role;
