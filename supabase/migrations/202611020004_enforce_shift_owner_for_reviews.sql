-- Re-evaluate shift ownership immediately before a request approval decision.
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
  perform public.ensure_shift_assignee();
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


