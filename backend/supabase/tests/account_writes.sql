-- Run only against a disposable migrated database. Every fixture rolls back.
begin;
insert into auth.users(id) values
 ('70000000-0000-4000-8000-000000000001'),
 ('70000000-0000-4000-8000-000000000002');
insert into public.aesthetics(id,code,label,definition,version,active) values
 ('71000000-0000-4000-8000-000000000001','fixture_rpc_1','Fixture RPC 1','Test only','fixture-rpc-v1',true),
 ('71000000-0000-4000-8000-000000000002','fixture_rpc_2','Fixture RPC 2','Test only','fixture-rpc-v1',true),
 ('71000000-0000-4000-8000-000000000003','fixture_rpc_3','Fixture RPC 3','Test only','fixture-rpc-v1',true),
 ('71000000-0000-4000-8000-000000000004','fixture_rpc_inactive','Fixture inactive','Test only','fixture-rpc-v1',false);

do $$ begin
 begin perform public.update_my_profile(true,'No auth',false,null); raise exception 'FAIL unauthenticated profile RPC';
 exception when insufficient_privilege then null; end;
 begin perform public.replace_my_aesthetic_preferences('[]'); raise exception 'FAIL unauthenticated preferences RPC';
 exception when insufficient_privilege then null; end;
 begin perform public.save_my_onboarding_state(null,false,false); raise exception 'FAIL unauthenticated onboarding RPC';
 exception when insufficient_privilege then null; end;
end $$;

set local role authenticated;
select set_config('request.jwt.claim.sub','70000000-0000-4000-8000-000000000001',true);

do $$ begin
 begin update public.profiles set display_name='direct'; raise exception 'FAIL direct profile write';
 exception when insufficient_privilege then null; end;
 begin insert into public.user_aesthetic_preferences(user_id,aesthetic_id,weight)
  values(auth.uid(),'71000000-0000-4000-8000-000000000001',1); raise exception 'FAIL direct preference write';
 exception when insufficient_privilege then null; end;

 perform public.update_my_profile(true,'Fixture User',true,'Asia/Seoul');
 if not exists(select 1 from public.profiles where id=auth.uid() and display_name='Fixture User' and timezone='Asia/Seoul')
 then raise exception 'FAIL profile update'; end if;
 perform public.update_my_profile(false,null,true,'UTC');
 if not exists(select 1 from public.profiles where id=auth.uid() and display_name='Fixture User' and timezone='UTC')
 then raise exception 'FAIL omitted display name'; end if;
 perform public.update_my_profile(true,null,false,null);
 if not exists(select 1 from public.profiles where id=auth.uid() and display_name is null and timezone='UTC')
 then raise exception 'FAIL explicit display name clear'; end if;
 if exists(select 1 from public.profiles where id='70000000-0000-4000-8000-000000000002' and (display_name is not null or timezone<>'Asia/Seoul'))
 then raise exception 'FAIL cross-user profile mutation'; end if;

 begin perform public.update_my_profile(false,null,false,null); raise exception 'FAIL empty patch';
 exception when invalid_parameter_value then if sqlerrm<>'empty_profile_patch' then raise; end if; end;
 begin perform public.update_my_profile(true,'',false,null); raise exception 'FAIL empty display name';
 exception when invalid_parameter_value then if sqlerrm<>'invalid_display_name' then raise; end if; end;
 begin perform public.update_my_profile(false,null,true,'Not/A_Timezone'); raise exception 'FAIL invalid timezone';
 exception when invalid_parameter_value then if sqlerrm<>'invalid_timezone' then raise; end if; end;

 perform public.replace_my_aesthetic_preferences('[
  {"aesthetic_id":"71000000-0000-4000-8000-000000000001","weight":0.7},
  {"aesthetic_id":"71000000-0000-4000-8000-000000000002","weight":0.3}
 ]');
 if (select count(*) from public.user_aesthetic_preferences where user_id=auth.uid())<>2
 or (select sum(weight) from public.user_aesthetic_preferences where user_id=auth.uid())<>1
 then raise exception 'FAIL valid preference replacement'; end if;

 begin perform public.replace_my_aesthetic_preferences('[]'); raise exception 'FAIL zero preferences';
 exception when invalid_parameter_value then if sqlerrm<>'invalid_preference_count' then raise; end if; end;
 begin perform public.replace_my_aesthetic_preferences('[
  {"aesthetic_id":"71000000-0000-4000-8000-000000000001","weight":0.5},
  {"aesthetic_id":"71000000-0000-4000-8000-000000000001","weight":0.5}
 ]'); raise exception 'FAIL duplicate preference';
 exception when invalid_parameter_value then if sqlerrm<>'duplicate_aesthetic' then raise; end if; end;
 begin perform public.replace_my_aesthetic_preferences('[
  {"aesthetic_id":"71000000-0000-4000-8000-000000000001","weight":0.8},
  {"aesthetic_id":"71000000-0000-4000-8000-000000000002","weight":0.3}
 ]'); raise exception 'FAIL invalid weight sum';
 exception when invalid_parameter_value then if sqlerrm<>'invalid_preference_weight_sum' then raise; end if; end;
 begin perform public.replace_my_aesthetic_preferences('[
  {"aesthetic_id":"71000000-0000-4000-8000-000000000004","weight":1}
 ]'); raise exception 'FAIL inactive preference';
 exception when invalid_parameter_value then if sqlerrm<>'inactive_or_unknown_aesthetic' then raise; end if; end;
 if (select count(*) from public.user_aesthetic_preferences where user_id=auth.uid())<>2
 then raise exception 'FAIL invalid replacement was not atomic'; end if;

 perform public.save_my_onboarding_state(null,true,true);
 if not exists(select 1 from public.profiles where id=auth.uid() and knows_aesthetic is null and tutorial_seen and onboarding_completed)
 then raise exception 'FAIL onboarding state'; end if;
 perform public.save_my_onboarding_state(false,false,false);
 if not exists(select 1 from public.profiles where id=auth.uid() and knows_aesthetic=false and not tutorial_seen and not onboarding_completed)
 then raise exception 'FAIL onboarding idempotent replacement'; end if;
 begin perform public.save_my_onboarding_state(true,null,true); raise exception 'FAIL null tutorial state';
 exception when invalid_parameter_value then if sqlerrm<>'invalid_onboarding_state' then raise; end if; end;
end $$;

reset role;
rollback;
