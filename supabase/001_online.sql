-- Turn Tactics online alpha. Run ONCE in a new dedicated Supabase project.
-- All state access is mediated by authenticated RPCs. No direct table grants.
begin;
create table public.tt_rooms (
 code text primary key,
 host uuid not null references auth.users(id),
 state jsonb not null,
 created_at timestamptz not null default now()
);
create table public.tt_requests (
 room text not null references public.tt_rooms(code),
 user_id uuid not null,
 request_id uuid not null,
 primary key(room,user_id,request_id)
);
alter table public.tt_rooms enable row level security;
alter table public.tt_requests enable row level security;
revoke all on public.tt_rooms,public.tt_requests from public,anon,authenticated;

create function public.tt_view(p_code text) returns jsonb
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
 jsonb_build_object('id',value->'id','name',value->'name','x',value->'x','y',value->'y','alive',value->'alive') end order by (value->>'id')::int),'[]'::jsonb)
 into players from jsonb_array_elements(s->'players');
 -- Ballots and account UUIDs never leave the backend. Host log is host-only.
 return jsonb_build_object('code',r.code,'isHost',host_view,'me',mine->'id','phase',s->'phase','day',s->'day','size',s->'size','closed',s->'closed','winner',s->'winner','players',players,'events',s->'events','hostLog',case when host_view then s->'hostLog' else '[]'::jsonb end);
end;$$;

create function public.tt_create() returns jsonb
language plpgsql security definer set search_path='' as $$
declare c text; n int;
begin
 if auth.uid() is null then raise exception 'Sign in first';end if;
 select count(*) into n from public.tt_rooms where host=auth.uid();
 if n>=5 then raise exception 'Alpha limit: five rooms per host account';end if;
 loop
 c:=upper(substr(replace(gen_random_uuid()::text,'-',''),1,12));
 begin
 insert into public.tt_rooms(code,host,state) values(c,auth.uid(),jsonb_build_object('phase','lobby','day',1,'size',4,'closed',false,'winner',null,'players','[]'::jsonb,'votes','{}'::jsonb,'events','[]'::jsonb,'hostLog','[]'::jsonb));
 exit;
 exception when unique_violation then null;
 end;
 end loop;
 return public.tt_view(c);
end;$$;

create function public.tt_join(p_code text,p_name text) returns jsonb
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
 player:=jsonb_build_object('id',n,'uid',auth.uid(),'name',trim(p_name),'x',null,'y',null,'hearts',3,'points',1,'range',2,'shield',false,'alive',true);
 s:=jsonb_set(s,'{players}',(s->'players')||jsonb_build_array(player));
 update public.tt_rooms set state=s where code=r.code;
 return public.tt_view(r.code);
end;$$;

create function public.tt_command(p_code text,p_request uuid,p_action text,p_target int default null,p_direction text default null,p_size int default null) returns jsonb
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
  side:=coalesce(p_size,n-1);if side<3 or side>24 or side*side<n then raise exception 'Invalid board size';end if;
  select array_agg(x order by random()) into cells from generate_series(0,side*side-1) x;
  for i in 0..n-1 loop
   item:=ps->i;cell:=cells[i+1];item:=item||jsonb_build_object('x',cell%side,'y',cell/side);ps:=jsonb_set(ps,array[i::text],item);
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
     if (target->>'hearts')::int=0 then target:=target||jsonb_build_object('alive',false);public_event:=(actor->>'name')||' eliminated '||(target->>'name')||'.';end if;
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
   actor:=actor||jsonb_build_object('points',(actor->>'points')::int-cost);ps:=jsonb_set(ps,array[idx::text],actor);
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
revoke all on function public.tt_view(text),public.tt_create(),public.tt_join(text,text),public.tt_command(text,uuid,text,int,text,int) from public,anon,authenticated;
grant execute on function public.tt_view(text),public.tt_create(),public.tt_join(text,text),public.tt_command(text,uuid,text,int,text,int) to authenticated;
commit;
