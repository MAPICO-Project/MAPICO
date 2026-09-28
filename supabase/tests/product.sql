begin;
insert into auth.users(id) values ('aaaaaaaa-0000-0000-0000-000000000001'),('bbbbbbbb-0000-0000-0000-000000000002');
insert into public.saved_outfits(id,user_id,title) values
 ('11111111-0000-0000-0000-000000000001','aaaaaaaa-0000-0000-0000-000000000001','private outfit');
insert into public.ootd_entries(id,user_id,worn_on,item_snapshot,saved_outfit_id) values
 ('22222222-0000-0000-0000-000000000002','aaaaaaaa-0000-0000-0000-000000000001','2026-09-28','[]','11111111-0000-0000-0000-000000000001');
insert into public.feed_posts(id,user_id,source_ootd_id,visibility) values
 ('33333333-0000-0000-0000-000000000003','aaaaaaaa-0000-0000-0000-000000000001','22222222-0000-0000-0000-000000000002','public'),
 ('44444444-0000-0000-0000-000000000004','aaaaaaaa-0000-0000-0000-000000000001',null,'private');
insert into public.post_likes(user_id,post_id) values
 ('bbbbbbbb-0000-0000-0000-000000000002','33333333-0000-0000-0000-000000000003');
insert into public.mimic_requests(user_id,post_id,result) values
 ('bbbbbbbb-0000-0000-0000-000000000002','33333333-0000-0000-0000-000000000003','{"internal":true}');
do $$ begin
 if (select count(*) from public.aesthetics where code in ('feminine','y2k','minimal','grunge','casual'))<>5 then raise exception 'missing seeds'; end if;
 begin
  insert into public.ootd_entries(user_id,worn_on,saved_outfit_id) values
   ('bbbbbbbb-0000-0000-0000-000000000002','2026-09-28','11111111-0000-0000-0000-000000000001');
  raise exception 'cross-owner outfit accepted';
 exception when foreign_key_violation then null; end;
 begin
  insert into public.feed_posts(user_id,source_ootd_id) values
   ('bbbbbbbb-0000-0000-0000-000000000002','22222222-0000-0000-0000-000000000002');
  raise exception 'cross-owner publication accepted';
 exception when foreign_key_violation then null; end;
end $$;
set local role authenticated;
select set_config('request.jwt.claim.sub','bbbbbbbb-0000-0000-0000-000000000002',true);
do $$ begin
 if (select count(id) from public.saved_outfits)<>0 then raise exception 'private outfit leak'; end if;
 if (select count(id) from public.feed_posts)<>1 then raise exception 'feed visibility broken'; end if;
 if (select count(*) from public.post_likes)<>1 then raise exception 'own archive missing'; end if;
 begin perform source_ootd_id from public.feed_posts; raise exception 'private source leaked'; exception when insufficient_privilege then null; end;
 begin perform object_key from public.feed_media; raise exception 'private storage leaked'; exception when insufficient_privilege then null; end;
 begin perform result from public.mimic_requests; raise exception 'raw model output leaked'; exception when insufficient_privilege then null; end;
 begin insert into public.post_likes(user_id,post_id) values(auth.uid(),'44444444-0000-0000-0000-000000000004'); raise exception 'direct write allowed'; exception when insufficient_privilege then null; end;
end $$;
reset role;
update public.feed_posts set visibility='private' where id='33333333-0000-0000-0000-000000000003';
set local role authenticated;
do $$ begin if (select count(*) from public.post_likes)<>0 then raise exception 'hidden post archive leaked'; end if; end $$;
select set_config('request.jwt.claim.sub','aaaaaaaa-0000-0000-0000-000000000001',true);
do $$ begin
 begin
  perform public.accept_outfit('99999999-0000-0000-0000-000000000009','2026-09-28');
  raise exception 'manual entry confused with recommendation';
 exception when raise_exception then
  if sqlerrm<>'ootd_date_conflict' then raise; end if;
 end;
end $$;
reset role;
delete from auth.users where id='aaaaaaaa-0000-0000-0000-000000000001';
do $$ begin if exists(select 1 from public.mimic_requests) then raise exception 'deleted author mimic retained'; end if; end $$;
rollback;
