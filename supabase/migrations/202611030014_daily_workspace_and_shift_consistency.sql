-- Daily member workspace views and immediate shift reconciliation.
-- Historical operational records remain available to Super Admin / SME.
-- Apply after migrations 001-012.

create or replace function public.upsert_shift(p_work_date date, p_shift_key text, p_start time, p_end time)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_workspace_id uuid; v_member_id uuid; v_shift_id uuid; v_old jsonb; v_local_date date; v_timezone text;
  v_new_start timestamptz; v_new_end timestamptz;

begin
  select workspace_id, member_id into v_workspace_id, v_member_id from public.member_sessions where auth_user_id = auth.uid();
  if v_member_id is null then raise exception 'Join the team workspace first.'; end if;
  if p_start = p_end then raise exception 'Start and end times cannot be identical.'; end if;
  select (now() at time zone timezone)::date, timezone into v_local_date, v_timezone from public.workspaces where id = v_workspace_id;
  if p_work_date < v_local_date - 1 or p_work_date > v_local_date + 90 then raise exception 'Shift date must be within the next 90 days.'; end if;
  if p_shift_key not in ('morning','mid','evening','night','custom') then raise exception 'Invalid shift pattern.'; end if;
  v_new_start := (p_work_date + p_start) at time zone v_timezone;
  v_new_end := ((p_work_date + p_end) + case when p_end <= p_start then interval '1 day' else interval '0' end) at time zone v_timezone;
  if exists (select 1 from public.shifts s where s.workspace_id = v_workspace_id and s.member_id = v_member_id and s.work_date between p_work_date - 1 and p_work_date + 1 and s.work_date <> p_work_date
      and v_new_start < (((s.work_date + s.end_time) + case when s.end_time <= s.start_time then interval '1 day' else interval '0' end) at time zone v_timezone)
      and v_new_end > ((s.work_date + s.start_time) at time zone v_timezone)) then
    raise exception 'This shift overlaps another scheduled shift. Update the conflicting date first.';
  end if;
  if exists (select 1 from public.breaks b where b.workspace_id = v_workspace_id and b.member_id = v_member_id and b.work_date = p_work_date
      and (((b.work_date + b.start_time) at time zone v_timezone) < v_new_start
        or (((b.work_date + b.end_time) + case when b.end_time <= b.start_time then interval '1 day' else interval '0' end) at time zone v_timezone) > v_new_end)) then
    raise exception 'The updated shift would leave a planned break outside working hours. Update or remove the break first.';
  end if;
  select to_jsonb(s) into v_old from public.shifts s where workspace_id = v_workspace_id and member_id = v_member_id and work_date = p_work_date;
  insert into public.shifts(workspace_id, member_id, work_date, shift_key, start_time, end_time, created_by)
  values (v_workspace_id, v_member_id, p_work_date, p_shift_key, p_start, p_end, v_member_id)
  on conflict (workspace_id, member_id, work_date) do update
    set shift_key = excluded.shift_key, start_time = excluded.start_time, end_time = excluded.end_time, updated_at = now()
  returning id into v_shift_id;
  insert into public.audit_events(workspace_id, actor_member_id, event_type, summary, entity_type, entity_id, metadata)
  values (v_workspace_id, v_member_id, 'shift_change', 'Updated shift schedule for ' || p_work_date::text, 'shift', v_shift_id, jsonb_build_object('before', v_old, 'after', jsonb_build_object('date', p_work_date, 'key', p_shift_key, 'start', p_start, 'end', p_end)));
  perform public.ensure_shift_assignee();
  return jsonb_build_object('shift_id', v_shift_id);
end;
$$;

create or replace function public.admin_upsert_shift(p_member_id uuid, p_work_date date, p_shift_key text, p_start time, p_end time)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_workspace_id uuid; v_member_id uuid; v_actor_id uuid; v_shift_id uuid; v_old jsonb; v_local_date date; v_timezone text;
  v_new_start timestamptz; v_new_end timestamptz;

begin
  select workspace_id, member_id into v_workspace_id, v_actor_id from public.member_sessions where auth_user_id = auth.uid();
  if v_actor_id is null then raise exception 'Join the team workspace first.'; end if;
  if not exists (select 1 from public.workspace_admins where workspace_id = v_workspace_id and member_id = v_actor_id) then raise exception 'Workspace admin access required.'; end if;
  if not exists (select 1 from public.members where id = p_member_id and workspace_id = v_workspace_id) then raise exception 'Member not found in this workspace.'; end if;
  v_member_id := p_member_id;
  if p_start = p_end then raise exception 'Start and end times cannot be identical.'; end if;
  select (now() at time zone timezone)::date, timezone into v_local_date, v_timezone from public.workspaces where id = v_workspace_id;
  if p_work_date < v_local_date - 1 or p_work_date > v_local_date + 90 then raise exception 'Shift date must be within the next 90 days.'; end if;
  if p_shift_key not in ('morning','mid','evening','night','custom') then raise exception 'Invalid shift pattern.'; end if;
  v_new_start := (p_work_date + p_start) at time zone v_timezone;
  v_new_end := ((p_work_date + p_end) + case when p_end <= p_start then interval '1 day' else interval '0' end) at time zone v_timezone;
  if exists (select 1 from public.shifts s where s.workspace_id = v_workspace_id and s.member_id = v_member_id and s.work_date between p_work_date - 1 and p_work_date + 1 and s.work_date <> p_work_date
      and v_new_start < (((s.work_date + s.end_time) + case when s.end_time <= s.start_time then interval '1 day' else interval '0' end) at time zone v_timezone)
      and v_new_end > ((s.work_date + s.start_time) at time zone v_timezone)) then
    raise exception 'This shift overlaps another scheduled shift. Update the conflicting date first.';
  end if;
  if exists (select 1 from public.breaks b where b.workspace_id = v_workspace_id and b.member_id = v_member_id and b.work_date = p_work_date
      and (((b.work_date + b.start_time) at time zone v_timezone) < v_new_start
        or (((b.work_date + b.end_time) + case when b.end_time <= b.start_time then interval '1 day' else interval '0' end) at time zone v_timezone) > v_new_end)) then
    raise exception 'The updated shift would leave a planned break outside working hours. Update or remove the break first.';
  end if;
  select to_jsonb(s) into v_old from public.shifts s where workspace_id = v_workspace_id and member_id = v_member_id and work_date = p_work_date;
  insert into public.shifts(workspace_id, member_id, work_date, shift_key, start_time, end_time, created_by)
  values (v_workspace_id, v_member_id, p_work_date, p_shift_key, p_start, p_end, v_actor_id)
  on conflict (workspace_id, member_id, work_date) do update
    set shift_key = excluded.shift_key, start_time = excluded.start_time, end_time = excluded.end_time, updated_at = now()
  returning id into v_shift_id;
  insert into public.audit_events(workspace_id, actor_member_id, event_type, summary, entity_type, entity_id, metadata)
  values (v_workspace_id, v_actor_id, 'shift_change', 'Admin updated shift schedule for ' || p_work_date::text, 'shift', v_shift_id, jsonb_build_object('before', v_old, 'after', jsonb_build_object('date', p_work_date, 'key', p_shift_key, 'start', p_start, 'end', p_end)));
  perform public.ensure_shift_assignee();
  return jsonb_build_object('shift_id', v_shift_id);
end;
$$;

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
  v_today date;
  v_time time;
  v_current_shift_start timestamptz;

begin
  select s.workspace_id into v_workspace_id from public.member_sessions s where s.auth_user_id = auth.uid();
  if v_workspace_id is null then raise exception 'Join the team workspace first.'; end if;
  select * into v_workspace from public.workspaces where id = v_workspace_id;
  v_today := (now() at time zone v_workspace.timezone)::date;
  v_time := (now() at time zone v_workspace.timezone)::time;
  select (s.work_date + s.start_time) at time zone v_workspace.timezone
  into v_current_shift_start
  from public.shifts s
  where s.workspace_id=v_workspace_id
    and s.member_id=(select member_id from public.member_sessions where auth_user_id=auth.uid())
    and (
      (s.work_date=v_today and ((s.start_time < s.end_time and v_time >= s.start_time and v_time < s.end_time) or (s.start_time > s.end_time and v_time >= s.start_time)))
      or (s.work_date=v_today - 1 and s.start_time > s.end_time and v_time < s.end_time)
    )
  order by s.work_date desc limit 1;
  if v_current_shift_start is null then
    v_current_shift_start := now();
  end if;
  select jsonb_build_object(
    'workspaceName', v_workspace.name,
    'timezone', v_workspace.timezone,
    'currentAssigneeId', (select current_assignee_id from public.allocation_state where workspace_id = v_workspace_id),
    'lastAllocatedMemberId', (select last_allocated_member_id from public.allocation_state where workspace_id = v_workspace_id),
    'members', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'name', m.name, 'active', m.active, 'sortOrder', m.sort_order) order by m.sort_order) from public.members m where m.workspace_id = v_workspace_id), '[]'::jsonb),
    'shifts', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'memberId', s.member_id, 'date', s.work_date, 'key', s.shift_key, 'start', to_char(s.start_time, 'HH24:MI'), 'end', to_char(s.end_time, 'HH24:MI')) order by s.work_date, s.start_time) from public.shifts s where s.workspace_id = v_workspace_id and s.work_date between (now() at time zone v_workspace.timezone)::date - 1 and (now() at time zone v_workspace.timezone)::date + 90), '[]'::jsonb),
    'breaks', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'memberId', b.member_id, 'date', b.work_date, 'start', to_char(b.start_time, 'HH24:MI'), 'end', to_char(b.end_time, 'HH24:MI'), 'note', b.note, 'breakType', b.break_type) order by b.work_date, b.start_time) from public.breaks b where b.workspace_id = v_workspace_id and b.work_date between (now() at time zone v_workspace.timezone)::date - 1 and (now() at time zone v_workspace.timezone)::date + 90), '[]'::jsonb),
    'requests', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'memberId', r.member_id, 'type', r.request_type, 'reason', r.reason, 'details', r.details, 'startAt', r.start_at, 'endAt', r.end_at, 'status', r.status, 'createdAt', r.created_at, 'reviewedBy', r.reviewed_by, 'reviewedAt', r.reviewed_at, 'confirmation', r.manager_confirmation) order by r.created_at desc) from (select * from public.availability_requests where workspace_id = v_workspace_id and (public.is_workspace_admin() or status = 'pending' or (status = 'approved' and end_at > now()) or (created_at at time zone v_workspace.timezone)::date = v_today) order by created_at desc limit 500) r), '[]'::jsonb),
    'allocations', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'memberId', a.recipient_member_id, 'assignedBy', a.assigned_by_member_id, 'assignedAt', a.assigned_at, 'reference', a.reference, 'emailSubject', a.email_subject, 'allocationKind', a.allocation_kind) order by a.assigned_at desc) from (select * from public.allocations a where a.workspace_id = v_workspace_id and (public.is_workspace_admin() or (a.assigned_at at time zone v_workspace.timezone)::date = v_today) order by a.assigned_at desc limit 500) a), '[]'::jsonb),
    'attendance', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'memberId', e.member_id, 'eventType', e.event_type, 'occurredAt', e.occurred_at) order by e.occurred_at desc) from (select * from public.attendance_events where workspace_id = v_workspace_id and (public.is_workspace_admin() or (occurred_at at time zone v_workspace.timezone)::date = v_today) order by occurred_at desc limit 200) e), '[]'::jsonb),
    'handovers', coalesce((select jsonb_agg(jsonb_build_object('id', h.id, 'fromMemberId', h.from_member_id, 'toMemberId', h.to_member_id, 'createdAt', h.handed_over_at) order by h.handed_over_at desc) from (select * from public.handovers where workspace_id = v_workspace_id and (public.is_workspace_admin() or (handed_over_at at time zone v_workspace.timezone)::date = v_today) order by handed_over_at desc limit 100) h), '[]'::jsonb),
    'shiftSwaps', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'requesterMemberId', x.requester_member_id, 'partnerMemberId', x.partner_member_id, 'workDate', x.work_date, 'status', x.status, 'createdAt', x.created_at, 'respondedAt', x.responded_at) order by x.created_at desc) from (select * from public.shift_swap_requests where workspace_id = v_workspace_id and (public.is_workspace_admin() or status = 'pending' or work_date >= v_today or (created_at at time zone v_workspace.timezone)::date = v_today) order by created_at desc limit 200) x), '[]'::jsonb),
    'activities', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'text', a.summary, 'icon', case when a.event_type = 'allocation' then '⇄' when a.event_type = 'approval' then '✓' when a.event_type = 'handover' then '↔' else '•' end, 'createdAt', a.created_at) order by a.created_at desc) from (select * from public.audit_events a where a.workspace_id = v_workspace_id and (public.is_workspace_admin() or (a.created_at at time zone v_workspace.timezone)::date = v_today) order by a.created_at desc limit 100) a), '[]'::jsonb)
  ) into v_payload;
  return v_payload;
end;
$$;

revoke execute on function public.upsert_shift(date, text, time, time) from public, anon;
grant execute on function public.upsert_shift(date, text, time, time) to authenticated;
revoke execute on function public.admin_upsert_shift(uuid, date, text, time, time) from public, anon;
grant execute on function public.admin_upsert_shift(uuid, date, text, time, time) to authenticated;
revoke execute on function public.get_dashboard() from public, anon;
grant execute on function public.get_dashboard() to authenticated;
