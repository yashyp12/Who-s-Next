-- Shift-aware status and allocation routing.
-- Apply after 202611020005_member_notifications.sql.

alter table public.breaks
  add column if not exists break_type text not null default 'bio'
  check (break_type in ('bio','meal'));

alter table public.allocations
  add column if not exists allocation_kind text not null default 'new_email'
  check (allocation_kind in ('new_email','existing_ticket'));

drop function if exists public.record_next_allocation(text, text);
drop function if exists public.record_next_allocation(text, text, boolean);
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
        and (not p_existing_ticket or r.request_type = 'leave')
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


drop function if exists public.add_break(date, time, time, text);
drop function if exists public.add_break(date, time, time, text, text);
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
  if length(trim(coalesce(p_note, ''))) > 100 then raise exception 'Break note is too long.'; end if;
  insert into public.breaks(workspace_id, member_id, work_date, start_time, end_time, note, break_type, created_by)
  values (v_workspace_id, v_member_id, p_work_date, p_start, p_end, coalesce(nullif(trim(p_note), ''), case when p_break_type = 'meal' then 'Meal break' else 'BioBreak' end), p_break_type, v_member_id)
  returning id into v_break_id;
  insert into public.audit_events(workspace_id, actor_member_id, event_type, summary, entity_type, entity_id)
  values (v_workspace_id, v_member_id, 'break_added', 'Planned a break for ' || p_work_date::text, 'break', v_break_id);
  return jsonb_build_object('break_id', v_break_id);
end;
$$;


-- Return the new subject field to connected clients without changing the existing dashboard contract.
create or replace function public.get_dashboard()
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare
  v_workspace_id uuid;
  v_workspace public.workspaces%rowtype;
  v_payload jsonb;

begin
  select s.workspace_id into v_workspace_id from public.member_sessions s where s.auth_user_id = auth.uid();
  if v_workspace_id is null then raise exception 'Join the team workspace first.'; end if;
  select * into v_workspace from public.workspaces where id = v_workspace_id;
  select jsonb_build_object(
    'workspaceName', v_workspace.name,
    'timezone', v_workspace.timezone,
    'currentAssigneeId', (select current_assignee_id from public.allocation_state where workspace_id = v_workspace_id),
    'lastAllocatedMemberId', (select last_allocated_member_id from public.allocation_state where workspace_id = v_workspace_id),
    'members', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'name', m.name, 'active', m.active, 'sortOrder', m.sort_order) order by m.sort_order) from public.members m where m.workspace_id = v_workspace_id), '[]'::jsonb),
    'shifts', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'memberId', s.member_id, 'date', s.work_date, 'key', s.shift_key, 'start', to_char(s.start_time, 'HH24:MI'), 'end', to_char(s.end_time, 'HH24:MI')) order by s.work_date, s.start_time) from public.shifts s where s.workspace_id = v_workspace_id and s.work_date between (now() at time zone v_workspace.timezone)::date - 1 and (now() at time zone v_workspace.timezone)::date + 90), '[]'::jsonb),
    'breaks', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'memberId', b.member_id, 'date', b.work_date, 'start', to_char(b.start_time, 'HH24:MI'), 'end', to_char(b.end_time, 'HH24:MI'), 'note', b.note, 'breakType', b.break_type) order by b.work_date, b.start_time) from public.breaks b where b.workspace_id = v_workspace_id and b.work_date between (now() at time zone v_workspace.timezone)::date - 1 and (now() at time zone v_workspace.timezone)::date + 90), '[]'::jsonb),
    'requests', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'memberId', r.member_id, 'type', r.request_type, 'reason', r.reason, 'details', r.details, 'startAt', r.start_at, 'endAt', r.end_at, 'status', r.status, 'createdAt', r.created_at, 'reviewedBy', r.reviewed_by, 'reviewedAt', r.reviewed_at, 'confirmation', r.manager_confirmation) order by r.created_at desc) from (select * from public.availability_requests where workspace_id = v_workspace_id order by created_at desc limit 500) r), '[]'::jsonb),
    'allocations', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'memberId', a.recipient_member_id, 'assignedBy', a.assigned_by_member_id, 'assignedAt', a.assigned_at, 'reference', a.reference, 'emailSubject', a.email_subject, 'allocationKind', a.allocation_kind) order by a.assigned_at desc) from (select * from public.allocations where workspace_id = v_workspace_id order by assigned_at desc limit 500) a), '[]'::jsonb),
    'attendance', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'memberId', e.member_id, 'eventType', e.event_type, 'occurredAt', e.occurred_at) order by e.occurred_at desc) from (select * from public.attendance_events where workspace_id = v_workspace_id order by occurred_at desc limit 200) e), '[]'::jsonb),
    'handovers', coalesce((select jsonb_agg(jsonb_build_object('id', h.id, 'fromMemberId', h.from_member_id, 'toMemberId', h.to_member_id, 'createdAt', h.handed_over_at) order by h.handed_over_at desc) from (select * from public.handovers where workspace_id = v_workspace_id order by handed_over_at desc limit 100) h), '[]'::jsonb),
    'shiftSwaps', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'requesterMemberId', x.requester_member_id, 'partnerMemberId', x.partner_member_id, 'workDate', x.work_date, 'status', x.status, 'createdAt', x.created_at, 'respondedAt', x.responded_at) order by x.created_at desc) from (select * from public.shift_swap_requests where workspace_id = v_workspace_id order by created_at desc limit 200) x), '[]'::jsonb),
    'activities', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'text', a.summary, 'icon', case when a.event_type = 'allocation' then '⇄' when a.event_type = 'approval' then '✓' when a.event_type = 'handover' then '↔' else '•' end, 'createdAt', a.created_at) order by a.created_at desc) from (select * from public.audit_events where workspace_id = v_workspace_id order by created_at desc limit 100) a), '[]'::jsonb)
  ) into v_payload;
  return v_payload;
end;
$$;



