-- Upgrade existing v0.2 database. Safe to re-run. Does not delete rooms or users.
begin;
create or replace function public.tt_view(p_code text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r public.tt_rooms%rowtype; s jsonb; mine jsonb; players jsonb; host_view boolean;
begin
if auth.uid() is null then raise exception 'Sign in first'; end if;
select * into r from public.tt_rooms where code=upper(trim(p_code));
if not found then raise exception 'Room unavailable'; end if;
s:=r.state;host_view:=r.host=auth.uid();
select value into mine from jsonb_array_elements(s->'players') where value->>'uid'=auth.uid()::text;
if not host_view and mine is null then raise exception 'Room unavailable';end if;
select coalesce(jsonb_agg(case when host_view or value->>'uid'=auth.uid()::text then value-'uid' else
jsonb_build_object('id',value->'id','name',value->'name','x',value->'x','y',value->'y','alive',value->'alive','isTestSeat',coalesce(value->'isTestSeat','false'::jsonb)) end order by (value->>'id')::int),'[]'::jsonb)
into players from jsonb_array_elements(s->'players');
-- Ballots and account UUIDs never leave the backend. Host log is host-only.
return jsonb_build_object('code',r.code,'isTest',coalesce(s->'isTest','false'::jsonb),'isHost',host_view,'me',mine->'id','phase',s->'phase','day',s->'day','size',s->'size','closed',s->'closed','winner',s->'winner','players',players,'events',s->'events','hostLog',case when host_view then s->'hostLog' else '[]'::jsonb end);
end;$$;


create or replace function public.tt_fill_test_seats(p_code text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r public.tt_rooms%rowtype;s jsonb;ps jsonb;n int;i int;seat jsonb;
begin
if auth.uid() is null then raise exception 'Sign in first';end if;
select * into r from public.tt_rooms where code=upper(trim(p_code)) for update;
if not found then raise exception 'Room unavailable';end if;
if r.host<>auth.uid() then raise exception 'Host only';end if;
s:=r.state;
if s->>'phase'<>'lobby' then raise exception 'Test seats can only be added before starting';end if;
ps:=s->'players';n:=jsonb_array_length(ps);
if not exists(select 1 from jsonb_array_elements(ps) where coalesce((value->>'isTestSeat')::boolean,false)=false) then raise exception 'Join with one real player first, using your other browser profile';end if;
-- Idempotent: a retry never adds duplicate seats or repeats the announcement.
if coalesce((s->>'isTest')::boolean,false) and n>=5 then return public.tt_view(r.code);end if;
if n>=5 then raise exception 'This lobby already has five players; test seats are unnecessary';end if;
for i in n..4 loop
seat:=jsonb_build_object('id',i,'uid','test:'||gen_random_uuid()::text,'name','Test seat '||(i+1)||' ['||substr(gen_random_uuid()::text,1,4)||']','isTestSeat',true,'x',null,'y',null,'hearts',3,'points',1,'range',2,'shield',false,'alive',true);
ps:=ps||jsonb_build_array(seat);
end loop;
s:=s||jsonb_build_object('players',ps,'isTest',true);
s:=jsonb_set(s,'{events}',jsonb_build_array('TEST ROOM: placeholder seats added. Not a competitive game.')||(s->'events'));
s:=jsonb_set(s,'{hostLog}',jsonb_build_array('Host filled empty seats for testing.')||(s->'hostLog'));
update public.tt_rooms set state=s where code=r.code;
return public.tt_view(r.code);
end;$$;
revoke all on function public.tt_view(text),public.tt_fill_test_seats(text) from public,anon,authenticated;
grant execute on function public.tt_view(text),public.tt_fill_test_seats(text) to authenticated;
commit;
