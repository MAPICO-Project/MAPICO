-- Run only against a disposable migrated database. Every fixture rolls back.
-- 2026-10-10 Track A: feed_post_items (>=1 own closet item per post) and garment_embeddings privacy.
begin;

insert into auth.users(id) values
 ('7a000000-0000-4000-8000-000000000001'),
 ('7a000000-0000-4000-8000-000000000002');
select set_config('test.links_aesthetic',(select id::text from public.aesthetics where active order by id limit 1),true);

create function pg_temp.mk_garment(p_user uuid,p_id uuid,p_category text,p_color text,p_pattern text)
returns void language plpgsql as $$
declare b uuid:=gen_random_uuid(); a uuid:=gen_random_uuid(); j uuid:=gen_random_uuid(); d uuid:=gen_random_uuid();
 k text:=p_user::text||'/links/'||p_id::text||'.png';
begin
 insert into public.garment_batches(id,user_id,status) values(b,p_user,'confirmed');
 insert into public.garment_assets(id,user_id,batch_id,kind,object_key,content_type,byte_size,verified_at)
  values(a,p_user,b,'cutout',k,'image/png',12,now());
 insert into storage.objects(bucket_id,name,owner_id,metadata) values('closet-private',k,p_user,'{"mimetype":"image/png","size":12}');
 insert into public.analysis_jobs(id,user_id,batch_id,status,completed_at) values(j,p_user,b,'succeeded',now());
 insert into public.garment_drafts(id,user_id,batch_id,job_id,item_index,asset_id,status,raw_prediction,model_version)
  values(d,p_user,b,j,0,a,'confirmed',jsonb_build_object('category',p_category),'v1');
 insert into public.garments(id,user_id,source_draft_id,asset_id,category,color_hex,pattern,attributes)
  values(p_id,p_user,d,a,p_category,p_color,p_pattern,jsonb_build_object('category',p_category));
end $$;
select pg_temp.mk_garment('7a000000-0000-4000-8000-000000000001','7a100000-0000-4000-8000-000000000001','top','#112233','stripe');
select pg_temp.mk_garment('7a000000-0000-4000-8000-000000000001','7a100000-0000-4000-8000-000000000002','bottom',null,null);
select pg_temp.mk_garment('7a000000-0000-4000-8000-000000000001','7a100000-0000-4000-8000-000000000003','shoes',null,null);
select pg_temp.mk_garment('7a000000-0000-4000-8000-000000000002','7a100000-0000-4000-8000-000000000009','top',null,null);
update public.garments set deleted_at=now() where id='7a100000-0000-4000-8000-000000000003';
insert into public.garment_aesthetic_scores(user_id,garment_id,aesthetic_id,score,model_version)
 values('7a000000-0000-4000-8000-000000000001','7a100000-0000-4000-8000-000000000001',current_setting('test.links_aesthetic')::uuid,0.9,'v1');
insert into public.ootd_entries(id,user_id,worn_on,visibility,item_snapshot,wear_status) values
 ('7a200000-0000-4000-8000-000000000001','7a000000-0000-4000-8000-000000000001',current_date-1,'private',
  '[{"garment_id":"7a100000-0000-4000-8000-000000000001","category":"top","unavailable":false},
    {"garment_id":"7a100000-0000-4000-8000-000000000003","category":"shoes","unavailable":false}]','worn'),
 ('7a200000-0000-4000-8000-000000000002','7a000000-0000-4000-8000-000000000001',current_date-2,'private',
  '[{"garment_id":"7a100000-0000-4000-8000-000000000003","category":"shoes","unavailable":false}]','worn');

set local role authenticated;
select set_config('request.jwt.claim.sub','7a000000-0000-4000-8000-000000000001',true);
do $$ declare aes uuid:=current_setting('test.links_aesthetic')::uuid; created jsonb; replay jsonb; v_post uuid; ootd_post uuid; begin
 begin perform id from public.feed_post_items; raise exception 'FAIL raw links exposed';
  exception when insufficient_privilege then null; end;
 begin perform garment_id from public.garment_embeddings; raise exception 'FAIL embeddings exposed';
  exception when insufficient_privilege then null; end;
 begin perform public.g10_link_post_items(auth.uid(),gen_random_uuid(),array['7a100000-0000-4000-8000-000000000001'::uuid]);
  raise exception 'FAIL link helper exposed'; exception when insufficient_privilege then null; end;

 -- Zero links: empty array, or neither links nor an OOTD source.
 begin perform public.create_my_feed_post(null,'none',aes,'clear',null,'links-zero-1','{}'::uuid[]);
  raise exception 'FAIL zero links accepted'; exception when invalid_parameter_value then if sqlerrm<>'invalid_garment_ids' then raise; end if; end;
 begin perform public.create_my_feed_post(null,'none',aes,'clear',null,'links-zero-2',null);
  raise exception 'FAIL omitted links accepted'; exception when invalid_parameter_value then if sqlerrm<>'invalid_garment_ids' then raise; end if; end;
 begin perform public.create_my_feed_post(null,'dup',aes,'clear',null,'links-dup-1',
  array['7a100000-0000-4000-8000-000000000001','7a100000-0000-4000-8000-000000000001']::uuid[]);
  raise exception 'FAIL duplicate links accepted'; exception when invalid_parameter_value then if sqlerrm<>'invalid_garment_ids' then raise; end if; end;
 -- Another member's garment behaves as not found; a deleted own garment is unavailable.
 begin perform public.create_my_feed_post(null,'foreign',aes,'clear',null,'links-foreign-1',array['7a100000-0000-4000-8000-000000000009'::uuid]);
  raise exception 'FAIL foreign garment linked'; exception when no_data_found then if sqlerrm<>'garment_not_found' then raise; end if; end;
 begin perform public.create_my_feed_post(null,'deleted',aes,'clear',null,'links-deleted-1',array['7a100000-0000-4000-8000-000000000003'::uuid]);
  raise exception 'FAIL deleted garment linked'; exception when raise_exception then if sqlerrm<>'garment_unavailable' then raise; end if; end;
 if exists(select 1 from public.feed_posts where user_id=auth.uid()) then raise exception 'FAIL failed create left a post'; end if;

 created:=public.create_my_feed_post(null,'two items',aes,'clear',null,'links-two-1',
  array['7a100000-0000-4000-8000-000000000002','7a100000-0000-4000-8000-000000000001']::uuid[]);
 replay:=public.create_my_feed_post(null,'two items',aes,'clear',null,'links-two-1',
  array['7a100000-0000-4000-8000-000000000002','7a100000-0000-4000-8000-000000000001']::uuid[]);
 v_post:=(created->>'post_id')::uuid;
 if replay->>'replayed'<>'true' or replay->>'post_id'<>v_post::text then raise exception 'FAIL linked create replay'; end if;
 begin perform public.create_my_feed_post(null,'two items',aes,'clear',null,'links-two-1',array['7a100000-0000-4000-8000-000000000001'::uuid]);
  raise exception 'FAIL link set not in fingerprint'; exception when raise_exception then if sqlerrm<>'idempotency_conflict' then raise; end if; end;

 -- OOTD import links only the OOTD's still-available items; nothing available => rejected.
 created:=public.create_my_feed_post('7a200000-0000-4000-8000-000000000001','from ootd',aes,null,null,'links-ootd-1',null);
 ootd_post:=(created->>'post_id')::uuid;
 begin perform public.create_my_feed_post('7a200000-0000-4000-8000-000000000002','gone',aes,null,null,'links-ootd-2',null);
  raise exception 'FAIL OOTD without available items'; exception when raise_exception then if sqlerrm<>'garment_unavailable' then raise; end if; end;

 -- Edits keep >=1 link and the same ownership rules.
 begin perform public.update_my_feed_post(v_post,false,null,false,null,false,null,true,'{}'::uuid[]);
  raise exception 'FAIL edit to zero links'; exception when invalid_parameter_value then if sqlerrm<>'invalid_garment_ids' then raise; end if; end;
 begin perform public.update_my_feed_post(v_post,false,null,false,null,false,null,true,null);
  raise exception 'FAIL edit to null links'; exception when invalid_parameter_value then if sqlerrm<>'invalid_garment_ids' then raise; end if; end;
 begin perform public.update_my_feed_post(v_post,false,null,false,null,false,null,true,array['7a100000-0000-4000-8000-000000000009'::uuid]);
  raise exception 'FAIL edit to foreign link'; exception when no_data_found then if sqlerrm<>'garment_not_found' then raise; end if; end;
 perform set_config('test.links_post',v_post::text,true);
 perform set_config('test.links_ootd_post',ootd_post::text,true);
end $$;
reset role;

do $$ begin
 if (select array_agg(garment_id::text||':'||position||':'||category order by position) from public.feed_post_items
  where post_id=current_setting('test.links_post')::uuid)
  <>array['7a100000-0000-4000-8000-000000000002:0:bottom','7a100000-0000-4000-8000-000000000001:1:top']
 then raise exception 'FAIL ordered link snapshot'; end if;
 if not exists(select 1 from public.feed_post_items where post_id=current_setting('test.links_post')::uuid
  and garment_id='7a100000-0000-4000-8000-000000000001' and color_hex='#112233' and pattern='stripe'
  and (aesthetic_scores->>current_setting('test.links_aesthetic'))::numeric=0.9)
 then raise exception 'FAIL matching snapshot copied'; end if;
 if (select array_agg(garment_id) from public.feed_post_items where post_id=current_setting('test.links_ootd_post')::uuid)
  <>array['7a100000-0000-4000-8000-000000000001'::uuid]
 then raise exception 'FAIL OOTD auto-link'; end if;
end $$;

set local role authenticated;
select set_config('request.jwt.claim.sub','7a000000-0000-4000-8000-000000000001',true);
select public.update_my_feed_post(current_setting('test.links_post')::uuid,false,null,false,null,false,null,true,
 array['7a100000-0000-4000-8000-000000000001'::uuid]);
reset role;
do $$ begin
 if (select count(*) from public.feed_post_items where post_id=current_setting('test.links_post')::uuid)<>1
 then raise exception 'FAIL relink replaces set'; end if;
end $$;

-- DB-level guarantees independent of the RPCs.
do $$ declare legacy uuid:='7a300000-0000-4000-8000-000000000001'; begin
 -- Cross-owner link is impossible even for privileged writers.
 begin insert into public.feed_post_items(user_id,post_id,garment_id,position,category)
  values('7a000000-0000-4000-8000-000000000001',current_setting('test.links_post')::uuid,'7a100000-0000-4000-8000-000000000009',5,'top');
  raise exception 'FAIL cross-owner link row'; exception when foreign_key_violation then null; end;
 -- Removing the last link fails at constraint check time.
 begin delete from public.feed_post_items where post_id=current_setting('test.links_post')::uuid;
  set constraints public.feed_post_items_keep_one immediate;
  raise exception 'FAIL zero links after delete'; exception when check_violation then if sqlerrm<>'feed_items_required' then raise; end if; end;
 -- A post row without links cannot be committed.
 begin insert into public.feed_posts(id,user_id,caption,visibility) values(gen_random_uuid(),'7a000000-0000-4000-8000-000000000001','raw','private');
  set constraints public.feed_post_items_on_insert immediate;
  raise exception 'FAIL link-less post insert'; exception when check_violation then if sqlerrm<>'feed_items_required' then raise; end if; end;
 -- Legacy link-less posts (pre-migration rows) cannot be published through the RPC.
 insert into public.feed_posts(id,user_id,caption,visibility) values(legacy,'7a000000-0000-4000-8000-000000000001','legacy','private');
 insert into public.feed_media(user_id,post_id,object_key,position,verified_at,content_type,byte_size)
  values('7a000000-0000-4000-8000-000000000001',legacy,'7a000000-0000-4000-8000-000000000001/'||legacy::text||'/m.jpg',0,now(),'image/jpeg',3);
end $$;
set local role authenticated;
select set_config('request.jwt.claim.sub','7a000000-0000-4000-8000-000000000001',true);
do $$ begin
 begin perform public.update_my_feed_post('7a300000-0000-4000-8000-000000000001',false,null,false,null,true,'public',false,null);
  raise exception 'FAIL legacy link-less publish'; exception when raise_exception then if sqlerrm<>'invalid_feed_state' then raise; end if; end;
 -- Linking an item in the same edit makes it publishable.
 perform public.update_my_feed_post('7a300000-0000-4000-8000-000000000001',false,null,false,null,true,'public',true,
  array['7a100000-0000-4000-8000-000000000002'::uuid]);
end $$;
reset role;

-- Public projection: link id/position/category only; snapshot survives a hard closet delete.
delete from public.garments where id='7a100000-0000-4000-8000-000000000002';
set local role service_role;
do $$ declare projected jsonb; item jsonb; begin
 projected:=public.project_feed_posts('7a000000-0000-4000-8000-000000000002',array['7a300000-0000-4000-8000-000000000001'::uuid]);
 item:=projected->0->'linked_items'->0;
 if jsonb_array_length(projected->0->'linked_items')<>1 or item->>'category'<>'bottom' or (item->>'position')::integer<>0
 or (select count(*) from jsonb_object_keys(item))<>3 or projected::text like '%7a100000-0000-4000-8000-000000000002%'
 or projected::text like '%closet-private%' or projected::text like '%/links/%'
 then raise exception 'FAIL safe linked item projection'; end if;
end $$;
reset role;
do $$ begin
 if not exists(select 1 from public.feed_post_items where post_id='7a300000-0000-4000-8000-000000000001' and garment_id is null and category='bottom')
 then raise exception 'FAIL link snapshot after garment delete'; end if;
 -- Account deletion cascades links and embeddings with the author's rows.
 insert into public.garment_embeddings(user_id,garment_id,model_version,embedding)
  values('7a000000-0000-4000-8000-000000000001','7a100000-0000-4000-8000-000000000001','emb-v1','{1,0}');
 begin insert into public.garment_embeddings(user_id,garment_id,model_version,embedding)
  values('7a000000-0000-4000-8000-000000000001','7a100000-0000-4000-8000-000000000009','emb-v1','{1,0}');
  raise exception 'FAIL cross-owner embedding'; exception when foreign_key_violation then null; end;
 delete from public.feed_posts where user_id='7a000000-0000-4000-8000-000000000001';
 delete from auth.users where id='7a000000-0000-4000-8000-000000000001';
 if exists(select 1 from public.feed_post_items where user_id='7a000000-0000-4000-8000-000000000001')
 or exists(select 1 from public.garment_embeddings where user_id='7a000000-0000-4000-8000-000000000001')
 then raise exception 'FAIL link/embedding cascade'; end if;
end $$;

rollback;
