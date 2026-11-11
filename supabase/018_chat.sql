-- After 016_slideshow_rules.sql. Chat is independent of points, action windows and rules versions.
begin;
create table if not exists public.tt_chat_messages (
id uuid primary key default gen_random_uuid(), seq bigint generated always as identity unique,
room text not null references public.tt_rooms(code),sender int not null check(sender between -1 and 19),
recipient int check(recipient between -1 and 19),sender_name text not null,
body text not null check(length(body) between 1 and 1000),request_id uuid not null,
sent_at timestamptz not null default clock_timestamp(),
check(recipient is null or recipient<>sender),unique(room,sender,request_id)
);
create index if not exists tt_chat_room_recipient_seq on public.tt_chat_messages(room,recipient,seq);
create index if not exists tt_chat_sender_recipient_seq on public.tt_chat_messages(room,sender,recipient,seq);
create index if not exists tt_chat_sender_time on public.tt_chat_messages(room,sender,sent_at);
create table if not exists public.tt_chat_reads (
room text not null references public.tt_rooms(code),seat int not null check(seat between -1 and 19),
peer int not null check(peer between -2 and 19),last_seq bigint not null default 0 check(last_seq>=0),
primary key(room,seat,peer)
);
alter table public.tt_chat_messages enable row level security;
alter table public.tt_chat_reads enable row level security;
revoke all on public.tt_chat_messages,public.tt_chat_reads from public,anon,authenticated;
revoke all on sequence public.tt_chat_messages_seq_seq from public,anon,authenticated;

-- Locks the room through authorization/read/send/ack; recovery uses that same room lock.
create or replace function public.tt_chat_slot(p_code text) returns int
language plpgsql security definer set search_path='' as $$
declare r public.tt_rooms%rowtype;slot int;
begin
if auth.uid() is null then raise exception 'Connect this browser first';end if;
select * into r from public.tt_rooms where code=upper(trim(p_code)) for update;
if not found then raise exception 'Room unavailable';end if;
if r.host=auth.uid() then return -1;end if;
select (value->>'id')::int into slot from jsonb_array_elements(r.state->'players') where value->>'uid'=auth.uid()::text and not coalesce((value->>'isTestSeat')::boolean,false);
if slot is null then raise exception 'Room unavailable';end if;
return slot;
end;$$;
create or replace function public.tt_chat_peer(p_code text,p_me int,p_peer int) returns void
language plpgsql security definer set search_path='' as $$
begin
if p_peer is null then return;end if;
if p_peer=p_me or p_peer < -1 or p_peer>19 then raise exception 'Choose another real room member';end if;
if p_peer<>-1 and not exists(select 1 from public.tt_rooms r cross join lateral jsonb_array_elements(r.state->'players') a where r.code=upper(trim(p_code)) and (a->>'id')::int=p_peer and not coalesce((a->>'isTestSeat')::boolean,false)) then raise exception 'Choose another real room member';end if;
end;$$;
create or replace function public.tt_chat_send(p_code text,p_request uuid,p_body text,p_peer int default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare c text:=upper(trim(p_code));slot int;m public.tt_chat_messages%rowtype;body_text text:=btrim(p_body,E' \t\n\r');who text;last_at timestamptz;recent int;
begin
slot:=public.tt_chat_slot(c);perform public.tt_chat_peer(c,slot,p_peer);
if p_request is null then raise exception 'Message request ID required';end if;
if body_text is null or length(body_text) not between 1 and 1000 then raise exception 'Use 1 to 1000 characters';end if;
-- Seat-keyed deduplication survives role recovery. A UUID cannot be reused with different content.
select * into m from public.tt_chat_messages where room=c and sender=slot and request_id=p_request;
if found then
if m.body<>body_text or m.recipient is distinct from p_peer then raise exception 'That request ID belongs to a different message';end if;
else
select max(sent_at),count(*) filter(where sent_at>clock_timestamp()-interval '1 minute') into last_at,recent from public.tt_chat_messages where room=c and sender=slot;
if last_at>clock_timestamp()-interval '1 second' then raise exception 'Please wait a second before sending another message';end if;
if recent>=20 then raise exception 'Message limit reached. Wait a minute before sending again';end if;
if slot=-1 then who:='Host / referee';else select a->>'name' into who from public.tt_rooms r cross join lateral jsonb_array_elements(r.state->'players') a where r.code=c and (a->>'id')::int=slot;end if;
insert into public.tt_chat_messages(room,sender,recipient,sender_name,body,request_id) values(c,slot,p_peer,who,body_text,p_request) returning * into m;
end if;
return jsonb_build_object('id',m.id,'sender',m.sender,'recipient',m.recipient,'senderName',m.sender_name,'body',m.body,'sentAt',m.sent_at);
end;$$;
create or replace function public.tt_chat_list(p_code text,p_peer int default null,p_before uuid default null,p_after uuid default null,p_limit int default 50) returns jsonb
language plpgsql security definer set search_path='' as $$
declare c text:=upper(trim(p_code));slot int;cursor_seq bigint;lim int:=least(100,greatest(1,coalesce(p_limit,50)));items jsonb;more boolean;oldest uuid;newest uuid;
begin
slot:=public.tt_chat_slot(c);perform public.tt_chat_peer(c,slot,p_peer);
if p_before is not null and p_after is not null then raise exception 'Choose one message cursor';end if;
if coalesce(p_before,p_after) is not null then
select seq into cursor_seq from public.tt_chat_messages where id=coalesce(p_before,p_after) and room=c and ((p_peer is null and recipient is null) or (p_peer is not null and ((sender=slot and recipient=p_peer) or (sender=p_peer and recipient=slot))));
if not found then raise exception 'Message cursor unavailable';end if;
end if;
with candidates as (
select * from public.tt_chat_messages where room=c
and ((p_peer is null and recipient is null) or (p_peer is not null and ((sender=slot and recipient=p_peer) or (sender=p_peer and recipient=slot))))
and (p_before is null or seq<cursor_seq) and (p_after is null or seq>cursor_seq)
order by case when p_after is null then seq end desc,case when p_after is not null then seq end asc limit lim+1
), page as (
select * from candidates order by case when p_after is null then seq end desc,case when p_after is not null then seq end asc limit lim
)
select coalesce((select jsonb_agg(jsonb_build_object('id',id,'sender',sender,'recipient',recipient,'senderName',sender_name,'body',body,'sentAt',sent_at) order by seq) from page),'[]'::jsonb),
(select count(*)>lim from candidates),(select id from page order by seq limit 1),(select id from page order by seq desc limit 1)
into items,more,oldest,newest;
-- Internal sequence numbers are never returned: other conversations' traffic is not an ID counter.
return jsonb_build_object('messages',items,'hasMore',more,'oldestId',oldest,'newestId',newest);
end;$$;
create or replace function public.tt_chat_ack(p_code text,p_peer int,p_last uuid) returns void
language plpgsql security definer set search_path='' as $$
declare c text:=upper(trim(p_code));slot int;seen bigint;
begin
slot:=public.tt_chat_slot(c);perform public.tt_chat_peer(c,slot,p_peer);
select seq into seen from public.tt_chat_messages where id=p_last and room=c and ((p_peer is null and recipient is null) or (p_peer is not null and ((sender=slot and recipient=p_peer) or (sender=p_peer and recipient=slot))));
if not found then raise exception 'Message cursor unavailable';end if;
insert into public.tt_chat_reads(room,seat,peer,last_seq) values(c,slot,coalesce(p_peer,-2),seen)
on conflict(room,seat,peer) do update set last_seq=greatest(public.tt_chat_reads.last_seq,excluded.last_seq);
end;$$;
create or replace function public.tt_chat_inbox(p_code text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare c text:=upper(trim(p_code));slot int;threads jsonb;
begin
slot:=public.tt_chat_slot(c);
with people as (
select -2 as peer,'Room chat'::text as name
union all select -1,'Host / referee' where slot<>-1
union all select (a->>'id')::int,a->>'name' from public.tt_rooms r cross join lateral jsonb_array_elements(r.state->'players') a where r.code=c and (a->>'id')::int<>slot and not coalesce((a->>'isTestSeat')::boolean,false)
), inbox as (
select p.peer,p.name,
(select count(*) from public.tt_chat_messages m where m.room=c and m.sender<>slot and m.seq>coalesce(seen.last_seq,0) and ((p.peer=-2 and m.recipient is null) or (p.peer<>-2 and ((m.sender=slot and m.recipient=p.peer) or (m.sender=p.peer and m.recipient=slot))))) as unread,
(select left(m.body,100) from public.tt_chat_messages m where m.room=c and ((p.peer=-2 and m.recipient is null) or (p.peer<>-2 and ((m.sender=slot and m.recipient=p.peer) or (m.sender=p.peer and m.recipient=slot)))) order by m.seq desc limit 1) as preview,
(select m.sent_at from public.tt_chat_messages m where m.room=c and ((p.peer=-2 and m.recipient is null) or (p.peer<>-2 and ((m.sender=slot and m.recipient=p.peer) or (m.sender=p.peer and m.recipient=slot)))) order by m.seq desc limit 1) as last_at
from people p left join public.tt_chat_reads seen on seen.room=c and seen.seat=slot and seen.peer=p.peer
)
select coalesce(jsonb_agg(jsonb_build_object('peer',case when peer=-2 then null else peer end,'name',name,'unread',unread,'preview',preview,'lastAt',last_at) order by case when peer=-2 then 0 else 1 end,last_at desc nulls last,name),'[]'::jsonb) into threads from inbox;
return jsonb_build_object('me',slot,'threads',threads);
end;$$;
revoke all on function public.tt_chat_slot(text),public.tt_chat_peer(text,int,int),public.tt_chat_send(text,uuid,text,int),public.tt_chat_list(text,int,uuid,uuid,int),public.tt_chat_ack(text,int,uuid),public.tt_chat_inbox(text) from public,anon,authenticated;
grant execute on function public.tt_chat_send(text,uuid,text,int),public.tt_chat_list(text,int,uuid,uuid,int),public.tt_chat_ack(text,int,uuid),public.tt_chat_inbox(text) to authenticated;
commit;
NOTIFY pgrst, 'reload schema';
