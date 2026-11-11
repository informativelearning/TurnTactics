-- Run AFTER 001_online.sql in SQL Editor. Rolls back all test rows and users.
begin;
do $$
declare host_id uuid:=gen_random_uuid(); ids uuid[];u uuid;c text;s jsonb;a jsonb;rid uuid:=gen_random_uuid();before_points int;i int;uid text;failed boolean;
begin
insert into auth.users(id) values(host_id);
for i in 1..5 loop u:=gen_random_uuid();insert into auth.users(id) values(u);ids:=array_append(ids,u);end loop;
perform set_config('request.jwt.claim.sub',host_id::text,true);
s:=public.tt_create();c:=s->>'code';
-- Too few players: start must fail.
failed:=false;begin perform public.tt_command(c,gen_random_uuid(),'start');exception when others then failed:=true;end;
if not failed then raise exception 'Minimum-player check failed';end if;
for i in 1..5 loop
perform set_config('request.jwt.claim.sub',ids[i]::text,true);s:=public.tt_join(c,'Test '||i);
end loop;
perform set_config('request.jwt.claim.sub',host_id::text,true);s:=public.tt_command(c,gen_random_uuid(),'start',p_size=>4);
if (select count(distinct (value->>'x')||','||(value->>'y')) from jsonb_array_elements(s->'players'))<>5 then raise exception 'Spawn collision';end if;
perform set_config('request.jwt.claim.sub',ids[1]::text,true);s:=public.tt_view(c);
if s->>'isHost'<>'false' or jsonb_array_length(s->'hostLog')<>0 then raise exception 'Host access leak';end if;
for a in select value from jsonb_array_elements(s->'players') loop
if a ? 'uid' then raise exception 'Account ID leaked';end if;
if a->>'id'<>'0' and (a ? 'points' or a ? 'hearts' or a ? 'range' or a ? 'shield') then raise exception 'Private resources leaked';end if;
end loop;
-- Fix positions and fund players using admin test context to make actions deterministic.
select state into s from public.tt_rooms where code=c;
for i in 0..4 loop
a:=(s->'players')->i;a:=a||jsonb_build_object('x',i%4,'y',i/4,'points',5);
s:=jsonb_set(s,array['players',i::text],a);
end loop;
update public.tt_rooms set state=s where code=c;
s:=public.tt_command(c,rid,'give',1);s:=public.tt_command(c,rid,'give',1);
if ((select value from jsonb_array_elements(s->'players') where value->>'id'='0')->>'points')::int<>4 then raise exception 'Deduplication failed';end if;
failed:=false;begin perform public.tt_command(c,gen_random_uuid(),'next_day');exception when others then failed:=true;end;
if not failed then raise exception 'Host-only check failed';end if;
failed:=false;begin perform public.tt_command(c,gen_random_uuid(),'attack',3);exception when others then failed:=true;end;
if not failed then raise exception 'Range check failed';end if;
s:=public.tt_command(c,gen_random_uuid(),'attack',1);
s:=public.tt_command(c,gen_random_uuid(),'attack',1);
s:=public.tt_command(c,gen_random_uuid(),'attack',1);
perform set_config('request.jwt.claim.sub',ids[2]::text,true);s:=public.tt_command(c,gen_random_uuid(),'vote',0);
perform set_config('request.jwt.claim.sub',host_id::text,true);s:=public.tt_command(c,gen_random_uuid(),'next_day');
if ((s->'players'->0)->>'points')::int<>3 then raise exception 'Income or vote bonus failed';end if;
if has_table_privilege('authenticated','public.tt_rooms','SELECT') or has_table_privilege('anon','public.tt_rooms','SELECT') then raise exception 'Direct state table exposure';end if;
if has_function_privilege('anon','public.tt_view(text)','EXECUTE') then raise exception 'Unauthenticated RPC exposure';end if;
perform set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
failed:=false;begin perform public.tt_view(c);exception when others then failed:=true;end;
if not failed then raise exception 'Nonmember read allowed';end if;
raise notice 'Turn Tactics smoke tests passed. All test data will roll back.';
end;$$;
rollback;
