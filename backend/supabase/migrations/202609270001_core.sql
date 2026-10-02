-- MyFit:Core M0.5. Run on Supabase, not a plain PostgreSQL database.
create extension if not exists pgcrypto;

create table public.tpo_presets (
  code text primary key, label text not null, active boolean not null default true
);
insert into public.tpo_presets(code,label) values
 ('daily_campus','일상·등교'),('office_business','출근·비즈니스'),
 ('date_social','데이트·모임'),('formal_event','격식·행사'),('outdoor_active','야외·활동');
create table public.aesthetics (
  id uuid primary key default gen_random_uuid(), code text unique not null,
  label text not null, definition text not null, version text not null,
  active boolean not null default true
); -- Five names/definitions await the team's decision: intentionally no seed rows.
create table public.profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 display_name text check(length(display_name)<=50), timezone text not null default 'Asia/Seoul',
 default_tpo text references public.tpo_presets(code),
 onboarding_completed boolean not null default false,
 training_consent boolean not null default false,
 created_at timestamptz not null default now()
);
create table public.user_aesthetic_preferences (
 user_id uuid not null references public.profiles(id) on delete cascade,
 aesthetic_id uuid not null references public.aesthetics(id),
 weight numeric not null check(weight>0 and weight<=1), primary key(user_id,aesthetic_id)
);
create table public.garment_batches (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references public.profiles(id) on delete cascade,
 status text not null default 'awaiting_upload' check(status in ('awaiting_upload','uploaded','processing','review','confirmed','failed')),
 created_at timestamptz not null default now(), unique(user_id,id)
);
create table public.garment_assets (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references public.profiles(id) on delete cascade,
 batch_id uuid not null, kind text not null check(kind in ('source','cutout')),
 bucket_id text not null default 'closet-private' check(bucket_id='closet-private'),
 object_key text unique not null, content_type text not null check(content_type in ('image/jpeg','image/png','image/webp')),
 byte_size bigint not null check(byte_size between 1 and 20971520), verified_at timestamptz,
 deleted_at timestamptz, created_at timestamptz not null default now(), unique(user_id,id),
 foreign key(user_id,batch_id) references public.garment_batches(user_id,id) on delete cascade,
 check(split_part(object_key,'/',1)=user_id::text)
);
create unique index one_source_per_batch on public.garment_assets(batch_id) where kind='source';
create table public.analysis_jobs (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references public.profiles(id) on delete cascade,
 batch_id uuid not null, status text not null default 'queued' check(status in ('queued','running','succeeded','partial_failed','failed','cancelled')),
 attempt integer not null default 0 check(attempt>=0), max_attempts integer not null default 3 check(max_attempts between 1 and 10),
 available_at timestamptz not null default now(), lease_token uuid, lease_expires_at timestamptz,
 progress integer not null default 0 check(progress between 0 and 100),
 stage text check(stage in ('detecting','segmenting','tagging')), result jsonb, error_code text,
 created_at timestamptz not null default now(), completed_at timestamptz, unique(user_id,id), unique(batch_id),
 foreign key(user_id,batch_id) references public.garment_batches(user_id,id) on delete cascade
);
create index jobs_poll on public.analysis_jobs(status,available_at,lease_expires_at);
create table public.garment_drafts (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references public.profiles(id) on delete cascade,
 batch_id uuid not null, job_id uuid not null, item_index integer not null check(item_index between 0 and 5),
 asset_id uuid not null, status text not null default 'predicted' check(status in ('predicted','edited','confirmed','rejected')),
 raw_prediction jsonb not null check(jsonb_typeof(raw_prediction)='object'),
 user_overrides jsonb not null default '{}' check(jsonb_typeof(user_overrides)='object'),
 model_version text not null, created_at timestamptz not null default now(), unique(user_id,id), unique(job_id,item_index),
 foreign key(user_id,batch_id) references public.garment_batches(user_id,id) on delete cascade,
 foreign key(user_id,job_id) references public.analysis_jobs(user_id,id) on delete cascade,
 foreign key(user_id,asset_id) references public.garment_assets(user_id,id)
);
create table public.garments (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references public.profiles(id) on delete cascade,
 source_draft_id uuid unique not null, asset_id uuid not null,
 category text not null check(category in ('top','bottom','outerwear','dress','shoes','accessory','other')),
 color_hex text check(color_hex ~ '^#[0-9A-Fa-f]{6}$'), pattern text,
 formality numeric check(formality between 0 and 1), activity numeric check(activity between 0 and 1),
 attributes jsonb not null default '{}' check(jsonb_typeof(attributes)='object'),
 created_at timestamptz not null default now(), deleted_at timestamptz, unique(user_id,id),
 foreign key(user_id,source_draft_id) references public.garment_drafts(user_id,id),
 foreign key(user_id,asset_id) references public.garment_assets(user_id,id)
);
create index closet_page on public.garments(user_id,created_at desc,id) where deleted_at is null;
create table public.garment_aesthetic_scores (
 user_id uuid not null, garment_id uuid not null, aesthetic_id uuid not null references public.aesthetics(id),
 score numeric not null check(score between 0 and 1), model_version text not null,
 primary key(garment_id,aesthetic_id), foreign key(user_id,garment_id) references public.garments(user_id,id) on delete cascade
);
create table public.weather_snapshots (
 id uuid primary key default gen_random_uuid(), grid_x integer not null, grid_y integer not null,
 issued_at timestamptz not null, valid_at timestamptz not null, fetched_at timestamptz not null default now(), source text not null,
 payload jsonb not null check(jsonb_typeof(payload)='object'), unique(grid_x,grid_y,issued_at,valid_at,source)
);
create table public.recommendation_requests (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references public.profiles(id) on delete cascade,
 weather_snapshot_id uuid references public.weather_snapshots(id), tpo text references public.tpo_presets(code),
 target_date date not null, requested_count integer not null default 3 check(requested_count between 1 and 3),
 status text not null default 'pending' check(status in ('pending','ready','insufficient_wardrobe','failed')),
 preference_snapshot jsonb not null default '[]', engine_version text not null,
 created_at timestamptz not null default now(), unique(user_id,id)
);
create table public.outfit_recommendations (
 id uuid primary key default gen_random_uuid(), user_id uuid not null, request_id uuid not null,
 rank integer not null check(rank between 1 and 3), scores jsonb not null,
 reason_facts jsonb not null default '[]', explanation text,
 unique(user_id,id), unique(request_id,rank),
 foreign key(user_id,request_id) references public.recommendation_requests(user_id,id) on delete cascade
);
create table public.outfit_items (
 user_id uuid not null, outfit_id uuid not null, garment_id uuid not null, slot text not null,
 primary key(outfit_id,garment_id),
 foreign key(user_id,outfit_id) references public.outfit_recommendations(user_id,id) on delete cascade,
 foreign key(user_id,garment_id) references public.garments(user_id,id)
);
create table public.ootd_entries (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references public.profiles(id) on delete cascade,
 outfit_id uuid not null, worn_on date not null, visibility text not null default 'private' check(visibility='private'),
 item_snapshot jsonb not null default '[]',
 created_at timestamptz not null default now(), unique(user_id,worn_on), unique(user_id,id),
 foreign key(user_id,outfit_id) references public.outfit_recommendations(user_id,id)
);
create table public.idempotency_keys (
 user_id uuid not null references public.profiles(id) on delete cascade, scope text not null, key text not null,
 request_hash text not null, response_body jsonb, response_status integer,
 created_at timestamptz not null default now(), expires_at timestamptz not null default now()+interval '24 hours',
 primary key(user_id,scope,key)
);

-- Provision profile without trusting user-provided metadata.
create function public.create_profile() returns trigger language plpgsql security definer set search_path='' as $$
begin insert into public.profiles(id) values(new.id); return new; end $$;
create trigger auth_user_profile after insert on auth.users for each row execute function public.create_profile();
insert into public.profiles(id) select id from auth.users on conflict do nothing;

-- Clients may read their own records. All writes go through authenticated BFF or narrow RPCs.
do $$ declare t text; begin
 foreach t in array array['profiles','user_aesthetic_preferences','garment_batches','garment_assets','analysis_jobs','garment_drafts','garments','garment_aesthetic_scores','recommendation_requests','outfit_recommendations','outfit_items','ootd_entries','idempotency_keys','weather_snapshots','aesthetics','tpo_presets'] loop
 execute format('alter table public.%I enable row level security',t);
 execute format('revoke all on public.%I from anon, authenticated',t);
 execute format('grant all on public.%I to service_role',t);
 end loop;
 foreach t in array array['user_aesthetic_preferences','garment_batches','garment_assets','analysis_jobs','garment_drafts','garments','garment_aesthetic_scores','recommendation_requests','outfit_recommendations','outfit_items','ootd_entries'] loop
 execute format('create policy owner_read on public.%I for select to authenticated using ((select auth.uid())=user_id)',t);
 execute format('grant select on public.%I to authenticated',t);
 end loop;
end $$;
create policy profile_read on public.profiles for select to authenticated using((select auth.uid())=id);
grant select on public.profiles to authenticated;
create policy active_aesthetics on public.aesthetics for select to anon,authenticated using(active);
create policy active_tpo on public.tpo_presets for select to anon,authenticated using(active);
grant select on public.aesthetics,public.tpo_presets to anon,authenticated;
drop policy owner_read on public.garments;
create policy owner_read on public.garments for select to authenticated using((select auth.uid())=user_id and deleted_at is null);
-- Lease tokens and full machine result never enter the browser-facing DB projection.
revoke select on public.analysis_jobs from authenticated;
grant select(id,user_id,batch_id,status,attempt,progress,stage,error_code,created_at,completed_at) on public.analysis_jobs to authenticated;

-- Only a backend-issued signed upload URL can create objects; browsers cannot enumerate/write bucket contents.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
 values('closet-private','closet-private',false,20971520,array['image/jpeg','image/png','image/webp']);
create policy closet_asset_read on storage.objects for select to authenticated using(
 bucket_id='closet-private' and exists(select 1 from public.garment_assets a
 where a.object_key=name and a.user_id=(select auth.uid()) and a.verified_at is not null and a.deleted_at is null)
);
revoke all on function public.create_profile() from public,anon,authenticated;
