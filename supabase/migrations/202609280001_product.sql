-- Mafico product delta. Existing migrations remain immutable.
insert into public.aesthetics(code,label,definition,version) values
 ('feminine','페미닌','팀 선정 스타일; 세부 학습 정의는 AI팀 확정 필요','prd-20260928'),
 ('y2k','Y2K','팀 선정 스타일; 세부 학습 정의는 AI팀 확정 필요','prd-20260928'),
 ('minimal','미니멀','팀 선정 스타일; 세부 학습 정의는 AI팀 확정 필요','prd-20260928'),
 ('grunge','그런지','팀 선정 스타일; 세부 학습 정의는 AI팀 확정 필요','prd-20260928'),
 ('casual','캐주얼','팀 선정 스타일; 세부 학습 정의는 AI팀 확정 필요','prd-20260928')
 on conflict(code) do nothing;
alter table public.garments add column memo text check(length(memo)<=1000);
alter table public.garments drop constraint garments_category_check;
alter table public.garments add constraint garments_category_check
 check(category in ('top','bottom','outerwear','dress','shoes','bag','accessory','other'));

create table public.saved_outfits (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references public.profiles(id) on delete cascade,
 title text not null default '' check(length(title)<=100), note text check(length(note)<=1000),
 source_recommendation_id uuid, version integer not null default 1 check(version>0),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 unique(user_id,id), foreign key(user_id,source_recommendation_id) references public.outfit_recommendations(user_id,id)
);
create trigger saved_outfit_updated before update on public.saved_outfits for each row execute function public.touch_updated_at();
create table public.saved_outfit_items (
 user_id uuid not null, saved_outfit_id uuid not null, garment_id uuid not null,
 position integer not null check(position>=0), primary key(saved_outfit_id,garment_id), unique(saved_outfit_id,position),
 foreign key(user_id,saved_outfit_id) references public.saved_outfits(user_id,id) on delete cascade,
 foreign key(user_id,garment_id) references public.garments(user_id,id)
);
alter table public.ootd_entries alter column outfit_id drop not null;
alter table public.ootd_entries add column saved_outfit_id uuid;
alter table public.ootd_entries add constraint ootd_saved_owner foreign key(user_id,saved_outfit_id) references public.saved_outfits(user_id,id);
-- Neutral default does not turn legacy/planned records into actual wear events.
-- planned/worn policy is a proposed technical distinction, not a settled UX rule.
alter table public.ootd_entries add column wear_status text not null default 'unconfirmed' check(wear_status in ('unconfirmed','planned','worn'));
alter table public.ootd_entries add column weather_snapshot_id uuid references public.weather_snapshots(id);
alter table public.ootd_entries add constraint ootd_snapshot_array check(jsonb_typeof(item_snapshot)='array');
-- Neither origin is valid for manually assembled snapshots, but two origins are ambiguous.
alter table public.ootd_entries add constraint ootd_single_origin check(num_nonnulls(outfit_id,saved_outfit_id)<=1);

create table public.feed_posts (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references public.profiles(id) on delete cascade,
 source_ootd_id uuid, caption text not null default '' check(length(caption)<=2000),
 aesthetic_id uuid references public.aesthetics(id),
 weather_code text check(weather_code in ('clear','cloudy','rain','snow','unknown')),
 temperature_c numeric check(temperature_c between -90 and 60),
 visibility text not null default 'private' check(visibility in ('private','public')),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 deleted_at timestamptz, unique(user_id,id),
 foreign key(user_id,source_ootd_id) references public.ootd_entries(user_id,id)
);
create index feed_public_page on public.feed_posts(created_at desc,id) where visibility='public' and deleted_at is null;
create trigger post_updated before update on public.feed_posts for each row execute function public.touch_updated_at();
-- Explicitly shared copies only. No link to closet-private objects is permitted.
create table public.feed_media (
 id uuid primary key default gen_random_uuid(), user_id uuid not null, post_id uuid not null,
 bucket_id text not null default 'feed-private' check(bucket_id='feed-private'),
 object_key text unique not null, position integer not null check(position>=0),
 verified_at timestamptz, deleted_at timestamptz,
 unique(post_id,position), foreign key(user_id,post_id) references public.feed_posts(user_id,id) on delete cascade,
 check(split_part(object_key,'/',1)=user_id::text)
);
create table public.post_likes (
 user_id uuid not null references public.profiles(id) on delete cascade,
 post_id uuid not null references public.feed_posts(id) on delete cascade,
 created_at timestamptz not null default now(), primary key(user_id,post_id)
);
create table public.mimic_requests (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references public.profiles(id) on delete cascade,
 post_id uuid not null references public.feed_posts(id) on delete cascade,
 status text not null default 'queued' check(status in ('queued','running','succeeded','no_match','failed')),
 -- Internal model result only; DTO must resolve/validate owned garment IDs.
 result jsonb check(result is null or jsonb_typeof(result)='object'), model_version text,
 created_at timestamptz not null default now(), completed_at timestamptz
);
do $$ declare t text; begin
 foreach t in array array['saved_outfits','saved_outfit_items','feed_posts','feed_media','post_likes','mimic_requests'] loop
 execute format('alter table public.%I enable row level security',t);
 execute format('revoke all on public.%I from public,anon,authenticated',t);
 execute format('grant all on public.%I to service_role',t);
 end loop;
 foreach t in array array['saved_outfits','saved_outfit_items','mimic_requests'] loop
 execute format('create policy owner_read on public.%I for select to authenticated using ((select auth.uid())=user_id)',t);
 execute format('grant select on public.%I to authenticated',t);
 end loop;
end $$;
revoke select on public.mimic_requests from authenticated;
grant select(id,user_id,post_id,status,created_at,completed_at) on public.mimic_requests to authenticated;
create policy feed_visible on public.feed_posts for select to authenticated using(
 deleted_at is null and (visibility='public' or user_id=(select auth.uid())));
-- No SELECT * grant: private OOTD linkage is never exposed to another member.
grant select(id,user_id,caption,aesthetic_id,weather_code,temperature_c,visibility,created_at,updated_at) on public.feed_posts to authenticated;
create policy own_visible_likes on public.post_likes for select to authenticated using(
 user_id=(select auth.uid()) and exists(select 1 from public.feed_posts p where p.id=post_id));
grant select on public.post_likes to authenticated;
-- Media mapping is server-only. BFF checks post visibility, verified_at and deleted_at before signing short-lived reads.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
 values('feed-private','feed-private',false,20971520,array['image/jpeg','image/png','image/webp']);

-- Nullable recommendation linkage requires null-safe conflict detection.
create or replace function public.accept_outfit(p_outfit_id uuid,p_worn_on date) returns public.ootd_entries
language plpgsql security definer set search_path='' as $$
declare owner_id uuid:=auth.uid(); result public.ootd_entries;
begin
 if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 if p_worn_on is null or p_outfit_id is null then raise exception 'date_and_outfit_required'; end if;
 perform pg_advisory_xact_lock(hashtextextended(owner_id::text||p_worn_on::text,0));
 select * into result from public.ootd_entries where user_id=owner_id and worn_on=p_worn_on;
 if found then
  if result.outfit_id is distinct from p_outfit_id then raise exception 'ootd_date_conflict'; end if;
  return result;
 end if;
 if not exists(select 1 from public.outfit_recommendations o join public.recommendation_requests r on r.id=o.request_id
 where o.id=p_outfit_id and o.user_id=owner_id and r.status='ready' and r.target_date=p_worn_on and r.expires_at>now()) then raise exception 'outfit_not_ready'; end if;
 if not exists(select 1 from public.outfit_items where outfit_id=p_outfit_id)
 or exists(select 1 from public.outfit_items i join public.garments g on g.id=i.garment_id where i.outfit_id=p_outfit_id and g.deleted_at is not null)
 then raise exception 'outfit_items_unavailable'; end if;
 insert into public.ootd_entries(user_id,outfit_id,worn_on,item_snapshot,weather_snapshot_id)
 select owner_id,p_outfit_id,p_worn_on,jsonb_agg(jsonb_build_object('garment_id',g.id,'category',g.category,'slot',i.slot)),
 (select r.weather_snapshot_id from public.outfit_recommendations o join public.recommendation_requests r on r.id=o.request_id where o.id=p_outfit_id)
 from public.outfit_items i join public.garments g on g.id=i.garment_id where i.outfit_id=p_outfit_id returning * into result;
 return result;
end $$;
