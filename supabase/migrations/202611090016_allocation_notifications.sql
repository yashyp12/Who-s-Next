-- Reliable in-app notifications for newly assigned work.
-- Additive migration: allocation order, eligibility, and shift rules are unchanged.

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  recipient_member_id uuid not null references public.members(id) on delete cascade,
  actor_member_id uuid references public.members(id) on delete set null,
  notification_type text not null,
  title text not null,
  body text not null,
  entity_type text,
  entity_id uuid,
  created_at timestamptz not null default now(),
  read_at timestamptz
);

-- Existing manually provisioned notification tables are upgraded additively as well.
alter table public.notifications
  add column if not exists actor_member_id uuid references public.members(id) on delete set null,
  add column if not exists entity_type text,
  add column if not exists entity_id uuid,
  add column if not exists read_at timestamptz;

create index if not exists idx_notifications_recipient_unread
  on public.notifications(recipient_member_id, created_at desc)
  where read_at is null;

alter table public.notifications enable row level security;
revoke all on public.notifications from anon;
grant select on public.notifications to authenticated;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname='public' and tablename='notifications'
      and policyname='Members read their own notifications'
  ) then
    create policy "Members read their own notifications"
      on public.notifications for select to authenticated
      using (exists (
        select 1 from public.member_sessions s
        where s.auth_user_id=auth.uid()
          and s.member_id=notifications.recipient_member_id
          and s.workspace_id=notifications.workspace_id
      ));
  end if;
end;
$$;

create or replace function public.get_my_notifications(p_limit integer default 30)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_workspace_id uuid; v_member_id uuid; v_result jsonb;
begin
  select workspace_id, member_id into v_workspace_id, v_member_id
  from public.member_sessions where auth_user_id=auth.uid();
  if v_member_id is null then raise exception 'Join the team workspace first.'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', n.id, 'type', n.notification_type, 'title', n.title, 'body', n.body,
    'entityType', n.entity_type, 'entityId', n.entity_id,
    'createdAt', n.created_at, 'readAt', n.read_at,
    'actorName', coalesce(actor.name, 'WHO’S next')
  ) order by n.created_at desc), '[]'::jsonb)
  into v_result
  from (
    select * from public.notifications
    where workspace_id=v_workspace_id and recipient_member_id=v_member_id
      and read_at is null
    order by created_at desc
    limit greatest(1, least(coalesce(p_limit,30),100))
  ) n
  left join public.members actor on actor.id=n.actor_member_id;
  return v_result;
end;
$$;

create or replace function public.mark_my_notification_read(p_notification_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_member_id uuid; v_count integer;
begin
  select member_id into v_member_id from public.member_sessions where auth_user_id=auth.uid();
  if v_member_id is null then raise exception 'Join the team workspace first.'; end if;
  update public.notifications set read_at=coalesce(read_at,now())
  where id=p_notification_id and recipient_member_id=v_member_id;
  get diagnostics v_count = row_count;
  if v_count=0 then raise exception 'Notification not found or access denied.'; end if;
  return jsonb_build_object('notification_id',p_notification_id,'read',true);
end;
$$;

create or replace function public.create_allocation_notification()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_actor_name text; v_body text;
begin
  select name into v_actor_name
  from public.members
  where id=new.assigned_by_member_id and workspace_id=new.workspace_id;

  v_body := coalesce(nullif(trim(new.email_subject),''), nullif(trim(new.reference),''), 'A new email has been assigned to you.');
  if nullif(trim(new.email_subject),'') is not null and nullif(trim(new.reference),'') is not null then
    v_body := trim(new.email_subject) || ' · ' || trim(new.reference);
  end if;

  insert into public.notifications(
    workspace_id, recipient_member_id, actor_member_id,
    notification_type, title, body, entity_type, entity_id, created_at
  ) values (
    new.workspace_id, new.recipient_member_id, new.assigned_by_member_id,
    'allocation_received', 'New email assigned to you',
    coalesce(v_actor_name,'A teammate') || ' assigned work to you: ' || v_body,
    'allocation', new.id, coalesce(new.assigned_at,now())
  );
  return new;
end;
$$;

drop trigger if exists trg_allocation_notification on public.allocations;
create trigger trg_allocation_notification
after insert on public.allocations
for each row execute function public.create_allocation_notification();

revoke execute on function public.get_my_notifications(integer) from public, anon;
grant execute on function public.get_my_notifications(integer) to authenticated;
revoke execute on function public.mark_my_notification_read(uuid) from public, anon;
grant execute on function public.mark_my_notification_read(uuid) to authenticated;
revoke execute on function public.create_allocation_notification() from public, anon, authenticated;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname='supabase_realtime' and schemaname='public' and tablename='notifications'
  ) then
    alter publication supabase_realtime add table public.notifications;
  end if;
end;
$$;
