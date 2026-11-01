-- WHO'S next: precise allocation timeline, email subject and automatic shift-owner handover.
-- Apply after 202611020001_individual_member_access_codes.sql.

alter table public.allocations
  add column if not exists email_subject text
  check (email_subject is null or length(email_subject) <= 200);

-- Keep allocation attribution server-derived from the anonymous session's mapped member.
-- The database timestamp (now()) is authoritative and retains sub-second precision.
drop function if exists public.record_next_allocation(text);

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
  -- move responsibility to the earliest-starting eligible shift colleague.
  select m.id into v_next
  from public.members m
  join public.shifts s on s.workspace_id = m.workspace_id and s.member_id = m.id
  where m.workspace_id = v_workspace_id and m.active
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
  p_subject text default null
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
    )
  order by case when v_last_order is null or m.sort_order > v_last_order then 0 else 1 end, m.sort_order
  limit 1;

  if v_target_id is null then raise exception 'No employees are currently eligible for allocation.'; end if;

  insert into public.allocations(workspace_id, recipient_member_id, assigned_by_member_id, reference, email_subject, assigned_at)
  values (v_workspace_id, v_target_id, v_actor_id, nullif(trim(coalesce(p_reference, '')), ''), v_subject, v_now)
  returning id into v_allocation_id;

  update public.allocation_state set last_allocated_member_id = v_target_id, updated_at = v_now
  where workspace_id = v_workspace_id;

  insert into public.audit_events(workspace_id, actor_member_id, event_type, summary, entity_type, entity_id, metadata, created_at)
  values (
    v_workspace_id, v_actor_id, 'allocation',
    'Assigned email to ' || v_target_name,
    'allocation', v_allocation_id,
    jsonb_build_object('recipient_member_id', v_target_id, 'email_subject', v_subject, 'reference', p_reference),
    v_now
  );

  return jsonb_build_object(
    'allocation_id', v_allocation_id,
    'member_id', v_target_id,
    'member_name', v_target_name,
    'assigned_by_member_id', v_actor_id,
    'email_subject', v_subject,
    'reference', nullif(trim(coalesce(p_reference, '')), ''),
    'assigned_at', v_now
  );
end;
$$;

revoke execute on function public.ensure_shift_assignee() from public, anon;
grant execute on function public.ensure_shift_assignee() to authenticated;
revoke execute on function public.record_next_allocation(text, text) from public, anon;
grant execute on function public.record_next_allocation(text, text) to authenticated;
