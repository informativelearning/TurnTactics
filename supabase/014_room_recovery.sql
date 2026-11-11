-- Upgrade after 012_shared_victory.sql. No room resets or auth-provider changes.
begin;
create table if not exists public.tt_recovery (
room text not null references public.tt_rooms(code),seat int not null check(seat between -1 and 19),
token_hash text not null check(token_hash ~ '^[0-9a-f]{64}$'),
updated_at timestamptz not null default clock_timestamp(),primary key(room,seat),unique(token_hash)
);
alter table public.tt_recovery enable row level security;
revoke all on public.tt_recovery from public,anon,authenticated;

create or replace function public.tt_save_recovery(p_code text,p_token text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r public.tt_rooms%rowtype;seat_id int;token text:=lower(trim(p_token));hash text;
begin
if auth.uid() is null then raise exception 'Connect this browser first';end if;
if token is null or token !~ '^[0-9a-f]{64}$' then raise exception 'Recovery code must contain 64 hexadecimal characters';end if;
select * into r from public.tt_rooms where code=upper(trim(p_code)) for update;
if not found then raise exception 'Room unavailable';end if;
if r.host=auth.uid() then seat_id:=-1;else
select (value->>'id')::int into seat_id from jsonb_array_elements(r.state->'players') where value->>'uid'=auth.uid()::text;
end if;
if seat_id is null then raise exception 'Only the current owner can create or replace their recovery code';end if;
hash:=encode(sha256(convert_to(token,'UTF8')),'hex');
insert into public.tt_recovery(room,seat,token_hash) values(r.code,seat_id,hash)
on conflict(room,seat) do update set token_hash=excluded.token_hash,updated_at=clock_timestamp();
return public.tt_view(r.code);
end;$$;

create or replace function public.tt_recover(p_code text,p_token text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r public.tt_rooms%rowtype;key_row public.tt_recovery%rowtype;token text:=lower(trim(p_token));hash text;old_owner uuid;idx int;ps jsonb;s jsonb;
begin
if auth.uid() is null then raise exception 'Connect this browser first';end if;
if token is null or token !~ '^[0-9a-f]{64}$' then raise exception 'Room or recovery code is invalid';end if;
hash:=encode(sha256(convert_to(token,'UTF8')),'hex');
select * into r from public.tt_rooms where code=upper(trim(p_code)) for update;
if not found then raise exception 'Room or recovery code is invalid';end if;
select * into key_row from public.tt_recovery where room=r.code and token_hash=hash;
if not found then raise exception 'Room or recovery code is invalid';end if;
s:=r.state;ps:=s->'players';
if key_row.seat=-1 then old_owner:=r.host;else
select (ord-1)::int,(value->>'uid')::uuid into idx,old_owner from jsonb_array_elements(ps) with ordinality a(value,ord) where (value->>'id')::int=key_row.seat and not coalesce((value->>'isTestSeat')::boolean,false);
end if;
if old_owner is null then raise exception 'Room or recovery code is invalid';end if;
-- Identical retry after a successful transfer does not change anything.
if old_owner=auth.uid() then return public.tt_view(r.code);end if;
if r.host=auth.uid() or exists(select 1 from jsonb_array_elements(ps) where value->>'uid'=auth.uid()::text) then raise exception 'This browser already has a different role in this room. Use a separate browser profile';end if;
if key_row.seat=-1 then
update public.tt_rooms set host=auth.uid() where code=r.code;
else
ps:=jsonb_set(ps,array[idx::text,'uid'],to_jsonb(auth.uid()::text));s:=jsonb_set(s,'{players}',ps);
update public.tt_proposals set author=auth.uid() where room=r.code and author=old_owner;
end if;
-- Preserve accepted request IDs so restoring an identity cannot replay an already accepted action.
update public.tt_requests set user_id=auth.uid() where room=r.code and user_id=old_owner;
s:=jsonb_set(s,'{hostLog}',jsonb_build_array(clock_timestamp()::text||' · Access restored for '||case when key_row.seat=-1 then 'host' else 'player seat '||(key_row.seat+1) end||'. Previous browser identity no longer controls this role.')||(s->'hostLog'));
update public.tt_rooms set state=s where code=r.code;
return public.tt_view(r.code);
end;$$;
revoke all on function public.tt_save_recovery(text,text),public.tt_recover(text,text) from public,anon,authenticated;
grant execute on function public.tt_save_recovery(text,text),public.tt_recover(text,text) to authenticated;
commit;
NOTIFY pgrst, 'reload schema';
