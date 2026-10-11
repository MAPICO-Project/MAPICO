-- 2026-10-10 track C. Run only against a disposable migrated database. Every fixture rolls back.
begin;
insert into auth.users(id) values ('7a000000-0000-4000-8000-000000000001'),('7a000000-0000-4000-8000-000000000002');
insert into public.user_aesthetic_preferences(user_id,aesthetic_id,weight,role)
 select '7a000000-0000-4000-8000-000000000001',id,case code when 'minimal' then 0.6 else 0.4 end,case code when 'minimal' then 'main' else 'sub' end
 from public.aesthetics where code in ('minimal','casual');
insert into public.garment_batches(id,user_id,status) values
 ('7a100000-0000-4000-8000-000000000001','7a000000-0000-4000-8000-000000000001','confirmed');
insert into public.garment_assets(id,user_id,batch_id,kind,object_key,content_type,byte_size,verified_at)
 select ('7a200000-0000-4000-8000-00000000000'||n)::uuid,'7a000000-0000-4000-8000-000000000001','7a100000-0000-4000-8000-000000000001','cutout',
  '7a000000-0000-4000-8000-000000000001/'||n||'.png','image/png',10,now() from generate_series(1,3) n;
insert into public.analysis_jobs(id,user_id,batch_id,status) values
 ('7a300000-0000-4000-8000-000000000001','7a000000-0000-4000-8000-000000000001','7a100000-0000-4000-8000-000000000001','succeeded');
insert into public.garment_drafts(id,user_id,batch_id,job_id,item_index,asset_id,status,raw_prediction,model_version)
 select ('7a400000-0000-4000-8000-00000000000'||n)::uuid,'7a000000-0000-4000-8000-000000000001','7a100000-0000-4000-8000-000000000001',
  '7a300000-0000-4000-8000-000000000001',n-1,('7a200000-0000-4000-8000-00000000000'||n)::uuid,'confirmed','{}','v1' from generate_series(1,3) n;
insert into public.garments(id,user_id,source_draft_id,asset_id,category)
 select ('7a500000-0000-4000-8000-00000000000'||n)::uuid,'7a000000-0000-4000-8000-000000000001',('7a400000-0000-4000-8000-00000000000'||n)::uuid,
  ('7a200000-0000-4000-8000-00000000000'||n)::uuid,(array['top','bottom','shoes'])[n] from generate_series(1,3) n;
-- g1 top: minimal .8 casual .2 / g2 bottom: minimal .5 casual .9 / g3 shoes: casual .7
insert into public.garment_aesthetic_scores(user_id,garment_id,aesthetic_id,score,model_version)
 select '7a000000-0000-4000-8000-000000000001',v.g::uuid,a.id,v.s,'fixture' from (values
  ('7a500000-0000-4000-8000-000000000001','minimal',0.8),('7a500000-0000-4000-8000-000000000001','casual',0.2),
  ('7a500000-0000-4000-8000-000000000002','minimal',0.5),('7a500000-0000-4000-8000-000000000002','casual',0.9),
  ('7a500000-0000-4000-8000-000000000003','casual',0.7)) v(g,c,s) join public.aesthetics a on a.code=v.c;
-- Two worn entries count separately (g2 twice); a planned entry and a future-dated worn entry do not count.
-- Distinct dates keep this independent of track B's one-entry-per-day change.
insert into public.ootd_entries(user_id,worn_on,wear_status,item_snapshot) values
 ('7a000000-0000-4000-8000-000000000001',current_date-1,'worn',
  '[{"garment_id":"7a500000-0000-4000-8000-000000000001"},{"garment_id":"7a500000-0000-4000-8000-000000000002"}]'),
 ('7a000000-0000-4000-8000-000000000001',current_date-2,'worn',
  '[{"garment_id":"7a500000-0000-4000-8000-000000000002"},{"garment_id":"7a500000-0000-4000-8000-000000000003"}]'),
 ('7a000000-0000-4000-8000-000000000001',current_date-3,'planned','[{"garment_id":"7a500000-0000-4000-8000-000000000001"}]'),
 ('7a000000-0000-4000-8000-000000000001',current_date+5,'worn','[{"garment_id":"7a500000-0000-4000-8000-000000000001"}]');

set local role authenticated;
select set_config('request.jwt.claim.sub','7a000000-0000-4000-8000-000000000001',true);
do $$ declare stats jsonb; r jsonb; minimal uuid; casual uuid; feminine uuid; begin
 select id into minimal from public.aesthetics where code='minimal';
 select id into casual from public.aesthetics where code='casual';
 select id into feminine from public.aesthetics where code='feminine';
 stats:=public.get_my_closet_statistics();
 if stats->'top_aesthetic'->>'code'<>'casual' or (stats->'top_aesthetic'->>'score_total')::numeric<>2.7
 or jsonb_array_length(stats->'aesthetic_totals')<>2
 or (stats->'aesthetic_totals'->1->>'code')<>'minimal' or (stats->'aesthetic_totals'->1->>'score_total')::numeric<>1.8
 or (select (x->>'count')::integer from jsonb_array_elements(stats->'wear_counts') x where x->>'garment_id'='7a500000-0000-4000-8000-000000000002')<>2
 then raise exception 'FAIL most-worn aesthetic statistics: %',stats; end if;

 -- Chip reservation: one of my preferences is stored; anything else is rejected.
 r:=public.begin_my_recommendation(60,127,date_trunc('hour',now()),3,'chip-sub',repeat('a',64),'engine','rules',casual);
 if (select selected_aesthetic_id from public.recommendation_requests where id=(r->>'request_id')::uuid)<>casual
 then raise exception 'FAIL selected aesthetic not stored'; end if;
 r:=public.begin_my_recommendation(60,127,date_trunc('hour',now()),3,'chip-sub',repeat('a',64),'engine','rules',casual);
 if r->>'replayed'<>'true' then raise exception 'FAIL chip reservation replay'; end if;
 begin perform public.begin_my_recommendation(60,127,date_trunc('hour',now()),3,'chip-other',repeat('b',64),'engine','rules',feminine);
  raise exception 'FAIL foreign chip accepted'; exception when invalid_parameter_value then if sqlerrm<>'invalid_recommendation' then raise; end if; end;
 begin perform public.begin_my_recommendation(60,127,date_trunc('hour',now()),3,'chip-null',repeat('c',64),'engine','rules',null::uuid);
  raise exception 'FAIL null chip accepted with preferences'; exception when invalid_parameter_value then if sqlerrm<>'invalid_recommendation' then raise; end if; end;
end $$;

-- Same-key retry after the chosen chip left the preferences: replay, not a validation error.
reset role;
delete from public.user_aesthetic_preferences p using public.aesthetics a
 where p.user_id='7a000000-0000-4000-8000-000000000001' and p.aesthetic_id=a.id and a.code='casual';
set local role authenticated;
do $$ declare r jsonb; casual uuid; begin
 select id into casual from public.aesthetics where code='casual';
 r:=public.begin_my_recommendation(60,127,date_trunc('hour',now()),3,'chip-sub',repeat('a',64),'engine','rules',casual);
 if r->>'replayed'<>'true' then raise exception 'FAIL replay must precede chip validation'; end if;
 begin perform public.begin_my_recommendation(60,127,date_trunc('hour',now()),3,'chip-sub-new',repeat('e',64),'engine','rules',casual);
  raise exception 'FAIL removed chip accepted for a new key'; exception when invalid_parameter_value then if sqlerrm<>'invalid_recommendation' then raise; end if; end;
end $$;

-- A user without preferences and without OOTD: null chip allowed, empty aggregate.
select set_config('request.jwt.claim.sub','7a000000-0000-4000-8000-000000000002',true);
do $$ declare stats jsonb; r jsonb; begin
 stats:=public.get_my_closet_statistics();
 if stats->'top_aesthetic'<>'null'::jsonb or stats->'aesthetic_totals'<>'[]'::jsonb then raise exception 'FAIL empty aesthetic statistics'; end if;
 r:=public.begin_my_recommendation(60,127,date_trunc('hour',now()),1,'chip-none',repeat('d',64),'engine','rules',null::uuid);
 if r->>'replayed'<>'false' then raise exception 'FAIL null chip reservation'; end if;
end $$;
reset role;
do $$ begin
 if (select count(*) from pg_proc where proname='begin_my_recommendation' and pronamespace='public'::regnamespace)<>1
 then raise exception 'FAIL begin_my_recommendation must have exactly one signature'; end if;
end $$;

rollback;
