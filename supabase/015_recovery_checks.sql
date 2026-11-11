-- Admin security/behavior checks after 014. All fixture users/data roll back.
-- These predictable tokens are ONLY synthetic test values, never use them for a real role.
begin;
do $$
declare h uuid:=gen_random_uuid();a uuid:=gen_random_uuid();b uuid:=gen_random_uuid();fresh_a uuid:=gen_random_uuid();fresh_h uuid:=gen_random_uuid();last_a uuid:=gen_random_uuid();c text;s jsonb;failed boolean;req uuid;
begin
insert into auth.users(id) values(h),(a),(b),(fresh_a),(fresh_h),(last_a);
perform set_config('request.jwt.claim.sub',h::text,true);s:=public.tt_create();c:=s->>'code';perform public.tt_save_recovery(c,repeat('1',64));
perform set_config('request.jwt.claim.sub',a::text,true);perform public.tt_join(c,'Restorable player');perform public.tt_save_recovery(c,repeat('a',64));
perform set_config('request.jwt.claim.sub',b::text,true);perform public.tt_join(c,'Observer');
if exists(select 1 from public.tt_recovery where room=c and token_hash in (repeat('a',64),repeat('1',64))) then raise exception 'Stored plaintext token';end if;
perform set_config('request.jwt.claim.sub',fresh_a::text,true);failed:=false;
begin perform public.tt_recover(c,repeat('f',64));exception when others then failed:=true;end;
if not failed then raise exception 'Invalid recovery token accepted';end if;
s:=public.tt_recover(c,repeat('a',64));s:=public.tt_recover(c,repeat('a',64));
if (s->>'me')::int<>0 or (s->>'isHost')::boolean then raise exception 'Player recovery/idempotency failed';end if;
perform set_config('request.jwt.claim.sub',a::text,true);failed:=false;
begin perform public.tt_view(c);exception when others then failed:=true;end;
if not failed then raise exception 'Old player identity still controls room';end if;
perform set_config('request.jwt.claim.sub',fresh_a::text,true);perform public.tt_save_recovery(c,repeat('b',64));
failed:=false;begin perform public.tt_recover(c,repeat('1',64));exception when others then failed:=true;end;
if not failed then raise exception 'Browser claimed two roles';end if;
perform set_config('request.jwt.claim.sub',a::text,true);failed:=false;
begin perform public.tt_recover(c,repeat('a',64));exception when others then failed:=true;end;
if not failed then raise exception 'Rotated token still valid';end if;
perform set_config('request.jwt.claim.sub',fresh_h::text,true);s:=public.tt_recover(c,repeat('1',64));
if not (s->>'isHost')::boolean then raise exception 'Host recovery failed';end if;
perform set_config('request.jwt.claim.sub',h::text,true);failed:=false;
begin perform public.tt_view(c);exception when others then failed:=true;end;
if not failed then raise exception 'Old host identity still controls room';end if;
perform set_config('request.jwt.claim.sub',fresh_h::text,true);perform public.tt_fill_test_seats(c);perform public.tt_command(c,gen_random_uuid(),'start',p_size=>3);
update public.tt_rooms set state=jsonb_set(state,'{players,0,points}','7') where code=c;
perform set_config('request.jwt.claim.sub',fresh_a::text,true);req:=gen_random_uuid();perform public.tt_propose(c,req,'Keep my proposal','Test pending author migration','house_rule');
perform set_config('request.jwt.claim.sub',last_a::text,true);s:=public.tt_recover(c,repeat('b',64));
if jsonb_array_length(s->'proposals')<>1 or (s->'players'->0->>'points')::int<>7 then raise exception 'Recovery lost seat state or pending proposals';end if;
perform public.tt_propose(c,req,'Keep my proposal','Test pending author migration','house_rule');
if (select count(*) from public.tt_proposals where room=c)<>1 then raise exception 'Accepted request IDs were not preserved';end if;
if has_table_privilege('authenticated','public.tt_recovery','SELECT') or has_table_privilege('anon','public.tt_recovery','SELECT') or has_function_privilege('anon','public.tt_recover(text,text)','EXECUTE') then raise exception 'Recovery access grants leaked';end if;
if s::text like '%'||repeat('b',64)||'%' then raise exception 'Recovery token leaked into snapshot';end if;
raise notice 'Recovery checks passed. Test users and room will roll back.';
end;$$;
rollback;
