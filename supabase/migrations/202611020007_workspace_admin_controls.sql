-- Workspace administration. Apply after migrations 001-005.
-- Bootstrap the first admin separately with the SQL snippet documented in the PR.

create table if not exists public.workspace_admins (
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  member_id uuid not null references public.members(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (workspace_id, member_id)
);
alter table public.workspace_admins enable row level security;
revoke all on public.workspace_admins from anon, authenticated;

create or replace function public.is_workspace_admin()
returns boolean
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.member_sessions s
    join public.workspace_admins a on a.workspace_id = s.workspace_id and a.member_id = s.member_id
    where s.auth_user_id = auth.uid()
  );
$$;

create or replace function public.get_my_member()
returns jsonb
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'member_id', m.id,
    'name', m.name,
    'workspace_id', w.id,
    'workspace_name', w.name,
    'is_admin', exists (
      select 1 from public.workspace_admins a
      where a.workspace_id = s.workspace_id and a.member_id = s.member_id
    )
  )
  from public.member_sessions s
  join public.members m on m.id = s.member_id
  join public.workspaces w on w.id = s.workspace_id
  where s.auth_user_id = auth.uid() and m.active = true
  limit 1;
$$;

create or replace function public.admin_list_members()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_workspace_id uuid; v_member_id uuid; v_result jsonb;
begin
  select workspace_id, member_id into v_workspace_id, v_member_id
  from public.member_sessions where auth_user_id = auth.uid();
  if v_member_id is null or not public.is_workspace_admin() then raise exception 'Workspace admin access required.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', m.id, 'name', m.name, 'active', m.active, 'sortOrder', m.sort_order,
    'accessCodeUpdatedAt', c.updated_at
  ) order by m.sort_order), '[]'::jsonb)
  into v_result
  from public.members m
  left join public.member_access_codes c on c.member_id = m.id and c.workspace_id = m.workspace_id
  where m.workspace_id = v_workspace_id;
  return v_result;
end;
$$;

create or replace function public.admin_create_member(p_name text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_workspace_id uuid; v_actor_id uuid; v_member_id uuid; v_code text; v_order integer;
begin
  select workspace_id, member_id into v_workspace_id, v_actor_id
  from public.member_sessions where auth_user_id = auth.uid();
  if v_actor_id is null or not public.is_workspace_admin() then raise exception 'Workspace admin access required.'; end if;
  if length(trim(coalesce(p_name,''))) < 2 or length(trim(p_name)) > 80 then raise exception 'Member name must be 2-80 characters.'; end if;
  if exists(select 1 from public.members where workspace_id=v_workspace_id and lower(name)=lower(trim(p_name))) then raise exception 'A member with this name already exists.'; end if;
  select coalesce(max(sort_order),0)+1 into v_order from public.members where workspace_id=v_workspace_id;
  insert into public.members(workspace_id,name,sort_order)
  values(v_workspace_id,trim(p_name),v_order) returning id into v_member_id;
  v_code := encode(extensions.gen_random_bytes(24),'hex');
  insert into public.member_access_codes(workspace_id,member_id,access_code_hash)
  values(v_workspace_id,v_member_id,encode(extensions.digest(v_code,'sha256'),'hex'));
  insert into public.audit_events(workspace_id,actor_member_id,event_type,summary,entity_type,entity_id)
  values(v_workspace_id,v_actor_id,'member_created','Added team member '||trim(p_name),'member',v_member_id);
  return jsonb_build_object('member_id',v_member_id,'name',trim(p_name),'access_code',v_code);
end;
$$;

create or replace function public.admin_rotate_member_access_code(p_member_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_workspace_id uuid; v_actor_id uuid; v_code text; v_name text;
begin
  select workspace_id, member_id into v_workspace_id, v_actor_id
  from public.member_sessions where auth_user_id = auth.uid();
  if v_actor_id is null or not public.is_workspace_admin() then raise exception 'Workspace admin access required.'; end if;
  select name into v_name from public.members where id=p_member_id and workspace_id=v_workspace_id and active;
  if v_name is null then raise exception 'Active member not found.'; end if;
  v_code := encode(extensions.gen_random_bytes(24),'hex');
  insert into public.member_access_codes(workspace_id,member_id,access_code_hash)
  values(v_workspace_id,p_member_id,encode(extensions.digest(v_code,'sha256'),'hex'))
  on conflict(member_id) do update set access_code_hash=excluded.access_code_hash,updated_at=now();
  delete from public.member_sessions where workspace_id=v_workspace_id and member_id=p_member_id and member_id<>v_actor_id;
  insert into public.audit_events(workspace_id,actor_member_id,event_type,summary,entity_type,entity_id)
  values(v_workspace_id,v_actor_id,'access_code_rotated','Rotated access code for '||v_name,'member',p_member_id);
  return jsonb_build_object('member_id',p_member_id,'name',v_name,'access_code',v_code);
end;
$$;

create or replace function public.admin_update_member(p_member_id uuid,p_name text,p_active boolean)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_workspace_id uuid; v_actor_id uuid; v_old_name text;
begin
  select workspace_id,member_id into v_workspace_id,v_actor_id
  from public.member_sessions where auth_user_id=auth.uid();
  if v_actor_id is null or not public.is_workspace_admin() then raise exception 'Workspace admin access required.'; end if;
  if length(trim(coalesce(p_name,'')))<2 or length(trim(p_name))>80 then raise exception 'Member name must be 2-80 characters.'; end if;
  select name into v_old_name from public.members where id=p_member_id and workspace_id=v_workspace_id;
  if v_old_name is null then raise exception 'Member not found.'; end if;
  if exists(select 1 from public.members where workspace_id=v_workspace_id and id<>p_member_id and lower(name)=lower(trim(p_name))) then raise exception 'Another member already uses this name.'; end if;
  update public.members set name=trim(p_name),active=p_active where id=p_member_id and workspace_id=v_workspace_id;
  if not p_active then
    if p_member_id = v_actor_id then raise exception 'You cannot deactivate your own active admin session.'; end if;
    if (select count(*) from public.workspace_admins a join public.members m on m.id=a.member_id and m.workspace_id=a.workspace_id where a.workspace_id=v_workspace_id and m.active) <= 1 and exists(select 1 from public.workspace_admins where workspace_id=v_workspace_id and member_id=p_member_id) then raise exception 'The last active admin cannot be deactivated.'; end if;
    delete from public.member_sessions where workspace_id=v_workspace_id and member_id=p_member_id;
    update public.allocation_state set current_assignee_id=null,updated_at=now() where workspace_id=v_workspace_id and current_assignee_id=p_member_id;
  end if;
  insert into public.audit_events(workspace_id,actor_member_id,event_type,summary,entity_type,entity_id)
  values(v_workspace_id,v_actor_id,'member_updated','Updated team member '||trim(p_name),'member',p_member_id);
  return jsonb_build_object('member_id',p_member_id,'name',trim(p_name),'active',p_active);
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
  return jsonb_build_object('shift_id', v_shift_id);
end;
$$;


revoke execute on function public.is_workspace_admin() from public, anon;
grant execute on function public.is_workspace_admin() to authenticated;
revoke execute on function public.admin_list_members() from public, anon;
grant execute on function public.admin_list_members() to authenticated;
revoke execute on function public.admin_create_member(text) from public, anon;
grant execute on function public.admin_create_member(text) to authenticated;
revoke execute on function public.admin_rotate_member_access_code(uuid) from public, anon;
grant execute on function public.admin_rotate_member_access_code(uuid) to authenticated;
revoke execute on function public.admin_update_member(uuid,text,boolean) from public, anon;
grant execute on function public.admin_update_member(uuid,text,boolean) to authenticated;
revoke execute on function public.admin_upsert_shift(uuid,date,text,time,time) from public, anon;
grant execute on function public.admin_upsert_shift(uuid,date,text,time,time) to authenticated;

-- One-time bootstrap after applying this migration:
-- insert into public.workspace_admins(workspace_id, member_id)
-- select m.workspace_id, m.id
-- from public.members m
-- where m.name = 'Yash Patil'
--   and m.active = true
--   and not exists (
--     select 1 from public.workspace_admins a
--     where a.workspace_id = m.workspace_id and a.member_id = m.id
--   );
