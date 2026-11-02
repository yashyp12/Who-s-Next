-- Let members safely edit their own pending requests and withdraw their own
-- pending or currently active approved requests. Keep request history intact.
alter table public.availability_requests
  drop constraint if exists availability_requests_status_check;

alter table public.availability_requests
  add constraint availability_requests_status_check
  check (status in ('pending','approved','rejected','cancelled'));

alter table public.availability_requests
  add column if not exists cancelled_at timestamptz,
  add column if not exists cancelled_by uuid references public.members(id);

create or replace function public.update_my_availability_request(
  p_request_id uuid,
  p_type text,
  p_reason text,
  p_details text,
  p_start_at timestamptz,
  p_end_at timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_workspace_id uuid;
  v_member_id uuid;
  v_request public.availability_requests%rowtype;
begin
  select workspace_id, member_id into v_workspace_id, v_member_id
  from public.member_sessions where auth_user_id = auth.uid();
  if v_member_id is null then raise exception 'Join the team workspace first.'; end if;

  select * into v_request
  from public.availability_requests
  where id = p_request_id and workspace_id = v_workspace_id
  for update;
  if v_request.id is null then raise exception 'Request not found.'; end if;
  if v_request.member_id is distinct from v_member_id then
    raise exception 'You can edit only your own availability requests.';
  end if;
  if v_request.status <> 'pending' then
    raise exception 'Only pending requests can be edited. Withdraw an active approved request instead.';
  end if;
  if p_type not in ('meeting','kt','technical','rdp','extended_break','late_login','early_logout','leave','other') then
    raise exception 'Invalid request type.';
  end if;
  if length(trim(coalesce(p_reason,''))) < 2 or length(trim(p_reason)) > 100 then
    raise exception 'Enter a reason between 2 and 100 characters.';
  end if;
  if p_end_at is null or p_start_at is null or p_end_at <= p_start_at then
    raise exception 'End time must be after start time.';
  end if;
  if p_end_at - p_start_at > interval '31 days' then
    raise exception 'A single request cannot exceed 31 days.';
  end if;

  update public.availability_requests
  set request_type = p_type,
      reason = trim(p_reason),
      details = nullif(trim(coalesce(p_details,'')), ''),
      start_at = p_start_at,
      end_at = p_end_at
  where id = p_request_id;

  insert into public.audit_events(workspace_id, actor_member_id, event_type, summary, entity_type, entity_id, metadata)
  values (v_workspace_id, v_member_id, 'request_updated', 'Updated an availability request', 'availability_request', p_request_id,
    jsonb_build_object('before', jsonb_build_object('type',v_request.request_type,'reason',v_request.reason,'start_at',v_request.start_at,'end_at',v_request.end_at),
                       'after', jsonb_build_object('type',p_type,'reason',trim(p_reason),'start_at',p_start_at,'end_at',p_end_at)));

  return jsonb_build_object('request_id',p_request_id,'status','pending');
end;
$$;

create or replace function public.withdraw_my_availability_request(p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_workspace_id uuid;
  v_member_id uuid;
  v_request public.availability_requests%rowtype;
begin
  select workspace_id, member_id into v_workspace_id, v_member_id
  from public.member_sessions where auth_user_id = auth.uid();
  if v_member_id is null then raise exception 'Join the team workspace first.'; end if;

  select * into v_request
  from public.availability_requests
  where id = p_request_id and workspace_id = v_workspace_id
  for update;
  if v_request.id is null then raise exception 'Request not found.'; end if;
  if v_request.member_id is distinct from v_member_id then
    raise exception 'You can withdraw only your own availability requests.';
  end if;
  if v_request.status not in ('pending','approved') then
    raise exception 'This request has already been resolved and cannot be withdrawn.';
  end if;
  if v_request.status = 'approved' and v_request.end_at <= now() then
    raise exception 'This approved request has already ended; its history is retained.';
  end if;

  update public.availability_requests
  set status = 'cancelled', cancelled_at = now(), cancelled_by = v_member_id
  where id = p_request_id;

  insert into public.audit_events(workspace_id, actor_member_id, event_type, summary, entity_type, entity_id, metadata)
  values (v_workspace_id, v_member_id, 'request_withdrawn', 'Withdrew an availability request', 'availability_request', p_request_id,
    jsonb_build_object('request_type',v_request.request_type,'previous_status',v_request.status));

  -- Re-evaluate ownership immediately; the cancelled approved window no longer blocks eligibility.
  perform public.ensure_shift_assignee();

  return jsonb_build_object('request_id',p_request_id,'status','cancelled');
end;
$$;

create or replace function public.take_over_allocation()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_workspace_id uuid;
  v_member_id uuid;
  v_previous uuid;
  v_timezone text;
  v_now timestamptz := now();
  v_today date;
  v_time time;
  v_blocking_type text;
begin
  select workspace_id, member_id into v_workspace_id, v_member_id
  from public.member_sessions where auth_user_id = auth.uid();
  if v_member_id is null then raise exception 'Join the team workspace first.'; end if;

  select timezone into v_timezone from public.workspaces where id = v_workspace_id;
  if v_timezone is null then raise exception 'Workspace timezone is not configured.'; end if;
  v_today := (v_now at time zone v_timezone)::date;
  v_time := (v_now at time zone v_timezone)::time;

  if not exists (
    select 1 from public.members m
    where m.id = v_member_id and m.workspace_id = v_workspace_id and m.active
  ) then raise exception 'Your team profile is inactive. Contact an SME or Super Admin.'; end if;

  if not exists (
    select 1 from public.member_presence p
    where p.workspace_id = v_workspace_id and p.member_id = v_member_id
      and p.presence_state = 'active' and p.last_seen_at > v_now - interval '90 seconds'
  ) then raise exception 'Your presence is not Active. Keep the workspace open and try again.'; end if;

  if not exists (
    select 1 from public.shifts s
    where s.workspace_id = v_workspace_id and s.member_id = v_member_id and (
      (s.work_date = v_today and ((s.start_time < s.end_time and v_time >= s.start_time and v_time < s.end_time) or (s.start_time > s.end_time and v_time >= s.start_time)))
      or (s.work_date = v_today - 1 and s.start_time > s.end_time and v_time < s.end_time)
    )
  ) then raise exception 'You are outside your scheduled shift. Update your shift in My profile before taking over.'; end if;

  if exists (
    select 1 from public.breaks b
    where b.workspace_id = v_workspace_id and b.member_id = v_member_id and (
      (b.work_date = v_today and ((b.start_time < b.end_time and v_time >= b.start_time and v_time < b.end_time) or (b.start_time > b.end_time and v_time >= b.start_time)))
      or (b.work_date = v_today - 1 and b.start_time > b.end_time and v_time < b.end_time)
    )
  ) then raise exception 'Your scheduled break is still active. Try again when it ends.'; end if;

  select r.request_type into v_blocking_type
  from public.availability_requests r
  where r.workspace_id = v_workspace_id and r.member_id = v_member_id
    and r.status = 'approved' and r.start_at <= v_now and r.end_at > v_now
  order by r.end_at desc limit 1;
  if v_blocking_type is not null then
    raise exception 'Your approved % request is still active. Withdraw it from My profile before taking over.', replace(v_blocking_type,'_',' ');
  end if;

  select current_assignee_id into v_previous
  from public.allocation_state where workspace_id = v_workspace_id for update;
  if not found then raise exception 'Allocation state is not initialized.'; end if;
  if v_previous is not distinct from v_member_id then
    return jsonb_build_object('current_assignee_id',v_member_id,'changed',false);
  end if;

  update public.allocation_state
  set current_assignee_id = v_member_id, updated_at = v_now
  where workspace_id = v_workspace_id;

  insert into public.handovers(workspace_id, from_member_id, to_member_id, handed_over_at)
  values (v_workspace_id, v_previous, v_member_id, v_now);

  insert into public.audit_events(workspace_id, actor_member_id, event_type, summary, entity_type, metadata, created_at)
  values (v_workspace_id, v_member_id, 'handover', 'Took over email allocation responsibility', 'allocation_state',
    jsonb_build_object('from_member_id',v_previous,'to_member_id',v_member_id), v_now);

  return jsonb_build_object('current_assignee_id',v_member_id,'changed',true);
end;
$$;

revoke execute on function public.update_my_availability_request(uuid,text,text,text,timestamptz,timestamptz) from public, anon;
grant execute on function public.update_my_availability_request(uuid,text,text,text,timestamptz,timestamptz) to authenticated;
revoke execute on function public.withdraw_my_availability_request(uuid) from public, anon;
grant execute on function public.withdraw_my_availability_request(uuid) to authenticated;
revoke execute on function public.take_over_allocation() from public, anon;
grant execute on function public.take_over_allocation() to authenticated;
