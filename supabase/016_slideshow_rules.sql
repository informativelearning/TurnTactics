-- Upgrade AFTER 014_room_recovery.sql. New rooms only; existing state is NOT rewritten.
begin;
create or replace function public.tt_is_slideshow(p_state jsonb) returns boolean
language sql immutable set search_path='' as $$select coalesce(p_state->>'rulesVersion','')='slideshow-2026-11'$$;
create or replace function public.tt_proposal_cost(p_state jsonb) returns int
language sql immutable set search_path='' as $$select case when public.tt_is_slideshow(p_state) then 5 else 4 end$$;
-- NULL is deliberate for fewer than five, six (not specified), and over twenty.
create or replace function public.tt_slideshow_board(p_count int) returns int
language sql immutable set search_path='' as $$select case when p_count=5 then 8 when p_count=7 then 9 when p_count between 8 and 9 then 10 when p_count=10 then 11 when p_count between 11 and 12 then 12 when p_count between 13 and 14 then 13 when p_count between 15 and 16 then 14 when p_count between 17 and 20 then 15 else null end$$;


create or replace function public.tt_create() returns jsonb
language plpgsql security definer set search_path='' as $$
declare c text; n int;
begin
if auth.uid() is null then raise exception 'Sign in first';end if;
select count(*) into n from public.tt_rooms where host=auth.uid();
if n>=5 then raise exception 'Alpha limit: five rooms per host account';end if;
loop
c:=upper(substr(replace(gen_random_uuid()::text,'-',''),1,12));
begin
insert into public.tt_rooms(code,host,state) values(c,auth.uid(),jsonb_build_object('rulesVersion','slideshow-2026-11','phase','lobby','day',1,'size',8,'closed',false,'winner',null,'players','[]'::jsonb,'votes','{}'::jsonb,'events','[]'::jsonb,'hostLog','[]'::jsonb));
exit;
exception when unique_violation then null;
end;
end loop;
return public.tt_view(c);
end;$$;

create or replace function public.tt_join(p_code text,p_name text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r public.tt_rooms%rowtype;s jsonb;n int;player jsonb;
begin
if auth.uid() is null then raise exception 'Sign in first';end if;
select * into r from public.tt_rooms where code=upper(trim(p_code)) for update;
if not found then raise exception 'Room unavailable';end if;
s:=r.state;
if exists(select 1 from jsonb_array_elements(s->'players') where value->>'uid'=auth.uid()::text) then return public.tt_view(r.code);end if;
if r.host=auth.uid() then raise exception 'Host is referee only; join as a player from another browser profile';end if;
if s->>'phase'<>'lobby' then raise exception 'This room has already started';end if;
if length(trim(p_name))<1 or length(trim(p_name))>24 then raise exception 'Use a name of 1–24 characters';end if;
if exists(select 1 from jsonb_array_elements(s->'players') where lower(value->>'name')=lower(trim(p_name))) then raise exception 'Name already used';end if;
n:=jsonb_array_length(s->'players');if n>=20 then raise exception 'Room full';end if;
player:=jsonb_build_object('id',n,'uid',auth.uid(),'name',trim(p_name),'x',null,'y',null,'hearts',3,'points',case when public.tt_is_slideshow(s) then 0 else 1 end,'range',case when public.tt_is_slideshow(s) then 3 else 2 end,'shield',false,'alive',true);
s:=jsonb_set(s,'{players}',(s->'players')||jsonb_build_array(player));
update public.tt_rooms set state=s where code=r.code;
return public.tt_view(r.code);
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
seat:=jsonb_build_object('id',i,'uid','test:'||gen_random_uuid()::text,'name','Test seat '||(i+1)||' ['||substr(gen_random_uuid()::text,1,4)||']','isTestSeat',true,'x',null,'y',null,'hearts',3,'points',case when public.tt_is_slideshow(s) then 0 else 1 end,'range',case when public.tt_is_slideshow(s) then 3 else 2 end,'shield',false,'alive',true);
ps:=ps||jsonb_build_array(seat);
end loop;
s:=s||jsonb_build_object('players',ps,'isTest',true);
s:=jsonb_set(s,'{events}',jsonb_build_array('TEST ROOM: placeholder seats added. Not a competitive game.')||(s->'events'));
s:=jsonb_set(s,'{hostLog}',jsonb_build_array('Host filled empty seats for testing.')||(s->'hostLog'));
update public.tt_rooms set state=s where code=r.code;
return public.tt_view(r.code);
end;$$;

create or replace function public.tt_command_core(p_code text,p_request uuid,p_action text,p_target int default null,p_direction text default null,p_size int default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r public.tt_rooms%rowtype;s jsonb;ps jsonb;actor jsonb;target jsonb;item jsonb;idx int;tidx int;i int;n int;side int;cell int;cells int[];cost int;dx int;dy int;newx int;newy int;survivors int;win int;total int;bonus text;counts jsonb;v record;public_event text;detail text;is_host boolean;
begin
if auth.uid() is null or p_request is null then raise exception 'Authentication and request ID required';end if;
select * into r from public.tt_rooms where code=upper(trim(p_code)) for update;
if not found then raise exception 'Room unavailable';end if;
s:=r.state;ps:=s->'players';is_host:=r.host=auth.uid();
select (ord-1)::int,value into idx,actor from jsonb_array_elements(ps) with ordinality a(value,ord) where value->>'uid'=auth.uid()::text;
if not is_host and actor is null then raise exception 'Room unavailable';end if;
if exists(select 1 from public.tt_requests where room=r.code and user_id=auth.uid() and request_id=p_request) then return public.tt_view(r.code);end if;
if p_action='start' then
if not is_host then raise exception 'Host only';end if;
if s->>'phase'<>'lobby' then raise exception 'Already started';end if;
n:=jsonb_array_length(ps);if n<5 then raise exception 'At least five players required';end if;
if public.tt_is_slideshow(s) then
side:=public.tt_slideshow_board(n);
if side is null then raise exception 'The slideshow does not specify a six-player board. Use five or seven to twenty players until that rule is clarified';end if;
if p_size is not null and p_size<>side then raise exception 'Slideshow requires a % by % board for % players',side,side,n;end if;
else side:=coalesce(p_size,n-1);end if;
if side<3 or side>24 or side*side<n then raise exception 'Invalid board size';end if;
select array_agg(x order by random()) into cells from generate_series(0,side*side-1) x;
for i in 0..n-1 loop
item:=ps->i;if public.tt_is_slideshow(s) then item:=item||jsonb_build_object('points',1,'range',3);end if;cell:=cells[i+1];item:=item||jsonb_build_object('x',cell%side,'y',cell/side);ps:=jsonb_set(ps,array[i::text],item);
end loop;
s:=s||jsonb_build_object('phase','active','size',side);public_event:='Game started. Each player received 1 point.';
elsif p_action in ('next_day','close') then
if not is_host then raise exception 'Host only';end if;
if s->>'phase'<>'active' then raise exception 'No active game';end if;
if p_action='close' then s:=jsonb_set(s,'{closed}','true');public_event:='The host closed actions for today.';
else
counts:='{}';total:=0;
for v in select * from jsonb_each_text(s->'votes') loop
-- Targets are guaranteed living when cast; ignore any that have since died.
if exists(select 1 from jsonb_array_elements(ps) where value->>'id'=v.value and (value->>'alive')::boolean) then
counts:=jsonb_set(counts,array[v.value],to_jsonb(coalesce((counts->>v.value)::int,0)+1));total:=total+1;
end if;
end loop;
select key into bonus from jsonb_each_text(counts) where value::int>total/2;
for i in 0..jsonb_array_length(ps)-1 loop
item:=ps->i;item:=item||jsonb_build_object('shield',false);
if (item->>'alive')::boolean then item:=item||jsonb_build_object('points',(item->>'points')::int+1+case when item->>'id'=bonus then 1 else 0 end);end if;
ps:=jsonb_set(ps,array[i::text],item);
end loop;
s:=s||jsonb_build_object('day',(s->>'day')::int+1,'closed',false,'votes','{}'::jsonb);
public_event:='Day '||(s->>'day')||' began. Income awarded; shields expired.';
end if;
else
if s->>'phase'<>'active' then raise exception 'No active game';end if;
if actor is null then raise exception 'The host referees; only players can act';end if;
if p_target is not null then
select (ord-1)::int,value into tidx,target from jsonb_array_elements(ps) with ordinality a(value,ord) where (value->>'id')::int=p_target;
end if;
if p_action='vote' then
if (actor->>'alive')::boolean then raise exception 'Only eliminated players may vote';end if;
if target is null or not (target->>'alive')::boolean then raise exception 'Choose a living recipient';end if;
s:=jsonb_set(s,array['votes',actor->>'id'],to_jsonb(p_target));detail:=(actor->>'name')||' cast a ballot.';
else
if (s->>'closed')::boolean then raise exception 'Actions are closed';end if;
if not (actor->>'alive')::boolean then raise exception 'You have been eliminated';end if;
cost:=case p_action when 'move' then 1 when 'attack' then 1 when 'give' then 1 when 'shield' then 2 when 'range' then 2 when 'remove' then 0 else null end;
if cost is null then raise exception 'Unknown action';end if;
if (actor->>'points')::int<cost then raise exception 'Not enough points';end if;
if p_action in ('attack','give') then
if target is null or p_target=(actor->>'id')::int or not (target->>'alive')::boolean then raise exception 'Choose another living player';end if;
if abs((actor->>'x')::int-(target->>'x')::int)+abs((actor->>'y')::int-(target->>'y')::int)>(actor->>'range')::int then raise exception 'Target out of range';end if;
if p_action='give' then target:=target||jsonb_build_object('points',(target->>'points')::int+1);
else
if (target->>'shield')::boolean then raise exception 'Target shielded; no points spent';end if;
target:=target||jsonb_build_object('hearts',(target->>'hearts')::int-1);
if (target->>'hearts')::int=0 then target:=target||jsonb_build_object('alive',false);if public.tt_is_slideshow(s) then target:=jsonb_set(target,'{points}','0'::jsonb);end if;public_event:=(actor->>'name')||' eliminated '||(target->>'name')||'.';end if;
end if;
ps:=jsonb_set(ps,array[tidx::text],target);
elsif p_action='move' then
dx:=case p_direction when 'left' then -1 when 'right' then 1 when 'up' then 0 when 'down' then 0 else null end;
dy:=case p_direction when 'up' then -1 when 'down' then 1 else 0 end;
if dx is null then raise exception 'Choose a direction';end if;
newx:=(actor->>'x')::int+dx;newy:=(actor->>'y')::int+dy;side:=(s->>'size')::int;
if newx<0 or newy<0 or newx>=side or newy>=side or exists(select 1 from jsonb_array_elements(ps) where (value->>'alive')::boolean and (value->>'x')::int=newx and (value->>'y')::int=newy) then raise exception 'Tile blocked';end if;
actor:=actor||jsonb_build_object('x',newx,'y',newy);public_event:=(actor->>'name')||' moved to ('||(newx+1)||', '||(newy+1)||').';
elsif p_action='shield' then
if (actor->>'shield')::boolean then raise exception 'Already shielded';end if;
actor:=actor||jsonb_build_object('shield',true);
elsif p_action='range' then actor:=actor||jsonb_build_object('range',(actor->>'range')::int+1);
elsif p_action='remove' then actor:=actor||jsonb_build_object('alive',false);public_event:=(actor->>'name')||' withdrew.';
end if;
actor:=actor||jsonb_build_object('points',case when public.tt_is_slideshow(s) and not (actor->>'alive')::boolean then 0 else (actor->>'points')::int-cost end);ps:=jsonb_set(ps,array[idx::text],actor);
detail:=(actor->>'name')||': '||p_action||case when target is not null then ' → '||(target->>'name') else coalesce(' '||p_direction,'') end;
end if;
end if;
if s->>'phase'='active' then
select count(*),min((value->>'id')::int) into survivors,win from jsonb_array_elements(ps) where (value->>'alive')::boolean;
if survivors=1 then s:=s||jsonb_build_object('phase','ended','winner',win);end if;
end if;
s:=jsonb_set(s,'{players}',ps);
if public_event is not null then s:=jsonb_set(s,'{events}',jsonb_build_array(public_event)||(s->'events'));end if;
s:=jsonb_set(s,'{hostLog}',jsonb_build_array(to_char(clock_timestamp() at time zone 'UTC','YYYY-MM-DD HH24:MI:SS.MS')||' UTC · '||coalesce(detail,public_event,'Host action'))||(s->'hostLog'));
update public.tt_rooms set state=s where code=r.code;
insert into public.tt_requests values(r.code,auth.uid(),p_request);
return public.tt_view(r.code);
end;$$;

create or replace function public.tt_clock_apply(p_code text,p_now timestamptz default clock_timestamp()) returns void
language plpgsql security definer set search_path='' as $$
declare r public.tt_rooms%rowtype;s jsonb;ps jsonb;item jsonb;local_now timestamp;today date;due date;days int;opening boolean;i int;counts jsonb:='{}';total int:=0;bonus text;v record;event text;
begin
select * into r from public.tt_rooms where code=upper(trim(p_code)) for update;
if not found then return;end if;s:=r.state;
if coalesce((s->>'isTest')::boolean,false) or s->>'phase' not in ('active','scheduled') then return;end if;
local_now:=p_now at time zone 'America/Los_Angeles';today:=local_now::date;
-- Existing active rooms start automatic accounting from the next local midnight, without retroactive income.
due:=coalesce((s->>'nextReset')::date,today+1);s:=jsonb_set(s,'{nextReset}',to_jsonb(due::text));
if due<=today then
days:=today-due+1;opening:=s->>'phase'='scheduled';ps:=s->'players';
-- Only ballots cast before the first unprocessed midnight can award a bonus. No repeated bonus during catch-up.
if not opening then
for v in select * from jsonb_each_text(s->'votes') loop
if exists(select 1 from jsonb_array_elements(ps) where value->>'id'=v.key and not (value->>'alive')::boolean) and exists(select 1 from jsonb_array_elements(ps) where value->>'id'=v.value and (value->>'alive')::boolean) then
counts:=jsonb_set(counts,array[v.value],to_jsonb(coalesce((counts->>v.value)::int,0)+1));total:=total+1;
end if;
end loop;
select key into bonus from jsonb_each_text(counts) where value::int>total/2;
end if;
for i in 0..jsonb_array_length(ps)-1 loop
item:=ps->i;item:=item||jsonb_build_object('shield',false);
if (item->>'alive')::boolean then item:=item||jsonb_build_object('points',(item->>'points')::int+days+case when item->>'id'=bonus then 1 else 0 end);end if;
ps:=jsonb_set(ps,array[i::text],item);
end loop;
s:=s||jsonb_build_object('players',ps,'phase','active','day',(s->>'day')::int+days-case when opening then 1 else 0 end,'nextReset',(today+1)::text,'votes','{}'::jsonb);
event:=case when opening then 'Game opened at Pacific midnight. ' else '' end||days||' midnight rollover(s) applied. Income awarded; shields expired.';
s:=jsonb_set(s,'{events}',jsonb_build_array(event)||(s->'events'));
s:=jsonb_set(s,'{hostLog}',jsonb_build_array(p_now::text||' · '||event)||(s->'hostLog'));
end if;
s:=jsonb_set(s,'{closed}',to_jsonb(s->>'phase'='scheduled' or local_now::time>=case when public.tt_is_slideshow(s) then time '18:00' else time '19:00' end));
if s is distinct from r.state then update public.tt_rooms set state=s where code=r.code;end if;
end;$$;

create or replace function public.tt_view_core(p_code text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r public.tt_rooms%rowtype; s jsonb; mine jsonb; players jsonb; host_view boolean; visible_proposals jsonb; approved_rules jsonb;
begin
if auth.uid() is null then raise exception 'Sign in first'; end if;
select * into r from public.tt_rooms where code=upper(trim(p_code));
if not found then raise exception 'Room unavailable'; end if;
s:=r.state;host_view:=r.host=auth.uid();
select value into mine from jsonb_array_elements(s->'players') where value->>'uid'=auth.uid()::text;
if not host_view and mine is null then raise exception 'Room unavailable';end if;
perform public.tt_finish_if_ready(r.code);select state into s from public.tt_rooms where code=r.code;
select coalesce(jsonb_agg(case when host_view or value->>'uid'=auth.uid()::text then value-'uid' else
jsonb_build_object('id',value->'id','name',value->'name','x',value->'x','y',value->'y','alive',value->'alive','icon',value->'icon','isTestSeat',coalesce(value->'isTestSeat','false'::jsonb)) end order by (value->>'id')::int),'[]'::jsonb)
into players from jsonb_array_elements(s->'players');
select coalesce(jsonb_agg(jsonb_build_object('id',q.id,'title',q.title,'body',q.body,'kind',q.kind,'survivorCount',q.survivor_count,'status',q.status,'reason',q.reason,'authorName',coalesce((select a->>'name' from jsonb_array_elements(s->'players') a where a->>'uid'=q.author::text),'Player'),'createdAt',q.created_at,'reviewedAt',q.reviewed_at) order by q.created_at desc),'[]'::jsonb)
into visible_proposals from public.tt_proposals q where q.room=r.code and (host_view or q.author=auth.uid());
select coalesce(jsonb_agg(jsonb_build_object('id',q.id,'title',q.title,'body',q.body,'kind',q.kind,'survivorCount',q.survivor_count,'authorName',case when public.tt_is_slideshow(s) then coalesce((select a->>'name' from jsonb_array_elements(s->'players') a where a->>'uid'=q.author::text),'Player') else null end,'reviewedAt',q.reviewed_at) order by q.reviewed_at),'[]'::jsonb)
into approved_rules from public.tt_proposals q where q.room=r.code and q.status='approved';
-- Ballots and account UUIDs never leave the backend. Host log is host-only.
return jsonb_build_object('code',r.code,'rulesVersion',coalesce(s->>'rulesVersion','legacy-v0.5'),'proposalCost',public.tt_proposal_cost(s),'cutoffHour',case when public.tt_is_slideshow(s) then 18 else 19 end,'baseRange',case when public.tt_is_slideshow(s) then 3 else 2 end,'requiredBoardSize',case when public.tt_is_slideshow(s) then public.tt_slideshow_board(jsonb_array_length(s->'players')) else null end,'timezone','America/Los_Angeles','nextReset',s->'nextReset','serverTime',clock_timestamp(),'isTest',coalesce(s->'isTest','false'::jsonb),'isHost',host_view,'me',mine->'id','phase',s->'phase','day',s->'day','size',s->'size','closed',s->'closed','survivorGoal',coalesce((s->>'survivorGoal')::int,1),'winners',coalesce(s->'winners','[]'::jsonb),'winner',s->'winner','players',players,'proposals',visible_proposals,'rules',approved_rules,'events',s->'events','hostLog',case when host_view then s->'hostLog' else '[]'::jsonb end);
end;$$;

create or replace function public.tt_propose(p_code text,p_request uuid,p_title text,p_body text,p_kind text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r public.tt_rooms%rowtype;actor jsonb;s jsonb;
slideshow_cost int;
begin
if auth.uid() is null or p_request is null then raise exception 'Authentication and request ID required';end if;
select * into r from public.tt_rooms where code=upper(trim(p_code)) for update;
if not found then raise exception 'Room unavailable';end if;
select value into actor from jsonb_array_elements(r.state->'players') where value->>'uid'=auth.uid()::text;
if actor is null then raise exception 'Only a player can propose a change';end if;
if exists(select 1 from public.tt_requests where room=r.code and user_id=auth.uid() and request_id=p_request) then return public.tt_view(r.code);end if;
perform public.tt_clock_apply(r.code);select state into s from public.tt_rooms where code=r.code;slideshow_cost:=public.tt_proposal_cost(s);
select value into actor from jsonb_array_elements(s->'players') where value->>'uid'=auth.uid()::text;
if s->>'phase'<>'active' or (s->>'closed')::boolean then raise exception 'Proposals require an active, open action window';end if;
if not (actor->>'alive')::boolean then raise exception 'Eliminated players cannot propose changes';end if;
if (actor->>'points')::int<slideshow_cost then raise exception 'You need % available points to propose; charged only on approval',slideshow_cost;end if;
if exists(select 1 from public.tt_proposals where room=r.code and author=auth.uid() and status='pending') then raise exception 'You already have a pending proposal';end if;
if p_kind is null or p_kind not in ('house_rule','all_hearts') then raise exception 'Unsupported rule type';end if;
if p_title is null or length(trim(p_title)) not between 1 and 80 or p_body is null or length(trim(p_body)) not between 1 and 1000 then raise exception 'Add a title (1–80 characters) and details (1–1000 characters)';end if;
insert into public.tt_proposals(room,author,title,body,kind) values(r.code,auth.uid(),trim(p_title),trim(p_body),p_kind);
insert into public.tt_requests values(r.code,auth.uid(),p_request);
return public.tt_view(r.code);
end;$$;

create or replace function public.tt_propose_survivors(p_code text,p_request uuid,p_title text,p_body text,p_count int) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r public.tt_rooms%rowtype;actor jsonb;s jsonb;
slideshow_cost int;
begin
if auth.uid() is null or p_request is null then raise exception 'Authentication and request ID required';end if;
select * into r from public.tt_rooms where code=upper(trim(p_code)) for update;
if not found then raise exception 'Room unavailable';end if;
select value into actor from jsonb_array_elements(r.state->'players') where value->>'uid'=auth.uid()::text;
if actor is null then raise exception 'Only a player can propose a change';end if;
if exists(select 1 from public.tt_requests where room=r.code and user_id=auth.uid() and request_id=p_request) then return public.tt_view(r.code);end if;
perform public.tt_clock_apply(r.code);select state into s from public.tt_rooms where code=r.code;slideshow_cost:=public.tt_proposal_cost(s);
select value into actor from jsonb_array_elements(s->'players') where value->>'uid'=auth.uid()::text;
if s->>'phase'<>'active' or (s->>'closed')::boolean then raise exception 'Proposals require an active, open action window';end if;
if not (actor->>'alive')::boolean then raise exception 'Eliminated players cannot propose changes';end if;
if (actor->>'points')::int<slideshow_cost then raise exception 'You need % available points to propose; charged only on approval',slideshow_cost;end if;
if exists(select 1 from public.tt_proposals where room=r.code and author=auth.uid() and status='pending') then raise exception 'You already have a pending proposal';end if;
if p_count is null or p_count<1 or p_count>jsonb_array_length(s->'players') or p_count>20 then raise exception 'Choose a survivor target between 1 and the initial player count';end if;
if p_count=coalesce((s->>'survivorGoal')::int,1) then raise exception 'That survivor target is already active';end if;
if p_title is null or length(trim(p_title)) not between 1 and 80 or p_body is null or length(trim(p_body)) not between 1 and 1000 then raise exception 'Add a title (1–80 characters) and details (1–1000 characters)';end if;
insert into public.tt_proposals(room,author,title,body,kind,survivor_count) values(r.code,auth.uid(),trim(p_title),trim(p_body),'last_survivors',p_count);
insert into public.tt_requests values(r.code,auth.uid(),p_request);
return public.tt_view(r.code);
end;$$;

create or replace function public.tt_review(p_code text,p_request uuid,p_proposal uuid,p_decision text,p_reason text default '') returns jsonb
language plpgsql security definer set search_path='' as $$
declare r public.tt_rooms%rowtype;q public.tt_proposals%rowtype;s jsonb;ps jsonb;actor jsonb;idx int;i int;item jsonb;
slideshow_cost int;
begin
if auth.uid() is null or p_request is null then raise exception 'Authentication and request ID required';end if;
select * into r from public.tt_rooms where code=upper(trim(p_code)) for update;
if not found then raise exception 'Room unavailable';end if;
if r.host<>auth.uid() then raise exception 'Host only';end if;
if exists(select 1 from public.tt_requests where room=r.code and user_id=auth.uid() and request_id=p_request) then return public.tt_view(r.code);end if;
if p_decision is null or p_decision not in ('approve','reject') or length(coalesce(p_reason,''))>300 then raise exception 'Choose approve or reject; reason maximum 300 characters';end if;
select * into q from public.tt_proposals where id=p_proposal and room=r.code for update;
if not found then raise exception 'Proposal unavailable';end if;
if q.status<>'pending' then raise exception 'This proposal was already reviewed';end if;
perform public.tt_clock_apply(r.code);select state into s from public.tt_rooms where code=r.code;slideshow_cost:=public.tt_proposal_cost(s);
if p_decision='approve' then
if s->>'phase'<>'active' or (s->>'closed')::boolean then raise exception 'Approval and payment require an open action window';end if;
ps:=s->'players';select (ord-1)::int,value into idx,actor from jsonb_array_elements(ps) with ordinality a(value,ord) where value->>'uid'=q.author::text;
if actor is null or not (actor->>'alive')::boolean then raise exception 'Proposer is no longer alive; reject this proposal instead';end if;
if (actor->>'points')::int<slideshow_cost then raise exception 'Proposer needs % points. No charge or approval was made',slideshow_cost;end if;
actor:=actor||jsonb_build_object('points',(actor->>'points')::int-slideshow_cost);ps:=jsonb_set(ps,array[idx::text],actor);
if q.kind='all_hearts' then
for i in 0..jsonb_array_length(ps)-1 loop
item:=ps->i;if (item->>'alive')::boolean then item:=item||jsonb_build_object('hearts',(item->>'hearts')::int+1);ps:=jsonb_set(ps,array[i::text],item);end if;
end loop;
end if;
s:=jsonb_set(s,'{players}',ps);
if q.kind='last_survivors' then
if q.survivor_count is null or q.survivor_count>jsonb_array_length(ps) then raise exception 'Invalid survivor target';end if;
if q.survivor_count=coalesce((s->>'survivorGoal')::int,1) then raise exception 'That survivor target is already active; no points charged';end if;
s:=jsonb_set(s,'{survivorGoal}',to_jsonb(q.survivor_count));
end if;
s:=jsonb_set(s,'{events}',jsonb_build_array('Host approved a rule change: '||q.title||case when public.tt_is_slideshow(s) then ' (proposed by '||(actor->>'name')||')' else '' end||case when q.kind='all_hearts' then ' — all living players gained 1 heart.' when q.kind='last_survivors' then ' — last '||q.survivor_count||' survivors win.' else ' — written house rule; enforced by the host.' end)||(s->'events'));
s:=jsonb_set(s,'{hostLog}',jsonb_build_array(clock_timestamp()::text||' · Approved '||q.title||'; charged '||(actor->>'name')||' '||slideshow_cost||' points.')||(s->'hostLog'));
update public.tt_rooms set state=s where code=r.code;
end if;
update public.tt_proposals set status=case when p_decision='approve' then 'approved' else 'rejected' end,reason=coalesce(p_reason,''),reviewed_at=clock_timestamp() where id=q.id;
insert into public.tt_requests values(r.code,auth.uid(),p_request);
return public.tt_view(r.code);
end;$$;
revoke all on function public.tt_is_slideshow(jsonb),public.tt_proposal_cost(jsonb),public.tt_slideshow_board(int),public.tt_command_core(text,uuid,text,int,text,int),public.tt_clock_apply(text,timestamptz),public.tt_view_core(text) from public,anon,authenticated;
revoke all on function public.tt_create(),public.tt_join(text,text),public.tt_fill_test_seats(text),public.tt_propose(text,uuid,text,text,text),public.tt_propose_survivors(text,uuid,text,text,int),public.tt_review(text,uuid,uuid,text,text) from public,anon,authenticated;
grant execute on function public.tt_create(),public.tt_join(text,text),public.tt_fill_test_seats(text),public.tt_propose(text,uuid,text,text,text),public.tt_propose_survivors(text,uuid,text,text,int),public.tt_review(text,uuid,uuid,text,text) to authenticated;
commit;
NOTIFY pgrst, 'reload schema';
