-- WHO'S next: persistent member presence, server-enforced queue eligibility,
-- one-hour break allowance, and equal-access Super Admin / SME role labels.
-- Additive only. Apply after 202611020007_workspace_admin_controls.sql.

create table if not exists public.member_presence (
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  member_id uuid not null references public.members(id) on delete cascade,
  auth_user_id uuid not null references auth.users(id) on delete cascade,
  presence_state text not null default 'active' check (presence_state in ('active','away')),
  last_seen_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (workspace_id, member_id),
  unique (auth_user_id)
);
create index if not exists idx_member_presence_fresh
  on public.member_presence(workspace_id, presence_state, last_seen_at desc);
alter table public.member_presence enable row level security;
revoke all on public.member_presence from anon, authenticated;

alter table public.workspace_admins
  add column if not exists role text not null default 'sme'
  check (role in ('super_admin','sme'));

-- Existing admin membership is preserved. Yash remains the initial Super Admin;
-- Super Admin and SME have identical permissions in this workspace.
update public.workspace_admins a
set role = 'super_admin'
from public.members m
where m.id = a.member_id
  and m.workspace_id = a.workspace_id
  and m.name = 'Yash Patil';

create or replace function public.heartbeat_member_presence(p_state text default 'active')
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_workspace_id uuid; v_member_id uuid; v_auth_id uuid;
begin
  if p_state not in ('active','away') then raise exception 'Presence state must be active or away.'; end if;
  v_auth_id := auth.uid();
  select workspace_id, member_id into v_workspace_id, v_member_id
  from public.member_sessions where auth_user_id = v_auth_id;
  if v_member_id is null then raise exception 'Join the team workspace first.'; end if;
  insert into public.member_presence(workspace_id,member_id,auth_user_id,presence_state,last_seen_at,updated_at)
  values(v_workspace_id,v_member_id,v_auth_id,p_state,now(),now())
  on conflict(workspace_id,member_id) do update
    set auth_user_id=excluded.auth_user_id,
        presence_state=excluded.presence_state,
        last_seen_at=excluded.last_seen_at,
        updated_at=excluded.updated_at;
  return jsonb_build_object('member_id',v_member_id,'presence_state',p_state,'last_seen_at',now());
end;
$$;

create or replace function public.set_member_offline()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_member_id uuid;
begin
  select member_id into v_member_id from public.member_sessions where auth_user_id=auth.uid();
  if v_member_id is null then return jsonb_build_object('offline',true); end if;
  delete from public.member_presence where auth_user_id=auth.uid();
  return jsonb_build_object('offline',true,'member_id',v_member_id);
end;
$$;

create or replace function public.get_workspace_presence()
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare v_workspace_id uuid; v_result jsonb;
begin
  select workspace_id into v_workspace_id from public.member_sessions where auth_user_id=auth.uid();
  if v_workspace_id is null then raise exception 'Join the team workspace first.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'memberId',m.id,
    'status',case when p.member_id is null or p.last_seen_at <= now()-interval '90 seconds'
      then 'offline' else p.presence_state end,
    'lastSeenAt',p.last_seen_at
  ) order by m.sort_order),'[]'::jsonb)
  into v_result
  from public.members m
  left join public.member_presence p
    on p.workspace_id=m.workspace_id and p.member_id=m.id
  where m.workspace_id=v_workspace_id and m.active;
  return v_result;
end;
$$;

create or replace function public.ensure_shift_assignee()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_workspace_id uuid;
  v_actor_id uuid;
  v_previous uuid;
  v_next uuid;
  v_today date;
  v_time time;
  v_now timestamptz;
  v_timezone text;
begin
  select workspace_id, member_id into v_workspace_id, v_actor_id
  from public.member_sessions where auth_user_id = auth.uid();
  if v_actor_id is null then raise exception 'Join the team workspace first.'; end if;

  select current_assignee_id into v_previous
  from public.allocation_state where workspace_id = v_workspace_id for update;
  if not found then raise exception 'Allocation state is not initialized.'; end if;

  select timezone into v_timezone from public.workspaces where id = v_workspace_id;
  v_now := now();
  v_today := (v_now at time zone v_timezone)::date;
  v_time := (v_now at time zone v_timezone)::time;

  -- Keep the existing owner while they are on shift and available.
  if v_previous is not null and exists (
    select 1
    from public.members m
    where m.id = v_previous and m.workspace_id = v_workspace_id and m.active
      and exists (
        select 1 from public.member_presence p
        where p.workspace_id = m.workspace_id and p.member_id = m.id
          and p.presence_state = 'active'
          and p.last_seen_at > now() - interval '90 seconds'
      )
      and exists (
        select 1 from public.shifts s where s.workspace_id = v_workspace_id and s.member_id = m.id and (
          (s.work_date = v_today and ((s.start_time < s.end_time and v_time >= s.start_time and v_time < s.end_time) or (s.start_time > s.end_time and v_time >= s.start_time)))
          or (s.work_date = v_today - 1 and s.start_time > s.end_time and v_time < s.end_time)
        )
      )
      and not exists (
        select 1 from public.breaks b where b.workspace_id = v_workspace_id and b.member_id = m.id and (
          (b.work_date = v_today and ((b.start_time < b.end_time and v_time >= b.start_time and v_time < b.end_time) or (b.start_time > b.end_time and v_time >= b.start_time)))
          or (b.work_date = v_today - 1 and b.start_time > b.end_time and v_time < b.end_time)
        )
      )
      and not exists (
        select 1 from public.availability_requests r
        where r.workspace_id = v_workspace_id and r.member_id = m.id
          and r.status = 'approved' and r.start_at <= v_now and r.end_at > v_now
      )
  ) then
    return jsonb_build_object('current_assignee_id', v_previous, 'changed', false);
  end if;

  -- If the current owner has left shift / started a break / become unavailable,
  -- move responsibility to the colleague in the most recently started eligible active shift.
  select m.id into v_next
  from public.members m
  join public.shifts s on s.workspace_id = m.workspace_id and s.member_id = m.id
  where m.workspace_id = v_workspace_id and m.active
    and exists (
        select 1 from public.member_presence p
        where p.workspace_id = m.workspace_id and p.member_id = m.id
          and p.presence_state = 'active'
          and p.last_seen_at > now() - interval '90 seconds'
      )
    and (
      (s.work_date = v_today and ((s.start_time < s.end_time and v_time >= s.start_time and v_time < s.end_time) or (s.start_time > s.end_time and v_time >= s.start_time)))
      or (s.work_date = v_today - 1 and s.start_time > s.end_time and v_time < s.end_time)
    )
    and not exists (
      select 1 from public.breaks b where b.workspace_id = v_workspace_id and b.member_id = m.id and (
        (b.work_date = v_today and ((b.start_time < b.end_time and v_time >= b.start_time and v_time < b.end_time) or (b.start_time > b.end_time and v_time >= b.start_time)))
        or (b.work_date = v_today - 1 and b.start_time > b.end_time and v_time < b.end_time)
      )
    )
    and not exists (
      select 1 from public.availability_requests r
      where r.workspace_id = v_workspace_id and r.member_id = m.id
        and r.status = 'approved' and r.start_at <= v_now and r.end_at > v_now
    )
  order by ((s.work_date + s.start_time) at time zone v_timezone) desc, m.sort_order
  limit 1;

  if v_next is not distinct from v_previous then
    return jsonb_build_object('current_assignee_id', v_previous, 'changed', false);
  end if;

  update public.allocation_state
  set current_assignee_id = v_next, updated_at = v_now
  where workspace_id = v_workspace_id;

  if v_next is not null then
    insert into public.handovers(workspace_id, from_member_id, to_member_id, handed_over_at)
    values (v_workspace_id, v_previous, v_next, v_now);
  end if;

  insert into public.audit_events(workspace_id, actor_member_id, event_type, summary, entity_type, metadata, created_at)
  values (
    v_workspace_id, null, 'automatic_handover',
    case when v_next is null then 'No eligible colleague is on shift; allocation responsibility is unassigned'
      else 'Automatic shift handover completed' end,
    'allocation_state',
    jsonb_build_object('from_member_id', v_previous, 'to_member_id', v_next, 'reason', 'shift_or_availability_change'),
    v_now
  );

  return jsonb_build_object('current_assignee_id', v_next, 'changed', true);
end;
$$;

create or replace function public.record_next_allocation(
  p_reference text default null,
  p_subject text default null,
  p_existing_ticket boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_workspace_id uuid;
  v_actor_id uuid;
  v_assignee_id uuid;
  v_last_id uuid;
  v_last_order integer;
  v_target_id uuid;
  v_target_name text;
  v_allocation_id uuid;
  v_today date;
  v_time time;
  v_now timestamptz;
  v_timezone text;
  v_subject text;
begin
  select workspace_id, member_id into v_workspace_id, v_actor_id
  from public.member_sessions where auth_user_id = auth.uid();
  if v_actor_id is null then raise exception 'Join the team workspace first.'; end if;

  perform public.ensure_shift_assignee();

  select current_assignee_id, last_allocated_member_id
    into v_assignee_id, v_last_id
  from public.allocation_state where workspace_id = v_workspace_id for update;
  if v_assignee_id is distinct from v_actor_id then
    raise exception 'Only the current shift assignee can record allocations. Refresh the workspace after shift handover.';
  end if;

  select timezone into v_timezone from public.workspaces where id = v_workspace_id;
  v_now := now();
  v_today := (v_now at time zone v_timezone)::date;
  v_time := (v_now at time zone v_timezone)::time;
  select sort_order into v_last_order from public.members where id = v_last_id and workspace_id = v_workspace_id;
  v_subject := nullif(trim(coalesce(p_subject, '')), '');
  if length(coalesce(v_subject, '')) > 200 then raise exception 'Email subject must be 200 characters or fewer.'; end if;
  if length(coalesce(p_reference, '')) > 100 then raise exception 'Email reference must be 100 characters or fewer.'; end if;

  select m.id, m.name into v_target_id, v_target_name
  from public.members m
  where m.workspace_id = v_workspace_id and m.active = true
    and exists (
      select 1 from public.member_presence p
      where p.workspace_id = m.workspace_id and p.member_id = m.id
        and p.presence_state = 'active'
        and p.last_seen_at > now() - interval '90 seconds'
    )
    and exists (
      select 1 from public.shifts s where s.workspace_id = v_workspace_id and s.member_id = m.id and (
        (s.work_date = v_today and ((s.start_time < s.end_time and v_time >= s.start_time and v_time < s.end_time) or (s.start_time > s.end_time and v_time >= s.start_time)))
        or (s.work_date = v_today - 1 and s.start_time > s.end_time and v_time < s.end_time)
      )
    )
    and not exists (
      select 1 from public.breaks b where b.workspace_id = v_workspace_id and b.member_id = m.id and (
        (b.work_date = v_today and ((b.start_time < b.end_time and v_time >= b.start_time and v_time < b.end_time) or (b.start_time > b.end_time and v_time >= b.start_time)))
        or (b.work_date = v_today - 1 and b.start_time > b.end_time and v_time < b.end_time)
      )
    )
    and not exists (
      select 1 from public.availability_requests r where r.workspace_id = v_workspace_id and r.member_id = m.id
        and r.status = 'approved' and r.start_at <= v_now and r.end_at > v_now
        and (not p_existing_ticket or r.request_type not in ('technical','rdp','meeting'))
    )
  order by case when v_last_order is null or m.sort_order > v_last_order then 0 else 1 end, m.sort_order
  limit 1;

  if v_target_id is null then raise exception 'No employees are currently eligible for allocation.'; end if;

  insert into public.allocations(workspace_id, recipient_member_id, assigned_by_member_id, reference, email_subject, allocation_kind, assigned_at)
  values (v_workspace_id, v_target_id, v_actor_id, nullif(trim(coalesce(p_reference, '')), ''), v_subject, case when p_existing_ticket then 'existing_ticket' else 'new_email' end, v_now)
  returning id into v_allocation_id;

  update public.allocation_state set last_allocated_member_id = v_target_id, updated_at = v_now
  where workspace_id = v_workspace_id;

  insert into public.audit_events(workspace_id, actor_member_id, event_type, summary, entity_type, entity_id, metadata, created_at)
  values (
    v_workspace_id, v_actor_id, 'allocation',
    'Assigned email to ' || v_target_name,
    'allocation', v_allocation_id,
    jsonb_build_object('recipient_member_id', v_target_id, 'email_subject', v_subject, 'reference', p_reference, 'allocation_kind', case when p_existing_ticket then 'existing_ticket' else 'new_email' end),
    v_now
  );

  return jsonb_build_object(
    'allocation_id', v_allocation_id,
    'member_id', v_target_id,
    'member_name', v_target_name,
    'assigned_by_member_id', v_actor_id,
    'email_subject', v_subject,
    'allocation_kind', case when p_existing_ticket then 'existing_ticket' else 'new_email' end,
    'reference', nullif(trim(coalesce(p_reference, '')), ''),
    'assigned_at', v_now
  );
end;
$$;

create or replace function public.add_break(p_work_date date, p_start time, p_end time, p_note text default 'Scheduled break', p_break_type text default 'bio')
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_workspace_id uuid; v_member_id uuid; v_break_id uuid; v_local_date date; v_timezone text;
  v_break_start timestamptz; v_break_end timestamptz;

begin
  select workspace_id, member_id into v_workspace_id, v_member_id from public.member_sessions where auth_user_id = auth.uid();
  if v_member_id is null then raise exception 'Join the team workspace first.'; end if;
  if p_start = p_end then raise exception 'Start and end times cannot be identical.'; end if;
  if p_break_type not in ('bio','meal') then raise exception 'Choose BioBreak or Meal break.'; end if;
  select (now() at time zone timezone)::date, timezone into v_local_date, v_timezone from public.workspaces where id = v_workspace_id;
  if p_work_date < v_local_date - 1 or p_work_date > v_local_date + 90 then raise exception 'Break date must be within the next 90 days.'; end if;
  v_break_start := (p_work_date + p_start) at time zone v_timezone;
  v_break_end := ((p_work_date + p_end) + case when p_end <= p_start then interval '1 day' else interval '0' end) at time zone v_timezone;
  if not exists (select 1 from public.shifts s where s.workspace_id = v_workspace_id and s.member_id = v_member_id and s.work_date between p_work_date - 1 and p_work_date
      and v_break_start >= ((s.work_date + s.start_time) at time zone v_timezone)
      and v_break_end <= (((s.work_date + s.end_time) + case when s.end_time <= s.start_time then interval '1 day' else interval '0' end) at time zone v_timezone)) then
    raise exception 'The planned break must fit inside one of your scheduled shifts.';
  end if;

  if v_break_end <= v_break_start then raise exception 'Break end must be after break start.'; end if;
  if extract(epoch from (v_break_end - v_break_start)) / 60 > 60 then
    raise exception 'A single break cannot exceed 60 minutes.';
  end if;
  if exists (
    select 1 from public.breaks b
    where b.workspace_id = v_workspace_id and b.member_id = v_member_id
      and tstzrange(
        (b.work_date + b.start_time) at time zone v_timezone,
        ((b.work_date + b.end_time) + case when b.end_time <= b.start_time then interval '1 day' else interval '0' end) at time zone v_timezone,
        '[)'
      ) && tstzrange(v_break_start, v_break_end, '[)')
  ) then raise exception 'This break overlaps another planned break.'; end if;
  if (
    coalesce((
      select sum(extract(epoch from (
        ((b.work_date + b.end_time) + case when b.end_time <= b.start_time then interval '1 day' else interval '0' end)
        - (b.work_date + b.start_time)
      )) / 60)
      from public.breaks b
      where b.workspace_id = v_workspace_id and b.member_id = v_member_id
        and b.work_date = p_work_date
    ), 0)
    + extract(epoch from (v_break_end - v_break_start)) / 60
  ) > 60 and not exists (
    select 1 from public.availability_requests r
    where r.workspace_id = v_workspace_id and r.member_id = v_member_id
      and r.request_type = 'extended_break' and r.status = 'approved'
      and r.start_at <= v_break_start and r.end_at >= v_break_end
  ) then
    raise exception 'Your 60-minute break allowance is used. Request additional time from an SME or Super Admin.';
  end if;

  if length(trim(coalesce(p_note, ''))) > 100 then raise exception 'Break note is too long.'; end if;
  insert into public.breaks(workspace_id, member_id, work_date, start_time, end_time, note, break_type, created_by)
  values (v_workspace_id, v_member_id, p_work_date, p_start, p_end, coalesce(nullif(trim(p_note), ''), case when p_break_type = 'meal' then 'Meal break' else 'BioBreak' end), p_break_type, v_member_id)
  returning id into v_break_id;
  insert into public.audit_events(workspace_id, actor_member_id, event_type, summary, entity_type, entity_id)
  values (v_workspace_id, v_member_id, 'break_added', 'Planned a break for ' || p_work_date::text, 'break', v_break_id);
  return jsonb_build_object('break_id', v_break_id);
end;
$$;

create or replace function public.admin_list_members()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_workspace_id uuid; v_member_id uuid; v_result jsonb;
begin
  select workspace_id, member_id into v_workspace_id, v_member_id
  from public.member_sessions where auth_user_id = auth.uid();
  if v_member_id is null or not public.is_workspace_admin() then raise exception 'Workspace admin access required.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', m.id, 'name', m.name, 'active', m.active, 'sortOrder', m.sort_order,
    'accessCodeUpdatedAt', c.updated_at,
    'adminRole', a.role
  ) order by m.sort_order), '[]'::jsonb)
  into v_result
  from public.members m
  left join public.member_access_codes c on c.member_id = m.id and c.workspace_id = m.workspace_id
  left join public.workspace_admins a on a.member_id = m.id and a.workspace_id = m.workspace_id
  where m.workspace_id = v_workspace_id;
  return v_result;
end;
$$;

create or replace function public.admin_set_member_role(p_member_id uuid,p_role text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_workspace_id uuid; v_actor_id uuid; v_name text;
begin
  select workspace_id,member_id into v_workspace_id,v_actor_id
  from public.member_sessions where auth_user_id=auth.uid();
  if v_actor_id is null or not public.is_workspace_admin() then
    raise exception 'Workspace admin access required.';
  end if;
  if p_role not in ('super_admin','sme','none') then raise exception 'Choose Super Admin, SME, or no admin access.'; end if;
  if not exists(select 1 from public.members where id=p_member_id and workspace_id=v_workspace_id and active) then
    raise exception 'Active team member not found.';
  end if;
  perform 1 from public.workspaces where id=v_workspace_id for update;
  if p_role='none' then
    if (select count(*) from public.workspace_admins where workspace_id=v_workspace_id) <= 1 then
      raise exception 'At least one admin account must remain.';
    end if;
    delete from public.workspace_admins where workspace_id=v_workspace_id and member_id=p_member_id;
  else
    insert into public.workspace_admins(workspace_id,member_id,role)
    values(v_workspace_id,p_member_id,p_role)
    on conflict(workspace_id,member_id) do update set role=excluded.role;
  end if;
  select name into v_name from public.members where id=p_member_id;
  insert into public.audit_events(workspace_id,actor_member_id,event_type,summary,entity_type,entity_id,metadata)
  values(v_workspace_id,v_actor_id,'admin_role_changed',
    case when p_role='none' then 'Removed admin access from '||v_name else 'Set '||v_name||' role to '||p_role end,
    'member',p_member_id,jsonb_build_object('role',p_role));
  return jsonb_build_object('member_id',p_member_id,'role',p_role);
end;
$$;

revoke execute on function public.heartbeat_member_presence(text) from public, anon;
grant execute on function public.heartbeat_member_presence(text) to authenticated;
revoke execute on function public.set_member_offline() from public, anon;
grant execute on function public.set_member_offline() to authenticated;
revoke execute on function public.get_workspace_presence() from public, anon;
grant execute on function public.get_workspace_presence() to authenticated;
revoke execute on function public.admin_set_member_role(uuid,text) from public, anon;
grant execute on function public.admin_set_member_role(uuid,text) to authenticated;
revoke execute on function public.ensure_shift_assignee() from public, anon;
grant execute on function public.ensure_shift_assignee() to authenticated;
revoke execute on function public.record_next_allocation(text,text,boolean) from public, anon;
grant execute on function public.record_next_allocation(text,text,boolean) to authenticated;
revoke execute on function public.add_break(date,time,time,text,text) from public, anon;
grant execute on function public.add_break(date,time,time,text,text) to authenticated;
revoke execute on function public.admin_list_members() from public, anon;
grant execute on function public.admin_list_members() to authenticated;
