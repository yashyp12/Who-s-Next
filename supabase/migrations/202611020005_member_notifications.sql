-- WHO'S next: persistent, member-scoped notifications.
-- Apply after 202611020004_enforce_shift_owner_for_reviews.sql.
-- Notifications are created by trusted database triggers, never by browser-supplied recipient IDs.

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  recipient_member_id uuid not null references public.members(id) on delete cascade,
  actor_member_id uuid references public.members(id) on delete set null,
  notification_type text not null check (notification_type in ('allocation_received','request_reviewed','shift_swap_received','shift_swap_resolved')),
  title text not null check (length(title) between 1 and 120),
  body text not null check (length(body) between 1 and 300),
  entity_type text,
  entity_id uuid,
  created_at timestamptz not null default now(),
  read_at timestamptz
);

create index if not exists idx_notifications_recipient_created
  on public.notifications(workspace_id, recipient_member_id, created_at desc);
create index if not exists idx_notifications_unread
  on public.notifications(workspace_id, recipient_member_id, created_at desc)
  where read_at is null;

alter table public.notifications enable row level security;
revoke all on public.notifications from anon, authenticated;

create or replace function public.create_member_notification(
  p_workspace_id uuid,
  p_recipient_member_id uuid,
  p_actor_member_id uuid,
  p_type text,
  p_title text,
  p_body text,
  p_entity_type text,
  p_entity_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
begin
  if p_recipient_member_id is null or p_recipient_member_id = p_actor_member_id then
    return null;
  end if;
  if not exists (
    select 1 from public.members
    where id = p_recipient_member_id and workspace_id = p_workspace_id and active
  ) then
    return null;
  end if;
  insert into public.notifications (
    workspace_id, recipient_member_id, actor_member_id,
    notification_type, title, body, entity_type, entity_id
  ) values (
    p_workspace_id, p_recipient_member_id, p_actor_member_id,
    p_type, left(p_title, 120), left(p_body, 300), p_entity_type, p_entity_id
  ) returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.notify_allocation_recipient()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor_name text;
begin
  select name into v_actor_name from public.members
  where id = new.assigned_by_member_id and workspace_id = new.workspace_id;
  perform public.create_member_notification(
    new.workspace_id,
    new.recipient_member_id,
    new.assigned_by_member_id,
    'allocation_received',
    'A new email was assigned to you',
    coalesce(v_actor_name, 'A teammate') || ' assigned an email to you'
      || case when nullif(new.reference, '') is not null then ' · ' || new.reference else '' end
      || case when nullif(new.email_subject, '') is not null then ' · ' || new.email_subject else '' end,
    'allocation',
    new.id
  );
  return new;
end;
$$;

drop trigger if exists trg_notify_allocation_recipient on public.allocations;
create trigger trg_notify_allocation_recipient
after insert on public.allocations
for each row execute function public.notify_allocation_recipient();

create or replace function public.notify_request_review()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_actor_name text;
begin
  if old.status = 'pending' and new.status in ('approved','rejected') then
    select name into v_actor_name from public.members
    where id = new.reviewed_by and workspace_id = new.workspace_id;
    perform public.create_member_notification(
      new.workspace_id,
      new.member_id,
      new.reviewed_by,
      'request_reviewed',
      'Your availability request was ' || new.status,
      coalesce(v_actor_name, 'The current assignee') || ' ' || new.status || ' your ' || replace(new.request_type, '_', ' ') || ' request',
      'availability_request',
      new.id
    );
  end if;
  return new;
end;
$$;

drop trigger if exists trg_notify_request_review on public.availability_requests;
create trigger trg_notify_request_review
after update of status on public.availability_requests
for each row execute function public.notify_request_review();

create or replace function public.notify_shift_swap_event()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_requester_name text;
  v_partner_name text;
begin
  select name into v_requester_name from public.members
  where id = new.requester_member_id and workspace_id = new.workspace_id;
  select name into v_partner_name from public.members
  where id = new.partner_member_id and workspace_id = new.workspace_id;

  if tg_op = 'INSERT' then
    perform public.create_member_notification(
      new.workspace_id, new.partner_member_id, new.requester_member_id,
      'shift_swap_received', 'A colleague requested a shift swap',
      coalesce(v_requester_name, 'A teammate') || ' requested a shift swap for ' || new.work_date::text,
      'shift_swap_request', new.id
    );
  elsif old.status = 'pending' and new.status in ('accepted','rejected','cancelled') then
    perform public.create_member_notification(
      new.workspace_id, new.requester_member_id, new.partner_member_id,
      'shift_swap_resolved', 'Your shift swap was ' || new.status,
      coalesce(v_partner_name, 'Your colleague') || ' ' || new.status || ' your shift swap for ' || new.work_date::text,
      'shift_swap_request', new.id
    );
  end if;
  return new;
end;
$$;

drop trigger if exists trg_notify_shift_swap_insert on public.shift_swap_requests;
create trigger trg_notify_shift_swap_insert
after insert on public.shift_swap_requests
for each row execute function public.notify_shift_swap_event();

drop trigger if exists trg_notify_shift_swap_update on public.shift_swap_requests;
create trigger trg_notify_shift_swap_update
after update of status on public.shift_swap_requests
for each row execute function public.notify_shift_swap_event();

create or replace function public.get_my_notifications(p_limit integer default 30)
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
  select workspace_id, member_id into v_workspace_id, v_member_id
  from public.member_sessions where auth_user_id = auth.uid();
  if v_member_id is null then raise exception 'Join the team workspace first.'; end if;

  select coalesce(jsonb_agg(item order by created_at desc), '[]'::jsonb)
  into v_result
  from (
    select jsonb_build_object(
      'id', n.id,
      'type', n.notification_type,
      'title', n.title,
      'body', n.body,
      'entityType', n.entity_type,
      'entityId', n.entity_id,
      'createdAt', n.created_at,
      'readAt', n.read_at,
      'actorName', actor.name
    ) as item, n.created_at
    from public.notifications n
    left join public.members actor
      on actor.id = n.actor_member_id and actor.workspace_id = n.workspace_id
    where n.workspace_id = v_workspace_id
      and n.recipient_member_id = v_member_id
    order by n.created_at desc
    limit greatest(1, least(coalesce(p_limit, 30), 100))
  ) recent;

  return v_result;
end;
$$;

create or replace function public.mark_my_notification_read(p_notification_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_workspace_id uuid;
  v_member_id uuid;
  v_updated_id uuid;
begin
  select workspace_id, member_id into v_workspace_id, v_member_id
  from public.member_sessions where auth_user_id = auth.uid();
  if v_member_id is null then raise exception 'Join the team workspace first.'; end if;

  update public.notifications
  set read_at = coalesce(read_at, now())
  where id = p_notification_id
    and workspace_id = v_workspace_id
    and recipient_member_id = v_member_id
  returning id into v_updated_id;

  if v_updated_id is null then
    raise exception 'Notification not found for this member.';
  end if;
  return jsonb_build_object('notification_id', v_updated_id, 'read', true);
end;
$$;

revoke execute on function public.create_member_notification(uuid, uuid, uuid, text, text, text, text, uuid) from public, anon, authenticated;
revoke execute on function public.get_my_notifications(integer) from public, anon;
revoke execute on function public.mark_my_notification_read(uuid) from public, anon;
grant execute on function public.get_my_notifications(integer) to authenticated;
grant execute on function public.mark_my_notification_read(uuid) to authenticated;


-- Realtime SELECT is limited to the member mapped to the current anonymous auth session.
create policy notifications_select_own
  on public.notifications
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.member_sessions s
      where s.auth_user_id = auth.uid()
        and s.workspace_id = notifications.workspace_id
        and s.member_id = notifications.recipient_member_id
    )
  );
grant select on public.notifications to authenticated;

-- Supabase Realtime delivers only rows selected by the member-specific filter in the client.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'notifications'
  ) then
    alter publication supabase_realtime add table public.notifications;
  end if;
end;
$$;
