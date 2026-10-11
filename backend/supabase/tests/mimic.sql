-- Run only against a disposable migrated database. Every fixture rolls back.
-- 2026-10-10: Styling Mimic matches a post's linked items (feed_post_items) against the viewer's
-- closet. Coverage evidence: mimic_requests, mimic_source_items, mimic_candidate_items,
-- feed_posts, feed_post_items, garments, garment_assets, garment_embeddings, idempotency_keys.
begin;

insert into auth.users(id) values
 ('78000000-0000-4000-8000-000000000001'),
 ('78000000-0000-4000-8000-000000000002'),
 ('78000000-0000-4000-8000-000000000003');
select set_config('test.aes1',(select id::text from public.aesthetics where active order by id limit 1),true);
select set_config('test.aes2',(select id::text from public.aesthetics where active order by id offset 1 limit 1),true);
select set_config('test.aes3',(select id::text from public.aesthetics where active order by id offset 2 limit 1),true);

create function pg_temp.mk_garment(p_user uuid,p_id uuid,p_category text,p_color text,p_pattern text)
returns void language plpgsql as $$
declare b uuid:=gen_random_uuid(); a uuid:=gen_random_uuid(); j uuid:=gen_random_uuid(); d uuid:=gen_random_uuid();
 k text:=p_user::text||'/mimic/'||p_id::text||'.png';
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
-- Author (…02) source garment; viewer (…01) closet; another member (…03).
select pg_temp.mk_garment('78000000-0000-4000-8000-000000000002','78050000-0000-4000-8000-000000000020','top','#112233','stripe');
select pg_temp.mk_garment('78000000-0000-4000-8000-000000000001','78050000-0000-4000-8000-000000000001','top','#112234','Stripe');
select pg_temp.mk_garment('78000000-0000-4000-8000-000000000001','78050000-0000-4000-8000-000000000002','top','#ffffff','dot');
select pg_temp.mk_garment('78000000-0000-4000-8000-000000000001','78050000-0000-4000-8000-000000000003','shoes',null,null);
select pg_temp.mk_garment('78000000-0000-4000-8000-000000000003','78050000-0000-4000-8000-000000000009','top','#112233','stripe');
insert into public.garment_aesthetic_scores(user_id,garment_id,aesthetic_id,score,model_version) values
 ('78000000-0000-4000-8000-000000000001','78050000-0000-4000-8000-000000000001',current_setting('test.aes1')::uuid,0.8,'v1'),
 ('78000000-0000-4000-8000-000000000001','78050000-0000-4000-8000-000000000001',current_setting('test.aes2')::uuid,0.2,'v1'),
 ('78000000-0000-4000-8000-000000000001','78050000-0000-4000-8000-000000000002',current_setting('test.aes3')::uuid,1,'v1');

-- Posts are inserted directly (transaction rolls back before the deferred link check).
insert into public.feed_posts(id,user_id,caption,visibility) values
 ('78100000-0000-4000-8000-000000000001','78000000-0000-4000-8000-000000000002','top+bottom','public'),
 ('78100000-0000-4000-8000-000000000002','78000000-0000-4000-8000-000000000002','bag only','public'),
 ('78100000-0000-4000-8000-000000000003','78000000-0000-4000-8000-000000000002','two tops','public'),
 ('78100000-0000-4000-8000-000000000004','78000000-0000-4000-8000-000000000002','legacy','public'),
 ('78100000-0000-4000-8000-000000000005','78000000-0000-4000-8000-000000000002','private','private');
insert into public.feed_post_items(id,user_id,post_id,garment_id,position,category,color_hex,pattern,aesthetic_scores) values
 ('78200000-0000-4000-8000-000000000001','78000000-0000-4000-8000-000000000002','78100000-0000-4000-8000-000000000001',
  '78050000-0000-4000-8000-000000000020',0,'top','#112233','stripe',
  jsonb_build_object(current_setting('test.aes1'),0.8,current_setting('test.aes2'),0.2)),
 ('78200000-0000-4000-8000-000000000002','78000000-0000-4000-8000-000000000002','78100000-0000-4000-8000-000000000001',null,1,'bottom',null,null,'{}'),
 ('78200000-0000-4000-8000-000000000003','78000000-0000-4000-8000-000000000002','78100000-0000-4000-8000-000000000002',null,0,'bag',null,null,'{}'),
 ('78200000-0000-4000-8000-000000000004','78000000-0000-4000-8000-000000000002','78100000-0000-4000-8000-000000000003',null,0,'top','#112233','stripe','{}'),
 ('78200000-0000-4000-8000-000000000005','78000000-0000-4000-8000-000000000002','78100000-0000-4000-8000-000000000003',null,1,'top','#112233','stripe','{}'),
 ('78200000-0000-4000-8000-000000000006','78000000-0000-4000-8000-000000000002','78100000-0000-4000-8000-000000000005',null,0,'top',null,null,'{}');

set local role authenticated;
select set_config('request.jwt.claim.sub','78000000-0000-4000-8000-000000000001',true);
do $$ declare created jsonb; replay jsonb; m0 jsonb; m1 jsonb; begin
 begin perform id from public.mimic_requests; raise exception 'FAIL raw mimic table exposed';
  exception when insufficient_privilege then null; end;
 begin perform job_id from public.mimic_source_items; raise exception 'FAIL source snapshot exposed';
  exception when insufficient_privilege then null; end;
 begin perform public.claim_mimic_job(120); raise exception 'FAIL claim exposed';
  exception when insufficient_privilege then null; end;
 begin perform public.g10_mimic_rule_score('#000000',null,'{}','#000000',null,'{}'); raise exception 'FAIL scorer exposed';
  exception when insufficient_privilege then null; end;
 begin perform public.create_my_mimic_job('78100000-0000-4000-8000-000000000005','mimic-private-one');
  raise exception 'FAIL private source accepted'; exception when no_data_found then null; end;
 -- Legacy link-less post: the representative-image path is retired.
 begin perform public.create_my_mimic_job('78100000-0000-4000-8000-000000000004','mimic-legacy-one');
  raise exception 'FAIL legacy post mimicked'; exception when raise_exception then if sqlerrm<>'feed_media_unavailable' then raise; end if; end;

 created:=public.create_my_mimic_job('78100000-0000-4000-8000-000000000001','mimic-create-one');
 replay:=public.create_my_mimic_job('78100000-0000-4000-8000-000000000001','mimic-create-one');
 m0:=created->'matches'->0; m1:=created->'matches'->1;
 if created->>'status'<>'succeeded' or created->>'model_version'<>'rule-v1' or (created->>'coverage')::numeric<>0.5
 or jsonb_array_length(created->'matches')<>2 or created->>'id'<>replay->>'id'
 or m0->>'garment_id'<>'78050000-0000-4000-8000-000000000001' or m0->>'grade'<>'high' or m0?'similarity'
 or m0->>'post_item_id'<>'78200000-0000-4000-8000-000000000001' or m0->>'category'<>'top'
 or m0->>'source_item_key'<>'item:78200000-0000-4000-8000-000000000001'
 or m1->'garment_id'<>'null'::jsonb or m1->'grade'<>'null'::jsonb or created->>'grade'<>'low' or created::text like '%similarity%' or m1->>'category'<>'bottom'
 then raise exception 'FAIL synchronous linked-item match %',created; end if;
 -- Neither the author's closet id nor any object key leaks.
 if created::text like '%78050000-0000-4000-8000-000000000020%' or created::text like '%object_key%' or created::text like '%/mimic/%'
 then raise exception 'FAIL private identifiers in result'; end if;
 begin perform public.create_my_mimic_job('78100000-0000-4000-8000-000000000002','mimic-create-one');
  raise exception 'FAIL create key conflict'; exception when raise_exception then if sqlerrm<>'idempotency_conflict' then raise; end if; end;

 -- No same-category garment => no_match with one null entry per linked item.
 created:=public.create_my_mimic_job('78100000-0000-4000-8000-000000000002','mimic-nomatch-one');
 if created->>'status'<>'no_match' or (created->>'coverage')::numeric<>0 or created->'matches'->0->'garment_id'<>'null'::jsonb
 then raise exception 'FAIL no-match result'; end if;

 -- One closet garment is assigned at most once; the far top scores below the 0.2 floor.
 created:=public.create_my_mimic_job('78100000-0000-4000-8000-000000000003','mimic-distinct-one');
 if created->>'status'<>'succeeded' or (created->>'coverage')::numeric<>0.5
 or (select count(distinct x->>'garment_id') from jsonb_array_elements(created->'matches') x where x->>'garment_id' is not null)<>1
 then raise exception 'FAIL distinct garment assignment'; end if;
 perform set_config('test.mimic_job_one',replay->>'id',true);
end $$;
reset role;

-- Rule scorer bounds: unknown attributes are weak evidence (0.3), identical attributes score 1.
do $$ begin
 if public.g10_mimic_rule_score(null,null,'{}',null,null,'{}')<>0.3
 or public.g10_mimic_rule_score('#000000','plain','{"a":1}','#000000','PLAIN','{"a":1}')<>1
 or public.g10_mimic_rule_score('#000000','plain','{"a":1}','#ffffff','dot','{"b":1}')<>0
 or public.g10_vector_similarity('{1,0}','{0,1}')<>0 or public.g10_vector_similarity('{1,0}','{1}') is not null
 then raise exception 'FAIL rule/vector scorer bounds'; end if;
end $$;

set local role authenticated;
select set_config('request.jwt.claim.sub','78000000-0000-4000-8000-000000000003',true);
do $$ begin
 begin perform public.get_my_mimic_job(current_setting('test.mimic_job_one')::uuid);
  raise exception 'FAIL cross owner job exposed'; exception when no_data_found then null; end;
end $$;
reset role;

-- The image worker path is retired: nothing is ever claimable.
set local role service_role;
do $$ begin
 if public.claim_mimic_job(120) is not null then raise exception 'FAIL retired claim path'; end if;
end $$;
reset role;

-- AI hook: embeddings with a shared model_version blend into the score and mark the model.
insert into public.garment_embeddings(user_id,garment_id,model_version,embedding) values
 ('78000000-0000-4000-8000-000000000002','78050000-0000-4000-8000-000000000020','emb-v1','{1,0}'),
 ('78000000-0000-4000-8000-000000000001','78050000-0000-4000-8000-000000000001','emb-v1','{0,1}');
set local role authenticated;
select set_config('request.jwt.claim.sub','78000000-0000-4000-8000-000000000001',true);
do $$ declare created jsonb; begin
 created:=public.create_my_mimic_job('78100000-0000-4000-8000-000000000001','mimic-vector-one');
 if created->>'model_version'<>'rule-v1-vector' or created#>>'{matches,0,grade}'<>'low'
 then raise exception 'FAIL vector blend %',created; end if;
 perform set_config('test.mimic_vector_job',created->>'id',true);
end $$;
reset role;
do $$ begin
 -- Raw scores stay internal.
 if (select (result#>>'{matches,0,similarity}')::numeric from public.mimic_requests where id=current_setting('test.mimic_vector_job')::uuid)
  not between 0.45 and 0.55
 or public.g10_mimic_grade(0.75)<>'high' or public.g10_mimic_grade(0.7499)<>'medium' or public.g10_mimic_grade(0.5)<>'medium'
 or public.g10_mimic_grade(0.4999)<>'low' or public.g10_mimic_grade(-1)<>'low' or public.g10_mimic_grade(null) is not null
 then raise exception 'FAIL internal score/grade thresholds'; end if;
end $$;

-- Viewer deletes the matched garment: the stored result withholds it.
update public.garments set deleted_at=now() where id='78050000-0000-4000-8000-000000000001';
set local role authenticated;
select set_config('request.jwt.claim.sub','78000000-0000-4000-8000-000000000001',true);
do $$ declare projected jsonb; begin
 projected:=public.get_my_mimic_job(current_setting('test.mimic_job_one')::uuid);
 if projected->>'status'<>'no_match' or (projected->>'coverage')::numeric<>0 or projected->'matches'->0->'garment_id'<>'null'::jsonb
 then raise exception 'FAIL unavailable terminal garment projection'; end if;
end $$;
reset role;
update public.garments set deleted_at=null where id='78050000-0000-4000-8000-000000000001';
update public.feed_posts set visibility='private' where id='78100000-0000-4000-8000-000000000001';
set local role authenticated;
select set_config('request.jwt.claim.sub','78000000-0000-4000-8000-000000000001',true);
do $$ begin
 begin perform public.get_my_mimic_job(current_setting('test.mimic_job_one')::uuid);
  raise exception 'FAIL private source result exposed'; exception when no_data_found then null; end;
end $$;
reset role;

do $$ begin
 if not exists(select 1 from public.mimic_requests where id=current_setting('test.mimic_job_one')::uuid
  and retention_expires_at between now()+interval '6 days 23 hours' and now()+interval '7 days 1 hour')
 then raise exception 'FAIL terminal seven-day retention'; end if;
 if exists(select 1 from public.mimic_candidate_items where garment_id='78050000-0000-4000-8000-000000000009')
 then raise exception 'FAIL foreign closet in candidates'; end if;
 delete from public.feed_posts where user_id='78000000-0000-4000-8000-000000000002';
 if exists(select 1 from public.mimic_requests where post_id in(
  '78100000-0000-4000-8000-000000000001','78100000-0000-4000-8000-000000000002','78100000-0000-4000-8000-000000000003'))
 then raise exception 'FAIL post mimic cascade'; end if;
end $$;

rollback;
