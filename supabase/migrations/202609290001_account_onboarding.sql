-- Narrow account/onboarding writes. Existing migrations remain immutable.
alter table public.profiles
 add column knows_aesthetic boolean,
 add column tutorial_seen boolean not null default false;

-- Presence flags distinguish an omitted PATCH field from an explicit null display name.
create function public.update_my_profile(
 p_set_display_name boolean,
 p_display_name text,
 p_set_timezone boolean,
 p_timezone text
) returns void language plpgsql security definer set search_path='' as $$
declare owner_id uuid:=auth.uid();
begin
 if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 if p_set_display_name is null or p_set_timezone is null or not (p_set_display_name or p_set_timezone)
 then raise exception 'empty_profile_patch' using errcode='22023'; end if;
 if p_set_display_name and p_display_name is not null and char_length(p_display_name) not between 1 and 50
 then raise exception 'invalid_display_name' using errcode='22023'; end if;
 if p_set_timezone and (
   p_timezone is null or not exists(select 1 from pg_catalog.pg_timezone_names where name=p_timezone)
 ) then raise exception 'invalid_timezone' using errcode='22023'; end if;
 update public.profiles set
  display_name=case when p_set_display_name then p_display_name else display_name end,
  timezone=case when p_set_timezone then p_timezone else timezone end
 where id=owner_id;
 if not found then raise exception 'profile_not_found' using errcode='P0002'; end if;
end $$;

create function public.replace_my_aesthetic_preferences(p_preferences jsonb)
returns void language plpgsql security definer set search_path='' as $$
declare owner_id uuid:=auth.uid(); item_count integer;
begin
 if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 if p_preferences is null or jsonb_typeof(p_preferences) is distinct from 'array'
 then raise exception 'invalid_preferences' using errcode='22023'; end if;
 item_count:=jsonb_array_length(p_preferences);
 if item_count not between 1 and 3 then raise exception 'invalid_preference_count' using errcode='22023'; end if;
 if exists(
  select 1 from jsonb_array_elements(p_preferences) value
  where jsonb_typeof(value) is distinct from 'object'
     or not (value ? 'aesthetic_id' and value ? 'weight')
     or (select count(*) from jsonb_object_keys(value))<>2
     or jsonb_typeof(value->'aesthetic_id') is distinct from 'string'
     or (value->>'aesthetic_id') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     or jsonb_typeof(value->'weight') is distinct from 'number'
     or (value->>'weight')::numeric<=0
     or (value->>'weight')::numeric>1
 ) then raise exception 'invalid_preferences' using errcode='22023'; end if;
 if (select count(distinct value->>'aesthetic_id') from jsonb_array_elements(p_preferences) value)<>item_count
 then raise exception 'duplicate_aesthetic' using errcode='22023'; end if;
 if abs((select sum((value->>'weight')::numeric) from jsonb_array_elements(p_preferences) value)-1)>0.0001
 then raise exception 'invalid_preference_weight_sum' using errcode='22023'; end if;

 -- The profile row is a per-user mutex for concurrent account writes and replacements.
 perform id from public.profiles where id=owner_id for update;
 if not found then raise exception 'profile_not_found' using errcode='P0002'; end if;
 if (
  select count(*) from public.aesthetics
  where active and id=any(array(
   select (value->>'aesthetic_id')::uuid from jsonb_array_elements(p_preferences) value
  ))
 )<>item_count then raise exception 'inactive_or_unknown_aesthetic' using errcode='22023'; end if;

 delete from public.user_aesthetic_preferences where user_id=owner_id;
 insert into public.user_aesthetic_preferences(user_id,aesthetic_id,weight)
 select owner_id,(value->>'aesthetic_id')::uuid,(value->>'weight')::numeric
 from jsonb_array_elements(p_preferences) value;
end $$;

-- No additional completion rule is invented here: all three fields are required by the API contract.
create function public.save_my_onboarding_state(
 p_knows_aesthetic boolean,
 p_tutorial_seen boolean,
 p_completed boolean
) returns void language plpgsql security definer set search_path='' as $$
declare owner_id uuid:=auth.uid();
begin
 if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 if p_tutorial_seen is null or p_completed is null
 then raise exception 'invalid_onboarding_state' using errcode='22023'; end if;
 update public.profiles set
  knows_aesthetic=p_knows_aesthetic,
  tutorial_seen=p_tutorial_seen,
  onboarding_completed=p_completed
 where id=owner_id;
 if not found then raise exception 'profile_not_found' using errcode='P0002'; end if;
end $$;

revoke all on function public.update_my_profile(boolean,text,boolean,text),
 public.replace_my_aesthetic_preferences(jsonb),
 public.save_my_onboarding_state(boolean,boolean,boolean)
 from public,anon,authenticated;
grant execute on function public.update_my_profile(boolean,text,boolean,text),
 public.replace_my_aesthetic_preferences(jsonb),
 public.save_my_onboarding_state(boolean,boolean,boolean)
to authenticated;
