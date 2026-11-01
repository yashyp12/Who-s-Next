-- WHO'S next: replace shared workspace code + self-selected profile with one code per colleague.
-- Apply after 202611010001_initial_schema.sql. Existing profile mappings are cleared so every browser must rejoin with its member-specific code.
-- Each access code is hashed in Postgres; plaintext codes must never be committed.

create table if not exists public.member_access_codes (
  member_id uuid primary key references public.members(id) on delete cascade,
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  access_code_hash text not null unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.member_access_codes enable row level security;
revoke all on public.member_access_codes from anon, authenticated;

-- Force browsers using the old shared-code/profile-picker flow to prove their individual code.
delete from public.member_sessions;

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
  if p_access_code is null or length(trim(p_access_code)) < 16 then
    raise exception 'Enter your individual access code.';
  end if;

  select c.member_id, c.workspace_id, m.name
    into v_member_id, v_workspace_id, v_member_name
  from public.member_access_codes c
  join public.members m on m.id = c.member_id and m.workspace_id = c.workspace_id
  where c.access_code_hash = encode(extensions.digest(trim(p_access_code), 'sha256'), 'hex')
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

-- The old shared-code join flow is no longer exposed to clients.
revoke execute on function public.get_joinable_workspace(text) from public, anon, authenticated;
revoke execute on function public.join_workspace(text, uuid) from public, anon, authenticated;
revoke execute on function public.join_workspace(text) from public, anon;
grant execute on function public.join_workspace(text) to authenticated;
