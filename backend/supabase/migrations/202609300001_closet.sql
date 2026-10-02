-- G2 closet writes. Existing migrations remain immutable.
create index closet_page_desc on public.garments(user_id,created_at desc,id desc) where deleted_at is null;

create function public.update_my_garment(
 p_garment_id uuid,
 p_expected_version integer,
 p_set_category boolean,
 p_category text,
 p_set_subcategory boolean,
 p_subcategory text,
 p_set_memo boolean,
 p_memo text
) returns void language plpgsql security definer set search_path='' as $$
declare
 owner_id uuid:=auth.uid();
 current_version integer;
 next_attributes jsonb;
begin
 if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 if p_garment_id is null or p_expected_version is null or p_expected_version<1
    or p_set_category is null or p_set_subcategory is null or p_set_memo is null
    or not (p_set_category or p_set_subcategory or p_set_memo)
 then raise exception 'invalid_garment_patch' using errcode='22023'; end if;
 if p_set_category and (p_category is null or p_category not in ('top','bottom','outerwear','dress','shoes','bag','accessory','other'))
 then raise exception 'invalid_garment_category' using errcode='22023'; end if;
 if p_set_subcategory and p_subcategory is not null and char_length(p_subcategory)>80
 then raise exception 'invalid_garment_subcategory' using errcode='22023'; end if;
 if p_set_memo and p_memo is not null and char_length(p_memo)>1000
 then raise exception 'invalid_garment_memo' using errcode='22023'; end if;

 select version,attributes into current_version,next_attributes
 from public.garments
 where id=p_garment_id and user_id=owner_id and deleted_at is null
 for update;
 if not found then raise exception 'garment_not_found' using errcode='P0002'; end if;
 if current_version<>p_expected_version then raise exception 'version_conflict' using errcode='P0001'; end if;

 if p_set_category then next_attributes:=jsonb_set(next_attributes,'{category}',to_jsonb(p_category),true); end if;
 if p_set_subcategory then
  next_attributes:=jsonb_set(next_attributes,'{subcategory}',coalesce(to_jsonb(p_subcategory),'null'::jsonb),true);
 end if;
 update public.garments set
  category=case when p_set_category then p_category else category end,
  attributes=next_attributes,
  memo=case when p_set_memo then p_memo else memo end,
  version=version+1
 where id=p_garment_id and user_id=owner_id;
end $$;

create function public.delete_my_garment(p_garment_id uuid,p_idempotency_key text)
returns void language plpgsql security definer set search_path='' as $$
declare
 owner_id uuid:=auth.uid();
 request_fingerprint text:=p_garment_id::text;
 prior public.idempotency_keys%rowtype;
 target_asset_id uuid;
 target_batch_id uuid;
begin
 if owner_id is null then raise exception 'authentication_required' using errcode='42501'; end if;
 if p_garment_id is null then raise exception 'invalid_garment_id' using errcode='22023'; end if;
 if p_idempotency_key is null or char_length(p_idempotency_key) not between 8 and 128
    or p_idempotency_key !~ '^[A-Za-z0-9._:-]+$'
 then raise exception 'invalid_idempotency_key' using errcode='22023'; end if;

 select * into prior from public.idempotency_keys
 where user_id=owner_id and scope='deleteGarment' and key=p_idempotency_key
 for update;
 if found then
  if prior.expires_at<=now() then
   delete from public.idempotency_keys where user_id=owner_id and scope='deleteGarment' and key=p_idempotency_key;
  elsif prior.request_hash<>request_fingerprint then
   raise exception 'idempotency_conflict' using errcode='P0001';
  elsif prior.response_status=202 then
   return;
  else
   raise exception 'idempotency_conflict' using errcode='P0001';
  end if;
 end if;

 insert into public.idempotency_keys(user_id,scope,key,request_hash)
 values(owner_id,'deleteGarment',p_idempotency_key,request_fingerprint);

 select asset_id into target_asset_id from public.garments
 where id=p_garment_id and user_id=owner_id and deleted_at is null
 for update;
 if not found then raise exception 'garment_not_found' using errcode='P0002'; end if;
 select batch_id into target_batch_id from public.garment_assets
 where id=target_asset_id and user_id=owner_id;
 if not found then raise exception 'garment_asset_not_found' using errcode='P0002'; end if;
 perform id from public.garment_batches where id=target_batch_id and user_id=owner_id for update;
 if not found then raise exception 'garment_asset_not_found' using errcode='P0002'; end if;

 update public.garments set deleted_at=now(),version=version+1
 where id=p_garment_id and user_id=owner_id;
 update public.garment_assets a set deleted_at=coalesce(a.deleted_at,now())
 where a.id=target_asset_id and a.user_id=owner_id and a.kind='cutout'
   and not exists(select 1 from public.garments g where g.user_id=owner_id and g.asset_id=a.id and g.deleted_at is null);
 update public.garment_assets a set deleted_at=coalesce(a.deleted_at,now())
 where a.batch_id=target_batch_id and a.user_id=owner_id and a.kind='source'
   and not exists(
    select 1 from public.garments g join public.garment_assets ga on ga.id=g.asset_id and ga.user_id=g.user_id
    where g.user_id=owner_id and ga.batch_id=target_batch_id and g.deleted_at is null
   );

 update public.idempotency_keys set response_status=202,
  response_body=jsonb_build_object('id',p_garment_id,'status','deletion_pending')
 where user_id=owner_id and scope='deleteGarment' and key=p_idempotency_key;
end $$;

revoke all on function public.update_my_garment(uuid,integer,boolean,text,boolean,text,boolean,text),
 public.delete_my_garment(uuid,text) from public,anon,authenticated;
grant execute on function public.update_my_garment(uuid,integer,boolean,text,boolean,text,boolean,text),
 public.delete_my_garment(uuid,text) to authenticated;
