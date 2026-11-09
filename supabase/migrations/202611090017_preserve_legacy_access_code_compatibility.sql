-- Preserve existing member records and access-code hashes while making login
-- compatible with both historical case-sensitive hashes and normalized hashes.
-- Apply after migrations 001-016. This migration changes only the RPC function;
-- it does not recreate, reseed, delete, or rewrite workspace/member data.

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
  v_raw_code text;
  v_normalized_code text;
begin
  if auth.uid() is null then
    raise exception 'A workspace session is required.';
  end if;

  v_raw_code := trim(coalesce(p_access_code, ''));
  v_normalized_code := lower(v_raw_code);

  if length(v_raw_code) < 8 or length(v_raw_code) > 200
     or v_raw_code !~ '^[A-Za-z0-9._-]+$' then
    raise exception 'Enter a valid individual access code (8-200 letters, numbers, dots, underscores or hyphens).';
  end if;

  -- New codes are stored as SHA-256(lower(code)). The raw-code digest is
  -- retained as a compatibility path for codes created before normalization.
  -- Both comparisons remain hash-only; plaintext codes are never stored.
  select c.member_id, c.workspace_id, m.name
    into v_member_id, v_workspace_id, v_member_name
  from public.member_access_codes c
  join public.members m
    on m.id = c.member_id
   and m.workspace_id = c.workspace_id
  where c.access_code_hash in (
    encode(extensions.digest(v_normalized_code, 'sha256'), 'hex'),
    encode(extensions.digest(v_raw_code, 'sha256'), 'hex')
  )
    and m.active = true
  limit 1;

  if v_member_id is null then
    raise exception 'This access code is not valid or the profile is inactive.';
  end if;

  insert into public.member_sessions(auth_user_id, workspace_id, member_id)
  values (auth.uid(), v_workspace_id, v_member_id)
  on conflict (auth_user_id) do update
    set workspace_id = excluded.workspace_id,
        member_id = excluded.member_id,
        updated_at = now();

  return jsonb_build_object(
    'workspace_id', v_workspace_id,
    'member_id', v_member_id,
    'member_name', v_member_name
  );
end;
$$;

revoke execute on function public.join_workspace(text) from public, anon;
grant execute on function public.join_workspace(text) to authenticated;
