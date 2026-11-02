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
    'breaks', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'memberId', b.member_id, 'date', b.work_date, 'start', to_char(b.start_time, 'HH24:MI'), 'end', to_char(b.end_time, 'HH24:MI'), 'note', b.note) order by b.work_date, b.start_time) from public.breaks b where b.workspace_id = v_workspace_id and b.work_date between (now() at time zone v_workspace.timezone)::date - 1 and (now() at time zone v_workspace.timezone)::date + 90), '[]'::jsonb),
    'requests', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'memberId', r.member_id, 'type', r.request_type, 'reason', r.reason, 'details', r.details, 'startAt', r.start_at, 'endAt', r.end_at, 'status', r.status, 'createdAt', r.created_at, 'reviewedBy', r.reviewed_by, 'reviewedAt', r.reviewed_at, 'confirmation', r.manager_confirmation) order by r.created_at desc) from (select * from public.availability_requests where workspace_id = v_workspace_id order by created_at desc limit 500) r), '[]'::jsonb),
    'allocations', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'memberId', a.recipient_member_id, 'assignedBy', a.assigned_by_member_id, 'assignedAt', a.assigned_at, 'reference', a.reference, 'emailSubject', a.email_subject) order by a.assigned_at desc) from (select * from public.allocations where workspace_id = v_workspace_id order by assigned_at desc limit 500) a), '[]'::jsonb),
    'attendance', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'memberId', e.member_id, 'eventType', e.event_type, 'occurredAt', e.occurred_at) order by e.occurred_at desc) from (select * from public.attendance_events where workspace_id = v_workspace_id order by occurred_at desc limit 200) e), '[]'::jsonb),
    'handovers', coalesce((select jsonb_agg(jsonb_build_object('id', h.id, 'fromMemberId', h.from_member_id, 'toMemberId', h.to_member_id, 'createdAt', h.handed_over_at) order by h.handed_over_at desc) from (select * from public.handovers where workspace_id = v_workspace_id order by handed_over_at desc limit 100) h), '[]'::jsonb),
    'shiftSwaps', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'requesterMemberId', x.requester_member_id, 'partnerMemberId', x.partner_member_id, 'workDate', x.work_date, 'status', x.status, 'createdAt', x.created_at, 'respondedAt', x.responded_at) order by x.created_at desc) from (select * from public.shift_swap_requests where workspace_id = v_workspace_id order by created_at desc limit 200) x), '[]'::jsonb),
    'activities', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'text', a.summary, 'icon', case when a.event_type = 'allocation' then '⇄' when a.event_type = 'approval' then '✓' when a.event_type = 'handover' then '↔' else '•' end, 'createdAt', a.created_at) order by a.created_at desc) from (select * from public.audit_events where workspace_id = v_workspace_id order by created_at desc limit 100) a), '[]'::jsonb)
  ) into v_payload;
  return v_payload;
end;
$$;


