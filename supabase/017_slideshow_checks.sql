-- Admin checks AFTER 016. No production room is modified; all fixtures roll back.
-- Run in SQL Editor before using this rules version for a real match.
begin;
do $$
declare h uuid:=gen_random_uuid();a uuid:=gen_random_uuid();b uuid:=gen_random_uuid();f uuid:=gen_random_uuid();c text;c2 text;l text;s jsonb;ps jsonb;q uuid;req uuid;failed boolean;i int;expected int;
begin
insert into auth.users(id) values(h),(a),(b),(f);
for i in 5..20 loop
expected:=case when i=5 then 8 when i=6 then null when i=7 then 9 when i<=9 then 10 when i=10 then 11 when i<=12 then 12 when i<=14 then 13 when i<=16 then 14 else 15 end;
if public.tt_slideshow_board(i) is distinct from expected then raise exception 'Board schedule mismatch for % players',i;end if;
end loop;
perform set_config('request.jwt.claim.sub',h::text,true);s:=public.tt_create();c:=s->>'code';
if s->>'rulesVersion'<>'slideshow-2026-11' or (s->>'proposalCost')::int<>5 or (s->>'cutoffHour')::int<>18 then raise exception 'New room rules not installed';end if;
perform set_config('request.jwt.claim.sub',a::text,true);s:=public.tt_join(c,'Author');
if (s->'players'->0->>'range')::int<>3 or (s->'players'->0->>'points')::int<>0 then raise exception 'Lobby range/opening-point mismatch';end if;
perform set_config('request.jwt.claim.sub',b::text,true);perform public.tt_join(c,'Recipient');
perform set_config('request.jwt.claim.sub',h::text,true);s:=public.tt_fill_test_seats(c);
failed:=false;begin perform public.tt_command(c,gen_random_uuid(),'start',p_size=>4);exception when others then failed:=true;end;
if not failed then raise exception 'Custom board allowed against slideshow';end if;
s:=public.tt_command(c,gen_random_uuid(),'start',p_size=>8);
if (s->>'size')::int<>8 or exists(select 1 from jsonb_array_elements(s->'players') where (value->>'range')::int<>3 or (value->>'points')::int<>1) then raise exception 'Test opening/range/board mismatch';end if;
update public.tt_rooms set state=jsonb_set(state,'{players,0,points}','4') where code=c;
perform set_config('request.jwt.claim.sub',a::text,true);failed:=false;
begin perform public.tt_propose(c,gen_random_uuid(),'Too early','Four points are not enough','house_rule');exception when others then failed:=true;end;
if not failed then raise exception 'Proposal accepted with four points';end if;
update public.tt_rooms set state=jsonb_set(state,'{players,0,points}','5') where code=c;
req:=gen_random_uuid();s:=public.tt_propose(c,req,'A public agreement','Approved changes identify their proposer','house_rule');perform public.tt_propose(c,req,'A public agreement','Approved changes identify their proposer','house_rule');
if (s->'players'->0->>'points')::int<>5 then raise exception 'Charged before approval';end if;q:=(s->'proposals'->0->>'id')::uuid;
perform set_config('request.jwt.claim.sub',b::text,true);s:=public.tt_view(c);
if jsonb_array_length(s->'proposals')<>0 or s->'players'->0 ? 'points' then raise exception 'Pending/resource privacy leak';end if;
perform set_config('request.jwt.claim.sub',h::text,true);req:=gen_random_uuid();s:=public.tt_review(c,req,q,'approve');s:=public.tt_review(c,req,q,'approve');
if (s->'players'->0->>'points')::int<>0 then raise exception 'Approval did not charge exactly five once';end if;
perform set_config('request.jwt.claim.sub',b::text,true);s:=public.tt_view(c);
if s->'rules'->0->>'authorName'<>'Author' then raise exception 'Approved author not public';end if;
update public.tt_rooms set state=jsonb_set(state,'{players,0,points}','5') where code=c;
perform set_config('request.jwt.claim.sub',a::text,true);s:=public.tt_propose_survivors(c,gen_random_uuid(),'Last four','Share the ending',4);q:=(s->'proposals'->0->>'id')::uuid;
perform set_config('request.jwt.claim.sub',h::text,true);s:=public.tt_review(c,gen_random_uuid(),q,'approve');
if (s->'players'->0->>'points')::int<>0 then raise exception 'Survivor proposal price mismatch';end if;
select state into s from public.tt_rooms where code=c;ps:=s->'players';
for i in 0..4 loop ps:=jsonb_set(ps,array[i::text],(ps->i)||jsonb_build_object('x',case i when 0 then 0 when 1 then 3 when 2 then 0 when 3 then 3 else 7 end,'y',case i when 0 then 0 when 1 then 0 when 2 then 3 when 3 then 3 else 7 end));end loop;
ps:=jsonb_set(ps,'{0,points}','3');ps:=jsonb_set(ps,'{1,points}','9');update public.tt_rooms set state=jsonb_set(s,'{players}',ps) where code=c;
perform set_config('request.jwt.claim.sub',a::text,true);for i in 1..3 loop s:=public.tt_command(c,gen_random_uuid(),'attack',1);end loop;
if s->>'phase'<>'ended' or jsonb_array_length(s->'winners')<>4 then raise exception 'Range-three attack/shared victory failed';end if;
if (select (state->'players'->1->>'points')::int from public.tt_rooms where code=c)<>0 then raise exception 'Eliminated target retained points';end if;
-- Separate test room: self removal forfeits every remaining point.
perform set_config('request.jwt.claim.sub',h::text,true);s:=public.tt_create();c2:=s->>'code';
perform set_config('request.jwt.claim.sub',a::text,true);perform public.tt_join(c2,'Withdrawer');
perform set_config('request.jwt.claim.sub',h::text,true);perform public.tt_fill_test_seats(c2);perform public.tt_command(c2,gen_random_uuid(),'start',p_size=>8);
update public.tt_rooms set state=jsonb_set(state,'{players,0,points}','9') where code=c2;
perform set_config('request.jwt.claim.sub',a::text,true);s:=public.tt_command(c2,gen_random_uuid(),'remove');
if (s->'players'->0->>'points')::int<>0 or (s->'players'->0->>'alive')::boolean then raise exception 'Withdrawal forfeiture failed';end if;
-- Six players: no guessed board size. Resetting this fixture is confined to this rollback transaction.
update public.tt_rooms set state=state||jsonb_build_object('phase','lobby','closed',false) where code=c2;
perform set_config('request.jwt.claim.sub',f::text,true);perform public.tt_join(c2,'Sixth');
perform set_config('request.jwt.claim.sub',h::text,true);failed:=false;
begin perform public.tt_command(c2,gen_random_uuid(),'start',p_size=>8);exception when others then failed:=true;end;
if not failed then raise exception 'Unspecified six-player board invented';end if;
-- Legacy fixture represents a room created before this migration.
s:=public.tt_create();l:=s->>'code';update public.tt_rooms set state=state-'rulesVersion' where code=l;
perform set_config('request.jwt.claim.sub',a::text,true);s:=public.tt_join(l,'Legacy author');
if (s->'players'->0->>'range')::int<>2 or (s->>'proposalCost')::int<>4 then raise exception 'Legacy range/price changed';end if;
perform set_config('request.jwt.claim.sub',h::text,true);perform public.tt_fill_test_seats(l);perform public.tt_command(l,gen_random_uuid(),'start',p_size=>4);
update public.tt_rooms set state=jsonb_set(state,'{players,0,points}','4') where code=l;
perform set_config('request.jwt.claim.sub',a::text,true);s:=public.tt_propose(l,gen_random_uuid(),'Legacy price','Still costs four','house_rule');q:=(s->'proposals'->0->>'id')::uuid;
perform set_config('request.jwt.claim.sub',h::text,true);s:=public.tt_review(l,gen_random_uuid(),q,'approve');
if (s->'players'->0->>'points')::int<>0 then raise exception 'Legacy payment changed';end if;
-- Trusted clock boundary checks; no browser-supplied time is accepted by public RPCs.
update public.tt_rooms set state=state||jsonb_build_object('phase','active','isTest',false,'nextReset','2026-11-11','closed',false) where code in(c,l);
perform public.tt_clock_apply(c,'2026-11-11T01:59:59Z');
if (select (state->>'closed')::boolean from public.tt_rooms where code=c) then raise exception 'Closed before 6 pm Pacific';end if;
perform public.tt_clock_apply(c,'2026-11-11T02:00:00Z');
if not (select (state->>'closed')::boolean from public.tt_rooms where code=c) then raise exception 'Not closed at 6 pm Pacific';end if;
perform public.tt_clock_apply(l,'2026-11-11T02:00:00Z');
if (select (state->>'closed')::boolean from public.tt_rooms where code=l) then raise exception 'Legacy cutoff moved to 6 pm';end if;
perform public.tt_clock_apply(l,'2026-11-11T03:00:00Z');
if not (select (state->>'closed')::boolean from public.tt_rooms where code=l) then raise exception 'Legacy 7 pm cutoff failed';end if;
if has_function_privilege('authenticated','public.tt_is_slideshow(jsonb)','EXECUTE') or has_function_privilege('authenticated','public.tt_clock_apply(text,timestamptz)','EXECUTE') then raise exception 'Private rule/clock helper exposed';end if;
raise notice 'Slideshow checks passed. Fixtures roll back.';
end;$$;
rollback;
