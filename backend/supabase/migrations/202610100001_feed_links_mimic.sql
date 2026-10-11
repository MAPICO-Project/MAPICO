-- 2026-10-10 decision (Track A): a feed post links >=1 of its author's own closet items, and
-- Styling Mimic matches those linked items against the viewer's closet. The representative
-- image is no longer re-analysed. Existing migrations remain immutable.
--
-- Privacy boundary: closet originals (garment_assets, closet-private) are never projected.
-- A link stores a display/matching snapshot (category, color, pattern, aesthetic scores) so the
-- post survives a later closet deletion. Only id/position/category reach other members.

-- 1. Post <-> closet item links -------------------------------------------------------------
create table public.feed_post_items (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null,
 post_id uuid not null,
 -- Live link to the author's own garment. Same user_id in both FKs => another member's garment
 -- can never be linked. Hard-deleting the garment only clears the link; the snapshot remains.
 garment_id uuid,
 position integer not null check(position between 0 and 9),
 category text not null check(category in ('outerwear','top','bottom','shoes','bag','accessory')),
 color_hex text check(color_hex ~ '^#[0-9A-Fa-f]{6}$'),
 pattern text check(length(pattern)<=100),
 aesthetic_scores jsonb not null default '{}' check(jsonb_typeof(aesthetic_scores)='object'),
 created_at timestamptz not null default now(),
 unique(post_id,position),
 foreign key(user_id,post_id) references public.feed_posts(user_id,id) on delete cascade,
 foreign key(user_id,garment_id) references public.garments(user_id,id) on delete set null (garment_id)
);
create unique index feed_post_items_one_garment on public.feed_post_items(post_id,garment_id) where garment_id is not null;
create index feed_post_items_garment on public.feed_post_items(garment_id) where garment_id is not null;
alter table public.feed_post_items enable row level security;
revoke all on public.feed_post_items from public,anon,authenticated;
grant all on public.feed_post_items to service_role;

-- DB-level ">=1 link": checked at commit so a write path can insert the post then its links.
-- Fires on post insert, on publish (visibility->public) and on link delete/move. Soft-deleted
-- posts are exempt. Legacy posts without links can still be hidden or deleted, never published.
create function public.g10_check_post_items() returns trigger
language plpgsql security definer set search_path='' as $$
declare target uuid; current_post public.feed_posts;
begin
 if tg_table_name='feed_posts' then target:=new.id; else target:=old.post_id; end if;
 select * into current_post from public.feed_posts where id=target;
 if not found or current_post.deleted_at is not null then return null; end if;
 if tg_table_name='feed_posts' and tg_op='UPDATE' and current_post.visibility<>'public' then return null; end if;
 if not exists(select 1 from public.feed_post_items where post_id=target) then
  raise exception 'feed_items_required' using errcode='23514';
 end if;
 return null;
end $$;
create constraint trigger feed_post_items_on_insert after insert on public.feed_posts
 deferrable initially deferred for each row execute function public.g10_check_post_items();
create constraint trigger feed_post_items_on_publish after update of visibility on public.feed_posts
 deferrable initially deferred for each row when (new.visibility='public') execute function public.g10_check_post_items();
create constraint trigger feed_post_items_keep_one after delete or update of post_id on public.feed_post_items
 deferrable initially deferred for each row execute function public.g10_check_post_items();

-- Replace a post's links with an owner-checked snapshot of p_garment_ids (order = position).
create function public.g10_link_post_items(p_owner uuid,p_post_id uuid,p_garment_ids uuid[])
returns integer language plpgsql security definer set search_path='' as $$
declare locked record; locked_count integer:=0;
begin
 if p_owner is null or p_post_id is null or p_garment_ids is null
 or cardinality(p_garment_ids) not between 1 and 10 or array_position(p_garment_ids,null) is not null
 or cardinality(p_garment_ids)<>(select count(distinct x) from unnest(p_garment_ids) x)
 then raise exception 'invalid_garment_ids' using errcode='22023'; end if;
 for locked in
  select g.id,g.deleted_at,a.verified_at,a.deleted_at as asset_deleted_at
  from public.garments g join public.garment_assets a on a.id=g.asset_id and a.user_id=g.user_id
  where g.user_id=p_owner and g.id=any(p_garment_ids) order by g.id for share of g,a
 loop
  locked_count:=locked_count+1;
  if locked.deleted_at is not null or locked.verified_at is null or locked.asset_deleted_at is not null
  then raise exception 'garment_unavailable' using errcode='P0001'; end if;
 end loop;
 -- Another member's (or a missing) garment is indistinguishable from "not found".
 if locked_count<>cardinality(p_garment_ids) then raise exception 'garment_not_found' using errcode='P0002'; end if;
 delete from public.feed_post_items where post_id=p_post_id and user_id=p_owner;
 insert into public.feed_post_items(user_id,post_id,garment_id,position,category,color_hex,pattern,aesthetic_scores)
 select p_owner,p_post_id,g.id,(u.ord-1)::integer,g.category,g.color_hex,left(nullif(btrim(g.pattern),''),100),
  coalesce((select jsonb_object_agg(s.aesthetic_id::text,s.score) from public.garment_aesthetic_scores s
   where s.garment_id=g.id and s.user_id=p_owner),'{}'::jsonb)
 from unnest(p_garment_ids) with ordinality u(id,ord) join public.garments g on g.id=u.id and g.user_id=p_owner
 order by u.ord;
 return cardinality(p_garment_ids);
end $$;

-- Garment IDs of an owned OOTD that are still linkable (owned, not deleted, verified asset).
create function public.g10_ootd_linkable_garments(p_owner uuid,p_ootd_id uuid)
returns uuid[] language sql stable security definer set search_path='' as $$
 select coalesce(array_agg(g.id order by x.ord),'{}'::uuid[])
 from public.ootd_entries o
 cross join lateral jsonb_array_elements(case when jsonb_typeof(o.item_snapshot)='array' then o.item_snapshot else '[]'::jsonb end)
  with ordinality x(value,ord)
 join public.garments g on g.user_id=p_owner and g.deleted_at is null
  and g.id=case when coalesce(x.value->>'garment_id','')~'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
   then (x.value->>'garment_id')::uuid end
 join public.garment_assets a on a.id=g.asset_id and a.user_id=g.user_id and a.verified_at is not null and a.deleted_at is null
 where o.id=p_ootd_id and o.user_id=p_owner
$$;

-- Backfill: legacy posts created from an OOTD get that OOTD's still-available items (max 10).
-- Posts with nothing derivable stay link-less (legacy); they cannot be published again.
insert into public.feed_post_items(user_id,post_id,garment_id,position,category,color_hex,pattern,aesthetic_scores)
select p.user_id,p.id,g.id,(l.ord-1)::integer,g.category,g.color_hex,left(nullif(btrim(g.pattern),''),100),
 coalesce((select jsonb_object_agg(s.aesthetic_id::text,s.score) from public.garment_aesthetic_scores s
  where s.garment_id=g.id and s.user_id=p.user_id),'{}'::jsonb)
from public.feed_posts p
cross join lateral unnest((public.g10_ootd_linkable_garments(p.user_id,p.source_ootd_id))[1:10]) with ordinality l(id,ord)
join public.garments g on g.id=l.id
where p.source_ootd_id is not null and p.deleted_at is null
 and not exists(select 1 from public.feed_post_items i where i.post_id=p.id);

-- 2. Feed write RPCs with links (signatures change; old overloads are dropped) -------------
drop function public.create_my_feed_post(uuid,text,uuid,text,numeric,text);
create function public.create_my_feed_post(
 p_source_ootd_id uuid,p_caption text,p_aesthetic_id uuid,p_weather_code text,
 p_temperature_c numeric,p_idempotency_key text,p_garment_ids uuid[]
) returns jsonb language plpgsql security definer set search_path='' as $$
declare owner_id uuid:=auth.uid(); stored public.idempotency_keys; result public.feed_posts;
 request_fingerprint text; response jsonb; normalized_weather text:=coalesce(p_weather_code,'unknown');
 link_ids uuid[];
begin
 if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 if p_caption is null or length(p_caption)>2000 or p_aesthetic_id is null
 or normalized_weather not in ('clear','cloudy','rain','snow','wind','unknown')
 or (p_temperature_c is not null and p_temperature_c not between -90 and 60)
 or p_idempotency_key is null or length(p_idempotency_key) not between 8 and 128
 or p_idempotency_key!~'^[A-Za-z0-9._:-]+$'
 then raise exception 'invalid_feed_post' using errcode='22023'; end if;
 -- Explicit links: 1..10 distinct IDs. Omitted links are allowed only when importing an OOTD.
 if (p_garment_ids is null and p_source_ootd_id is null) or (p_garment_ids is not null and (
  cardinality(p_garment_ids) not between 1 and 10 or array_position(p_garment_ids,null) is not null
  or cardinality(p_garment_ids)<>(select count(distinct x) from unnest(p_garment_ids) x)))
 then raise exception 'invalid_garment_ids' using errcode='22023'; end if;
 if not exists(select 1 from public.aesthetics where id=p_aesthetic_id and active)
 then raise exception 'aesthetic_not_found' using errcode='P0002'; end if;
 if p_source_ootd_id is not null and not exists(
  select 1 from public.ootd_entries where id=p_source_ootd_id and user_id=owner_id
 ) then raise exception 'ootd_not_found' using errcode='P0002'; end if;
 request_fingerprint:=md5(coalesce(p_source_ootd_id::text,'<null>')||':'||p_caption||':'||p_aesthetic_id::text||':'||normalized_weather||':'||coalesce(p_temperature_c::text,'<null>')
  ||':'||coalesce(array_to_string(p_garment_ids,','),'<ootd>'));
 insert into public.idempotency_keys(user_id,scope,key,request_hash)
 values(owner_id,'feed_post_create',p_idempotency_key,request_fingerprint) on conflict do nothing;
 select * into stored from public.idempotency_keys
  where user_id=owner_id and scope='feed_post_create' and key=p_idempotency_key for update;
 if stored.expires_at<=now() then
  delete from public.idempotency_keys where user_id=owner_id and scope='feed_post_create' and key=p_idempotency_key;
  insert into public.idempotency_keys(user_id,scope,key,request_hash)
  values(owner_id,'feed_post_create',p_idempotency_key,request_fingerprint) returning * into stored;
 end if;
 if stored.request_hash<>request_fingerprint then raise exception 'idempotency_conflict' using errcode='P0001'; end if;
 if stored.response_body is not null then
  return jsonb_build_object('post_id',stored.response_body->>'post_id','replayed',true);
 end if;
 link_ids:=coalesce(p_garment_ids,(public.g10_ootd_linkable_garments(owner_id,p_source_ootd_id))[1:10]);
 if cardinality(link_ids)=0 then raise exception 'garment_unavailable' using errcode='P0001'; end if;
 insert into public.feed_posts(user_id,source_ootd_id,caption,aesthetic_id,weather_code,temperature_c,visibility)
 values(owner_id,p_source_ootd_id,p_caption,p_aesthetic_id,normalized_weather,p_temperature_c,'private') returning * into result;
 perform public.g10_link_post_items(owner_id,result.id,link_ids);
 response:=jsonb_build_object('post_id',result.id);
 update public.idempotency_keys set response_body=response,response_status=201
  where user_id=owner_id and scope='feed_post_create' and key=p_idempotency_key;
 return response||jsonb_build_object('replayed',false);
end $$;

drop function public.update_my_feed_post(uuid,boolean,text,boolean,uuid,boolean,text);
create function public.update_my_feed_post(
 p_post_id uuid,p_has_caption boolean,p_caption text,p_has_aesthetic_id boolean,p_aesthetic_id uuid,
 p_has_visibility boolean,p_visibility text,p_has_garment_ids boolean,p_garment_ids uuid[]
) returns jsonb language plpgsql security definer set search_path='' as $$
declare owner_id uuid:=auth.uid(); current_row public.feed_posts; final_visibility text;
begin
 if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 if p_post_id is null or p_has_caption is null or p_has_aesthetic_id is null or p_has_visibility is null
 or p_has_garment_ids is null or not(p_has_caption or p_has_aesthetic_id or p_has_visibility or p_has_garment_ids)
 then raise exception 'invalid_feed_patch' using errcode='22023'; end if;
 if p_has_caption and (p_caption is null or length(p_caption)>2000)
 then raise exception 'invalid_caption' using errcode='22023'; end if;
 -- An edit can never leave a post with fewer than one link.
 if p_has_garment_ids and (p_garment_ids is null or cardinality(p_garment_ids) not between 1 and 10)
 then raise exception 'invalid_garment_ids' using errcode='22023'; end if;
 if p_has_aesthetic_id and (p_aesthetic_id is null or not exists(
  select 1 from public.aesthetics where id=p_aesthetic_id and active
 )) then raise exception 'aesthetic_not_found' using errcode='P0002'; end if;
 if p_has_visibility and p_visibility not in ('private','public')
 then raise exception 'invalid_visibility' using errcode='22023'; end if;
 select * into current_row from public.feed_posts
  where id=p_post_id and user_id=owner_id and deleted_at is null for update;
 if not found then raise exception 'feed_post_not_found' using errcode='P0002'; end if;
 if p_has_garment_ids then perform public.g10_link_post_items(owner_id,current_row.id,p_garment_ids); end if;
 final_visibility:=case when p_has_visibility then p_visibility else current_row.visibility end;
 if final_visibility='public' and (
  not exists(select 1 from public.feed_media where post_id=current_row.id and user_id=owner_id and verified_at is not null and deleted_at is null)
  or exists(select 1 from public.feed_media where post_id=current_row.id and user_id=owner_id and verified_at is null and deleted_at is null)
 ) then raise exception 'feed_media_required' using errcode='P0001'; end if;
 if final_visibility='public' and not exists(select 1 from public.feed_post_items where post_id=current_row.id)
 then raise exception 'invalid_feed_state' using errcode='P0001'; end if;
 update public.feed_posts set
  caption=case when p_has_caption then p_caption else caption end,
  aesthetic_id=case when p_has_aesthetic_id then p_aesthetic_id else aesthetic_id end,
  visibility=final_visibility
 where id=current_row.id;
 return jsonb_build_object('post_id',current_row.id,'visibility',final_visibility);
end $$;

-- Service-only projection gains linked_items. Only the link row id, its position and category
-- are projected: no garment_id (private closet identifier), no closet object key or URL.
create or replace function public.project_feed_posts(p_actor_id uuid,p_post_ids uuid[])
returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 if p_actor_id is null or not exists(select 1 from public.profiles where id=p_actor_id)
 or p_post_ids is null or cardinality(p_post_ids) not between 1 and 100
 or cardinality(p_post_ids)<>(select count(distinct x) from unnest(p_post_ids) x)
 then raise exception 'invalid_feed_projection' using errcode='22023'; end if;
 select coalesce(jsonb_agg(jsonb_build_object(
  'id',p.id,'author',jsonb_build_object('id',p.user_id,'display_name',pr.display_name),
  'caption',p.caption,'aesthetic_id',p.aesthetic_id,'weather_code',p.weather_code,
  'temperature_c',p.temperature_c,'visibility',p.visibility,'created_at',p.created_at,
  'liked_by_me',exists(select 1 from public.post_likes mine where mine.post_id=p.id and mine.user_id=p_actor_id),
  'like_count',(select count(*) from public.post_likes likes where likes.post_id=p.id),
  'media',coalesce((select jsonb_agg(jsonb_build_object('bucket_id',m.bucket_id,'object_key',m.object_key,'position',m.position) order by m.position)
   from public.feed_media m where m.post_id=p.id and m.user_id=p.user_id and m.verified_at is not null and m.deleted_at is null),'[]'::jsonb),
  'linked_items',coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'position',i.position,'category',i.category) order by i.position)
   from public.feed_post_items i where i.post_id=p.id and i.user_id=p.user_id),'[]'::jsonb)
 ) order by u.ord),'[]'::jsonb) into result
 from unnest(p_post_ids) with ordinality u(id,ord)
 join public.feed_posts p on p.id=u.id and p.deleted_at is null and (p.visibility='public' or p.user_id=p_actor_id)
 join public.profiles pr on pr.id=p.user_id;
 return result;
end $$;

-- 3. Mimic: linked items -> viewer closet --------------------------------------------------
-- Future AI hook: a worker may store one embedding per garment. When the linked source garment
-- and a candidate share a model_version, the matcher blends cosine similarity into the rule
-- score. Service-only; nothing writes it yet.
create table public.garment_embeddings (
 user_id uuid not null,
 garment_id uuid primary key,
 model_version text not null check(model_version ~ '^[A-Za-z0-9._:-]{1,100}$'),
 embedding real[] not null check(array_ndims(embedding)=1 and cardinality(embedding) between 1 and 4096),
 created_at timestamptz not null default now(),
 foreign key(user_id,garment_id) references public.garments(user_id,id) on delete cascade
);
alter table public.garment_embeddings enable row level security;
revoke all on public.garment_embeddings from public,anon,authenticated;
grant all on public.garment_embeddings to service_role;

-- Source rows are now either legacy media snapshots or linked-item snapshots.
alter table public.mimic_source_items drop constraint mimic_source_items_check;
alter table public.mimic_source_items alter column feed_media_id drop not null;
alter table public.mimic_source_items alter column bucket_id drop not null;
alter table public.mimic_source_items alter column object_key drop not null;
alter table public.mimic_source_items alter column storage_object_id drop not null;
alter table public.mimic_source_items alter column storage_updated_at drop not null;
alter table public.mimic_source_items alter column content_type drop not null;
alter table public.mimic_source_items alter column byte_size drop not null;
alter table public.mimic_source_items alter column verified_at drop not null;
-- post_item_id is a snapshot reference (no FK): later link edits must not rewrite old results.
alter table public.mimic_source_items add column post_item_id uuid;
alter table public.mimic_source_items add column category text
 check(category in ('outerwear','top','bottom','shoes','bag','accessory'));
alter table public.mimic_source_items add constraint mimic_source_kind check(
 (feed_media_id is not null and post_item_id is null and category is null and source_item_key='media:'||feed_media_id::text
  and num_nonnulls(bucket_id,object_key,storage_object_id,storage_updated_at,content_type,byte_size,verified_at)=7)
 or (post_item_id is not null and feed_media_id is null and category is not null and source_item_key='item:'||post_item_id::text
  and num_nonnulls(bucket_id,object_key,storage_object_id,storage_updated_at,content_type,byte_size,verified_at)=0)
);

-- Retire the representative-image worker path: open legacy jobs fail closed and no job is claimable.
update public.mimic_requests set status='failed',error_code='LEGACY_PIPELINE_RETIRED',completed_at=now(),
 retention_expires_at=now()+interval '7 days',lease_token=null,lease_expires_at=null
where status in ('queued','running');

create or replace function public.claim_mimic_job(p_lease_seconds integer default 120)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if p_lease_seconds is null or p_lease_seconds not between 30 and 900
 then raise exception 'invalid_lease' using errcode='22023'; end if;
 -- Retired 2026-10-10: Mimic no longer re-detects the representative image. Jobs complete
 -- synchronously from linked items, so there is never a queued job to lease.
 return null;
end $$;

-- Rule-based baseline score in [0,1] for a same-category pair. Unknown attributes count as
-- weak evidence (0.3) rather than as a match. Weights: color 0.4, pattern 0.3, aesthetic 0.3.
create function public.g10_mimic_rule_score(
 p_source_color text,p_source_pattern text,p_source_aesthetics jsonb,
 p_color text,p_pattern text,p_aesthetics jsonb
) returns numeric language plpgsql immutable set search_path='' as $$
declare unknown constant numeric:=0.3; color_s numeric; pattern_s numeric; aesthetic_s numeric;
 a bytea; b bytea; dot numeric; n1 numeric; n2 numeric;
begin
 if p_source_color is null or p_color is null then color_s:=unknown;
 else
  a:=decode(substr(p_source_color,2),'hex'); b:=decode(substr(p_color,2),'hex');
  color_s:=greatest(0,1-sqrt(power(get_byte(a,0)-get_byte(b,0),2)+power(get_byte(a,1)-get_byte(b,1),2)
   +power(get_byte(a,2)-get_byte(b,2),2))/441.6729559300637);
 end if;
 if nullif(btrim(coalesce(p_source_pattern,'')),'') is null or nullif(btrim(coalesce(p_pattern,'')),'') is null then pattern_s:=unknown;
 elsif lower(btrim(p_source_pattern))=lower(btrim(p_pattern)) then pattern_s:=1;
 else pattern_s:=0; end if;
 select sum((s.value)::numeric*coalesce((p_aesthetics->>s.key)::numeric,0)),sqrt(sum(power((s.value)::numeric,2)))
 into dot,n1 from jsonb_each_text(coalesce(p_source_aesthetics,'{}'::jsonb)) s;
 select sqrt(sum(power((c.value)::numeric,2))) into n2 from jsonb_each_text(coalesce(p_aesthetics,'{}'::jsonb)) c;
 if coalesce(n1,0)=0 or coalesce(n2,0)=0 then aesthetic_s:=unknown; else aesthetic_s:=least(1,greatest(0,dot/(n1*n2))); end if;
 return round(0.4*color_s+0.3*pattern_s+0.3*aesthetic_s,4);
end $$;

create function public.g10_vector_similarity(p_a real[],p_b real[])
returns numeric language sql immutable set search_path='' as $$
 select case when p_a is null or p_b is null or cardinality(p_a)<>cardinality(p_b) then null
  else (select case when sum(x*x)=0 or sum(y*y)=0 or sum(x*y)='NaN'::float8 then null
   else (sum(x*y)/(sqrt(sum(x*x))*sqrt(sum(y*y))))::numeric end
   from unnest(p_a::float8[],p_b::float8[]) t(x,y)) end
$$;

-- Display grade (2026-10-10 decision: 높음·보통·낮음). Single source of the thresholds:
-- high >= 0.75, medium >= 0.5, otherwise low. Raw scores stay internal (mimic_requests.result):
-- per-item numbers would let a viewer probe the author's private item attributes.
create function public.g10_mimic_grade(p_score numeric)
returns text language sql immutable set search_path='' as $$
 select case when p_score is null then null when p_score>=0.75 then 'high' when p_score>=0.5 then 'medium' else 'low' end
$$;

create or replace function public.get_my_mimic_job(p_job_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_owner_id uuid:=auth.uid(); j public.mimic_requests; safe_matches jsonb:='[]'::jsonb;
 safe_status text; safe_coverage numeric; safe_error jsonb; valid_count integer:=0; source_count integer:=0;
 score_sum numeric:=0; match_count integer:=0; overall_grade text;
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
  -- A matched garment the viewer has since deleted (or whose cutout changed) is withheld.
  select coalesce(jsonb_agg(jsonb_build_object(
   'source_item_key',x.value->>'source_item_key',
   'post_item_id',src.post_item_id,'category',src.category,
   'garment_id',case when available then x.value->'garment_id' else 'null'::jsonb end,
   'grade',case when available then to_jsonb(public.g10_mimic_grade((x.value->>'similarity')::numeric)) else 'null'::jsonb end,
   'reason',case when (x.value->>'garment_id') is null then x.value->'reason'
    when available then x.value->'reason' else to_jsonb('현재 사용할 수 없는 옷입니다.'::text) end
  ) order by x.ord),'[]'::jsonb),count(*) filter(where available),
  coalesce(sum(case when available then (x.value->>'similarity')::numeric else 0 end),0),count(*)
  into safe_matches,valid_count,score_sum,match_count
  from jsonb_array_elements(coalesce(j.result->'matches','[]'::jsonb)) with ordinality x(value,ord)
  left join public.mimic_source_items src on src.job_id=j.id and src.source_item_key=x.value->>'source_item_key'
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
 -- Overall grade: mean score over every source item (unmatched = 0), succeeded only.
 if safe_status='succeeded' and match_count>0 then overall_grade:=public.g10_mimic_grade(score_sum/match_count); end if;
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
  'coverage',safe_coverage,'grade',overall_grade,'error',safe_error);
end $$;

-- Synchronous matcher. Category must match; each closet garment is used at most once (greedy
-- by score) so the result can be saved as one outfit. Pairs scoring below 0.2 do not match.
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
 join storage.objects o on o.bucket_id=a.bucket_id and o.name=a.object_key and o.owner_id::text=g.user_id::text
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

-- 4. Grants --------------------------------------------------------------------------------
revoke all on function public.g10_check_post_items(),public.g10_link_post_items(uuid,uuid,uuid[]),
 public.g10_ootd_linkable_garments(uuid,uuid),
 public.create_my_feed_post(uuid,text,uuid,text,numeric,text,uuid[]),
 public.update_my_feed_post(uuid,boolean,text,boolean,uuid,boolean,text,boolean,uuid[]),
 public.g10_mimic_rule_score(text,text,jsonb,text,text,jsonb),public.g10_vector_similarity(real[],real[]),
 public.g10_mimic_grade(numeric)
 from public,anon,authenticated;
grant execute on function public.create_my_feed_post(uuid,text,uuid,text,numeric,text,uuid[]),
 public.update_my_feed_post(uuid,boolean,text,boolean,uuid,boolean,text,boolean,uuid[]) to authenticated;
