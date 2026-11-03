-- Allow workspace admins to choose simple, memorable member access codes.
-- Apply after migrations 001-012. Codes remain SHA-256 hashed; plaintext is never stored.

create or replace function public.join_workspace(p_access_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_member_id uuid;
  v_workspace_id uuid;
  v_member_name text;
begin
  if auth.uid() is null then raise exception 'A workspace session is required.'; end if;
  if p_access_code is null or length(trim(p_access_code)) < 8 or length(trim(p_access_code)) > 40
     or trim(p_access_code) !~ '^[A-Za-z0-9._-]+$' then
    raise exception 'Enter a valid individual access code (8-40 letters, numbers, dots, underscores or hyphens).';
  end if;

  select c.member_id, c.workspace_id, m.name
    into v_member_id, v_workspace_id, v_member_name
  from public.member_access_codes c
  join public.members m on m.id = c.member_id and m.workspace_id = c.workspace_id
  where c.access_code_hash = encode(extensions.digest(lower(trim(p_access_code)), 'sha256'), 'hex')
    and m.active = true
  limit 1;

  if v_member_id is null then raise exception 'This access code is not valid or the profile is inactive.'; end if;

  insert into public.member_sessions(auth_user_id, workspace_id, member_id)
  values (auth.uid(), v_workspace_id, v_member_id)
  on conflict (auth_user_id) do update
    set workspace_id = excluded.workspace_id, member_id = excluded.member_id, updated_at = now();

  return jsonb_build_object(
    'workspace_id', v_workspace_id,
    'member_id', v_member_id,
    'member_name', v_member_name
  );
end;
$$;

create or replace function public.admin_set_member_access_code(p_member_id uuid, p_access_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_workspace_id uuid;
  v_actor_id uuid;
  v_member_name text;
  v_normalized_code text;
  v_code_hash text;
begin
  select workspace_id, member_id into v_workspace_id, v_actor_id
  from public.member_sessions
  where auth_user_id = auth.uid();

  if v_actor_id is null or not public.is_workspace_admin() then
    raise exception 'Workspace admin access required.';
  end if;

  v_normalized_code := lower(trim(coalesce(p_access_code, '')));
  if length(v_normalized_code) < 8 or length(v_normalized_code) > 40
     or v_normalized_code !~ '^[a-z0-9._-]+$' then
    raise exception 'Access code must be 8-40 characters using letters, numbers, dots, underscores or hyphens.';
  end if;

  select name into v_member_name
  from public.members
  where id = p_member_id and workspace_id = v_workspace_id and active = true;

  if v_member_name is null then
    raise exception 'Active member not found in this workspace.';
  end if;

  v_code_hash := encode(extensions.digest(v_normalized_code, 'sha256'), 'hex');

  if exists (
    select 1 from public.member_access_codes
    where workspace_id = v_workspace_id
      and access_code_hash = v_code_hash
      and member_id <> p_member_id
  ) then
    raise exception 'That access code is already assigned to another member. Choose a different code.';
  end if;

  insert into public.member_access_codes(workspace_id, member_id, access_code_hash)
  values (v_workspace_id, p_member_id, v_code_hash)
  on conflict (member_id) do update
    set access_code_hash = excluded.access_code_hash, updated_at = now();

  -- Revoke the old identity from every other browser/session immediately.
  delete from public.member_sessions
  where workspace_id = v_workspace_id
    and member_id = p_member_id
    and auth_user_id <> auth.uid();

  insert into public.audit_events(workspace_id, actor_member_id, event_type, summary, entity_type, entity_id)
  values (
    v_workspace_id, v_actor_id, 'access_code_updated',
    'Updated private access code for ' || v_member_name,
    'member', p_member_id
  );

  return jsonb_build_object('member_id', p_member_id, 'name', v_member_name);
end;
$$;

revoke execute on function public.join_workspace(text) from public, anon;
grant execute on function public.join_workspace(text) to authenticated;
revoke execute on function public.admin_set_member_access_code(uuid, text) from public, anon;
grant execute on function public.admin_set_member_access_code(uuid, text) to authenticated;
