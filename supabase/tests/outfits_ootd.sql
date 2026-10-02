-- Run only against a disposable migrated database. Every fixture rolls back.
begin;

insert into auth.users(id) values
 ('76000000-0000-4000-8000-000000000001'),('76000000-0000-4000-8000-000000000002');
insert into public.garment_batches(id,user_id,status) values
 ('76100000-0000-4000-8000-000000000001','76000000-0000-4000-8000-000000000001','confirmed'),
 ('76100000-0000-4000-8000-000000000002','76000000-0000-4000-8000-000000000002','confirmed');
insert into public.garment_assets(id,user_id,batch_id,kind,object_key,content_type,byte_size,verified_at) values
 ('76200000-0000-4000-8000-000000000001','76000000-0000-4000-8000-000000000001','76100000-0000-4000-8000-000000000001','cutout','76000000-0000-4000-8000-000000000001/a.png','image/png',10,now()),
 ('76200000-0000-4000-8000-000000000002','76000000-0000-4000-8000-000000000001','76100000-0000-4000-8000-000000000001','cutout','76000000-0000-4000-8000-000000000001/b.png','image/png',10,now()),
 ('76200000-0000-4000-8000-000000000003','76000000-0000-4000-8000-000000000001','76100000-0000-4000-8000-000000000001','cutout','76000000-0000-4000-8000-000000000001/c.png','image/png',10,now()),
 ('76200000-0000-4000-8000-000000000004','76000000-0000-4000-8000-000000000002','76100000-0000-4000-8000-000000000002','cutout','76000000-0000-4000-8000-000000000002/a.png','image/png',10,now());
insert into public.analysis_jobs(id,user_id,batch_id,status) values
 ('76300000-0000-4000-8000-000000000001','76000000-0000-4000-8000-000000000001','76100000-0000-4000-8000-000000000001','succeeded'),
 ('76300000-0000-4000-8000-000000000002','76000000-0000-4000-8000-000000000002','76100000-0000-4000-8000-000000000002','succeeded');
insert into public.garment_drafts(id,user_id,batch_id,job_id,item_index,asset_id,status,raw_prediction,model_version) values
 ('76400000-0000-4000-8000-000000000001','76000000-0000-4000-8000-000000000001','76100000-0000-4000-8000-000000000001','76300000-0000-4000-8000-000000000001',0,'76200000-0000-4000-8000-000000000001','confirmed','{"category":"top"}','v1'),
 ('76400000-0000-4000-8000-000000000002','76000000-0000-4000-8000-000000000001','76100000-0000-4000-8000-000000000001','76300000-0000-4000-8000-000000000001',1,'76200000-0000-4000-8000-000000000002','confirmed','{"category":"bottom"}','v1'),
 ('76400000-0000-4000-8000-000000000003','76000000-0000-4000-8000-000000000001','76100000-0000-4000-8000-000000000001','76300000-0000-4000-8000-000000000001',2,'76200000-0000-4000-8000-000000000003','confirmed','{"category":"shoes"}','v1'),
 ('76400000-0000-4000-8000-000000000004','76000000-0000-4000-8000-000000000002','76100000-0000-4000-8000-000000000002','76300000-0000-4000-8000-000000000002',0,'76200000-0000-4000-8000-000000000004','confirmed','{"category":"top"}','v1');
insert into public.garments(id,user_id,source_draft_id,asset_id,category) values
 ('76500000-0000-4000-8000-000000000001','76000000-0000-4000-8000-000000000001','76400000-0000-4000-8000-000000000001','76200000-0000-4000-8000-000000000001','top'),
 ('76500000-0000-4000-8000-000000000002','76000000-0000-4000-8000-000000000001','76400000-0000-4000-8000-000000000002','76200000-0000-4000-8000-000000000002','bottom'),
 ('76500000-0000-4000-8000-000000000003','76000000-0000-4000-8000-000000000001','76400000-0000-4000-8000-000000000003','76200000-0000-4000-8000-000000000003','shoes'),
 ('76500000-0000-4000-8000-000000000004','76000000-0000-4000-8000-000000000002','76400000-0000-4000-8000-000000000004','76200000-0000-4000-8000-000000000004','top');

insert into public.weather_snapshots(id,grid_x,grid_y,issued_at,valid_at,source,payload) values
 ('76600000-0000-4000-8000-000000000001',60,127,
  ((current_date-2)::timestamp+interval '6 hours') at time zone 'Asia/Seoul',
  ((current_date-2)::timestamp+interval '12 hours') at time zone 'Asia/Seoul','kma_short_term',
  '{"temperature_c":20,"precipitation_type":"none"}');
insert into public.recommendation_requests(id,user_id,weather_snapshot_id,target_date,requested_count,status,preference_snapshot,engine_version,expires_at,rules_version)
 values('76700000-0000-4000-8000-000000000001','76000000-0000-4000-8000-000000000001','76600000-0000-4000-8000-000000000001',current_date-2,1,'ready','[]','v1',now()+interval '1 day','v1');
insert into public.outfit_recommendations(id,user_id,request_id,rank,scores,reason_facts,explanation_source)
 values('76800000-0000-4000-8000-000000000001','76000000-0000-4000-8000-000000000001','76700000-0000-4000-8000-000000000001',1,'{}','[]','template');
insert into public.outfit_items(user_id,outfit_id,garment_id,slot) values
 ('76000000-0000-4000-8000-000000000001','76800000-0000-4000-8000-000000000001','76500000-0000-4000-8000-000000000001','top'),
 ('76000000-0000-4000-8000-000000000001','76800000-0000-4000-8000-000000000001','76500000-0000-4000-8000-000000000002','bottom');
-- Legacy/corrupt array members must not make the statistics RPC cast-fail.
insert into public.ootd_entries(id,user_id,worn_on,wear_status,item_snapshot)
 values('76910000-0000-4000-8000-000000000001','76000000-0000-4000-8000-000000000001',current_date-20,'worn',
  '[{"garment_id":"not-a-uuid","category":"top","unavailable":false},{"category":"top"}]');

set local role authenticated;
select set_config('request.jwt.claim.sub','76000000-0000-4000-8000-000000000001',true);
do $$ declare created jsonb; replay jsonb; saved uuid; ootd uuid; planned uuid; disposable uuid; blocked uuid; accepted uuid; patched jsonb; stats jsonb; snap jsonb; begin
 begin insert into public.saved_outfits(user_id,title) values(auth.uid(),'forged'); raise exception 'FAIL direct saved write';
  exception when insufficient_privilege then null; end;
 begin insert into public.ootd_entries(user_id,worn_on,item_snapshot) values(auth.uid(),current_date,'[]'); raise exception 'FAIL direct ootd write';
  exception when insufficient_privilege then null; end;
 begin perform public.g6_build_snapshot(auth.uid(),array['76500000-0000-4000-8000-000000000001'::uuid]); raise exception 'FAIL helper exposed';
  exception when insufficient_privilege then null; end;

 created:=public.create_my_saved_outfit('source look',null,array['76500000-0000-4000-8000-000000000002'::uuid,'76500000-0000-4000-8000-000000000001'::uuid],
  '76800000-0000-4000-8000-000000000001','saved-key-one');
 replay:=public.create_my_saved_outfit('source look',null,array['76500000-0000-4000-8000-000000000002'::uuid,'76500000-0000-4000-8000-000000000001'::uuid],
  '76800000-0000-4000-8000-000000000001','saved-key-one');
 saved:=(created->>'saved_outfit_id')::uuid;
 if created->>'replayed'<>'false' or replay->>'replayed'<>'true' or replay->>'saved_outfit_id'<>saved::text
 or (select array_agg(garment_id order by position) from public.saved_outfit_items where saved_outfit_id=saved)
  <>array['76500000-0000-4000-8000-000000000002'::uuid,'76500000-0000-4000-8000-000000000001'::uuid]
 then raise exception 'FAIL saved create/replay/order'; end if;
 begin perform public.create_my_saved_outfit('changed',null,array['76500000-0000-4000-8000-000000000001'::uuid],null,'saved-key-one');
  raise exception 'FAIL saved idempotency conflict'; exception when raise_exception then if sqlerrm<>'idempotency_conflict' then raise; end if; end;
 begin perform public.create_my_saved_outfit('cross',null,array['76500000-0000-4000-8000-000000000004'::uuid],null,'saved-cross');
  raise exception 'FAIL cross owner garment'; exception when no_data_found then null; end;
 begin perform public.update_my_saved_outfit(saved,1,false,null,false,null,true,array['76500000-0000-4000-8000-000000000003'::uuid],false,null);
  raise exception 'FAIL source mismatch update'; exception when raise_exception then if sqlerrm<>'source_composition_mismatch' then raise; end if; end;
 patched:=public.update_my_saved_outfit(saved,1,true,'renamed',false,null,false,null,false,null);
 if patched->>'version'<>'2' then raise exception 'FAIL saved version'; end if;
 begin perform public.update_my_saved_outfit(saved,1,true,'stale',false,null,false,null,false,null);
  raise exception 'FAIL saved stale version'; exception when raise_exception then if sqlerrm<>'version_conflict' then raise; end if; end;

 created:=public.create_my_ootd(current_date-2,array['76500000-0000-4000-8000-000000000002'::uuid,'76500000-0000-4000-8000-000000000001'::uuid],saved,null,'worn',null,5,'76600000-0000-4000-8000-000000000001','ootd-create-one');
 replay:=public.create_my_ootd(current_date-2,array['76500000-0000-4000-8000-000000000002'::uuid,'76500000-0000-4000-8000-000000000001'::uuid],saved,null,'worn',null,5,'76600000-0000-4000-8000-000000000001','ootd-create-one');
 ootd:=(created->>'ootd_id')::uuid;
 snap:=(select item_snapshot from public.ootd_entries where id=ootd);
 if replay->>'replayed'<>'true' or jsonb_array_length(snap)<>2
 or (select array_agg(key order by key) from jsonb_object_keys(snap->0) key)<>array['category','garment_id','unavailable']
 or snap->0->>'garment_id'<>'76500000-0000-4000-8000-000000000002' then raise exception 'FAIL ootd replay/exact ordered snapshot'; end if;
 begin perform public.create_my_ootd(current_date-2,array['76500000-0000-4000-8000-000000000003'::uuid],null,null,'planned',null,null,null,'ootd-date-other');
  raise exception 'FAIL date conflict'; exception when raise_exception then if sqlerrm<>'ootd_date_conflict' then raise; end if; end;
 begin perform public.create_my_ootd(current_date+1,array['76500000-0000-4000-8000-000000000003'::uuid],null,null,'worn',null,null,null,'ootd-future');
  raise exception 'FAIL future worn'; exception when invalid_parameter_value then null; end;
 created:=public.create_my_ootd(current_date-1,array['76500000-0000-4000-8000-000000000003'::uuid],null,null,'planned',null,null,null,'ootd-planned');
 planned:=(created->>'ootd_id')::uuid;
 patched:=public.update_my_ootd(planned,1,false,null,false,null,false,null,false,null,false,null,true,'plan note',false,null,false,null);
 if patched->>'version'<>'2' then raise exception 'FAIL ootd update version'; end if;
 begin perform public.update_my_ootd(planned,1,false,null,false,null,false,null,false,null,false,null,true,'stale',false,null,false,null);
  raise exception 'FAIL ootd stale'; exception when raise_exception then if sqlerrm<>'version_conflict' then raise; end if; end;
 patched:=public.update_my_ootd(planned,2,true,current_date-6,false,null,false,null,false,null,false,null,false,null,false,null,false,null);
 if patched->>'version'<>'3' or (select worn_on from public.ootd_entries where id=planned)<>current_date-6
 then raise exception 'FAIL ootd ordered date-lock update'; end if;

 perform public.delete_my_saved_outfit(saved);
 if (select saved_outfit_id is not null or item_snapshot<>snap from public.ootd_entries where id=ootd)
 then raise exception 'FAIL saved delete detach/snapshot'; end if;
 replay:=public.create_my_saved_outfit('source look',null,array['76500000-0000-4000-8000-000000000002'::uuid,'76500000-0000-4000-8000-000000000001'::uuid],
  '76800000-0000-4000-8000-000000000001','saved-key-one');
 if replay->>'replayed'<>'false' or replay->>'saved_outfit_id'=saved::text
 then raise exception 'FAIL saved create replay tombstone cleanup'; end if;

 created:=public.create_my_ootd(current_date-3,array['76500000-0000-4000-8000-000000000003'::uuid],null,null,'planned',null,null,null,'ootd-disposable');
 disposable:=(created->>'ootd_id')::uuid;
 created:=public.delete_my_ootd(disposable,'ootd-delete-one');
 replay:=public.delete_my_ootd(disposable,'ootd-delete-one');
 if created->>'replayed'<>'false' or replay->>'replayed'<>'true' then raise exception 'FAIL delete replay'; end if;
 replay:=public.create_my_ootd(current_date-3,array['76500000-0000-4000-8000-000000000003'::uuid],null,null,'planned',null,null,null,'ootd-disposable');
 if replay->>'replayed'<>'false' or replay->>'ootd_id'=disposable::text
 then raise exception 'FAIL OOTD create replay tombstone cleanup'; end if;

 created:=public.create_my_ootd(current_date-4,array['76500000-0000-4000-8000-000000000003'::uuid],null,null,'planned',null,null,null,'ootd-blocked');
 blocked:=(created->>'ootd_id')::uuid;
 perform set_config('test.g6_blocked_ootd',blocked::text,true);
 created:=public.create_my_ootd(current_date-5,array['76500000-0000-4000-8000-000000000003'::uuid],null,null,'planned',null,null,null,'ootd-accepted');
 accepted:=(created->>'ootd_id')::uuid;
 perform set_config('test.g6_accepted_ootd',accepted::text,true);

 stats:=public.get_my_closet_statistics();
 if stats->>'as_of' is null
 or (select (x->>'count')::integer from jsonb_array_elements(stats->'wear_counts') x where x->>'garment_id'='76500000-0000-4000-8000-000000000001')<>1
 or (select (x->>'count')::integer from jsonb_array_elements(stats->'wear_counts') x where x->>'garment_id'='76500000-0000-4000-8000-000000000003')<>0
 or not(stats->'unworn_30_days' ? '76500000-0000-4000-8000-000000000003')
 then raise exception 'FAIL worn-only statistics'; end if;
end $$;
reset role;

insert into public.idempotency_keys(user_id,scope,key,request_hash,response_body,response_status)
 values('76000000-0000-4000-8000-000000000001','recommendation_accept','legacy-accept-key','hash',
  jsonb_build_object('ootd_id',current_setting('test.g6_accepted_ootd')),201);
insert into public.feed_posts(id,user_id,source_ootd_id,caption,visibility)
 values('76900000-0000-4000-8000-000000000001','76000000-0000-4000-8000-000000000001',current_setting('test.g6_blocked_ootd')::uuid,'shared','private');
set local role authenticated;
select set_config('request.jwt.claim.sub','76000000-0000-4000-8000-000000000001',true);
do $$ begin
 begin perform public.update_my_ootd(current_setting('test.g6_accepted_ootd')::uuid,1,false,null,false,null,false,null,false,null,false,null,true,'changed',false,null,false,null);
  raise exception 'FAIL accepted replay target update'; exception when raise_exception then if sqlerrm<>'accepted_ootd_immutable' then raise; end if; end;
 begin perform public.delete_my_ootd(current_setting('test.g6_accepted_ootd')::uuid,'ootd-delete-accepted');
  raise exception 'FAIL accepted replay target delete'; exception when raise_exception then if sqlerrm<>'accepted_ootd_immutable' then raise; end if; end;
 begin perform public.delete_my_ootd(current_setting('test.g6_blocked_ootd')::uuid,'ootd-delete-blocked');
  raise exception 'FAIL feed reference delete'; exception when raise_exception then if sqlerrm<>'ootd_in_use' then raise; end if; end;
 if not exists(select 1 from public.ootd_entries where id=current_setting('test.g6_blocked_ootd')::uuid)
 then raise exception 'FAIL blocked OOTD removed'; end if;
end $$;
reset role;

update public.garments set deleted_at=now() where id='76500000-0000-4000-8000-000000000003';
set local role authenticated;
select set_config('request.jwt.claim.sub','76000000-0000-4000-8000-000000000001',true);
do $$ declare overlay jsonb; begin
 overlay:=public.get_my_ootd_snapshot(current_setting('test.g6_blocked_ootd')::uuid);
 if overlay->0->>'unavailable'<>'true' or overlay->0->>'category'<>'shoes'
 then raise exception 'FAIL unavailable overlay'; end if;
 if (select item_snapshot->0->>'unavailable' from public.ootd_entries where id=current_setting('test.g6_blocked_ootd')::uuid)<>'false'
 then raise exception 'FAIL overlay mutated snapshot'; end if;
end $$;
reset role;

rollback;
