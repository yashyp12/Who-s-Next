-- WHO'S next: shared, passwordless team workspace.
-- Apply in a fresh Supabase project using the SQL editor or Supabase CLI.
-- All data writes go through security-definer RPCs; browser clients receive no direct table grants.

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.workspaces (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 2 and 80),
  timezone text not null default 'Asia/Kolkata',
  join_code_hash text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.members (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  name text not null check (length(trim(name)) between 2 and 80),
  active boolean not null default true,
  sort_order integer not null,
  created_at timestamptz not null default now(),
  unique (workspace_id, sort_order),
  unique (workspace_id, name)
);

-- Anonymous Supabase user IDs are hidden browser sessions, not employee credentials.
-- A browser session selects a roster profile once. The team code is a shared workspace gate.
create table if not exists public.member_sessions (
  auth_user_id uuid primary key references auth.users(id) on delete cascade,
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  member_id uuid not null references public.members(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.shifts (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  member_id uuid not null references public.members(id) on delete cascade,
  work_date date not null,
  shift_key text not null default 'custom' check (shift_key in ('morning','mid','evening','night','custom')),
  start_time time not null,
  end_time time not null,
  created_by uuid not null references public.members(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (start_time <> end_time),
  unique (workspace_id, member_id, work_date)
);

create table if not exists public.breaks (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  member_id uuid not null references public.members(id) on delete cascade,
  work_date date not null,
  start_time time not null,
  end_time time not null,
  note text not null default 'Scheduled break' check (length(note) <= 100),
  created_by uuid not null references public.members(id),
  created_at timestamptz not null default now(),
  check (start_time <> end_time)
);

create table if not exists public.availability_requests (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  member_id uuid not null references public.members(id) on delete cascade,
  request_type text not null check (request_type in ('meeting','kt','technical','rdp','extended_break','late_login','early_logout','leave','other')),
  reason text not null check (length(trim(reason)) between 2 and 100),
  details text check (length(details) <= 500),
  start_at timestamptz not null,
  end_at timestamptz not null,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  reviewed_by uuid references public.members(id),
  reviewed_at timestamptz,
  manager_confirmation text check (length(manager_confirmation) <= 250),
  created_at timestamptz not null default now(),
  check (end_at > start_at)
);

create table if not exists public.allocation_state (
  workspace_id uuid primary key references public.workspaces(id) on delete cascade,
  current_assignee_id uuid references public.members(id),
  last_allocated_member_id uuid references public.members(id),
  updated_at timestamptz not null default now()
);

create table if not exists public.allocations (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  recipient_member_id uuid not null references public.members(id),
  assigned_by_member_id uuid not null references public.members(id),
  reference text check (length(reference) <= 100),
  assigned_at timestamptz not null default now()
);

create table if not exists public.handovers (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  from_member_id uuid references public.members(id),
  to_member_id uuid not null references public.members(id),
  handed_over_at timestamptz not null default now()
);

create table if not exists public.shift_swap_requests (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  requester_member_id uuid not null references public.members(id),
  partner_member_id uuid not null references public.members(id),
  work_date date not null,
  status text not null default 'pending' check (status in ('pending','accepted','rejected','cancelled')),
  responded_at timestamptz,
  created_at timestamptz not null default now(),
  check (requester_member_id <> partner_member_id)
);

create table if not exists public.attendance_events (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  member_id uuid not null references public.members(id),
  event_type text not null check (event_type in ('check_in','check_out')),
  occurred_at timestamptz not null default now(),
  created_by uuid not null references public.members(id)
);

create table if not exists public.audit_events (
  id bigint generated always as identity primary key,
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  actor_member_id uuid references public.members(id),
  event_type text not null,
  summary text not null,
  entity_type text,
  entity_id uuid,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists idx_shifts_workspace_date on public.shifts(workspace_id, work_date);
create index if not exists idx_breaks_member_date on public.breaks(workspace_id, member_id, work_date);
create index if not exists idx_requests_workspace_status on public.availability_requests(workspace_id, status, created_at desc);
create index if not exists idx_requests_active_window on public.availability_requests(workspace_id, start_at, end_at) where status = 'approved';
create index if not exists idx_allocations_workspace_time on public.allocations(workspace_id, assigned_at desc);
create index if not exists idx_audit_workspace_time on public.audit_events(workspace_id, created_at desc);
create index if not exists idx_attendance_workspace_time on public.attendance_events(workspace_id, occurred_at desc);
create unique index if not exists uq_pending_shift_swap_pair on public.shift_swap_requests(workspace_id, work_date, least(requester_member_id, partner_member_id), greatest(requester_member_id, partner_member_id)) where status = 'pending';

-- Tables are intentionally not exposed to browser roles. The UI uses only the RPC surface below.
alter table public.workspaces enable row level security;
alter table public.members enable row level security;
alter table public.member_sessions enable row level security;
alter table public.shifts enable row level security;
alter table public.breaks enable row level security;
alter table public.availability_requests enable row level security;
alter table public.allocation_state enable row level security;
alter table public.allocations enable row level security;
alter table public.handovers enable row level security;
alter table public.shift_swap_requests enable row level security;
alter table public.attendance_events enable row level security;
alter table public.audit_events enable row level security;

revoke all on public.workspaces, public.members, public.member_sessions, public.shifts,
  public.breaks, public.availability_requests, public.allocation_state, public.allocations,
  public.handovers, public.shift_swap_requests, public.attendance_events, public.audit_events
  from anon, authenticated;

create or replace function public.get_joinable_workspace(p_join_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_workspace public.workspaces%rowtype;
  v_members jsonb;

begin
  if auth.uid() is null then raise exception 'A workspace session is required.'; end if;
  if p_join_code is null or length(trim(p_join_code)) < 20 then raise exception 'Enter a valid team access code.'; end if;
  select * into v_workspace from public.workspaces
  where join_code_hash = encode(extensions.digest(trim(p_join_code), 'sha256'), 'hex')
  order by created_at limit 1;
  if v_workspace.id is null then raise exception 'The team access code is not valid.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name) order by sort_order), '[]'::jsonb)
  into v_members from public.members where workspace_id = v_workspace.id and active = true;
  return jsonb_build_object('workspace_id', v_workspace.id, 'name', v_workspace.name, 'members', v_members);
end;
$$;

create or replace function public.join_workspace(p_join_code text, p_member_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_workspace public.workspaces%rowtype;
  v_member public.members%rowtype;

begin
  if auth.uid() is null then raise exception 'A workspace session is required.'; end if;
  select * into v_workspace from public.workspaces
  where join_code_hash = encode(extensions.digest(trim(coalesce(p_join_code, '')), 'sha256'), 'hex')
  order by created_at limit 1;
  if v_workspace.id is null then raise exception 'The team access code is not valid.'; end if;
  select * into v_member from public.members
  where id = p_member_id and workspace_id = v_workspace.id and active = true;
  if v_member.id is null then raise exception 'Choose an active team member.'; end if;
  insert into public.member_sessions(auth_user_id, workspace_id, member_id)
  values (auth.uid(), v_workspace.id, v_member.id)
  on conflict (auth_user_id) do update
    set workspace_id = excluded.workspace_id, member_id = excluded.member_id, updated_at = now();
  return jsonb_build_object('workspace_id', v_workspace.id, 'member_id', v_member.id, 'member_name', v_member.name);
end;
$$;

create or replace function public.get_my_member()
returns jsonb
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select jsonb_build_object('member_id', m.id, 'name', m.name, 'workspace_id', w.id, 'workspace_name', w.name)
  from public.member_sessions s
  join public.members m on m.id = s.member_id
  join public.workspaces w on w.id = s.workspace_id
  where s.auth_user_id = auth.uid() and m.active = true
  limit 1;
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
    'allocations', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'memberId', a.recipient_member_id, 'assignedBy', a.assigned_by_member_id, 'assignedAt', a.assigned_at, 'reference', a.reference) order by a.assigned_at desc) from (select * from public.allocations where workspace_id = v_workspace_id order by assigned_at desc limit 500) a), '[]'::jsonb),
    'attendance', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'memberId', e.member_id, 'eventType', e.event_type, 'occurredAt', e.occurred_at) order by e.occurred_at desc) from (select * from public.attendance_events where workspace_id = v_workspace_id order by occurred_at desc limit 200) e), '[]'::jsonb),
    'handovers', coalesce((select jsonb_agg(jsonb_build_object('id', h.id, 'fromMemberId', h.from_member_id, 'toMemberId', h.to_member_id, 'createdAt', h.handed_over_at) order by h.handed_over_at desc) from (select * from public.handovers where workspace_id = v_workspace_id order by handed_over_at desc limit 100) h), '[]'::jsonb),
    'shiftSwaps', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'requesterMemberId', x.requester_member_id, 'partnerMemberId', x.partner_member_id, 'workDate', x.work_date, 'status', x.status, 'createdAt', x.created_at, 'respondedAt', x.responded_at) order by x.created_at desc) from (select * from public.shift_swap_requests where workspace_id = v_workspace_id order by created_at desc limit 200) x), '[]'::jsonb),
    'activities', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'text', a.summary, 'icon', case when a.event_type = 'allocation' then '⇄' when a.event_type = 'approval' then '✓' when a.event_type = 'handover' then '↔' else '•' end, 'createdAt', a.created_at) order by a.created_at desc) from (select * from public.audit_events where workspace_id = v_workspace_id order by created_at desc limit 100) a), '[]'::jsonb)
  ) into v_payload;
  return v_payload;
end;
$$;

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
  return jsonb_build_object('shift_id', v_shift_id);
end;
$$;

create or replace function public.add_break(p_work_date date, p_start time, p_end time, p_note text default 'Scheduled break')
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
  insert into public.breaks(workspace_id, member_id, work_date, start_time, end_time, note, created_by)
  values (v_workspace_id, v_member_id, p_work_date, p_start, p_end, coalesce(nullif(trim(p_note), ''), 'Scheduled break'), v_member_id)
  returning id into v_break_id;
  insert into public.audit_events(workspace_id, actor_member_id, event_type, summary, entity_type, entity_id)
  values (v_workspace_id, v_member_id, 'break_added', 'Planned a break for ' || p_work_date::text, 'break', v_break_id);
  return jsonb_build_object('break_id', v_break_id);
end;
$$;

create or replace function public.submit_availability_request(p_type text, p_reason text, p_details text, p_start_at timestamptz, p_end_at timestamptz)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_workspace_id uuid; v_member_id uuid; v_request_id uuid;

begin
  select workspace_id, member_id into v_workspace_id, v_member_id from public.member_sessions where auth_user_id = auth.uid();
  if v_member_id is null then raise exception 'Join the team workspace first.'; end if;
  if p_type not in ('meeting','kt','technical','rdp','extended_break','late_login','early_logout','leave','other') then raise exception 'Invalid request type.'; end if;
  if length(trim(coalesce(p_reason, ''))) < 2 or length(trim(p_reason)) > 100 then raise exception 'Enter a reason between 2 and 100 characters.'; end if;
  if p_end_at <= p_start_at then raise exception 'End time must be after start time.'; end if;
  if p_end_at - p_start_at > interval '31 days' then raise exception 'A single request cannot exceed 31 days.'; end if;
  insert into public.availability_requests(workspace_id, member_id, request_type, reason, details, start_at, end_at)
  values (v_workspace_id, v_member_id, p_type, trim(p_reason), nullif(trim(coalesce(p_details, '')), ''), p_start_at, p_end_at)
  returning id into v_request_id;
  insert into public.audit_events(workspace_id, actor_member_id, event_type, summary, entity_type, entity_id)
  values (v_workspace_id, v_member_id, 'request_submitted', 'Submitted a ' || replace(p_type, '_', ' ') || ' request', 'availability_request', v_request_id);
  return jsonb_build_object('request_id', v_request_id, 'status', 'pending');
end;
$$;

create or replace function public.review_availability_request(p_request_id uuid, p_decision text, p_confirmation text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_workspace_id uuid; v_member_id uuid; v_current_assignee uuid; v_request public.availability_requests%rowtype;

begin
  select workspace_id, member_id into v_workspace_id, v_member_id from public.member_sessions where auth_user_id = auth.uid();
  if v_member_id is null then raise exception 'Join the team workspace first.'; end if;
  select current_assignee_id into v_current_assignee from public.allocation_state where workspace_id = v_workspace_id for update;
  if v_current_assignee is distinct from v_member_id then raise exception 'Only the current email assignee can review requests.'; end if;
  if p_decision not in ('approved','rejected') then raise exception 'Decision must be approved or rejected.'; end if;
  select * into v_request from public.availability_requests where id = p_request_id and workspace_id = v_workspace_id for update;
  if v_request.id is null then raise exception 'Request not found.'; end if;
  if v_request.status <> 'pending' then raise exception 'This request has already been reviewed.'; end if;
  if v_request.member_id = v_member_id then raise exception 'You cannot approve your own request. Hand over allocation responsibility first.'; end if;
  update public.availability_requests set status = p_decision, reviewed_by = v_member_id, reviewed_at = now(), manager_confirmation = nullif(trim(coalesce(p_confirmation, '')), '') where id = p_request_id;
  insert into public.audit_events(workspace_id, actor_member_id, event_type, summary, entity_type, entity_id, metadata)
  values (v_workspace_id, v_member_id, 'approval', 'Marked a request as ' || p_decision, 'availability_request', p_request_id, jsonb_build_object('member_id', v_request.member_id, 'confirmation', p_confirmation));
  return jsonb_build_object('request_id', p_request_id, 'status', p_decision);
end;
$$;

create or replace function public.take_over_allocation()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_workspace_id uuid; v_member_id uuid; v_previous uuid;

begin
  select workspace_id, member_id into v_workspace_id, v_member_id from public.member_sessions where auth_user_id = auth.uid();
  if v_member_id is null then raise exception 'Join the team workspace first.'; end if;
  select current_assignee_id into v_previous from public.allocation_state where workspace_id = v_workspace_id for update;
  if v_previous is not distinct from v_member_id then return jsonb_build_object('current_assignee_id', v_member_id, 'changed', false); end if;
  update public.allocation_state set current_assignee_id = v_member_id, updated_at = now() where workspace_id = v_workspace_id;
  insert into public.handovers(workspace_id, from_member_id, to_member_id) values (v_workspace_id, v_previous, v_member_id);
  insert into public.audit_events(workspace_id, actor_member_id, event_type, summary, entity_type, metadata)
  values (v_workspace_id, v_member_id, 'handover', 'Took over email allocation responsibility', 'allocation_state', jsonb_build_object('from_member_id', v_previous, 'to_member_id', v_member_id));
  return jsonb_build_object('current_assignee_id', v_member_id, 'changed', true);
end;
$$;

create or replace function public.record_next_allocation(p_reference text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_workspace_id uuid; v_actor_id uuid; v_assignee_id uuid; v_last_id uuid;
  v_last_order integer; v_target_id uuid; v_target_name text; v_allocation_id uuid;
  v_today date; v_time time; v_now timestamptz;

begin
  select workspace_id, member_id into v_workspace_id, v_actor_id from public.member_sessions where auth_user_id = auth.uid();
  if v_actor_id is null then raise exception 'Join the team workspace first.'; end if;
  select current_assignee_id, last_allocated_member_id into v_assignee_id, v_last_id
    from public.allocation_state where workspace_id = v_workspace_id for update;
  if v_assignee_id is distinct from v_actor_id then raise exception 'Only the current email assignee can record allocations.'; end if;
  select (now() at time zone w.timezone)::date, (now() at time zone w.timezone)::time, now()
    into v_today, v_time, v_now from public.workspaces w where w.id = v_workspace_id;
  select sort_order into v_last_order from public.members where id = v_last_id and workspace_id = v_workspace_id;

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
  if v_target_id = v_actor_id then
    -- Self-allocation is allowed only when the current assignee is also next in the rotation.
    null;
  end if;
  insert into public.allocations(workspace_id, recipient_member_id, assigned_by_member_id, reference)
  values (v_workspace_id, v_target_id, v_actor_id, nullif(trim(coalesce(p_reference, '')), ''))
  returning id into v_allocation_id;
  update public.allocation_state set last_allocated_member_id = v_target_id, updated_at = now() where workspace_id = v_workspace_id;
  insert into public.audit_events(workspace_id, actor_member_id, event_type, summary, entity_type, entity_id, metadata)
  values (v_workspace_id, v_actor_id, 'allocation', 'Recorded an allocation for ' || v_target_name, 'allocation', v_allocation_id, jsonb_build_object('recipient_member_id', v_target_id, 'reference', p_reference));
  return jsonb_build_object('allocation_id', v_allocation_id, 'member_id', v_target_id, 'member_name', v_target_name, 'assigned_at', v_now);
end;
$$;

create or replace function public.create_shift_swap_request(p_partner_member_id uuid, p_work_date date)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_workspace_id uuid; v_member_id uuid; v_request_id uuid;

begin
  select workspace_id, member_id into v_workspace_id, v_member_id from public.member_sessions where auth_user_id = auth.uid();
  if v_member_id is null then raise exception 'Join the team workspace first.'; end if;
  if p_partner_member_id = v_member_id then raise exception 'Choose another employee for a shift swap.'; end if;
  if not exists (select 1 from public.members where id = p_partner_member_id and workspace_id = v_workspace_id and active) then raise exception 'The selected employee is not active in this workspace.'; end if;
  if not exists (select 1 from public.shifts where workspace_id = v_workspace_id and member_id = v_member_id and work_date = p_work_date) then raise exception 'You do not have a shift scheduled on this date.'; end if;
  if not exists (select 1 from public.shifts where workspace_id = v_workspace_id and member_id = p_partner_member_id and work_date = p_work_date) then raise exception 'The other employee has no shift scheduled on this date.'; end if;
  insert into public.shift_swap_requests(workspace_id, requester_member_id, partner_member_id, work_date)
  values (v_workspace_id, v_member_id, p_partner_member_id, p_work_date) returning id into v_request_id;
  insert into public.audit_events(workspace_id, actor_member_id, event_type, summary, entity_type, entity_id)
  values (v_workspace_id, v_member_id, 'shift_swap', 'Requested a one-day shift swap for ' || p_work_date::text, 'shift_swap_request', v_request_id);
  return jsonb_build_object('request_id', v_request_id, 'status', 'pending');
end;
$$;

create or replace function public.respond_shift_swap_request(p_request_id uuid, p_accept boolean)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_workspace_id uuid; v_member_id uuid; v_request public.shift_swap_requests%rowtype;
  v_left public.shifts%rowtype; v_right public.shifts%rowtype; v_timezone text;
  v_new_start timestamptz; v_new_end timestamptz;

begin
  select workspace_id, member_id into v_workspace_id, v_member_id from public.member_sessions where auth_user_id = auth.uid();
  if v_member_id is null then raise exception 'Join the team workspace first.'; end if;
  select * into v_request from public.shift_swap_requests where id = p_request_id and workspace_id = v_workspace_id for update;
  if v_request.id is null then raise exception 'Shift swap request not found.'; end if;
  if v_request.partner_member_id <> v_member_id then raise exception 'Only the invited employee can respond to this shift swap.'; end if;
  if v_request.status <> 'pending' then raise exception 'This shift swap has already been resolved.'; end if;
  if p_accept then
    select * into v_left from public.shifts where workspace_id = v_workspace_id and member_id = v_request.requester_member_id and work_date = v_request.work_date for update;
    select * into v_right from public.shifts where workspace_id = v_workspace_id and member_id = v_request.partner_member_id and work_date = v_request.work_date for update;
    if v_left.id is null or v_right.id is null then raise exception 'One of the shifts no longer exists. Refresh the schedule.'; end if;
    select timezone into v_timezone from public.workspaces where id = v_workspace_id;
    v_new_start := (v_request.work_date + v_right.start_time) at time zone v_timezone;
    v_new_end := ((v_request.work_date + v_right.end_time) + case when v_right.end_time <= v_right.start_time then interval '1 day' else interval '0' end) at time zone v_timezone;
    if exists (select 1 from public.shifts s where s.workspace_id = v_workspace_id and s.member_id = v_request.requester_member_id and s.id <> v_left.id and s.work_date between v_request.work_date - 1 and v_request.work_date + 1
        and v_new_start < (((s.work_date + s.end_time) + case when s.end_time <= s.start_time then interval '1 day' else interval '0' end) at time zone v_timezone)
        and v_new_end > ((s.work_date + s.start_time) at time zone v_timezone)) then
      raise exception 'The accepted shift would overlap the requester''s adjacent shift.';
    end if;
    v_new_start := (v_request.work_date + v_left.start_time) at time zone v_timezone;
    v_new_end := ((v_request.work_date + v_left.end_time) + case when v_left.end_time <= v_left.start_time then interval '1 day' else interval '0' end) at time zone v_timezone;
    if exists (select 1 from public.shifts s where s.workspace_id = v_workspace_id and s.member_id = v_request.partner_member_id and s.id <> v_right.id and s.work_date between v_request.work_date - 1 and v_request.work_date + 1
        and v_new_start < (((s.work_date + s.end_time) + case when s.end_time <= s.start_time then interval '1 day' else interval '0' end) at time zone v_timezone)
        and v_new_end > ((s.work_date + s.start_time) at time zone v_timezone)) then
      raise exception 'The accepted shift would overlap the invited colleague''s adjacent shift.';
    end if;
    update public.shifts set shift_key = v_right.shift_key, start_time = v_right.start_time, end_time = v_right.end_time, updated_at = now() where id = v_left.id;
    update public.shifts set shift_key = v_left.shift_key, start_time = v_left.start_time, end_time = v_left.end_time, updated_at = now() where id = v_right.id;
  end if;
  update public.shift_swap_requests set status = case when p_accept then 'accepted' else 'rejected' end, responded_at = now() where id = p_request_id;
  insert into public.audit_events(workspace_id, actor_member_id, event_type, summary, entity_type, entity_id)
  values (v_workspace_id, v_member_id, 'shift_swap', case when p_accept then 'Accepted a one-day shift swap' else 'Rejected a one-day shift swap' end, 'shift_swap_request', p_request_id);
  return jsonb_build_object('request_id', p_request_id, 'status', case when p_accept then 'accepted' else 'rejected' end);
end;
$$;

-- Attendance is deliberately a lightweight event log. It is not biometric or HR-grade attendance.
create or replace function public.record_attendance(p_event_type text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_workspace_id uuid; v_member_id uuid; v_event_id uuid; v_last_event_type text;

begin
  select workspace_id, member_id into v_workspace_id, v_member_id from public.member_sessions where auth_user_id = auth.uid();
  if v_member_id is null then raise exception 'Join the team workspace first.'; end if;
  if p_event_type not in ('check_in','check_out') then raise exception 'Invalid attendance event.'; end if;
  perform 1 from public.members where id = v_member_id and workspace_id = v_workspace_id for update;
  select event_type into v_last_event_type from public.attendance_events
    where workspace_id = v_workspace_id and member_id = v_member_id order by occurred_at desc limit 1;
  if p_event_type = 'check_in' and v_last_event_type = 'check_in' then raise exception 'You are already checked in. Record check-out first.'; end if;
  if p_event_type = 'check_out' and v_last_event_type is distinct from 'check_in' then raise exception 'Record check-in before checking out.'; end if;
  insert into public.attendance_events(workspace_id, member_id, event_type, created_by)
  values (v_workspace_id, v_member_id, p_event_type, v_member_id) returning id into v_event_id;
  insert into public.audit_events(workspace_id, actor_member_id, event_type, summary, entity_type, entity_id)
  values (v_workspace_id, v_member_id, 'attendance', case when p_event_type = 'check_in' then 'Recorded shift check-in' else 'Recorded shift check-out' end, 'attendance_event', v_event_id);
  return jsonb_build_object('event_id', v_event_id, 'event_type', p_event_type);
end;
$$;

-- No browser role receives direct table access. Only authenticated anonymous sessions can use RPCs.
grant usage on schema public to authenticated;
revoke execute on function public.get_joinable_workspace(text) from public, anon;
revoke execute on function public.join_workspace(text, uuid) from public, anon;
revoke execute on function public.get_my_member() from public, anon;
revoke execute on function public.get_dashboard() from public, anon;
revoke execute on function public.upsert_shift(date, text, time, time) from public, anon;
revoke execute on function public.add_break(date, time, time, text) from public, anon;
revoke execute on function public.submit_availability_request(text, text, text, timestamptz, timestamptz) from public, anon;
revoke execute on function public.review_availability_request(uuid, text, text) from public, anon;
revoke execute on function public.take_over_allocation() from public, anon;
revoke execute on function public.record_next_allocation(text) from public, anon;
revoke execute on function public.create_shift_swap_request(uuid, date) from public, anon;
revoke execute on function public.respond_shift_swap_request(uuid, boolean) from public, anon;
revoke execute on function public.record_attendance(text) from public, anon;
grant execute on function public.get_joinable_workspace(text) to authenticated;
grant execute on function public.join_workspace(text, uuid) to authenticated;
grant execute on function public.get_my_member() to authenticated;
grant execute on function public.get_dashboard() to authenticated;
grant execute on function public.upsert_shift(date, text, time, time) to authenticated;
grant execute on function public.add_break(date, time, time, text) to authenticated;
grant execute on function public.submit_availability_request(text, text, text, timestamptz, timestamptz) to authenticated;
grant execute on function public.review_availability_request(uuid, text, text) to authenticated;
grant execute on function public.take_over_allocation() to authenticated;
grant execute on function public.record_next_allocation(text) to authenticated;
grant execute on function public.create_shift_swap_request(uuid, date) to authenticated;
grant execute on function public.respond_shift_swap_request(uuid, boolean) to authenticated;
grant execute on function public.record_attendance(text) to authenticated;
