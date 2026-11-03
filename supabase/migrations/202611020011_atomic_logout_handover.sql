-- Make explicit logout and allocation handover one atomic database transaction.
-- Prefer the next eligible colleague in the departing owner's active shift,
-- rotating by member sort order; fall back to another active shift only when
-- nobody in the same shift is eligible.

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
  v_previous_work_date date;
  v_previous_shift_key text;
  v_previous_start time;
  v_previous_end time;
  v_previous_sort_order integer;
begin
  select workspace_id, member_id into v_workspace_id, v_actor_id
  from public.member_sessions
  where auth_user_id = auth.uid();
  if v_actor_id is null then
    raise exception 'Join the team workspace first.';
  end if;

  -- Serialize every ownership reconciliation for this workspace.
  select current_assignee_id into v_previous
  from public.allocation_state
  where workspace_id = v_workspace_id
  for update;
  if not found then
    raise exception 'Allocation state is not initialized.';
  end if;

  select timezone into v_timezone
  from public.workspaces
  where id = v_workspace_id;
  if v_timezone is null then
    raise exception 'Workspace timezone is not configured.';
  end if;

  v_now := now();
  v_today := (v_now at time zone v_timezone)::date;
  v_time := (v_now at time zone v_timezone)::time;

  -- Keep the current owner only while every eligibility condition is true.
  if v_previous is not null and exists (
    select 1
    from public.members m
    where m.id = v_previous
      and m.workspace_id = v_workspace_id
      and m.active
      and exists (
        select 1 from public.member_presence p
        where p.workspace_id = m.workspace_id
          and p.member_id = m.id
          and p.presence_state = 'active'
          and p.last_seen_at > v_now - interval '90 seconds'
      )
      and exists (
        select 1 from public.shifts s
        where s.workspace_id = v_workspace_id
          and s.member_id = m.id
          and (
            (s.work_date = v_today and (
              (s.start_time < s.end_time and v_time >= s.start_time and v_time < s.end_time)
              or (s.start_time > s.end_time and v_time >= s.start_time)
            ))
            or (s.work_date = v_today - 1 and s.start_time > s.end_time and v_time < s.end_time)
          )
      )
      and not exists (
        select 1 from public.breaks b
        where b.workspace_id = v_workspace_id
          and b.member_id = m.id
          and (
            (b.work_date = v_today and (
              (b.start_time < b.end_time and v_time >= b.start_time and v_time < b.end_time)
              or (b.start_time > b.end_time and v_time >= b.start_time)
            ))
            or (b.work_date = v_today - 1 and b.start_time > b.end_time and v_time < b.end_time)
          )
      )
      and not exists (
        select 1 from public.availability_requests r
        where r.workspace_id = v_workspace_id
          and r.member_id = m.id
          and r.status = 'approved'
          and r.start_at <= v_now
          and r.end_at > v_now
      )
  ) then
    return jsonb_build_object('current_assignee_id', v_previous, 'changed', false);
  end if;

  -- Capture the departing owner's active shift so the handover stays within
  -- that shift whenever another eligible colleague is available.
  if v_previous is not null then
    select s.work_date, s.shift_key, s.start_time, s.end_time, m.sort_order
    into v_previous_work_date, v_previous_shift_key,
         v_previous_start, v_previous_end, v_previous_sort_order
    from public.shifts s
    join public.members m
      on m.id = s.member_id and m.workspace_id = s.workspace_id
    where s.workspace_id = v_workspace_id
      and s.member_id = v_previous
      and (
        (s.work_date = v_today and (
          (s.start_time < s.end_time and v_time >= s.start_time and v_time < s.end_time)
          or (s.start_time > s.end_time and v_time >= s.start_time)
        ))
        or (s.work_date = v_today - 1 and s.start_time > s.end_time and v_time < s.end_time)
      )
    order by s.work_date desc, s.start_time desc
    limit 1;
  end if;

  -- Pick the next eligible colleague after the departing owner in the same
  -- shift. If that shift has no eligible colleague, fall back to the most
  -- recently started active shift. Presence, shift, break and approved-request
  -- checks are all performed against the database clock.
  select m.id into v_next
  from public.members m
  join public.shifts s
    on s.workspace_id = m.workspace_id
   and s.member_id = m.id
  where m.workspace_id = v_workspace_id
    and m.active
    and exists (
      select 1 from public.member_presence p
      where p.workspace_id = m.workspace_id
        and p.member_id = m.id
        and p.presence_state = 'active'
        and p.last_seen_at > v_now - interval '90 seconds'
    )
    and (
      (s.work_date = v_today and (
        (s.start_time < s.end_time and v_time >= s.start_time and v_time < s.end_time)
        or (s.start_time > s.end_time and v_time >= s.start_time)
      ))
      or (s.work_date = v_today - 1 and s.start_time > s.end_time and v_time < s.end_time)
    )
    and not exists (
      select 1 from public.breaks b
      where b.workspace_id = v_workspace_id
        and b.member_id = m.id
        and (
          (b.work_date = v_today and (
            (b.start_time < b.end_time and v_time >= b.start_time and v_time < b.end_time)
            or (b.start_time > b.end_time and v_time >= b.start_time)
          ))
          or (b.work_date = v_today - 1 and b.start_time > b.end_time and v_time < b.end_time)
        )
    )
    and not exists (
      select 1 from public.availability_requests r
      where r.workspace_id = v_workspace_id
        and r.member_id = m.id
        and r.status = 'approved'
        and r.start_at <= v_now
        and r.end_at > v_now
    )
  order by
    case
      when s.work_date = v_previous_work_date
       and s.shift_key = v_previous_shift_key
       and s.start_time = v_previous_start
       and s.end_time = v_previous_end
      then 0 else 1
    end,
    case
      when s.work_date = v_previous_work_date
       and s.shift_key = v_previous_shift_key
       and s.start_time = v_previous_start
       and s.end_time = v_previous_end
       and m.sort_order > coalesce(v_previous_sort_order, -2147483648)
      then 0
      when s.work_date = v_previous_work_date
       and s.shift_key = v_previous_shift_key
       and s.start_time = v_previous_start
       and s.end_time = v_previous_end
      then 1
      else 0
    end,
    case
      when s.work_date = v_previous_work_date
       and s.shift_key = v_previous_shift_key
       and s.start_time = v_previous_start
       and s.end_time = v_previous_end
      then m.sort_order
      else null
    end,
    ((s.work_date + s.start_time) at time zone v_timezone) desc,
    m.sort_order
  limit 1;

  if v_next is not distinct from v_previous then
    return jsonb_build_object('current_assignee_id', v_previous, 'changed', false);
  end if;

  update public.allocation_state
  set current_assignee_id = v_next,
      updated_at = v_now
  where workspace_id = v_workspace_id;

  if v_next is not null then
    insert into public.handovers(workspace_id, from_member_id, to_member_id, handed_over_at)
    values (v_workspace_id, v_previous, v_next, v_now);
  end if;

  insert into public.audit_events(
    workspace_id, actor_member_id, event_type, summary,
    entity_type, metadata, created_at
  )
  values (
    v_workspace_id,
    null,
    'automatic_handover',
    case
      when v_next is null then 'No eligible colleague is on shift; allocation responsibility is unassigned'
      else 'Automatic shift handover completed'
    end,
    'allocation_state',
    jsonb_build_object(
      'from_member_id', v_previous,
      'to_member_id', v_next,
      'reason', 'shift_or_availability_change'
    ),
    v_now
  );

  return jsonb_build_object(
    'current_assignee_id', v_next,
    'changed', true
  );
end;
$$;

-- Deleting presence and reconciling ownership now happen in one transaction.
-- If reconciliation fails, the delete is rolled back rather than leaving the
-- workspace with a silently stale owner.
create or replace function public.set_member_offline()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_workspace_id uuid;
  v_member_id uuid;
  v_handover jsonb;
begin
  select workspace_id, member_id
  into v_workspace_id, v_member_id
  from public.member_sessions
  where auth_user_id = auth.uid();

  if v_member_id is null then
    return jsonb_build_object('offline', true);
  end if;

  delete from public.member_presence
  where workspace_id = v_workspace_id
    and member_id = v_member_id
    and auth_user_id = auth.uid();

  v_handover := public.ensure_shift_assignee();

  return jsonb_build_object(
    'offline', true,
    'member_id', v_member_id,
    'handover', v_handover
  );
end;
$$;

revoke execute on function public.ensure_shift_assignee() from public, anon;
grant execute on function public.ensure_shift_assignee() to authenticated;
revoke execute on function public.set_member_offline() from public, anon;
grant execute on function public.set_member_offline() to authenticated;
