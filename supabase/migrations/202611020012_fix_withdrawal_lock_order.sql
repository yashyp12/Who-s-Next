-- Keep request withdrawal lock ordering consistent with request review.
-- review_availability_request locks allocation_state before availability_requests.
-- Doing the same here prevents a withdrawal/review deadlock under concurrency.

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
  from public.member_sessions
  where auth_user_id = auth.uid();

  if v_member_id is null then
    raise exception 'Join the team workspace first.';
  end if;

  -- Global lock order: allocation_state first, then availability_requests.
  perform 1
  from public.allocation_state
  where workspace_id = v_workspace_id
  for update;

  if not found then
    raise exception 'Allocation state is not initialized.';
  end if;

  select * into v_request
  from public.availability_requests
  where id = p_request_id and workspace_id = v_workspace_id
  for update;

  if v_request.id is null then
    raise exception 'Request not found.';
  end if;
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
  set status = 'cancelled',
      cancelled_at = now(),
      cancelled_by = v_member_id
  where id = p_request_id;

  insert into public.audit_events(
    workspace_id, actor_member_id, event_type, summary,
    entity_type, entity_id, metadata
  )
  values (
    v_workspace_id, v_member_id, 'request_withdrawn',
    'Withdrew an availability request', 'availability_request',
    p_request_id,
    jsonb_build_object(
      'request_type', v_request.request_type,
      'previous_status', v_request.status
    )
  );

  perform public.ensure_shift_assignee();

  return jsonb_build_object(
    'request_id', p_request_id,
    'status', 'cancelled'
  );
end;
$$;

revoke execute on function public.withdraw_my_availability_request(uuid) from public, anon;
grant execute on function public.withdraw_my_availability_request(uuid) to authenticated;
