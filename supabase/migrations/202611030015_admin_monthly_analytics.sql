-- Secure, full-period analytics for workspace admins. Aggregates directly from source tables
-- so monthly reports are not limited by the dashboard's recent-record payload cap.

create or replace function public.admin_get_monthly_analytics(
  p_start_date date,
  p_end_date date
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_workspace_id uuid;
  v_member_id uuid;
  v_result jsonb;
begin
  select workspace_id, member_id
    into v_workspace_id, v_member_id
  from public.member_sessions
  where auth_user_id = auth.uid();

  if v_member_id is null or not public.is_workspace_admin() then
    raise exception 'Workspace admin access required.';
  end if;

  if p_start_date is null or p_end_date is null
     or p_end_date <= p_start_date
     or p_end_date - p_start_date > 93 then
    raise exception 'Choose a reporting period between 1 and 93 days.';
  end if;

  with filtered as (
    select a.id, a.recipient_member_id, a.assigned_by_member_id,
           a.assigned_at, a.reference, a.email_subject, a.allocation_kind
    from public.allocations a
    where a.workspace_id = v_workspace_id
      and a.assigned_at >= (p_start_date::timestamp at time zone (select timezone from public.workspaces where id = v_workspace_id))
      and a.assigned_at < (p_end_date::timestamp at time zone (select timezone from public.workspaces where id = v_workspace_id))
  ),
  daily as (
    select (f.assigned_at at time zone w.timezone)::date as work_day, count(*)::integer as amount
    from filtered f cross join public.workspaces w
    where w.id = v_workspace_id
    group by 1
  ),
  by_member as (
    select m.id, m.name,
      count(f.id)::integer as amount,
      count(f.id) filter (where f.allocation_kind = 'new_email')::integer as new_emails,
      count(f.id) filter (where f.allocation_kind = 'existing_ticket')::integer as existing_tickets
    from public.members m
    left join filtered f on f.recipient_member_id = m.id
    where m.workspace_id = v_workspace_id
    group by m.id, m.name, m.sort_order
    order by amount desc, m.sort_order, m.name
  ),
  by_kind as (
    select case when allocation_kind = 'existing_ticket' then 'Existing tickets' else 'New emails' end as label,
           count(*)::integer as amount
    from filtered
    group by 1
    order by 1
  ),
  records as (
    select f.*, recipient.name as recipient_name, assigner.name as assigner_name,
      (f.assigned_at at time zone w.timezone)::date as work_day
    from filtered f
    join public.members recipient on recipient.id = f.recipient_member_id
    left join public.members assigner on assigner.id = f.assigned_by_member_id
    cross join public.workspaces w
    where w.id = v_workspace_id
    order by f.assigned_at desc
    limit 1500
  )
  select jsonb_build_object(
    'total', (select count(*) from filtered),
    'newEmails', (select count(*) from filtered where allocation_kind = 'new_email'),
    'existingTickets', (select count(*) from filtered where allocation_kind = 'existing_ticket'),
    'activeAgents', (select count(*) from by_member where amount > 0),
    'days', coalesce((
      select jsonb_agg(jsonb_build_object('day', to_char(d.day, 'DD Mon'), 'date', d.day, 'count', coalesce(daily.amount, 0)) order by d.day)
      from generate_series(p_start_date, p_end_date - 1, interval '1 day') as d(day)
      left join daily on daily.work_day = d.day::date
    ), '[]'::jsonb),
    'members', coalesce((
      select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'count', amount, 'newEmails', new_emails, 'existingTickets', existing_tickets) order by amount desc, name)
      from by_member
    ), '[]'::jsonb),
    'kinds', coalesce((
      select jsonb_agg(jsonb_build_object('label', label, 'count', amount) order by label)
      from by_kind
    ), '[]'::jsonb),
    'records', coalesce((
      select jsonb_agg(jsonb_build_object(
        'day', to_char(work_day, 'DD Mon YYYY'),
        'recipient', recipient_name,
        'assigner', coalesce(assigner_name, 'Unknown'),
        'reference', reference,
        'subject', email_subject,
        'kind', case when allocation_kind = 'existing_ticket' then 'Existing ticket' else 'New email' end,
        'assignedAt', assigned_at
      ) order by assigned_at desc)
      from records
    ), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;

revoke execute on function public.admin_get_monthly_analytics(date, date) from public, anon;
grant execute on function public.admin_get_monthly_analytics(date, date) to authenticated;
