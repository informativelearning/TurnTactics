-- Upgrade AFTER 010_rule_proposals.sql. Preserves Pacific clock wrappers.
begin;
alter table public.tt_proposals add column if not exists survivor_count int;
alter table public.tt_proposals drop constraint if exists tt_proposals_kind_check;
alter table public.tt_proposals add constraint tt_proposals_kind_check check(kind in ('house_rule','all_hearts','last_survivors'));
alter table public.tt_proposals drop constraint if exists tt_survivor_count_check;
alter table public.tt_proposals add constraint tt_survivor_count_check check(kind<>'last_survivors' or (survivor_count is not null and survivor_count between 1 and 20));
create or replace function public.tt_finish_if_ready(p_code text) returns void
language plpgsql security definer set search_path='' as $$
declare r public.tt_rooms%rowtype;s jsonb;ids jsonb;names text;n int;goal int;
begin
select * into r from public.tt_rooms where code=upper(trim(p_code)) for update;
if not found then return;end if;s:=r.state;goal:=coalesce((s->>'survivorGoal')::int,1);
if s->>'phase'='ended' then
if s->'winners' is null and s->>'winner' is not null then update public.tt_rooms set state=jsonb_set(s,'{winners}',jsonb_build_array((s->>'winner')::int)) where code=r.code;end if;
return;
end if;
if s->>'phase'<>'active' then return;end if;
select count(*),coalesce(jsonb_agg((value->>'id')::int order by (value->>'id')::int),'[]'::jsonb),string_agg(value->>'name',', ' order by (value->>'id')::int) into n,ids,names from jsonb_array_elements(s->'players') where (value->>'alive')::boolean;
if n>0 and n<=goal then
s:=s||jsonb_build_object('phase','ended','closed',true,'winners',ids,'winner',ids->0);
s:=jsonb_set(s,'{events}',jsonb_build_array('Game over. Winner'||case when n=1 then '' else 's' end||': '||names||'.')||(s->'events'));
update public.tt_rooms set state=s where code=r.code;
end if;
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
select coalesce(jsonb_agg(jsonb_build_object('id',q.id,'title',q.title,'body',q.body,'kind',q.kind,'survivorCount',q.survivor_count,'reviewedAt',q.reviewed_at) order by q.reviewed_at),'[]'::jsonb)
into approved_rules from public.tt_proposals q where q.room=r.code and q.status='approved';
-- Ballots and account UUIDs never leave the backend. Host log is host-only.
return jsonb_build_object('code',r.code,'timezone','America/Los_Angeles','nextReset',s->'nextReset','serverTime',clock_timestamp(),'isTest',coalesce(s->'isTest','false'::jsonb),'isHost',host_view,'me',mine->'id','phase',s->'phase','day',s->'day','size',s->'size','closed',s->'closed','survivorGoal',coalesce((s->>'survivorGoal')::int,1),'winners',coalesce(s->'winners','[]'::jsonb),'winner',s->'winner','players',players,'proposals',visible_proposals,'rules',approved_rules,'events',s->'events','hostLog',case when host_view then s->'hostLog' else '[]'::jsonb end);
end;$$;




create or replace function public.tt_propose_survivors(p_code text,p_request uuid,p_title text,p_body text,p_count int) returns jsonb
language plpgsql security definer set search_path='' as $$
declare r public.tt_rooms%rowtype;actor jsonb;s jsonb;
begin
if auth.uid() is null or p_request is null then raise exception 'Authentication and request ID required';end if;
select * into r from public.tt_rooms where code=upper(trim(p_code)) for update;
if not found then raise exception 'Room unavailable';end if;
select value into actor from jsonb_array_elements(r.state->'players') where value->>'uid'=auth.uid()::text;
if actor is null then raise exception 'Only a player can propose a change';end if;
if exists(select 1 from public.tt_requests where room=r.code and user_id=auth.uid() and request_id=p_request) then return public.tt_view(r.code);end if;
perform public.tt_clock_apply(r.code);select state into s from public.tt_rooms where code=r.code;
select value into actor from jsonb_array_elements(s->'players') where value->>'uid'=auth.uid()::text;
if s->>'phase'<>'active' or (s->>'closed')::boolean then raise exception 'Proposals require an active, open action window';end if;
if not (actor->>'alive')::boolean then raise exception 'Eliminated players cannot propose changes';end if;
if (actor->>'points')::int<4 then raise exception 'You need 4 available points to propose; they are only charged on approval';end if;
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
perform public.tt_clock_apply(r.code);select state into s from public.tt_rooms where code=r.code;
if p_decision='approve' then
if s->>'phase'<>'active' or (s->>'closed')::boolean then raise exception 'Approval and payment require an open action window';end if;
ps:=s->'players';select (ord-1)::int,value into idx,actor from jsonb_array_elements(ps) with ordinality a(value,ord) where value->>'uid'=q.author::text;
if actor is null or not (actor->>'alive')::boolean then raise exception 'Proposer is no longer alive; reject this proposal instead';end if;
if (actor->>'points')::int<4 then raise exception 'Proposer no longer has 4 points. No charge or approval was made';end if;
actor:=actor||jsonb_build_object('points',(actor->>'points')::int-4);ps:=jsonb_set(ps,array[idx::text],actor);
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
s:=jsonb_set(s,'{events}',jsonb_build_array('Host approved a rule change: '||q.title||case when q.kind='all_hearts' then ' — all living players gained 1 heart.' when q.kind='last_survivors' then ' — last '||q.survivor_count||' survivors win.' else ' — written house rule; enforced by the host.' end)||(s->'events'));
s:=jsonb_set(s,'{hostLog}',jsonb_build_array(clock_timestamp()::text||' · Approved '||q.title||'; charged '||(actor->>'name')||' 4 points.')||(s->'hostLog'));
update public.tt_rooms set state=s where code=r.code;
end if;
update public.tt_proposals set status=case when p_decision='approve' then 'approved' else 'rejected' end,reason=coalesce(p_reason,''),reviewed_at=clock_timestamp() where id=q.id;
insert into public.tt_requests values(r.code,auth.uid(),p_request);
return public.tt_view(r.code);
end;$$;

revoke all on function public.tt_finish_if_ready(text),public.tt_view_core(text),public.tt_propose_survivors(text,uuid,text,text,int),public.tt_review(text,uuid,uuid,text,text) from public,anon,authenticated;
grant execute on function public.tt_propose_survivors(text,uuid,text,text,int),public.tt_review(text,uuid,uuid,text,text) to authenticated;
commit;
NOTIFY pgrst, 'reload schema';
